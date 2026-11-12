import AppKit
import Foundation
import MacPulseCore
import UserNotifications

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }
    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

@MainActor
final class MonitorModel: ObservableObject {
    struct PortItem: Identifiable {
        let socket: ListeningSocket
        let process: ProcessSnapshot?
        let group: ProcessGroup?
        /// 关闭端口时实际要结束的进程：监听进程及其子进程，不包含同名分组里的其他进程。
        let target: ProcessGroup?
        let idleDuration: TimeInterval
        let isDevelopmentServer: Bool

        var id: String { socket.id }
        var isSafeOneClickCandidate: Bool {
            isDevelopmentServer && !socket.hasEstablishedConnection && group?.classification.level != .protected
        }
        var isAutomaticCandidate: Bool {
            DevelopmentPortPolicy().shouldAutoClose(
                isDevelopmentServer: isDevelopmentServer,
                hasEstablishedConnection: socket.hasEstablishedConnection,
                idleDuration: idleDuration
            )
        }
    }

    @Published private(set) var snapshot: SystemSnapshot?
    @Published private(set) var ports: [PortItem] = []
    @Published private(set) var aiCaches: [AICacheUsage] = []
    @Published private(set) var cpuHistory: [CPUHistorySample] = []
    @Published private(set) var memoryHistory: [MemoryHistorySample] = []
    /// 界面与菜单栏显示的 CPU 占用（最近 3 次采样的平均），历史曲线仍使用原始值。
    @Published private(set) var displayCPU: CPUHistorySample?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isScanningCaches = false
    @Published var notice: String?
    @Published var autoClosePortsEnabled: Bool {
        didSet { defaults.set(autoClosePortsEnabled, forKey: Keys.autoClose) }
    }
    /// 内存压力变「紧张」时发系统通知：今早整机卡死前压力先变红，但面板收起时看不到。
    @Published var pressureAlertsEnabled: Bool {
        didSet {
            defaults.set(pressureAlertsEnabled, forKey: Keys.pressureAlerts)
            if pressureAlertsEnabled { requestNotificationAuthorization() }
        }
    }
    @Published var appearanceMode: AppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: Keys.appearance) }
    }
    @Published private(set) var dashboardWidth: CGFloat
    @Published private(set) var dashboardHeight: CGFloat
    var didUpdate: ((SystemSnapshot) -> Void)?
    var didResize: ((CGSize) -> Void)?

    private let sampler = MetricsSampler()
    private let terminator = ProcessTerminator()
    private let portScanner = PortScanner()
    private let classifier = ProcessClassifier(currentPID: getpid(), currentUser: NSUserName())
    private let cacheCleaner = AICacheCleaner()
    private let defaults = UserDefaults.standard
    private var lastBusyAt: [String: Date] = [:]
    private var autoCloseAttempted: Set<String> = []
    private var historyBuffer = CPUHistoryBuffer(capacity: 80)
    private var memoryHistoryBuffer = MemoryHistoryBuffer(capacity: 80)
    private var pressureAlertTracker = PressureAlertTracker(threshold: .critical)
    private var cpuSmoother = CPUSmoother(window: 3)

    private enum Keys {
        static let autoClose = "autoCloseDevelopmentPorts"
        static let appearance = "appearanceMode"
        static let dashboardWidth = "dashboardWidth"
        static let dashboardHeight = "dashboardHeight"
        static let pressureAlerts = "memoryPressureAlerts"
    }

    init() {
        autoClosePortsEnabled = defaults.bool(forKey: Keys.autoClose)
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        pressureAlertsEnabled = defaults.object(forKey: Keys.pressureAlerts) as? Bool ?? true
        let savedWidth = defaults.double(forKey: Keys.dashboardWidth)
        let savedHeight = defaults.double(forKey: Keys.dashboardHeight)
        dashboardWidth = savedWidth > 0 ? min(max(savedWidth, 400), 600) : 440
        dashboardHeight = savedHeight > 0 ? min(max(savedHeight, 560), 800) : 660
    }

    var recommendedGroups: [ProcessGroup] {
        snapshot?.groups.filter { $0.classification.level == .recommended } ?? []
    }

    var safePortCandidates: [PortItem] { ports.filter(\.isSafeOneClickCandidate) }

    var health: SystemHealth? {
        guard let snapshot else { return nil }
        return SystemHealth.evaluate(
            cpuPercent: displayCPU?.totalPercent ?? snapshot.cpuPercent,
            pressure: snapshot.memoryPressure,
            swapRatio: snapshot.swapRatio
        )
    }

    /// 内存占用最多的几组应用，用于压力偏高时的提示与通知正文。
    func topMemoryGroups(limit: Int = 3) -> [ProcessGroup] {
        Array((snapshot?.groups ?? []).sorted { $0.memoryBytes > $1.memoryBytes }.prefix(limit))
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let sampler = sampler

        Task {
            let result = await Task.detached(priority: .utility) { [portScanner] in
                let system = Result { try sampler.sample() }
                let ports = Result { try portScanner.scan() }
                return (system, ports)
            }.value

            isRefreshing = false
            switch result.0 {
            case .success(let value):
                snapshot = value
                let cpuSample = CPUHistorySample(
                    timestamp: value.sampledAt,
                    totalPercent: value.cpuPercent,
                    userPercent: value.userCPUPercent,
                    systemPercent: value.systemCPUPercent
                )
                historyBuffer.append(cpuSample)
                displayCPU = cpuSmoother.add(cpuSample)
                cpuHistory = historyBuffer.samples
                memoryHistoryBuffer.append(MemoryHistorySample(
                    timestamp: value.sampledAt,
                    usedPercent: value.memoryPercent,
                    pressure: value.memoryPressure
                ))
                memoryHistory = memoryHistoryBuffer.samples
                notifyIfPressureRose(value.memoryPressure)
                updateIdleTracking(value)
                rebuildPorts(result.1.successValue ?? [])
                didUpdate?(value)
                performAutomaticPortCleanup()
            case .failure(let error):
                notice = error.localizedDescription
            }
        }
    }

    func terminate(_ group: ProcessGroup) {
        let result = terminator.terminate(group)
        if result.failed > 0 || result.refused > 0 {
            notice = "已请求结束 \(result.stopped) 个进程，\(result.refused) 个受保护，\(result.failed) 个失败"
        } else {
            notice = "已请求结束 \(result.stopped) 个 \(group.name) 进程"
        }
        scheduleRefresh()
    }

    func optimizeRecommended() {
        let results = recommendedGroups.map { terminator.terminate($0) }
        let stopped = results.reduce(0) { $0 + $1.stopped }
        let refused = results.reduce(0) { $0 + $1.refused }
        let failed = results.reduce(0) { $0 + $1.failed }
        notice = failed == 0 && refused == 0
            ? "已请求结束 \(stopped) 个可选后台进程"
            : "已结束 \(stopped) 个，保护 \(refused) 个，失败 \(failed) 个"
        scheduleRefresh()
    }

    func closePort(_ item: PortItem) {
        guard let target = item.target, item.isSafeOneClickCandidate else {
            notice = "该端口不符合安全关闭规则"
            return
        }
        terminate(target)
    }

    func closeSafePorts() {
        let targets = Dictionary(grouping: safePortCandidates.compactMap(\.target), by: \.id).compactMap(\.value.first)
        let results = targets.map(terminator.terminate)
        let stopped = results.reduce(0) { $0 + $1.stopped }
        let failed = results.reduce(0) { $0 + $1.failed + $1.refused }
        notice = failed == 0 ? "已请求关闭 \(stopped) 个开发进程" : "已关闭 \(stopped) 个，失败或受保护 \(failed) 个"
        scheduleRefresh()
    }

    func refreshAICaches() {
        guard !isScanningCaches else { return }
        isScanningCaches = true
        let commands = snapshot?.groups.flatMap(\.processes).map(\.command) ?? []
        let cleaner = cacheCleaner
        Task {
            aiCaches = await Task.detached(priority: .utility) {
                cleaner.scan(runningCommands: commands)
            }.value.sorted { $0.sizeBytes > $1.sizeBytes }
            isScanningCaches = false
        }
    }

    func cleanAICaches() {
        let candidates = aiCaches.filter { !$0.isInUse && $0.sizeBytes > 0 }
        guard !candidates.isEmpty else {
            notice = "没有可安全清理的 AI 缓存；正在使用的应用已跳过"
            return
        }
        let cleaner = cacheCleaner
        Task {
            do {
                let result = try await Task.detached(priority: .utility) {
                    try cleaner.clean(candidates)
                }.value
                notice = result.message
            } catch {
                notice = "缓存清理失败：\(error.localizedDescription)"
            }
            // 部分失败时磁盘状态也已变化，无论结果如何都重新计算。
            refreshAICaches()
        }
    }

    func resizeDashboard(width: CGFloat, height: CGFloat, persist: Bool = false) {
        dashboardWidth = min(max(width, 400), 600)
        dashboardHeight = min(max(height, 560), 800)
        if persist {
            defaults.set(Double(dashboardWidth), forKey: Keys.dashboardWidth)
            defaults.set(Double(dashboardHeight), forKey: Keys.dashboardHeight)
        }
        didResize?(CGSize(width: dashboardWidth, height: dashboardHeight))
    }

    func resetDashboardSize() {
        resizeDashboard(width: 440, height: 660, persist: true)
    }

    private func notifyIfPressureRose(_ pressure: MemoryPressure?) {
        // 关闭提醒时也要持续更新追踪状态，否则重新打开的瞬间会把早已存在的紧张状态当成新发生的事件。
        guard let level = pressureAlertTracker.update(pressure), pressureAlertsEnabled else { return }
        guard Self.notificationsAvailable else {
            notice = "内存压力\(level.label)，建议关闭不用的应用"
            return
        }
        let top = topMemoryGroups().map { "\($0.name) \(ByteCountFormatter.string(fromByteCount: Int64($0.memoryBytes), countStyle: .memory))" }
        let content = UNMutableNotificationContent()
        content.title = "内存压力\(level.label)"
        content.body = top.isEmpty
            ? "系统可能变慢，建议关闭不用的应用。"
            : "占用最多：\(top.joined(separator: "、"))。建议关闭不用的应用或停止测试、容器。"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "memory-pressure", content: content, trigger: nil)
        // 用 async 接口：回调版本在后台队列执行，而本类隔离在主线程，Swift 6 运行时会直接断言崩溃。
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                notice = "内存紧张通知发送失败：\(error.localizedDescription)"
            }
        }
    }

    /// 不在 .app 包内运行（如 `swift run`）时没有 bundle id，调用通知中心会直接崩溃。
    private static var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func requestNotificationAuthorization() {
        guard Self.notificationsAvailable else { return }
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            if !granted {
                notice = "未获得通知权限，内存紧张时无法提醒。可在「系统设置 → 通知 → MacPulse」中开启。"
            }
        }
    }

    private func updateIdleTracking(_ snapshot: SystemSnapshot) {
        let now = snapshot.sampledAt
        let processes = snapshot.groups.flatMap(\.processes)
        let currentKeys = Set(processes.map(stableKey))
        lastBusyAt = lastBusyAt.filter { currentKeys.contains($0.key) }
        autoCloseAttempted = autoCloseAttempted.filter { currentKeys.contains($0) }
        for process in processes {
            let key = stableKey(process)
            if process.cpuPercent >= 0.5 || lastBusyAt[key] == nil {
                lastBusyAt[key] = now
            }
        }
    }

    private func rebuildPorts(_ sockets: [ListeningSocket]) {
        let groups = snapshot?.groups ?? []
        let allProcesses = groups.flatMap(\.processes)
        let processByPID = Dictionary(allProcesses.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let processToGroup = Dictionary(uniqueKeysWithValues: groups.flatMap { group in
            group.processes.map { ($0.pid, group) }
        })
        let groupByPID = Dictionary(uniqueKeysWithValues: processToGroup.map { ($0.key, $0.value.id) })
        let groupAwareSockets = PortScanner.propagateActiveConnections(in: sockets, groupByPID: groupByPID)
        ports = groupAwareSockets.map { socket in
            let group = processToGroup[socket.pid]
            let process = group?.processes.first(where: { $0.pid == socket.pid })
            let target = group.map { group in
                let rootPID = classifier.serviceRootPID(for: socket.pid, in: processByPID)
                return ProcessGroup(
                    name: "\(group.name) · PID \(rootPID)",
                    processes: allProcesses.subtree(rootedAt: rootPID).filter { !classifier.isInfrastructure($0) },
                    classification: group.classification
                )
            }
            let targetIdleDurations = target?.processes.compactMap { process in
                lastBusyAt[stableKey(process)].map { Date().timeIntervalSince($0) }
            } ?? []
            let idle = targetIdleDurations.min() ?? 0
            return PortItem(
                socket: socket,
                process: process,
                group: group,
                target: target,
                idleDuration: max(idle, 0),
                isDevelopmentServer: process.map(classifier.isAutoClosableDevelopmentServer) ?? false
            )
        }
    }

    private func performAutomaticPortCleanup() {
        guard autoClosePortsEnabled else { return }
        let candidates = ports.filter { item in
            guard item.isAutomaticCandidate, let process = item.process else { return false }
            return !autoCloseAttempted.contains(stableKey(process))
        }
        let targets = Dictionary(grouping: candidates.compactMap(\.target), by: \.id).compactMap(\.value.first)
        guard !targets.isEmpty else { return }
        var stopped = 0
        var notStopped = 0
        for target in targets {
            target.processes.forEach { autoCloseAttempted.insert(stableKey($0)) }
            let result = terminator.terminate(target)
            stopped += result.stopped
            notStopped += result.refused + result.failed
        }
        notice = notStopped == 0
            ? "已自动关闭 \(targets.count) 个闲置的开发服务"
            : "自动关闭开发服务：已请求结束 \(stopped) 个进程，\(notStopped) 个受保护或失败"
        scheduleRefresh()
    }

    private func stableKey(_ process: ProcessSnapshot) -> String {
        "\(process.pid):\(process.startTime)"
    }

    private func scheduleRefresh() {
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            refresh()
        }
    }
}

private extension Result {
    var successValue: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }
}
