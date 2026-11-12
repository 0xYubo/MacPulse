import Foundation
import Testing
@testable import MacPulseCore

/// 在临时目录中构造假的主目录，测试不会触碰真实的 ~/Library 或废纸篓。
private struct Sandbox {
    let root: URL
    let home: URL
    let outside: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macpulse-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        home = root.appendingPathComponent("home")
        outside = root.appendingPathComponent("outside")
        for path in ["Library/Caches", "Library/Logs", "Library/Preferences", "Downloads"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ relativePath: String, in base: URL? = nil, bytes: Int = 16, modified: Date? = nil) throws -> URL {
        let url = (base ?? home).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        if let modified { try touch(url, modified) }
        return url
    }

    @discardableResult
    func directory(_ relativePath: String, modified: Date? = nil) throws -> URL {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let modified { try touch(url, modified) }
        return url
    }

    func touch(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// 测试中用直接删除代替移入废纸篓。
private let removeInsteadOfTrash: SafeTrash.Remover = { try FileManager.default.removeItem(at: $0) }
private func daysAgo(_ days: Double) -> Date { Date().addingTimeInterval(-days * 24 * 3_600) }

@Suite("Safe trash guard")
struct SafeTrashTests {
    @Test("Rejects paths outside the allowed roots")
    func rejectsOutsideRoots() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let victim = try box.file("keep.txt", in: box.outside)
        let trash = SafeTrash(homeDirectory: box.home)

        let outcomes = trash.trash([TrashTarget(url: victim, sizeBytes: 1)], remover: removeInsteadOfTrash)

        guard case .skipped = outcomes.first else { Issue.record("应当跳过"); return }
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test("Rejects protected container directories themselves")
    func rejectsContainers() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let trash = SafeTrash(homeDirectory: box.home)

        #expect(trash.rejectionReason(for: box.home) != nil)
        #expect(trash.rejectionReason(for: box.home.appendingPathComponent("Library")) != nil)
        #expect(trash.rejectionReason(for: box.home.appendingPathComponent("Library/Caches")) != nil)
        #expect(trash.rejectionReason(for: box.home.appendingPathComponent("Downloads")) != nil)
        #expect(trash.rejectionReason(for: box.home.appendingPathComponent("Library/Caches/com.example.app")) == nil)
    }

    @Test("Removing a symlink never touches its target")
    func symlinkOnlyRemovesLink() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let precious = try box.file("precious/data.txt", in: box.outside)
        let link = box.home.appendingPathComponent("Library/Caches/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: precious.deletingLastPathComponent())

        let outcomes = SafeTrash(homeDirectory: box.home).trash([TrashTarget(url: link, sizeBytes: 0)], remover: removeInsteadOfTrash)

        guard case .trashed = outcomes.first else { Issue.record("链接本身应被移除"); return }
        #expect(PathSafety.exists(link) == false)
        #expect(FileManager.default.fileExists(atPath: precious.path))
    }

    @Test("Rejects targets reached through a symlinked parent")
    func rejectsSymlinkedParent() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let precious = try box.file("precious/data.txt", in: box.outside)
        let link = box.home.appendingPathComponent("Library/Caches/evil")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: precious.deletingLastPathComponent())

        let outcomes = SafeTrash(homeDirectory: box.home).trash(
            [TrashTarget(url: link.appendingPathComponent("data.txt"), sizeBytes: 1)],
            remover: removeInsteadOfTrash
        )

        guard case .skipped = outcomes.first else { Issue.record("应当跳过"); return }
        #expect(FileManager.default.fileExists(atPath: precious.path))
    }

    @Test("Reports an outcome for every target")
    func reportsEveryTarget() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let existing = try box.file("Library/Caches/a/file")
        let missing = box.home.appendingPathComponent("Library/Caches/missing")

        let outcomes = SafeTrash(homeDirectory: box.home).trash(
            [TrashTarget(url: existing.deletingLastPathComponent(), sizeBytes: 10), TrashTarget(url: missing, sizeBytes: 0)],
            remover: removeInsteadOfTrash
        )
        let summary = TrashSummary(outcomes)

        #expect(outcomes.count == 2)
        #expect(summary.trashedCount == 1)
        #expect(summary.skipped.count == 1)
        #expect(summary.message.contains("已不存在"))
    }
}

@Suite("AI cache symlink safety")
struct AICacheSymlinkTests {
    @Test("Refuses a cache directory that is a symlink")
    func refusesSymlinkedCacheDirectory() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let precious = try box.file("project/main.swift", in: box.outside)
        let cacheDirectory = box.home.appendingPathComponent("Library/Caches/Codex")
        try FileManager.default.createSymbolicLink(at: cacheDirectory, withDestinationURL: precious.deletingLastPathComponent())
        let cleaner = AICacheCleaner(homeDirectory: box.home)
        let definition = try #require(AICacheCleaner.catalog.first { $0.relativePath == "Library/Caches/Codex" })

        #expect(cleaner.rejectionReason(for: cacheDirectory) != nil)
        let result = try cleaner.clean([AICacheUsage(definition: definition, sizeBytes: 100, isInUse: false)])

        #expect(result.cleanedCount == 0)
        #expect(result.skipped.count == 1)
        #expect(FileManager.default.fileExists(atPath: precious.path))
    }

    @Test("Refuses a cache directory reached through a symlinked parent")
    func refusesSymlinkedParent() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let realCaches = box.outside.appendingPathComponent("caches")
        try box.file("Codex/blob", in: realCaches)
        let library = box.home.appendingPathComponent("Library")
        try FileManager.default.removeItem(at: library.appendingPathComponent("Caches"))
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("Caches"), withDestinationURL: realCaches)
        let cleaner = AICacheCleaner(homeDirectory: box.home)

        #expect(cleaner.rejectionReason(for: library.appendingPathComponent("Caches/Codex")) != nil)
    }
}

@Suite("Disk cleanup scanning")
struct DiskCleanupScannerTests {
    private let idle = RunningEnvironment(bundleIDs: [], commands: [])

    /// 构造一个「所有文件都在 days 天前修改」的项目。
    private func makeProject(_ box: Sandbox, _ name: String, artifact: String, days: Double) throws -> URL {
        let project = box.home.appendingPathComponent("work/\(name)")
        try box.file("work/\(name)/\(artifact)/pkg/index.js")
        try box.file("work/\(name)/src/deep/app.ts", modified: daysAgo(days))
        try box.file("work/\(name)/package.json", modified: daysAgo(days))
        for dir in ["src/deep", "src", ""] {
            try box.touch(project.appendingPathComponent(dir), daysAgo(days))
        }
        return project
    }

    private func scanner(_ box: Sandbox) -> DiskCleanupScanner {
        DiskCleanupScanner(homeDirectory: box.home, workspaceRoots: [box.home.appendingPathComponent("work")])
    }

    @Test("Lists build artifacts only for projects untouched for 30 days")
    func staleProjectsOnly() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        _ = try makeProject(box, "old", artifact: "node_modules", days: 40)
        _ = try makeProject(box, "new", artifact: "node_modules", days: 29)

        let names = try scanner(box).scan(environment: idle).items.map(\.name)

        #expect(names.contains("old · node_modules"))
        #expect(names.contains("new · node_modules") == false)
    }

    @Test("A recent change deep inside the project keeps it active")
    func deepChangeKeepsProjectActive() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let project = try makeProject(box, "busy", artifact: "node_modules", days: 40)
        // 只改深层文件：目录本身的修改时间保持在 40 天前。
        try Data("x".utf8).write(to: project.appendingPathComponent("src/deep/app.ts"))
        for dir in ["src/deep", "src", ""] { try box.touch(project.appendingPathComponent(dir), daysAgo(40)) }

        #expect(try scanner(box).scan(environment: idle).items.isEmpty)
    }

    @Test("Recent git activity keeps the project active")
    func gitActivityKeepsProjectActive() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let project = try makeProject(box, "committed", artifact: "node_modules", days: 40)
        try box.file("work/committed/.git/index")
        try box.touch(project, daysAgo(40))

        #expect(try scanner(box).scan(environment: idle).items.isEmpty)
    }

    @Test("Virtual environments are never preselected")
    func venvNotPreselected() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        _ = try makeProject(box, "py", artifact: ".venv", days: 40)

        let item = try #require(try scanner(box).scan(environment: idle).items.first { $0.name == "py · .venv" })

        #expect(item.selectedByDefault == false)
        #expect(item.note != nil)
    }

    @Test("Detects projects in use through process working directories")
    func projectInUseByWorkingDirectory() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let project = try makeProject(box, "served", artifact: "node_modules", days: 40)
        // `npm run dev` 的命令行里没有项目路径，只能靠工作目录判断。
        let environment = RunningEnvironment(bundleIDs: [], commands: ["npm run dev"], workingDirectories: [project.path + "/src"])

        let item = try #require(try scanner(box).scan(environment: environment).items.first)

        #expect(item.isInUse)
        #expect(scanner(box).inUseReason(for: item, environment: idle) == nil)
    }

    @Test("Reports invalid workspace roots instead of silently ignoring them")
    func invalidWorkspaceWarnings() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let scanner = DiskCleanupScanner(
            homeDirectory: box.home,
            workspaceRoots: [box.home, box.home.appendingPathComponent("missing"), box.outside]
        )

        let result = try scanner.scan(environment: idle)

        #expect(result.warnings.count == 3)
    }

    @Test("Scanning stops when the task is cancelled")
    func cancellation() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let scanner = DiskCleanupScanner(homeDirectory: box.home)
        let task = Task { try scanner.scan(environment: RunningEnvironment(bundleIDs: [], commands: [])) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Skips Apple caches, marks running apps, and avoids double counting")
    func appCacheRules() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let big = 51 * 1_024 * 1_024
        try box.file("Library/Caches/com.apple.Safari/blob", bytes: big)
        try box.file("Library/Caches/com.example.running/blob", bytes: big)
        try box.file("Library/Caches/pypoetry/virtualenvs/env/blob", bytes: big)
        try box.file("Library/Caches/ms-playwright/chromium/blob", bytes: big)
        try box.file("Library/Caches/Yarn/blob")
        try box.file("Library/Caches/pip/blob")

        let scanner = DiskCleanupScanner(
            homeDirectory: box.home,
            excludedPaths: [box.home.appendingPathComponent("Library/Caches/Yarn").path]
        )
        let items = try scanner.scan(environment: RunningEnvironment(bundleIDs: ["com.example.running"], commands: [])).items

        #expect(items.contains { $0.name == "com.apple.Safari" } == false)
        #expect(items.contains { $0.name == "pypoetry" } == false)
        let playwright = try #require(items.first { $0.name == "ms-playwright" })
        #expect(playwright.selectedByDefault == false)
        let running = try #require(items.first { $0.name == "com.example.running" })
        #expect(running.isInUse)
        #expect(items.contains { $0.url.lastPathComponent == "Yarn" } == false)
        #expect(items.filter { $0.url.lastPathComponent == "pip" }.map(\.category) == [.developer])
    }

    @Test("Apple bundle id components never mark unrelated caches in use")
    func appleComponentsIgnored() {
        let environment = RunningEnvironment(bundleIDs: ["com.apple.dock", "com.apple.siri.embeddedspeech"], commands: [])

        #expect(environment.appCacheInUseReason(directoryName: "Docker Desktop", path: "/x/Docker Desktop") == nil)
        #expect(environment.appCacheInUseReason(directoryName: "SiriTTS", path: "/x/SiriTTS") == nil)
    }

    @Test("Projects that cannot be verified are reported by name")
    func unverifiableProjectWarning() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let project = try makeProject(box, "locked", artifact: "node_modules", days: 40)
        try box.file("work/locked/private/secret.txt")
        let locked = project.appendingPathComponent("private")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        try box.touch(project, daysAgo(40))

        let result = try scanner(box).scan(environment: idle)

        #expect(result.items.isEmpty)
        #expect(result.warnings.contains { $0.contains("locked") && $0.contains("无法读取") })
    }

    @Test("App cache in-use heuristics include command-line tools")
    func appCacheHeuristics() {
        let environment = RunningEnvironment(
            bundleIDs: ["com.google.Chrome", "com.electron.lark"],
            appNames: ["Go"],
            commands: ["/Users/me/.local/bin/uv run app.py", "node /Users/me/Library/Caches/ms-playwright/driver/cli.js"]
        )

        #expect(environment.appCacheInUseReason(directoryName: "Google", path: "/x/Google") != nil)
        #expect(environment.appCacheInUseReason(directoryName: "LarkShell", path: "/x/LarkShell") != nil)
        #expect(environment.appCacheInUseReason(directoryName: "uv", path: "/x/uv") != nil)
        #expect(environment.appCacheInUseReason(directoryName: "ms-playwright", path: "/Users/me/Library/Caches/ms-playwright") != nil)
        #expect(environment.appCacheInUseReason(directoryName: "com", path: "/x/com") == nil)
        #expect(environment.appCacheInUseReason(directoryName: "Gofer", path: "/x/Gofer") == nil)
    }

    @Test("Developer caches are in use while a related command runs")
    func developerCacheInUse() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.file("Library/Caches/pip/blob")
        let environment = RunningEnvironment(bundleIDs: [], commands: ["/usr/bin/python3 -m pip install requests"])

        let item = try #require(try DiskCleanupScanner(homeDirectory: box.home).scan(environment: environment).items.first { $0.name == "pip 缓存" })

        #expect(item.isInUse)
    }

    @Test("Logs are judged by their newest file; installers are not preselected")
    func logsAndDownloads() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.file("Library/Logs/OldTool/run.log", modified: daysAgo(10))
        try box.touch(box.home.appendingPathComponent("Library/Logs/OldTool"), daysAgo(10))
        // 目录修改时间很旧，但里面的日志文件刚被写入。
        try box.file("Library/Logs/ActiveTool/run.log")
        try box.touch(box.home.appendingPathComponent("Library/Logs/ActiveTool"), daysAgo(30))
        try box.file("Downloads/Setup.dmg", modified: daysAgo(10))
        try box.file("Downloads/notes.txt", modified: daysAgo(100))

        let items = try DiskCleanupScanner(homeDirectory: box.home).scan(environment: idle).items

        #expect(items.contains { $0.name == "OldTool" && $0.category == .logs })
        #expect(items.contains { $0.name == "ActiveTool" } == false)
        let installer = try #require(items.first { $0.name == "Setup.dmg" })
        #expect(installer.category == .installer)
        #expect(installer.selectedByDefault == false)
        #expect(items.contains { $0.name == "notes.txt" } == false)
    }
}

@Suite("App uninstaller")
struct AppUninstallerTests {
    private func makeApp(_ name: String, bundleID: String, in root: URL) throws {
        let contents = root.appendingPathComponent("\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": "1.0"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    @Test("Lists third-party apps only")
    func listsThirdPartyApps() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let apps = box.root.appendingPathComponent("Applications")
        try makeApp("Foo", bundleID: "com.foo.bar", in: apps)
        try makeApp("Safari", bundleID: "com.apple.Safari", in: apps)
        try makeApp("MacPulse", bundleID: "com.mayubo.macpulse", in: apps)

        let uninstaller = AppUninstaller(homeDirectory: box.home, applicationRoots: [apps], excludedBundleIDs: ["com.mayubo.macpulse"])
        let result = uninstaller.listApplications()

        #expect(result.apps.map(\.bundleID) == ["com.foo.bar"])
        #expect(result.warnings.isEmpty)
    }

    @Test("Reports unreadable application folders instead of an empty list")
    func reportsUnreadableRoot() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let apps = box.root.appendingPathComponent("Applications")
        try makeApp("Foo", bundleID: "com.foo.bar", in: apps)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: apps.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: apps.path) }

        let result = AppUninstaller(homeDirectory: box.home, applicationRoots: [apps]).listApplications()

        #expect(result.apps.isEmpty)
        #expect(result.warnings.count == 1)
    }

    @Test("Matches leftovers exactly; shared containers need confirmation")
    func exactLeftoverMatching() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let apps = box.root.appendingPathComponent("Applications")
        try makeApp("Foo", bundleID: "com.foo.bar", in: apps)
        for path in [
            "Library/Preferences/com.foo.bar.plist",
            "Library/Preferences/com.foo.bar2.plist",
            "Library/Caches/com.foo.bar/blob",
            "Library/Caches/com.foo.bar2/blob",
            "Library/Containers/com.foo.bar/Data/doc",
            "Library/Group Containers/TEAM123.com.foo.bar/data",
            "Library/Group Containers/TEAM123.com.foo.bar2/data",
            "Library/LaunchAgents/com.foo.bar.helper.plist",
            "Library/LaunchAgents/com.foo.bar2.plist",
            "Library/Application Support/Foo/state",
        ] {
            try box.file(path)
        }

        let uninstaller = AppUninstaller(homeDirectory: box.home, applicationRoots: [apps])
        let app = try #require(uninstaller.listApplications().apps.first)
        let leftovers = uninstaller.leftovers(for: app).leftovers
        let names = Set(leftovers.map(\.url.lastPathComponent))
        let preselected = Set(leftovers.filter(\.selectedByDefault).map { "\($0.location)/\($0.url.lastPathComponent)" })

        #expect(names == ["com.foo.bar.plist", "com.foo.bar", "TEAM123.com.foo.bar", "com.foo.bar.helper.plist", "Foo"])
        // Containers 与 Group Containers 可能含用户数据或被共用，名称匹配可能属于其他软件：都不默认勾选。
        #expect(leftovers.count == 6)
        #expect(preselected == [
            "Library/Preferences/com.foo.bar.plist",
            "Library/Caches/com.foo.bar",
            "Library/LaunchAgents/com.foo.bar.helper.plist",
        ])
    }

    @Test("A malicious bundle id cannot reach arbitrary directories")
    func rejectsPathTraversalBundleID() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let apps = box.root.appendingPathComponent("Applications")
        try makeApp("Evil", bundleID: "../../Projects/important", in: apps)
        try box.file("Projects/important/source.swift")

        let uninstaller = AppUninstaller(homeDirectory: box.home, applicationRoots: [apps])
        let app = try #require(uninstaller.listApplications().apps.first)
        let leftovers = uninstaller.leftovers(for: app).leftovers

        #expect(app.bundleID == nil)
        #expect(app.warning != nil)
        #expect(leftovers.contains { $0.url.path.contains("Projects") } == false)
        #expect(AppUninstaller.isValidBundleID("com.foo.bar"))
        #expect(AppUninstaller.isValidBundleID("com/foo") == false)
        #expect(AppUninstaller.isValidBundleID("..") == false)
    }

    @Test("Shared bundle ids make every leftover require confirmation")
    func sharedInstallLeftovers() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let apps = box.root.appendingPathComponent("Applications")
        try makeApp("Dup", bundleID: "com.x.dup", in: apps)
        try makeApp("Dup Beta", bundleID: "com.x.dup", in: apps)
        try box.file("Library/Application Support/com.x.dup/state")

        let uninstaller = AppUninstaller(homeDirectory: box.home, applicationRoots: [apps])
        let installed = uninstaller.listApplications().apps
        let beta = try #require(installed.first { $0.name == "Dup Beta" })
        let leftovers = uninstaller.leftovers(for: beta, installedApps: installed).leftovers

        #expect(leftovers.count == 1)
        #expect(leftovers.allSatisfy { !$0.selectedByDefault && $0.caution != nil })
    }

    @Test("Application roots are protected but apps inside are allowed")
    func applicationRootsGuard() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let apps = box.root.appendingPathComponent("Applications")
        try makeApp("Foo", bundleID: "com.foo.bar", in: apps)
        let trash = AppUninstaller(homeDirectory: box.home, applicationRoots: [apps]).safeTrash

        #expect(trash.rejectionReason(for: apps) != nil)
        #expect(trash.rejectionReason(for: apps.appendingPathComponent("Foo.app")) == nil)
    }
}

@Suite("Safe trash hardening")
struct SafeTrashHardeningTests {
    @Test("Protected paths are compared case-insensitively")
    func caseInsensitiveProtection() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let trash = SafeTrash(homeDirectory: box.home)

        #expect(trash.rejectionReason(for: box.home.appendingPathComponent("library/caches")) != nil)
        #expect(trash.rejectionReason(for: box.home.appendingPathComponent("LIBRARY")) != nil)
        #expect(trash.rejectionReason(for: box.home.appendingPathComponent("downloads")) != nil)
    }

    @Test("Account and sync data subtrees are never cleaned")
    func forbiddenSubtrees() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let trash = SafeTrash(homeDirectory: box.home)

        #expect(trash.rejectionReason(for: box.home.appendingPathComponent("Library/Keychains/login.keychain-db")) != nil)
        #expect(trash.rejectionReason(for: box.home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/a")) != nil)
    }

    @Test("Unreadable targets are not reported as missing")
    func unreadableIsNotMissing() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let locked = box.home.appendingPathComponent("Library/Caches/locked")
        try box.file("Library/Caches/locked/inner/file")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let outcomes = SafeTrash(homeDirectory: box.home).trash(
            [TrashTarget(url: locked.appendingPathComponent("inner"), sizeBytes: 0)],
            remover: removeInsteadOfTrash
        )

        guard case .skipped(_, let reason) = outcomes.first else { Issue.record("应当跳过"); return }
        #expect(reason.hasPrefix("无法读取"))
    }
}

@Suite("Process subtree")
struct ProcessSubtreeTests {
    private func process(_ pid: Int32, parent: Int32, name: String = "node") -> ProcessSnapshot {
        ProcessSnapshot(pid: pid, parentPID: parent, user: "me", name: name, command: name, cpuPercent: 0, memoryBytes: 0, startTime: 1)
    }

    @Test("Includes descendants but not unrelated processes with the same name")
    func subtreeExcludesSiblings() {
        let processes = [
            process(10, parent: 1),
            process(11, parent: 10),
            process(12, parent: 11),
            process(20, parent: 1),
            process(21, parent: 20),
        ]

        #expect(Set(processes.subtree(rootedAt: 10).map(\.pid)) == [10, 11, 12])
        #expect(processes.subtree(rootedAt: 99).isEmpty)
    }
}

@Suite("Termination safety")
struct TerminationSafetyTests {
    @Test("Refuses to signal a process without a start time")
    func refusesUnknownStartTime() {
        let process = ProcessSnapshot(pid: 4_000_000, parentPID: 1, user: "me", name: "node", command: "node server.js", cpuPercent: 0, memoryBytes: 0, startTime: 0)
        let group = ProcessGroup(name: "node", processes: [process], classification: .init(level: .review, label: "", reason: ""))

        let result = ProcessTerminator(currentPID: 1, currentUser: "me").terminate(group)

        #expect(result.refused == 1)
        #expect(result.stopped == 0)
    }

    @Test("Smart optimize never recommends development servers")
    func developmentServersAreNotRecommended() {
        let classifier = ProcessClassifier(currentPID: 1, currentUser: "me")
        for command in ["/p/.venv/bin/gunicorn main:app", "/p/node_modules/esbuild --service=0.21", "node webpack-dev-server"] {
            let process = ProcessSnapshot(pid: 500, parentPID: 1, user: "me", name: "x", command: command, cpuPercent: 0, memoryBytes: 0, startTime: 1)
            #expect(classifier.classify(process).level != .recommended)
        }
    }
}

@Suite("Port service root")
struct PortServiceRootTests {
    @Test("Walks up from a worker to the development server master")
    func walksUpToMaster() {
        let classifier = ProcessClassifier(currentPID: 1, currentUser: "me")
        func process(_ pid: Int32, _ parent: Int32, _ command: String) -> ProcessSnapshot {
            ProcessSnapshot(pid: pid, parentPID: parent, user: "me", name: "x", command: command, cpuPercent: 0, memoryBytes: 0, startTime: 1)
        }
        let processes = [
            process(100, 1, "-zsh"),
            process(200, 100, "/p/.venv/bin/gunicorn main:app"),
            process(201, 200, "/p/.venv/bin/gunicorn main:app"),
        ]
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })

        #expect(classifier.serviceRootPID(for: 201, in: byPID) == 200)
        #expect(classifier.serviceRootPID(for: 200, in: byPID) == 200)
        #expect(classifier.isInfrastructure(process(300, 200, "/opt/homebrew/bin/postgres -D data")))
    }
}
