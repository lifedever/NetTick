import Foundation
import SQLite3

/// 极薄的 SQLite 封装。只在 Recorder 的数据库队列上用。
final class Database: @unchecked Sendable {   // 只在 Recorder 的 dbQueue 上用

    private var db: OpaquePointer?
    let url: URL

    /// 库放在 Application Support/<bundle id>/ 下（别放根目录，和别的 App 撞名）
    static func defaultURL() -> URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lifedever.NetTick"
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nettick.sqlite")
    }

    init(url: URL) throws {
        self.url = url
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw NSError(domain: "NetTick.DB", code: 1, userInfo: [NSLocalizedDescriptionKey: "打不开数据库 \(url.path)"])
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try migrate()
    }

    deinit { sqlite3_close_v2(db) }

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS apps(
            key TEXT PRIMARY KEY, name TEXT NOT NULL, kind INTEGER NOT NULL,
            bundle_id TEXT, path TEXT, first_seen REAL NOT NULL, last_seen REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS daily(
            day TEXT NOT NULL, app_key TEXT NOT NULL,
            rx INTEGER NOT NULL DEFAULT 0, tx INTEGER NOT NULL DEFAULT 0,
            rx_proxy INTEGER NOT NULL DEFAULT 0, tx_proxy INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(day, app_key));
        CREATE TABLE IF NOT EXISTS daily_proc(
            day TEXT NOT NULL, app_key TEXT NOT NULL, proc TEXT NOT NULL,
            rx INTEGER NOT NULL DEFAULT 0, tx INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(day, app_key, proc));
        CREATE TABLE IF NOT EXISTS minute_if(ts INTEGER PRIMARY KEY, rx INTEGER NOT NULL, tx INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS daily_if(day TEXT PRIMARY KEY, rx INTEGER NOT NULL DEFAULT 0, tx INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS minute_app(
            ts INTEGER NOT NULL, app_key TEXT NOT NULL, rx INTEGER NOT NULL, tx INTEGER NOT NULL,
            PRIMARY KEY(ts, app_key));
        """)
        // 老库升级：daily_if 是后加的，用还在的分钟数据把这几天补上（分钟数据只留 3 天）
        var n = 0
        prepare("SELECT COUNT(*) FROM daily_if")?.rows { n = Int($0.int(0)) }
        if n == 0 {
            var byDay: [String: (Int64, Int64)] = [:]
            prepare("SELECT ts, rx, tx FROM minute_if")?.rows { r in
                let day = Day.key(Date(timeIntervalSince1970: TimeInterval(r.int(0))))
                let cur = byDay[day] ?? (0, 0)
                byDay[day] = (cur.0 + r.int(1), cur.1 + r.int(2))
            }
            for (day, v) in byDay {
                prepare("INSERT OR REPLACE INTO daily_if(day, rx, tx) VALUES(?, ?, ?)")?.bind(day, v.0, v.1).run()
            }
        }
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(err)
            throw NSError(domain: "NetTick.DB", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    func prepare(_ sql: String) -> Statement? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            log("SQL 预编译失败：\(String(cString: sqlite3_errmsg(db))) —— \(sql.prefix(80))")
            return nil
        }
        return Statement(stmt)
    }

    func transaction(_ body: () -> Void) {
        try? exec("BEGIN IMMEDIATE")
        body()
        do { try exec("COMMIT") } catch { log("提交失败：\(error.localizedDescription)"); try? exec("ROLLBACK") }
    }

    var fileSize: Int64 {
        let fm = FileManager.default
        return [url.path, url.path + "-wal", url.path + "-shm"].reduce(0) { sum, p in
            sum + ((try? fm.attributesOfItem(atPath: p)[.size] as? Int64) ?? 0)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Statement {
    private let stmt: OpaquePointer
    init(_ stmt: OpaquePointer) { self.stmt = stmt }
    deinit { sqlite3_finalize(stmt) }

    @discardableResult
    func bind(_ values: Any?...) -> Statement {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case nil: sqlite3_bind_null(stmt, idx)
            case let x as Int: sqlite3_bind_int64(stmt, idx, Int64(x))
            case let x as Int64: sqlite3_bind_int64(stmt, idx, x)
            case let x as UInt64: sqlite3_bind_int64(stmt, idx, Int64(clamping: x))
            case let x as Double: sqlite3_bind_double(stmt, idx, x)
            case let x as String: sqlite3_bind_text(stmt, idx, x, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return self
    }

    /// 执行不返回行的语句
    func run() {
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            log("SQL 执行失败（\(rc)）")
        }
    }

    /// 逐行回调
    func rows(_ each: (Row) -> Void) {
        while sqlite3_step(stmt) == SQLITE_ROW {
            each(Row(stmt: stmt))
        }
    }

    struct Row {
        let stmt: OpaquePointer
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func string(_ i: Int32) -> String? {
            guard let p = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: p)
        }
    }
}
