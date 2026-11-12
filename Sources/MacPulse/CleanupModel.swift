import AppKit
import Foundation
import MacPulseCore

/// 磁盘清理与软件卸载的状态。与 MonitorModel 分开，避免监控模型继续承担更多职责。
@MainActor
final class CleanupModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    // MARK: 磁盘清理状态

    @Published private(set) var diskState: LoadState = .idle
    @Published private(set) var diskPhase: String?
    @Published private(set) var diskItems: [CleanupItem] = []
    @Published private(set) var diskUnreadableCount = 0
    @Published private(set) var diskWarnings: [String] = []
    @Published private(set) var diskScannedAt: Date?
    /// 工作区等扫描条件变化后，现有结果已经过期，需要重新扫描。
    @Published private(set) var diskResultsOutdated = false
    @Published var diskSelection: Set<String> = []

    // MARK: 软件卸载状态

    @Published private(set) var appsState: LoadState = .idle
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var appWarnings: [String] = []
    @Published private(set) var selectedApp: InstalledApp?
    @Published private(set) var leftoversState: LoadState = .idle
    @Published private(set) var leftovers: [AppLeftover] = []
    @Published private(set) var leftoverWarnings: [String] = []
    @Published var leftoverSelection: Set<String> = []
    /// 运行中的应用（bundle id 与路径），随应用启动/退出实时更新，用于卸载按钮状态。
    @Published private(set) var runningAppKeys: Set<String> = []

    @Published private(set) var isTrashing = false
    @Published private(set) var workspaceRoots: [String] {
        didSet {
            defaults.set(workspaceRoots, forKey: Keys.workspaceRoots)
            if diskState == .loaded { diskResultsOutdated = true }
        }
    }

    /// 结果通过监控模型已有的提示弹窗展示。
    var report: ((String) -> Void)?

    private let defaults = UserDefaults.standard
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var scanTask: Task<Void, Never>?
    private var appsGeneration = 0
    private var leftoversGeneration = 0
    private var workspaceObservers: [NSObjectProtocol] = []

    private enum Keys {
        static let workspaceRoots = "cleanupWorkspaceRootList"
        static let legacyWorkspaceRoots = "cleanupWorkspaceRoots"
    }

    init() {
        if let stored = defaults.stringArray(forKey: Keys.workspaceRoots) {
            workspaceRoots = stored
        } else {
            // 兼容上一版以多行文本保存的配置。
            workspaceRoots = (defaults.string(forKey: Keys.legacyWorkspaceRoots) ?? "")
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { ($0 as NSString).expandingTildeInPath }
        }
        refreshRunningApps()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunningApps() }
            })
        }
    }

    // MARK: - 工作区目录

    func workspaceProblem(_ path: String) -> String? {
        makeScanner().workspaceProblem(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    func addWorkspaceRoots(_ urls: [URL]) {
        let paths = urls.map { $0.standardizedFileURL.path }.filter { !workspaceRoots.contains($0) }
        workspaceRoots += paths
    }

    func removeWorkspaceRoot(_ path: String) {
        workspaceRoots.removeAll { $0 == path }
    }

    // MARK: - 磁盘清理

    /// 删除的范围由界面传入：只处理用户当前能看到且已勾选的项，搜索隐藏的项不会被带上。
    func selectedDiskItems(in visible: [CleanupItem]) -> [CleanupItem] {
        visible.filter { diskSelection.contains($0.id) && !$0.isInUse }
    }

    func setSelection(_ items: [CleanupItem], selected: Bool) {
        let ids = items.filter { !$0.isInUse }.map(\.id)
        if selected { diskSelection.formUnion(ids) } else { diskSelection.subtract(ids) }
    }

    func scanDisk() {
        guard diskState != .loading, !isTrashing else { return }
        diskState = .loading
        diskPhase = nil
        let scanner = makeScanner()
        let running = Self.runningApps()
        let previousSelection = diskSelection
        let previousIDs = Set(diskItems.map(\.id))
        scanTask = Task {
            let task = Task.detached(priority: .utility) { () -> Result<DiskCleanupScanResult, Error> in
                guard let processes = RunningProcesses.read() else { return .failure(CleanupError.processListUnavailable) }
                let environment = RunningEnvironment(
                    bundleIDs: running.bundleIDs,
                    appNames: running.names,
                    commands: processes.commands,
                    workingDirectories: processes.workingDirectories
                )
                do {
                    return .success(try scanner.scan(environment: environment) { phase in
                        Task { @MainActor [weak self] in self?.diskPhase = phase.rawValue }
                    })
                } catch {
                    return .failure(error)
                }
            }
            let outcome = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            diskPhase = nil
            switch outcome {
            case .success(let result):
                diskItems = result.items
                diskUnreadableCount = result.unreadableCount
                diskWarnings = result.warnings
                // 重新扫描时保留用户对已有条目的勾选；新出现的条目按默认规则勾选。
                diskSelection = Set(result.items.filter { item in
                    guard !item.isInUse else { return false }
                    return previousIDs.contains(item.id) ? previousSelection.contains(item.id) : item.selectedByDefault
                }.map(\.id))
                diskScannedAt = Date()
                diskResultsOutdated = false
                diskState = .loaded
            case .failure(let error) where error is CancellationError:
                diskState = diskScannedAt == nil ? .idle : .loaded
            case .failure(let error):
                diskState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDiskScan() {
        scanTask?.cancel()
    }

    func trashDiskItems(_ items: [CleanupItem]) {
        guard !items.isEmpty, !isTrashing, diskState != .loading else { return }
        isTrashing = true
        let scanner = makeScanner()
        let trash = SafeTrash(homeDirectory: home)
        let running = Self.runningApps()
        Task {
            let summary: Result<TrashSummary, CleanupError> = await Task.detached(priority: .utility) {
                guard let processes = RunningProcesses.read() else { return .failure(.processListUnavailable) }
                let environment = RunningEnvironment(
                    bundleIDs: running.bundleIDs,
                    appNames: running.names,
                    commands: processes.commands,
                    workingDirectories: processes.workingDirectories
                )
                var outcomes: [TrashOutcome] = []
                var targets: [TrashTarget] = []
                // 扫描到确认之间相关应用可能已启动，删除前按最新运行状态再判断一次。
                for item in items {
                    if let reason = scanner.inUseReason(for: item, environment: environment) {
                        outcomes.append(.skipped(item.url, reason))
                    } else {
                        targets.append(TrashTarget(url: item.url, sizeBytes: item.sizeBytes))
                    }
                }
                outcomes += trash.trash(targets)
                return .success(TrashSummary(outcomes))
            }.value
            isTrashing = false
            switch summary {
            case .success(let summary):
                // 只从列表移除已移入废纸篓的条目，不做耗时的全量重扫；其余条目保持原状与勾选。
                let removed = Set(summary.trashedURLs.map(\.path))
                diskItems.removeAll { removed.contains($0.url.path) }
                diskSelection.subtract(removed)
                report?(summary.message)
            case .failure(let error):
                report?(error.localizedDescription)
            }
        }
    }

    private func makeScanner() -> DiskCleanupScanner {
        let aiCachePaths = AICacheCleaner.catalog.map { home.appendingPathComponent($0.relativePath).path }
        return DiskCleanupScanner(
            homeDirectory: home,
            workspaceRoots: workspaceRoots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            excludedPaths: Set(aiCachePaths)
        )
    }

    // MARK: - 软件卸载

    func loadApps() {
        guard appsState != .loading else { return }
        appsState = .loading
        appsGeneration += 1
        let generation = appsGeneration
        let uninstaller = makeUninstaller()
        Task {
            let result = await Task.detached(priority: .utility) { uninstaller.listApplications() }.value
            // 期间又发起了新的读取（例如卸载后刷新），旧结果作废。
            guard generation == appsGeneration else { return }
            apps = result.apps
            appWarnings = result.warnings
            appsState = result.apps.isEmpty && !result.warnings.isEmpty
                ? .failed(result.warnings.joined(separator: "\n"))
                : .loaded
        }
    }

    func select(_ app: InstalledApp?) {
        guard !isTrashing else { return }
        selectedApp = app
        leftovers = []
        leftoverWarnings = []
        leftoverSelection = []
        leftoversGeneration += 1
        guard let app else {
            leftoversState = .idle
            return
        }
        leftoversState = .loading
        let generation = leftoversGeneration
        let uninstaller = makeUninstaller()
        let installed = apps
        Task {
            let result = await Task.detached(priority: .utility) {
                uninstaller.leftovers(for: app, installedApps: installed)
            }.value
            guard generation == leftoversGeneration else { return }
            leftovers = result.leftovers
            leftoverWarnings = result.warnings
            leftoverSelection = Set(result.leftovers.filter(\.selectedByDefault).map(\.id))
            leftoversState = .loaded
        }
    }

    func runningReason(for app: InstalledApp) -> String? {
        let isRunning = app.bundleID.map { runningAppKeys.contains("id:" + $0.lowercased()) } == true
            || runningAppKeys.contains("path:" + app.url.standardizedFileURL.path)
        return isRunning ? "\(app.name) 正在运行，请先退出后再卸载" : nil
    }

    func quit(_ app: InstalledApp) {
        let targets = NSWorkspace.shared.runningApplications.filter { running in
            (app.bundleID != nil && running.bundleIdentifier == app.bundleID)
                || running.bundleURL?.standardizedFileURL.path == app.url.standardizedFileURL.path
        }
        targets.forEach { $0.terminate() }
    }

    func uninstallSelectedApp() {
        guard let app = selectedApp, !isTrashing, leftoversState == .loaded else { return }
        refreshRunningApps()
        if let reason = runningReason(for: app) {
            report?(reason)
            return
        }
        isTrashing = true
        let uninstaller = makeUninstaller()
        let leftoverTargets = leftovers.filter { leftoverSelection.contains($0.id) }
            .map { TrashTarget(url: $0.url, sizeBytes: $0.sizeBytes) }
        let appTarget = TrashTarget(url: app.url, sizeBytes: app.sizeBytes)
        let executablePrefix = app.url.standardizedFileURL.path.lowercased() + "/contents/"
        Task {
            let result: (message: String, appRemoved: Bool) = await Task.detached(priority: .utility) {
                // 确认弹窗打开期间应用可能被启动：真正删除前按进程列表再查一次。
                guard let processes = RunningProcesses.read() else {
                    return (CleanupError.processListUnavailable.localizedDescription, false)
                }
                // 按路径与 bundle id 两种方式复查：从 App Translocation 等其他路径启动时，命令行里看不到原路径。
                let launchedByPath = processes.commands.contains { $0.lowercased().hasPrefix(executablePrefix) }
                let launchedByID = await MainActor.run {
                    NSWorkspace.shared.runningApplications.contains { running in
                        (app.bundleID != nil && running.bundleIdentifier == app.bundleID)
                            || running.bundleURL?.standardizedFileURL.path == app.url.standardizedFileURL.path
                    }
                }
                if launchedByPath || launchedByID {
                    return ("\(app.name) 刚刚被启动，已取消卸载。请先退出后再试。", false)
                }
                let trash = uninstaller.safeTrash
                // 先移走 App 本体；本体失败时不再动残留，避免出现「软件还在、数据没了」的状态。
                let appOutcomes = trash.trash([appTarget], remover: { try WorkspaceRecycler.recycle($0) })
                guard case .trashed = appOutcomes.first else {
                    return ("卸载未完成：\n" + TrashSummary(appOutcomes).message, false)
                }
                return (TrashSummary(appOutcomes + trash.trash(leftoverTargets)).message, true)
            }.value
            isTrashing = false
            report?(result.message)
            if result.appRemoved {
                // 成功后只从列表移除该应用，不重新统计所有应用的大小。
                apps.removeAll { $0.id == app.id }
                select(nil)
            }
        }
    }

    private func refreshRunningApps() {
        var keys = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { keys.insert("id:" + id.lowercased()) }
            if let url = app.bundleURL { keys.insert("path:" + url.standardizedFileURL.path) }
        }
        runningAppKeys = keys
    }

    private func makeUninstaller() -> AppUninstaller {
        AppUninstaller(
            homeDirectory: home,
            excludedBundleIDs: Set([Bundle.main.bundleIdentifier, "com.mayubo.macpulse"].compactMap { $0 })
        )
    }

    private static func runningApps() -> (bundleIDs: Set<String>, names: [String]) {
        let apps = NSWorkspace.shared.runningApplications
        return (Set(apps.compactMap(\.bundleIdentifier)), apps.compactMap(\.localizedName))
    }
}

enum CleanupError: Error, LocalizedError {
    case processListUnavailable

    var errorDescription: String? { "无法读取进程列表，不能确认文件是否正在使用，已取消操作" }
}
