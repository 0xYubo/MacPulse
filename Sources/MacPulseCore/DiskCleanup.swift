import Foundation

public enum CleanupCategory: String, CaseIterable, Identifiable, Sendable {
    case developer
    case appCache
    case logs
    case installer
    case largeFile

    public var id: Self { self }

    public var label: String {
        switch self {
        case .developer: "开发垃圾"
        case .appCache: "应用缓存"
        case .logs: "日志"
        case .installer: "旧安装包与压缩包"
        case .largeFile: "大文件"
        }
    }

    /// 下载、桌面中的条目是用户自己的文件，而不是可重建的缓存。
    public var isUserFiles: Bool {
        self == .installer || self == .largeFile
    }
}

public struct CleanupItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public let category: CleanupCategory
    public let name: String
    public let sizeBytes: UInt64
    public let lastModified: Date?
    public let inUseReason: String?
    /// 需要用户知道的附加说明，例如显示大小与实际可释放空间不一致。
    public let note: String?
    /// 用户文件或删除后难以恢复的条目默认不勾选。
    public let selectedByDefault: Bool

    public var id: String { url.path }
    public var isInUse: Bool { inUseReason != nil }

    public init(
        url: URL,
        category: CleanupCategory,
        name: String,
        sizeBytes: UInt64,
        lastModified: Date?,
        inUseReason: String?,
        note: String? = nil,
        selectedByDefault: Bool
    ) {
        self.url = url
        self.category = category
        self.name = name
        self.sizeBytes = sizeBytes
        self.lastModified = lastModified
        self.inUseReason = inUseReason
        self.note = note
        self.selectedByDefault = selectedByDefault
    }
}

public struct DiskCleanupScanResult: Sendable {
    public let items: [CleanupItem]
    /// 无权限或读取出错的条目数；大小统计可能因此偏小，界面需要提示。
    public let unreadableCount: Int
    /// 配置问题等需要用户处理的提示（例如工作区目录不存在）。
    public let warnings: [String]
}

/// 正在使用判断所需的运行环境快照。删除前需要用最新快照重新判断一次。
public struct RunningEnvironment: Sendable {
    public let bundleIDs: Set<String>
    public let appNames: [String]
    public let commands: [String]
    public let workingDirectories: [String]

    private static let genericBundleComponents: Set<String> = ["com", "org", "net", "io", "app", "apple", "inc", "co", "cn", "www", "dev"]

    public init(bundleIDs: Set<String>, appNames: [String] = [], commands: [String], workingDirectories: [String] = []) {
        self.bundleIDs = Set(bundleIDs.map { $0.lowercased() })
        self.appNames = appNames.map { $0.lowercased() }.filter { $0.count >= 4 }
        self.commands = commands.map { $0.lowercased() }
        self.workingDirectories = workingDirectories.map { $0.lowercased() }
    }

    /// ~/Library/Caches 下的目录名与应用没有固定对应关系（如 Chrome 用「Google」、Lark 用「LarkShell」），
    /// 命令行工具（playwright、poetry 等）也会使用这里的目录。
    /// 这里宁可多判为「使用中」：误判只会让该项暂时不能删除，漏判则可能在程序运行时删除其缓存。
    func appCacheInUseReason(directoryName: String, path: String) -> String? {
        let name = directoryName.lowercased()
        if bundleIDs.contains(name) { return "对应应用正在运行" }
        // Apple 自带进程（com.apple.dock、com.apple.siri……）的段会误命中「Docker」「SiriTTS」等目录，不参与模糊匹配。
        let components = bundleIDs.filter { !$0.hasPrefix("com.apple.") }
            .flatMap { $0.split(separator: ".").map(String.init) }
            .filter { !Self.genericBundleComponents.contains($0) }
        // 「LarkShell」对应 com.electron.lark：目录名以 bundle id 中某一段开头也视为相关。
        if let component = components.first(where: { $0 == name || ($0.count >= 4 && name.hasPrefix($0)) }) {
            return "疑似相关应用正在运行（\(component)）"
        }
        if let appName = appNames.first(where: { name.hasPrefix($0) }) {
            return "疑似相关应用正在运行（\(appName)）"
        }
        if usesPath(path) { return "有进程正在使用该目录" }
        if commands.contains(where: { command in
            let executable = command.split(separator: " ").first.map { String($0.split(separator: "/").last ?? "") }
            return executable == name
        }) {
            return "同名命令正在运行（\(directoryName)）"
        }
        return nil
    }

    /// 命令行中出现该路径，或有进程的工作目录位于该路径之内。
    func usesPath(_ path: String) -> Bool {
        let folded = path.lowercased()
        let prefix = folded.hasSuffix("/") ? folded : folded + "/"
        return commands.contains { $0.contains(prefix) || $0.hasSuffix(folded) }
            || workingDirectories.contains { $0 == folded || $0.hasPrefix(prefix) }
    }
}

public struct DiskCleanupScanner: Sendable {
    struct DeveloperCache: Sendable {
        let name: String
        let relativePath: String
        let bundleIDs: [String]
        let commandTokens: [String]
        var note: String? = nil
    }

    public enum Phase: String, Sendable {
        case developer = "开发缓存"
        case workspaces = "工作区项目"
        case appCaches = "应用缓存"
        case logs = "日志"
        case downloads = "下载与桌面"
    }

    static let developerCatalog: [DeveloperCache] = [
        .init(name: "Xcode DerivedData", relativePath: "Library/Developer/Xcode/DerivedData", bundleIDs: ["com.apple.dt.xcode"], commandTokens: ["xcodebuild"]),
        .init(name: "Xcode iOS DeviceSupport", relativePath: "Library/Developer/Xcode/iOS DeviceSupport", bundleIDs: ["com.apple.dt.xcode"], commandTokens: []),
        .init(name: "模拟器缓存", relativePath: "Library/Developer/CoreSimulator/Caches", bundleIDs: ["com.apple.dt.xcode", "com.apple.iphonesimulator"], commandTokens: ["simctl"]),
        .init(name: "SwiftPM 缓存", relativePath: "Library/Caches/org.swift.swiftpm", bundleIDs: ["com.apple.dt.xcode"], commandTokens: ["swift-build", "swift-package", "swift build", "swift package", "xcodebuild"]),
        .init(name: "npm 缓存", relativePath: ".npm/_cacache", bundleIDs: [], commandTokens: ["npm install", "npm ci", "npm i "]),
        .init(name: "pnpm 存储", relativePath: "Library/pnpm/store", bundleIDs: [], commandTokens: ["pnpm install", "pnpm i ", "pnpm add"],
              note: "与项目 node_modules 硬链接共享，实际释放空间可能明显小于显示值"),
        .init(name: "pnpm 元数据缓存", relativePath: "Library/Caches/pnpm", bundleIDs: [], commandTokens: ["pnpm install", "pnpm i ", "pnpm add"]),
        .init(name: "Yarn 缓存", relativePath: "Library/Caches/Yarn", bundleIDs: [], commandTokens: ["yarn install", "yarn add"]),
        .init(name: "pip 缓存", relativePath: "Library/Caches/pip", bundleIDs: [], commandTokens: ["pip install", "pip3 install"]),
        .init(name: "Homebrew 下载缓存", relativePath: "Library/Caches/Homebrew", bundleIDs: [], commandTokens: ["brew.rb"]),
        .init(name: "Gradle 缓存", relativePath: ".gradle/caches", bundleIDs: [], commandTokens: ["gradle"]),
        .init(name: "Cargo 下载缓存", relativePath: ".cargo/registry/cache", bundleIDs: [], commandTokens: ["cargo "]),
    ]

    /// ~/Library/Caches 下名为缓存、实际存放不可重建数据的目录，不列为候选。
    /// 名字不带 com.apple. 前缀的 Apple 系统缓存（地图、iCloud 等），由系统自行管理，不列为清理项。
    static let nonCacheDirectoryNames: Set<String> = ["pypoetry", "cloudkit", "geoservices", "familycircle", "passkit", "storedownload"]
    /// 可以删除、但重建代价高（需重新下载浏览器、重建索引）的目录，默认不勾选。
    static let expensiveCacheNotes: [String: String] = [
        "ms-playwright": "Playwright 浏览器，删除后需重新下载",
        "jetbrains": "JetBrains IDE 索引，删除后需重建",
    ]

    static let projectArtifactNames: Set<String> = ["node_modules", ".build", "DerivedData", ".venv"]
    static let projectMarkerFiles = [".git/index", ".git/HEAD", ".git/FETCH_HEAD"]
    static let appCacheMinimumBytes: UInt64 = 50 * 1_024 * 1_024
    static let largeFileMinimumBytes: UInt64 = 500 * 1_024 * 1_024
    static let installerExtensions: Set<String> = ["dmg", "pkg", "zip", "xip"]
    static let staleProjectInterval: TimeInterval = 30 * 24 * 3_600
    static let staleLogInterval: TimeInterval = 7 * 24 * 3_600
    static let staleInstallerInterval: TimeInterval = 7 * 24 * 3_600
    static let workspaceScanDepth = 4
    /// 判断项目是否活跃时最多检查的文件数；超过上限仍未找到近期改动时，按「无法确认」处理，不列为候选。
    static let projectFileScanLimit = 20_000

    private let home: URL
    private let workspaceRoots: [URL]
    private let excludedPaths: Set<String>
    private let now: Date

    /// - Parameter excludedPaths: 已由其他功能（AI 缓存）管理的路径，避免重复统计和重复删除。
    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        workspaceRoots: [URL] = [],
        excludedPaths: Set<String> = [],
        now: Date = Date()
    ) {
        home = homeDirectory.standardizedFileURL
        self.workspaceRoots = workspaceRoots.map(\.standardizedFileURL)
        self.excludedPaths = Set(excludedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        self.now = now
    }

    /// 校验工作区目录：返回问题说明，nil 表示可用。
    public func workspaceProblem(_ root: URL) -> String? {
        let standardized = root.standardizedFileURL
        if standardized.path == home.path { return "不能直接使用主目录，请选择具体的项目目录" }
        guard standardized.path.hasPrefix(home.path + "/") else { return "不在主目录内" }
        switch PathSafety.state(of: standardized) {
        case .missing: return "目录不存在"
        case .symbolicLink: return "是符号链接，请选择实际目录"
        case .unreadable(let message): return "无法读取：\(message)"
        case .present: break
        }
        guard isRealDirectory(standardized) else { return "不是目录" }
        if PathSafety.resolvedLocation(standardized).path != standardized.path {
            return "上级路径包含符号链接，请选择实际目录"
        }
        return nil
    }

    /// 扫描可在每个阶段之间以及遍历过程中取消（调用方取消所在的 Task 即可）。
    public func scan(
        environment: RunningEnvironment,
        progress: @Sendable (Phase) -> Void = { _ in }
    ) throws -> DiskCleanupScanResult {
        var items: [CleanupItem] = []
        var unreadable = 0
        var warnings: [String] = []
        func collect(_ phase: Phase, _ work: () throws -> (items: [CleanupItem], unreadable: Int)) throws {
            try Task.checkCancellation()
            progress(phase)
            let result = try work()
            items += result.items
            unreadable += result.unreadable
        }
        try collect(.developer) { scanDeveloperCaches(environment) }
        try collect(.workspaces) { try scanWorkspaces(environment, warnings: &warnings) }
        try collect(.appCaches) { try scanAppCaches(environment, warnings: &warnings) }
        try collect(.logs) { try scanLogs(environment, warnings: &warnings) }
        try collect(.downloads) { try scanDownloads(environment) }
        return DiskCleanupScanResult(items: items.sorted { $0.sizeBytes > $1.sizeBytes }, unreadableCount: unreadable, warnings: warnings)
    }

    /// 删除前用最新运行环境重新判断：扫描到确认之间，相关应用或命令可能已经启动。
    public func inUseReason(for item: CleanupItem, environment: RunningEnvironment) -> String? {
        switch item.category {
        case .developer:
            if let cache = Self.developerCatalog.first(where: { home.appendingPathComponent($0.relativePath).path == item.url.path }) {
                return inUseReason(cache, environment)
            }
            return projectInUseReason(project: item.url.deletingLastPathComponent(), environment)
        case .appCache:
            return environment.appCacheInUseReason(directoryName: item.url.lastPathComponent, path: item.url.path)
        case .logs, .installer, .largeFile:
            return environment.usesPath(item.url.path) ? "有进程正在使用该文件" : nil
        }
    }

    private var coveredPaths: Set<String> {
        excludedPaths.union(Self.developerCatalog.map { home.appendingPathComponent($0.relativePath).path })
    }

    private func scanDeveloperCaches(_ environment: RunningEnvironment) -> (items: [CleanupItem], unreadable: Int) {
        var unreadable = 0
        let items = Self.developerCatalog.compactMap { cache -> CleanupItem? in
            let url = home.appendingPathComponent(cache.relativePath)
            guard isRealDirectory(url), !excludedPaths.contains(url.path) else { return nil }
            let size = PathSafety.allocatedSize(of: url)
            unreadable += size.unreadableCount
            guard size.bytes > 0 else { return nil }
            return CleanupItem(
                url: url,
                category: .developer,
                name: cache.name,
                sizeBytes: size.bytes,
                lastModified: modificationDate(url),
                inUseReason: inUseReason(cache, environment),
                note: cache.note,
                selectedByDefault: true
            )
        }
        return (items, unreadable)
    }

    /// 只扫描用户在设置中显式配置的工作区：项目 30 天内没有任何文件改动，才把它的依赖/构建产物列为候选。
    private func scanWorkspaces(_ environment: RunningEnvironment, warnings: inout [String]) throws -> (items: [CleanupItem], unreadable: Int) {
        var items: [CleanupItem] = []
        var unreadable = 0
        var queue: [(url: URL, depth: Int)] = []
        for root in workspaceRoots {
            if let problem = workspaceProblem(root) {
                warnings.append("工作区 \((root.path as NSString).abbreviatingWithTildeInPath) \(problem)，已忽略")
            } else {
                queue.append((root, 0))
            }
        }
        var visited = Set<String>()

        while !queue.isEmpty {
            try Task.checkCancellation()
            let (directory, depth) = queue.removeFirst()
            guard visited.insert(directory.path).inserted else { continue }
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else {
                unreadable += 1
                continue
            }

            for child in children where isRealDirectory(child) {
                let name = child.lastPathComponent
                if Self.projectArtifactNames.contains(name) {
                    let projectModified: Date
                    switch try projectModificationDate(directory) {
                    case .date(let date):
                        projectModified = date
                    case .tooManyFiles:
                        warnings.append("项目 \(directory.lastPathComponent) 文件超过 \(Self.projectFileScanLimit) 个，无法确认是否仍在开发，已跳过其中的 \(name)")
                        continue
                    case .unreadable:
                        warnings.append("项目 \(directory.lastPathComponent) 中有目录无法读取，无法确认是否仍在开发，已跳过其中的 \(name)")
                        continue
                    }
                    guard now.timeIntervalSince(projectModified) >= Self.staleProjectInterval else { continue }
                    let size = PathSafety.allocatedSize(of: child)
                    unreadable += size.unreadableCount
                    guard size.bytes > 0 else { continue }
                    let isVirtualEnv = name == ".venv"
                    items.append(CleanupItem(
                        url: child,
                        category: .developer,
                        name: "\(directory.lastPathComponent) · \(name)",
                        sizeBytes: size.bytes,
                        lastModified: projectModified,
                        inUseReason: projectInUseReason(project: directory, environment),
                        note: isVirtualEnv ? "虚拟环境中手动安装的包可能无法按锁文件复现" : nil,
                        selectedByDefault: !isVirtualEnv
                    ))
                } else if depth + 1 < Self.workspaceScanDepth, !name.hasPrefix("."), child.pathExtension != "app" {
                    queue.append((child, depth + 1))
                }
            }
        }
        return (items, unreadable)
    }

    private func scanAppCaches(_ environment: RunningEnvironment, warnings: inout [String]) throws -> (items: [CleanupItem], unreadable: Int) {
        let caches = home.appendingPathComponent("Library/Caches")
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)
        } catch {
            if PathSafety.exists(caches) { warnings.append("无法读取 ~/Library/Caches，应用缓存未参与扫描：\(error.localizedDescription)") }
            return ([], 0)
        }
        let covered = coveredPaths
        var unreadable = 0
        var items: [CleanupItem] = []
        for child in children {
            try Task.checkCancellation()
            let name = child.lastPathComponent
            let folded = name.lowercased()
            guard !folded.hasPrefix("com.apple."),
                  !Self.nonCacheDirectoryNames.contains(folded),
                  !PathSafety.isSymbolicLink(child),
                  !covered.contains(child.standardizedFileURL.path) else { continue }
            let size = PathSafety.allocatedSize(of: child)
            unreadable += size.unreadableCount
            guard size.bytes >= Self.appCacheMinimumBytes else { continue }
            let expensiveNote = Self.expensiveCacheNotes[folded]
            items.append(CleanupItem(
                url: child,
                category: .appCache,
                name: name,
                sizeBytes: size.bytes,
                lastModified: modificationDate(child),
                inUseReason: environment.appCacheInUseReason(directoryName: name, path: child.path),
                note: expensiveNote,
                selectedByDefault: expensiveNote == nil
            ))
        }
        return (items, unreadable)
    }

    /// 日志按目录内最新文件的修改时间判断：往已有文件追加内容不会更新目录本身的修改时间。
    private func scanLogs(_ environment: RunningEnvironment, warnings: inout [String]) throws -> (items: [CleanupItem], unreadable: Int) {
        let logs = home.appendingPathComponent("Library/Logs")
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
        } catch {
            if PathSafety.exists(logs) { warnings.append("无法读取 ~/Library/Logs，日志未参与扫描：\(error.localizedDescription)") }
            return ([], 0)
        }
        var unreadable = 0
        var items: [CleanupItem] = []
        for child in children where !PathSafety.isSymbolicLink(child) {
            try Task.checkCancellation()
            guard case .date(let modified) = try newestModificationDate(in: child, limit: 5_000) else {
                warnings.append("日志 \(child.lastPathComponent) 无法确认最近是否仍在写入，已跳过")
                continue
            }
            guard now.timeIntervalSince(modified) >= Self.staleLogInterval else { continue }
            let size = PathSafety.allocatedSize(of: child)
            unreadable += size.unreadableCount
            guard size.bytes > 0 else { continue }
            items.append(CleanupItem(
                url: child,
                category: .logs,
                name: child.lastPathComponent,
                sizeBytes: size.bytes,
                lastModified: modified,
                inUseReason: environment.usesPath(child.path) ? "有进程正在使用该文件" : nil,
                selectedByDefault: true
            ))
        }
        return (items, unreadable)
    }

    private func scanDownloads(_ environment: RunningEnvironment) throws -> (items: [CleanupItem], unreadable: Int) {
        var items: [CleanupItem] = []
        final class Counter: @unchecked Sendable { var value = 0 }
        let unreadable = Counter()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        for folder in ["Downloads", "Desktop"] {
            let root = home.appendingPathComponent(folder)
            guard isRealDirectory(root) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    unreadable.value += 1
                    return true
                }
            ) else {
                unreadable.value += 1
                continue
            }
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                if enumerator.level >= 2 { enumerator.skipDescendants() }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                    unreadable.value += 1
                    continue
                }
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let size = UInt64(max(values.totalFileAllocatedSize ?? values.fileSize ?? 0, 0))
                let modified = values.contentModificationDate
                let age = modified.map { now.timeIntervalSince($0) } ?? 0
                let category: CleanupCategory
                if Self.installerExtensions.contains(url.pathExtension.lowercased()), age >= Self.staleInstallerInterval {
                    category = .installer
                } else if size >= Self.largeFileMinimumBytes {
                    category = .largeFile
                } else {
                    continue
                }
                items.append(CleanupItem(
                    url: url,
                    category: category,
                    name: url.lastPathComponent,
                    sizeBytes: size,
                    lastModified: modified,
                    inUseReason: environment.usesPath(url.path) ? "有进程正在使用该文件" : nil,
                    note: folder == "Desktop" ? "若开启了 iCloud 桌面同步，其他设备上的副本也会被移除" : nil,
                    selectedByDefault: false
                ))
            }
        }
        return (items, unreadable.value)
    }

    private func inUseReason(_ cache: DeveloperCache, _ environment: RunningEnvironment) -> String? {
        if cache.bundleIDs.contains(where: environment.bundleIDs.contains) {
            return "相关应用正在运行"
        }
        if cache.commandTokens.contains(where: { token in environment.commands.contains { $0.contains(token) } }) {
            return "相关命令正在执行"
        }
        if environment.usesPath(home.appendingPathComponent(cache.relativePath).path) {
            return "有进程正在使用该目录"
        }
        return nil
    }

    private func projectInUseReason(project: URL, _ environment: RunningEnvironment) -> String? {
        environment.usesPath(project.standardizedFileURL.path) ? "项目中有进程正在运行" : nil
    }

    enum ModificationScan: Equatable {
        case date(Date)
        case tooManyFiles
        case unreadable
    }

    /// 项目最近修改时间：git 状态文件加上项目内源文件（跳过依赖、构建产物和隐藏目录）的最新修改时间。
    /// 只看一级目录会漏掉深层文件的改动，把正在开发的项目误判为闲置。
    private func projectModificationDate(_ project: URL) throws -> ModificationScan {
        // git 状态文件不存在是常态（非 git 项目），不算读取失败。
        let markers = Self.projectMarkerFiles.compactMap { modificationDate(project.appendingPathComponent($0)) }
        let scan = try newestModificationDate(in: project, limit: Self.projectFileScanLimit, skipping: Self.projectArtifactNames)
        guard case .date(let newestFile) = scan else { return scan }
        return .date((markers + [newestFile]).max() ?? newestFile)
    }

    /// 递归取最新修改时间，可跳过指定目录名与隐藏目录；超过文件数上限或遇到读取错误时无法确认，分别返回对应结果。
    private func newestModificationDate(in url: URL, limit: Int, skipping skipped: Set<String> = []) throws -> ModificationScan {
        guard let own = modificationDate(url) else { return .unreadable }
        guard isRealDirectory(url) else { return .date(own) }
        final class Flag: @unchecked Sendable { var failed = false }
        let flag = Flag()
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                flag.failed = true
                return true
            }
        ) else { return .unreadable }
        var newest = own
        var count = 0
        for case let child as URL in enumerator {
            count += 1
            if count % 500 == 0 { try Task.checkCancellation() }
            if count > limit { return .tooManyFiles }
            let values = try? child.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            if values?.isDirectory == true, skipped.contains(child.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard let date = values?.contentModificationDate else {
                flag.failed = true
                continue
            }
            newest = max(newest, date)
        }
        return flag.failed ? .unreadable : .date(newest)
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func isRealDirectory(_ url: URL) -> Bool {
        guard !PathSafety.isSymbolicLink(url) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
