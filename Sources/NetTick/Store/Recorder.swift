import Foundation

struct Bytes: Equatable {
    var rx: UInt64 = 0
    var tx: UInt64 = 0
    var total: UInt64 { rx &+ tx }
    static func += (l: inout Bytes, r: Bytes) { l.rx &+= r.rx; l.tx &+= r.tx }
}

/// 把采集到的字节记下来：内存里先累加，每分钟写一次库。
///
/// 线程：add / addInterface / tick 只在采集队列（engine）上调用；写库和所有查询在 dbQueue 上。
/// 查询前会先把内存里还没写的部分写进去，界面看到的永远是最新的。
/// 线程安全靠队列：内存状态只在 engine 队列上改，库只在 dbQueue 上读写。
final class Recorder: @unchecked Sendable {

    let db: Database
    let engine: DispatchQueue
    private let dbQueue = DispatchQueue(label: "com.lifedever.NetTick.db", qos: .utility)

    // MARK: 采集队列上的状态

    private struct DayApp: Hashable { var day: String; var app: String }
    private struct DayAppProc: Hashable { var day: String; var app: String; var proc: String }
    private struct MinApp: Hashable { var ts: Int; var app: String }

    private var pendingDaily: [DayApp: Bytes] = [:]
    private var pendingProc: [DayAppProc: Bytes] = [:]
    private var pendingMinuteIf: [Int: Bytes] = [:]
    private var pendingDailyIf: [String: Bytes] = [:]
    private var pendingMinuteApp: [MinApp: Bytes] = [:]
    private var pendingApps: [String: AppIdentity] = [:]
    private var lastAppSave: [String: Date] = [:]

    /// 今天每个 App 的累计（面板直接用，不查库）
    private(set) var today = Day.key()
    private(set) var todayTotals: [String: Bytes] = [:]
    /// 今天物理网卡的合计（App 合计以外的部分算「其他」）
    private(set) var todayIface = Bytes()
    private(set) var identities: [String: AppIdentity] = [:]

    /// 最近 1 小时，10 秒一格（速率曲线的「1 小时」用）
    struct Bucket {
        var start: Int
        var iface = Bytes()
        var apps: [String: Bytes] = [:]
    }
    private(set) var buckets: [Bucket] = []

    private var knownKeys: Set<String> = []
    private var learnUntil: Double = 0
    /// 新 App 第一次出现（且已过学习期）时在采集队列上回调
    var onNewApp: ((AppIdentity) -> Void)?

    private(set) var firstLaunch: Double = Date().timeIntervalSince1970

    init(db: Database, engine: DispatchQueue) {
        self.db = db
        self.engine = engine
        loadState()
    }

    /// 启动时：今天的累计、认识的 App、首次启动时间、学习期
    private func loadState() {
        let now = Date().timeIntervalSince1970
        db.prepare("SELECT key, name, kind, bundle_id, path FROM apps")?.rows { r in
            let key = r.string(0) ?? ""
            knownKeys.insert(key)
            identities[key] = AppIdentity(key: key, name: r.string(1) ?? key,
                                          kind: AppIdentity.Kind(rawValue: Int(r.int(2))) ?? .cli,
                                          bundleID: r.string(3), path: r.string(4) ?? "")
        }
        db.prepare("SELECT rx, tx FROM daily_if WHERE day = ?")?.bind(today).rows { r in
            todayIface = Bytes(rx: UInt64(r.int(0)), tx: UInt64(r.int(1)))
        }
        db.prepare("SELECT app_key, rx, tx FROM daily WHERE day = ?")?.bind(today).rows { r in
            todayTotals[r.string(0) ?? ""] = Bytes(rx: UInt64(r.int(1)), tx: UInt64(r.int(2)))
        }
        if let v = meta("first_launch"), let d = Double(v) {
            firstLaunch = d
        } else {
            setMeta("first_launch", String(now))
            firstLaunch = now
        }
        // 刚装好的头两小时：见到的 App 都是「第一次」，不通知，只记下来
        if let v = meta("learn_until"), let d = Double(v) {
            learnUntil = d
        } else {
            learnUntil = now + 2 * 3600
            setMeta("learn_until", String(learnUntil))
        }
        log("库已打开：认识 \(knownKeys.count) 个 App，今天已有 \(todayTotals.count) 个")
    }

    private func meta(_ key: String) -> String? {
        var v: String?
        db.prepare("SELECT value FROM meta WHERE key = ?")?.bind(key).rows { v = $0.string(0) }
        return v
    }

    private func setMeta(_ key: String, _ value: String) {
        db.prepare("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")?
            .bind(key, value).run()
    }

    // MARK: - 采集队列入口

    func add(_ id: AppIdentity, proc: String, _ b: Bytes, at now: Date) {
        guard b.total > 0 else { return }
        rollDayIfNeeded(now)
        let t = Int(now.timeIntervalSince1970)
        pendingDaily[DayApp(day: today, app: id.key), default: Bytes()] += b
        pendingProc[DayAppProc(day: today, app: id.key, proc: proc), default: Bytes()] += b
        pendingMinuteApp[MinApp(ts: t / 60 * 60, app: id.key), default: Bytes()] += b
        todayTotals[id.key, default: Bytes()] += b
        buckets[bucketIndex(at: t)].apps[id.key, default: Bytes()] += b

        if identities[id.key] == nil || identities[id.key] != id { identities[id.key] = id }
        // 名字、路径偶尔会变（App 升级、换位置），每个 App 十分钟最多写一次 apps 表
        if lastAppSave[id.key].map({ now.timeIntervalSince($0) > 600 }) ?? true {
            pendingApps[id.key] = id
            lastAppSave[id.key] = now
        }
        if !knownKeys.contains(id.key) {
            knownKeys.insert(id.key)
            if id.kind != .system, now.timeIntervalSince1970 > learnUntil {
                onNewApp?(id)
            }
        }
    }

    func addInterface(_ b: Bytes, at now: Date) {
        let t = Int(now.timeIntervalSince1970)
        rollDayIfNeeded(now)
        pendingMinuteIf[t / 60 * 60, default: Bytes()] += b
        pendingDailyIf[today, default: Bytes()] += b
        todayIface += b
        buckets[bucketIndex(at: t)].iface += b
    }

    /// 当前 10 秒格的下标（没有就新建一格，顺手丢掉一小时以前的）
    private func bucketIndex(at t: Int) -> Int {
        let start = t / 10 * 10
        if let last = buckets.last, last.start == start { return buckets.count - 1 }
        if let last = buckets.last, last.start > start {
            // 系统时间往回拨了：找到对应的格，找不到就记进最后一格
            return buckets.lastIndex(where: { $0.start <= start }) ?? buckets.count - 1
        }
        buckets.append(Bucket(start: start))
        let cutoff = start - 3600
        if let firstKeep = buckets.firstIndex(where: { $0.start > cutoff }), firstKeep > 0 {
            buckets.removeFirst(firstKeep)
        }
        return buckets.count - 1
    }

    private func rollDayIfNeeded(_ now: Date) {
        let d = Day.key(now)
        if d != today {
            today = d
            todayTotals = [:]
            todayIface = Bytes()
        }
    }

    // MARK: - 写库

    private struct Pending {
        var daily: [DayApp: Bytes]
        var proc: [DayAppProc: Bytes]
        var minuteIf: [Int: Bytes]
        var dailyIf: [String: Bytes]
        var minuteApp: [MinApp: Bytes]
        var apps: [String: AppIdentity]
        var isEmpty: Bool { daily.isEmpty && proc.isEmpty && minuteIf.isEmpty && dailyIf.isEmpty && minuteApp.isEmpty && apps.isEmpty }
    }

    /// 采集队列上调用：取走内存里的增量
    private func takePending() -> Pending {
        let p = Pending(daily: pendingDaily, proc: pendingProc, minuteIf: pendingMinuteIf, dailyIf: pendingDailyIf,
                        minuteApp: pendingMinuteApp, apps: pendingApps)
        pendingDaily = [:]; pendingProc = [:]; pendingMinuteIf = [:]; pendingDailyIf = [:]; pendingMinuteApp = [:]; pendingApps = [:]
        return p
    }

    private var lastPrune = Date.distantPast

    /// dbQueue 上执行
    private func write(_ p: Pending) {
        guard !p.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        db.transaction {
            if let s = db.prepare("""
                INSERT INTO daily(day, app_key, rx, tx) VALUES(?, ?, ?, ?)
                ON CONFLICT(day, app_key) DO UPDATE SET rx = rx + excluded.rx, tx = tx + excluded.tx
                """) {
                for (k, b) in p.daily { s.bind(k.day, k.app, b.rx, b.tx).run() }
            }
            if let s = db.prepare("""
                INSERT INTO daily_proc(day, app_key, proc, rx, tx) VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(day, app_key, proc) DO UPDATE SET rx = rx + excluded.rx, tx = tx + excluded.tx
                """) {
                for (k, b) in p.proc { s.bind(k.day, k.app, k.proc, b.rx, b.tx).run() }
            }
            if let s = db.prepare("""
                INSERT INTO minute_if(ts, rx, tx) VALUES(?, ?, ?)
                ON CONFLICT(ts) DO UPDATE SET rx = rx + excluded.rx, tx = tx + excluded.tx
                """) {
                for (ts, b) in p.minuteIf { s.bind(ts, b.rx, b.tx).run() }
            }
            if let s = db.prepare("""
                INSERT INTO daily_if(day, rx, tx) VALUES(?, ?, ?)
                ON CONFLICT(day) DO UPDATE SET rx = rx + excluded.rx, tx = tx + excluded.tx
                """) {
                for (day, b) in p.dailyIf { s.bind(day, b.rx, b.tx).run() }
            }
            if let s = db.prepare("""
                INSERT INTO minute_app(ts, app_key, rx, tx) VALUES(?, ?, ?, ?)
                ON CONFLICT(ts, app_key) DO UPDATE SET rx = rx + excluded.rx, tx = tx + excluded.tx
                """) {
                for (k, b) in p.minuteApp { s.bind(k.ts, k.app, b.rx, b.tx).run() }
            }
            if let s = db.prepare("""
                INSERT INTO apps(key, name, kind, bundle_id, path, first_seen, last_seen) VALUES(?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET name = excluded.name, kind = excluded.kind,
                    bundle_id = excluded.bundle_id, path = excluded.path, last_seen = excluded.last_seen
                """) {
                for (_, id) in p.apps { s.bind(id.key, id.name, id.kind.rawValue, id.bundleID, id.path, now, now).run() }
            }
        }
        // 分钟级明细只留 3 天（24 小时曲线和「每小时」够用），一小时清一次
        if Date().timeIntervalSince(lastPrune) > 3600 {
            lastPrune = Date()
            let cutoff = Int(now) - 3 * 86400
            db.prepare("DELETE FROM minute_if WHERE ts < ?")?.bind(cutoff).run()
            db.prepare("DELETE FROM minute_app WHERE ts < ?")?.bind(cutoff).run()
        }
    }

    /// 定时（每分钟）和退出前调用。采集队列上调用；wait = true 时等写完（退出用）。
    func flush(wait: Bool = false) {
        let p = takePending()
        if wait {
            dbQueue.sync { write(p) }
        } else {
            dbQueue.async { self.write(p) }
        }
    }

    /// 界面查询：先把内存里的增量写进库，再在 dbQueue 上查，结果回主线程。
    func query<T>(_ work: @escaping (Database) -> T, completion: @escaping (T) -> Void) {
        engine.async {
            let p = self.takePending()
            self.dbQueue.async {
                self.write(p)
                let r = work(self.db)
                DispatchQueue.main.async { completion(r) }
            }
        }
    }
}
