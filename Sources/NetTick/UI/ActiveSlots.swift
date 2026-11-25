import Foundation

/// 「正在用网」固定 3 行：行数不变，面板高度就不跳。
/// - 显示顺序见 `ordered`：有流量的在上，变灰的沉到下面；有流量的几行按进来的先后排、不按速率，
///   免得速率相近的两行每秒互换位置。
/// - 停了的 App 变灰，速率照实显示（多半是 0）；又用起来就亮回来、回到有流量的那组。
/// - 新 App 联网：先填空行，再顶替停了 3 秒以上、停得最久的那行。刚停的不让顶：
///   一阵一阵下载的 App（实测 java）掉到门槛下一两秒就会被顶走，回来又要抢，同一行换个不停。
/// - 3 行都在用（或刚停）：新 App 的速率是在用的最慢那行的 2 倍以上、且那行已经占了 3 秒，才顶替它。
///   不然大下载会被几个小流量挤在外面看不到；占满 3 秒的要求防止两个速率相近的 App 来回抢一行。
struct ActiveSlots {
    static let count = 3
    /// 低于这个速率算停了（变灰），也不会被顶上来
    static let threshold: Double = 1000
    /// 停了多久才让别的 App 顶替；也是被抢之前至少要占的时长
    static let hold: TimeInterval = 3

    struct Slot {
        var identity: AppIdentity
        var rx: Double          // 字节/秒
        var tx: Double
        var since: Date         // 占这一行的时间
        var lastActive: Date    // 最后一次过门槛的时间
        var isActive: Bool
        var seq: Int            // 进来的先后，排序时同一秒进来的靠它分先后
        var total: Double { rx + tx }
    }

    private(set) var slots: [Slot?] = Array(repeating: nil, count: count)
    private var nextSeq = 0

    var isEmpty: Bool { slots.allSatisfy { $0 == nil } }

    /// 显示顺序：有流量的在上（先进来的在前），变灰的在下（刚停的在前、最先被顶替的垫底），空行最后
    var ordered: [Slot?] {
        let taken = slots.compactMap { $0 }
        let active = taken.filter(\.isActive).sorted { $0.seq < $1.seq }
        let idle = taken.filter { !$0.isActive }
            .sorted { $0.lastActive != $1.lastActive ? $0.lastActive > $1.lastActive : $0.seq < $1.seq }
        let rows: [Slot?] = active + idle
        return rows + Array(repeating: nil, count: Self.count - rows.count)
    }

    mutating func update(_ rates: [Collector.AppRate], now: Date) {
        var byKey: [String: Collector.AppRate] = [:]
        for r in rates { byKey[r.identity.key] = r }

        for i in slots.indices {
            guard var s = slots[i] else { continue }
            let r = byKey[s.identity.key]
            s.rx = r?.rx ?? 0
            s.tx = r?.tx ?? 0
            s.isActive = s.total >= Self.threshold
            if s.isActive { s.lastActive = now }
            slots[i] = s
        }

        let shown = Set(slots.compactMap { $0?.identity.key })
        let candidates = rates
            .filter { $0.rx + $0.tx >= Self.threshold && !shown.contains($0.identity.key) }
            .sorted { $0.rx + $0.tx > $1.rx + $1.tx }
        for c in candidates {
            // 从快到慢排的：快的都没位置，慢的更没有
            guard let i = slotToTake(rate: c.rx + c.tx, now: now) else { break }
            slots[i] = Slot(identity: c.identity, rx: c.rx, tx: c.tx, since: now, lastActive: now, isActive: true, seq: nextSeq)
            nextSeq += 1
        }
    }

    private func slotToTake(rate: Double, now: Date) -> Int? {
        if let i = slots.firstIndex(where: { $0 == nil }) { return i }
        let taken = slots.indices.compactMap { i in slots[i].map { (i, $0) } }
        if let idle = taken.filter({ !$0.1.isActive && now.timeIntervalSince($0.1.lastActive) >= Self.hold })
                           .min(by: { $0.1.lastActive < $1.1.lastActive }) {
            return idle.0
        }
        guard let slowest = taken.filter({ $0.1.isActive }).min(by: { $0.1.total < $1.1.total }),
              rate >= 2 * slowest.1.total,
              now.timeIntervalSince(slowest.1.since) >= Self.hold else { return nil }
        return slowest.0
    }
}
