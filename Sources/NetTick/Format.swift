import Foundation

/// 字节和速率的显示格式。十进制（1 KB = 1000 B），和访达一致；三位有效数字，末尾的 0 去掉。
enum Fmt {
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    /// 拆成数字和单位，菜单栏三列对齐要分开画。
    static func parts(_ value: Double) -> (number: String, unit: String) {
        var v = max(0, value)
        var i = 0
        while v >= 999.5 && i < units.count - 1 {
            v /= 1000
            i += 1
        }
        if i == 0 { return (String(Int(v.rounded())), units[0]) }
        let s: String
        if v >= 99.95 { s = String(format: "%.0f", v) }
        else if v >= 9.995 { s = String(format: "%.1f", v) }
        else { s = String(format: "%.2f", v) }
        return (trimZeros(s), units[i])
    }

    static func bytes(_ value: Double) -> String {
        let p = parts(value)
        return "\(p.number) \(p.unit)"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let p = parts(bytesPerSecond)
        return "\(p.number) \(p.unit)/s"
    }

    static func percent(_ x: Double) -> String {
        "\(Int((x * 100).rounded()))%"
    }

    private static func trimZeros(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
}

/// 本地日历的「天」，存库和查询都用 yyyy-MM-dd。
enum Day {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ date: Date = Date()) -> String { formatter.string(from: date) }
    static func date(_ key: String) -> Date? { formatter.date(from: key) }

    /// 往前 / 往后数 n 天
    static func offset(_ key: String, _ days: Int) -> String {
        guard let d = date(key), let r = Calendar.current.date(byAdding: .day, value: days, to: d) else { return key }
        return self.key(r)
    }
}
