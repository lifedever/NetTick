import Foundation

struct AppTotal: Identifiable {
    var identity: AppIdentity
    var bytes: Bytes
    var processCount: Int
    var id: String { identity.key }
}

/// 界面要的查询。都在 Recorder 的 dbQueue 上跑（经 Recorder.query）。
extension Database {

    func identities() -> [String: AppIdentity] {
        var out: [String: AppIdentity] = [:]
        prepare("SELECT key, name, kind, bundle_id, path FROM apps")?.rows { r in
            let key = r.string(0) ?? ""
            out[key] = AppIdentity(key: key, name: r.string(1) ?? key,
                                   kind: AppIdentity.Kind(rawValue: Int(r.int(2))) ?? .cli,
                                   bundleID: r.string(3), path: r.string(4) ?? "")
        }
        return out
    }

    /// 时间段内每个 App 的合计，按总量倒序。from / to 是含两端的 yyyy-MM-dd。
    func ranking(from: String, to: String) -> [AppTotal] {
        let ids = identities()
        var procCounts: [String: Int] = [:]
        prepare("SELECT app_key, COUNT(DISTINCT proc) FROM daily_proc WHERE day BETWEEN ? AND ? GROUP BY app_key")?
            .bind(from, to).rows { procCounts[$0.string(0) ?? ""] = Int($0.int(1)) }
        var out: [AppTotal] = []
        prepare("SELECT app_key, SUM(rx), SUM(tx) FROM daily WHERE day BETWEEN ? AND ? GROUP BY app_key")?
            .bind(from, to).rows { r in
                let key = r.string(0) ?? ""
                let id = ids[key] ?? AppIdentity(key: key, name: key, kind: .cli, bundleID: nil, path: "")
                out.append(AppTotal(identity: id, bytes: Bytes(rx: UInt64(r.int(1)), tx: UInt64(r.int(2))),
                                    processCount: procCounts[key] ?? 1))
            }
        let other = otherBytes(from: from, to: to)
        if other.total > 0 { out.append(AppTotal(identity: .other, bytes: other, processCount: 0)) }
        return out.sorted { $0.bytes.total > $1.bytes.total }
    }

    /// 每天网卡的量
    func ifaceDays(from: String, to: String) -> [String: Bytes] {
        var out: [String: Bytes] = [:]
        prepare("SELECT day, rx, tx FROM daily_if WHERE day BETWEEN ? AND ?")?.bind(from, to)
            .rows { out[$0.string(0) ?? ""] = Bytes(rx: UInt64($0.int(1)), tx: UInt64($0.int(2))) }
        return out
    }

    /// 每天「其他」的量：网卡减所有 App，按天、按方向各自不小于 0（没有网卡记录的老日子算 0）
    func otherDays(from: String, to: String) -> [String: Bytes] {
        let iface = ifaceDays(from: from, to: to)
        var apps: [String: Bytes] = [:]
        prepare("SELECT day, SUM(rx), SUM(tx) FROM daily WHERE day BETWEEN ? AND ? GROUP BY day")?.bind(from, to)
            .rows { apps[$0.string(0) ?? ""] = Bytes(rx: UInt64($0.int(1)), tx: UInt64($0.int(2))) }
        var out: [String: Bytes] = [:]
        for (day, i) in iface {
            let a = apps[day] ?? Bytes()
            out[day] = Bytes(rx: i.rx > a.rx ? i.rx - a.rx : 0, tx: i.tx > a.tx ? i.tx - a.tx : 0)
        }
        return out
    }

    func otherBytes(from: String, to: String) -> Bytes {
        otherDays(from: from, to: to).values.reduce(Bytes()) { var b = $0; b += $1; return b }
    }

    /// 每天的合计（所有 App 加起来，含「其他」）
    func dayTotals(from: String, to: String) -> [String: Bytes] {
        var out: [String: Bytes] = [:]
        prepare("SELECT day, SUM(rx), SUM(tx) FROM daily WHERE day BETWEEN ? AND ? GROUP BY day")?
            .bind(from, to).rows { out[$0.string(0) ?? ""] = Bytes(rx: UInt64($0.int(1)), tx: UInt64($0.int(2))) }
        for (day, o) in otherDays(from: from, to: to) { out[day, default: Bytes()] += o }
        return out
    }

    /// 某个 App 每天的量
    func appDays(app: String, from: String, to: String) -> [String: Bytes] {
        if app == AppIdentity.otherKey { return otherDays(from: from, to: to) }
        var out: [String: Bytes] = [:]
        prepare("SELECT day, rx, tx FROM daily WHERE app_key = ? AND day BETWEEN ? AND ?")?
            .bind(app, from, to).rows { out[$0.string(0) ?? ""] = Bytes(rx: UInt64($0.int(1)), tx: UInt64($0.int(2))) }
        return out
    }

    func processes(app: String, from: String, to: String) -> [(name: String, bytes: Bytes)] {
        var out: [(String, Bytes)] = []
        prepare("""
            SELECT proc, SUM(rx), SUM(tx) FROM daily_proc WHERE app_key = ? AND day BETWEEN ? AND ?
            GROUP BY proc ORDER BY SUM(rx) + SUM(tx) DESC
            """)?.bind(app, from, to).rows { out.append(($0.string(0) ?? "", Bytes(rx: UInt64($0.int(1)), tx: UInt64($0.int(2))))) }
        return out
    }

    /// 某天每小时的量（本地时间）。app 为 nil 时是物理网卡的总量。分钟明细只留 3 天，更早的返回全 0。
    func hourly(app: String?, day: String) -> [Bytes] {
        var out = [Bytes](repeating: Bytes(), count: 24)
        guard let start = Day.date(day), let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return out }
        let (a, b) = (Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
        let cal = Calendar.current
        let each: (Statement.Row) -> Void = { r in
            let h = cal.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(r.int(0))))
            out[h] += Bytes(rx: UInt64(r.int(1)), tx: UInt64(r.int(2)))
        }
        if app == AppIdentity.otherKey {
            // 其他 = 网卡 − 所有 App，按小时各自不小于 0
            let iface = hourly(app: nil, day: day)
            var apps = [Bytes](repeating: Bytes(), count: 24)
            prepare("SELECT ts, rx, tx FROM minute_app WHERE ts >= ? AND ts < ?")?.bind(a, b).rows { r in
                let h = cal.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(r.int(0))))
                apps[h] += Bytes(rx: UInt64(r.int(1)), tx: UInt64(r.int(2)))
            }
            return (0..<24).map { h in
                Bytes(rx: iface[h].rx > apps[h].rx ? iface[h].rx - apps[h].rx : 0,
                      tx: iface[h].tx > apps[h].tx ? iface[h].tx - apps[h].tx : 0)
            }
        }
        if let app {
            prepare("SELECT ts, rx, tx FROM minute_app WHERE app_key = ? AND ts >= ? AND ts < ?")?.bind(app, a, b).rows(each)
        } else {
            prepare("SELECT ts, rx, tx FROM minute_if WHERE ts >= ? AND ts < ?")?.bind(a, b).rows(each)
        }
        return out
    }

    /// 物理网卡每分钟的量
    func minuteSeries(from: Int, to: Int) -> [Int: Bytes] {
        var out: [Int: Bytes] = [:]
        prepare("SELECT ts, rx, tx FROM minute_if WHERE ts >= ? AND ts < ?")?.bind(from, to)
            .rows { out[Int($0.int(0))] = Bytes(rx: UInt64($0.int(1)), tx: UInt64($0.int(2))) }
        return out
    }

    /// 一段时间里各 App 的量（速率曲线点某一处时用）
    func appsBetween(from: Int, to: Int) -> [(key: String, bytes: Bytes)] {
        var out: [(String, Bytes)] = []
        prepare("SELECT app_key, SUM(rx), SUM(tx) FROM minute_app WHERE ts >= ? AND ts < ? GROUP BY app_key ORDER BY SUM(rx) + SUM(tx) DESC")?
            .bind(from, to).rows { out.append(($0.string(0) ?? "", Bytes(rx: UInt64($0.int(1)), tx: UInt64($0.int(2))))) }
        return out
    }

    /// 「开机以来」的排行：各 App + 「其他」（NetTick 运行期间分不出是谁的）+「NetTick 没运行时」，
    /// 加起来等于开机以来网卡的量。nicSinceBoot 是网卡现在的计数（从开机起累计）
    func bootRanking(boot: String, nicSinceBoot: Bytes?) -> [AppTotal] {
        let ids = identities()
        var apps: [String: Bytes] = [:]
        prepare("SELECT app_key, rx, tx FROM boot_app WHERE boot = ?")?.bind(boot)
            .rows { apps[$0.string(0) ?? ""] = Bytes(rx: UInt64($0.int(1)), tx: UInt64($0.int(2))) }
        var iface = Bytes()
        prepare("SELECT rx, tx FROM boot_if WHERE boot = ?")?.bind(boot)
            .rows { iface = Bytes(rx: UInt64($0.int(0)), tx: UInt64($0.int(1))) }
        // 进程数按开机那天起的每日明细数，开机那天开机前的也算在里面（只用来写「N 个进程」）
        var procCounts: [String: Int] = [:]
        prepare("SELECT app_key, COUNT(DISTINCT proc) FROM daily_proc WHERE day >= ? GROUP BY app_key")?
            .bind(Day.key(BootSession.bootTime)).rows { procCounts[$0.string(0) ?? ""] = Int($0.int(1)) }
        var out = apps.map { key, b in
            AppTotal(identity: ids[key] ?? AppIdentity(key: key, name: key, kind: .cli, bundleID: nil, path: ""),
                     bytes: b, processCount: procCounts[key] ?? 1)
        }
        let other = Recorder.gap(iface, apps)
        if other.total > 0 { out.append(AppTotal(identity: .other, bytes: other, processCount: 0)) }
        if let nic = nicSinceBoot {
            let missing = Bytes(rx: nic.rx > iface.rx ? nic.rx - iface.rx : 0, tx: nic.tx > iface.tx ? nic.tx - iface.tx : 0)
            if missing.total > 0 { out.append(AppTotal(identity: .unrecorded, bytes: missing, processCount: 0)) }
        }
        return out.sorted { $0.bytes.total > $1.bytes.total }
    }

    func firstDay() -> String? {
        var d: String?
        prepare("SELECT MIN(day) FROM daily")?.rows { d = $0.string(0) }
        return d
    }

    func metaValue(_ key: String) -> String? {
        var v: String?
        prepare("SELECT value FROM meta WHERE key = ?")?.bind(key).rows { v = $0.string(0) }
        return v
    }
}
