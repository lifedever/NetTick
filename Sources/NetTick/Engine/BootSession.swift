import Darwin
import Foundation

/// 这次开机：标识和开机时间。「开机以来」的统计按它分。
///
/// 标识用 kern.bootsessionuuid：kern.boottime 会随系统校时挪几秒，不能当键。
/// 物理网卡的计数从开机起累计，休眠唤醒不清零（2026-11-25 实测：开机后休眠 94 次、过了一夜，
/// en0 的计数仍是开机以来的量），所以「开机以来的总量」直接读网卡计数，NetTick 没运行的时段也算在内。
enum BootSession {
    static let bootTime: Date = {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }()

    static let id: String = sysctlString("kern.bootsessionuuid") ?? "boot-\(Int(bootTime.timeIntervalSince1970))"

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buf)
        return s.isEmpty ? nil : s
    }
}
