import Foundation

/// 采集：每秒读一次物理网卡（菜单栏速率），每 2 秒问一次系统各条连接的计数，按 App 记账。
///
/// 计哪些连接：
/// - App 直接走网卡的、走虚拟网卡（TUN 模式进代理软件）的 —— 都是这个 App 自己的流量；
/// - App 连本机系统代理端口的（系统代理模式）—— 也算，否则 Chrome 这类走系统代理的 App 一点流量都没有；
/// - 其他本机回环（进程间通信）不算；
/// - 代理软件自己的连接不算：它转发的就是上面那些 App 的流量，再算一遍是双倍。
final class Collector: @unchecked Sendable {   // 状态只在 queue 上改

    /// 采集队列：和 Recorder 共用一条串行队列（Recorder 的内存状态只在这上面改）
    let queue: DispatchQueue
    let recorder: Recorder
    private let nstat: NStat
    private let resolver = AppResolver()
    private let proxy = ProxyDetector()
    private let launchedAt = Date().timeIntervalSince1970

    private struct Flow {
        var identity: AppIdentity?
        var pid = 0
        var proc = ""
        var counted = false            // 这条要不要记账（描述到了才知道）
        var described = false
        var baselineSet = false
        var lastRx: UInt64 = 0
        var lastTx: UInt64 = 0
        var pendingRx: UInt64 = 0      // 描述还没到时先攒着的累计值
        var pendingTx: UInt64 = 0
        var hasPending = false
        var firstSeen = Date().timeIntervalSince1970
        var start: Double?
    }
    private var flows: [Int: Flow] = [:]
    /// 在系统代理端口上接连接的进程
    private var proxyPids: Set<Int> = []

    // 实时
    private var lastIface: InterfaceCounters.Totals?
    private var lastIfaceAt = Date()
    /// 每秒一格的按 App 增量，「正在用网」取最近 3 秒（不靠「上一轮问计数」的时间窗，免得和顶上的总速率对不上）
    private var secondBuckets: [Int: [String: Bytes]] = [:]
    private var lastPollAt = Date()
    /// 面板开着时每秒问一次计数，「正在用网」跟得上；关着时 2 秒一次省 CPU。只在采集队列上读写
    private var fastPolling = false
    private var ifaceAtLastPoll: UInt64 = 0
    private var tickCount = 0

    struct AppRate {
        var identity: AppIdentity
        var rx: Double   // 字节/秒
        var tx: Double
    }

    /// 发给界面的快照
    struct Live {
        var rx: Double = 0                     // 物理网卡，字节/秒
        var tx: Double = 0
        var history: [Bytes] = []              // 最近 60 秒，每秒一格（字节/秒）
        var active: [AppRate] = []             // 正在用网的 App，按速率排
        var today: [(AppIdentity, Bytes)] = [] // 今天各 App
        var available = true                   // 按 App 统计能不能用（私有框架加载失败时 false）
    }
    private var history: [Bytes] = []
    private var active: [AppRate] = []
    private(set) var statsAvailable = false

    /// 每秒在主线程回调一次
    var onLive: ((Live) -> Void)?

    init(recorder: Recorder) {
        self.recorder = recorder
        self.queue = recorder.engine
        self.nstat = NStat(queue: recorder.engine)
    }

    func start() {
        queue.async { [self] in
            nstat.onDescription = { [weak self] id, d in self?.describe(id, d) }
            nstat.onCounts = { [weak self] id, rx, tx in self?.counts(id, rx, tx) }
            nstat.onRemoved = { [weak self] id in self?.flows.removeValue(forKey: id) }
            // 先认出代理软件再订阅：不然启动头几百毫秒推上来的连接里，代理软件自己的会被当成普通 App 记账
            proxy.apply(ProxyDetector.probe())
            statsAvailable = nstat.start()
            lastIface = InterfaceCounters.read()
            lastIfaceAt = Date()
        }
        refreshProxy()


        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }
    private var timer: DispatchSourceTimer?

    /// 代理设置变了也要能跟上：每分钟重新认一次
    private func refreshProxy() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snap = ProxyDetector.probe()
            self?.queue.async {
                guard let self else { return }
                if snap.ports != self.proxy.snapshot.ports || snap.vpnBundleIDs != self.proxy.snapshot.vpnBundleIDs {
                    log("代理：系统代理端口 \(snap.ports.sorted())，已连接的 VPN 服务 \(snap.vpnBundleIDs)")
                }
                self.proxy.apply(snap)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [weak self] in self?.refreshProxy() }
    }

    // MARK: - 每秒

    private func tick() {
        let now = Date()
        // 物理网卡
        if let cur = InterfaceCounters.read() {
            if let last = lastIface {
                let dt = max(0.2, now.timeIntervalSince(lastIfaceAt))
                // 网卡重置（休眠唤醒、插拔）时计数会变小，这一秒按 0 算
                let d = Bytes(rx: cur.rx >= last.rx ? cur.rx - last.rx : 0, tx: cur.tx >= last.tx ? cur.tx - last.tx : 0)
                recorder.addInterface(d, at: now)
                history.append(Bytes(rx: UInt64(Double(d.rx) / dt), tx: UInt64(Double(d.tx) / dt)))
                if history.count > 60 { history.removeFirst(history.count - 60) }
            }
            lastIface = cur
            lastIfaceAt = now
        }
        // 每 2 秒问一次连接计数 —— 但网卡这段时间几乎没动就不问：每问一次系统要给几百条连接各造一个字典，
        // 是采集最大的开销（2026-11-24 采样），没流量时也没东西可分。最多 10 秒强制问一次兜底。
        tickCount += 1
        if let cur = lastIface {
            let moved = (cur.rx &+ cur.tx) &- ifaceAtLastPoll
            let due = (fastPolling || tickCount % 2 == 0) && moved > 2048
            let forced = Date().timeIntervalSince(lastPollAt) >= 10
            if statsAvailable && (due || forced) {
                ifaceAtLastPoll = cur.rx &+ cur.tx
                nstat.poll { [weak self] in self?.pollFinished() }
            }
        }
        // 每分钟写一次库
        if tickCount % 60 == 0 {
            recorder.flush()
        }
        publish()
    }

    private var lastSweep = Date()

    private func pollFinished() {
        let now = Date()
        // 只收到计数、一直没收到描述的源（极少数），一分钟后丢掉，免得越攒越多
        if now.timeIntervalSince(lastSweep) > 60 {
            lastSweep = now
            let cutoff = now.timeIntervalSince1970 - 60
            flows = flows.filter { $0.value.described || $0.value.firstSeen > cutoff }
        }
        let dt = max(0.5, now.timeIntervalSince(lastPollAt))
        lastPollAt = now
        _ = dt
    }

    /// 最近 3 秒各 App 的平均速率；网卡比各 App 明显多出一截时补一行「其他」
    private func computeActive(now: Date) {
        let sec = Int(now.timeIntervalSince1970)
        secondBuckets = secondBuckets.filter { $0.key > sec - 6 }
        func sum(_ window: Int) -> [String: Bytes] {
            var out: [String: Bytes] = [:]
            for (s, apps) in secondBuckets where s > sec - window { for (k, b) in apps { out[k, default: Bytes()] += b } }
            return out
        }
        var rates = sum(3).compactMap { key, b -> AppRate? in
            guard let id = recorder.identities[key] else { return nil }
            return AppRate(identity: id, rx: Double(b.rx) / 3, tx: Double(b.tx) / 3)
        }
        // 「其他」：root 等系统账户的进程（比如系统更新）在用网，看不到是谁；列出来免得菜单栏在跳、列表却是空的。
        // 用 5 秒平均来比：网卡计数和各 App 的计数前后差一两秒，3 秒窗口里流量一起伏就对不齐，
        // 只有 Chrome 在稳定下载时会冒出一行假的「其他」（2026-11-24 实测）。门槛：多出 10 KB/s 且占网卡三成以上
        let recent = history.suffix(5)
        if recent.count >= 3 {
            let n = Double(recent.count)
            let nicRx = Double(recent.reduce(0) { $0 + $1.rx }) / n, nicTx = Double(recent.reduce(0) { $0 + $1.tx }) / n
            let apps5 = sum(5).values.reduce(Bytes()) { var x = $0; x += $1; return x }
            let oRx = max(0, nicRx - Double(apps5.rx) / 5), oTx = max(0, nicTx - Double(apps5.tx) / 5)
            if oRx + oTx >= 10_000, oRx + oTx >= 0.3 * (nicRx + nicTx) {
                rates.append(AppRate(identity: .other, rx: oRx, tx: oTx))
            }
        }
        active = rates.sorted { $0.rx + $0.tx > $1.rx + $1.tx }
    }

    /// 面板打开 / 关上时调用（任意线程）
    func setFastPolling(_ on: Bool) {
        queue.async { self.fastPolling = on }
    }

    private func publish() {
        computeActive(now: Date())
        guard let onLive else { return }
        var live = Live()
        live.rx = Double(history.last?.rx ?? 0)
        live.tx = Double(history.last?.tx ?? 0)
        live.history = history
        live.active = active
        var today: [(AppIdentity, Bytes)] = recorder.todayTotals.compactMap { key, b in
            recorder.identities[key].map { ($0, b) }
        }
        let apps = recorder.todayTotals.values.reduce(Bytes()) { var x = $0; x += $1; return x }
        let iface = recorder.todayIface
        let other = Bytes(rx: iface.rx > apps.rx ? iface.rx - apps.rx : 0, tx: iface.tx > apps.tx ? iface.tx - apps.tx : 0)
        if other.total > 0 { today.append((.other, other)) }
        live.today = today.sorted { $0.1.total > $1.1.total }
        live.available = statsAvailable
        DispatchQueue.main.async { onLive(live) }
    }

    // MARK: - 连接

    private func describe(_ id: Int, _ d: NStat.Description) {
        var f = flows[id] ?? Flow()
        if f.described { flows[id] = f; return }   // 描述只在第一次时用
        f.described = true
        f.start = d.start

        let ifName = interfaceName(d.interfaceIndex)
        let local = splitHostPort(d.local), remote = splitHostPort(d.remote)
        let loopback = ifName == "lo0" || isLoopbackHost(remote.host) || isLoopbackHost(local.host)
        let ports = proxy.snapshot.ports
        if loopback, ports.contains(local.port), !proxyPids.contains(d.pid) {
            // 这一端是代理软件在接连接。它之前被当成普通 App 的连接也一并不算了
            proxyPids.insert(d.pid)
            for (k, var other) in flows where other.pid == d.pid && other.counted {
                other.counted = false
                flows[k] = other
            }
        }
        let (identity, proc) = resolver.resolve(pid: d.pid, epid: d.epid, processName: d.processName)
        let isProxy = proxyPids.contains(d.pid) || proxy.isProxyApp(identity, exePath: resolver.executablePath(pid: d.pid))
        let toSystemProxy = loopback && ports.contains(remote.port)

        f.identity = identity
        f.pid = d.pid
        f.proc = proc
        f.counted = !isProxy && (!loopback || toSystemProxy)
        flows[id] = f

        if f.hasPending {
            counts(id, f.pendingRx, f.pendingTx)
        }
    }

    private func counts(_ id: Int, _ rx: UInt64, _ tx: UInt64) {
        var f = flows[id] ?? Flow()
        guard f.described else {
            // 描述还没到，先攒着，到了再算
            f.pendingRx = rx; f.pendingTx = tx; f.hasPending = true
            flows[id] = f
            return
        }
        f.hasPending = false
        if !f.baselineSet {
            f.baselineSet = true
            // NetTick 启动前就有的连接：之前的量不算，从现在开始记。
            // 拿不到开始时间的，启动后 5 秒内第一次见到的都当老连接
            let started = f.start ?? (f.firstSeen < launchedAt + 5 ? 0 : f.firstSeen)
            if started < launchedAt - 1 {
                f.lastRx = rx; f.lastTx = tx
                flows[id] = f
                return
            }
        }
        let d = Bytes(rx: rx >= f.lastRx ? rx - f.lastRx : rx, tx: tx >= f.lastTx ? tx - f.lastTx : tx)
        f.lastRx = rx; f.lastTx = tx
        flows[id] = f
        guard f.counted, d.total > 0, let identity = f.identity else { return }
        let now = Date()
        recorder.add(identity, proc: f.proc, d, at: now)
        secondBuckets[Int(now.timeIntervalSince1970), default: [:]][identity.key, default: Bytes()] += d
    }

    /// 退出前：把内存里的写进库
    func shutdown() {
        queue.sync { recorder.flush(wait: true) }
    }
}
