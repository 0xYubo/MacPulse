import Foundation
import Testing
@testable import MacPulseCore

@Suite("Process safety classification")
struct ProcessClassifierTests {
    private let classifier = ProcessClassifier(currentPID: 999, currentUser: "alice")

    @Test("Protects macOS services")
    func protectsSystemServices() {
        let process = ProcessSnapshot(
            pid: 393,
            parentPID: 1,
            user: "_windowserver",
            name: "WindowServer",
            command: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
            cpuPercent: 20,
            memoryBytes: 100_000_000
        )

        #expect(classifier.classify(process).level == .protected)
        #expect(classifier.canTerminate(process) == false)
    }

    @Test("Protects MacPulse itself")
    func protectsCurrentProcess() {
        let process = ProcessSnapshot(
            pid: 999,
            parentPID: 1,
            user: "alice",
            name: "MacPulse",
            command: "/Applications/MacPulse.app/Contents/MacOS/MacPulse",
            cpuPercent: 1,
            memoryBytes: 20_000_000
        )

        #expect(classifier.classify(process).level == .protected)
    }

    @Test("Recommends optional cloud background services")
    func recommendsKnownOptionalBackgroundService() {
        let process = ProcessSnapshot(
            pid: 68616,
            parentPID: 1,
            user: "alice",
            name: "wpscloudsvr",
            command: "/Applications/wpsoffice.app/Contents/SharedSupport/wpscloudsvr.app/Contents/MacOS/wpscloudsvr autologin",
            cpuPercent: 3,
            memoryBytes: 60_000_000
        )

        let result = classifier.classify(process)
        #expect(result.level == .recommended)
        #expect(classifier.canTerminate(process))
    }

    @Test("Flags remote access for review")
    func flagsRemoteAccess() {
        let process = ProcessSnapshot(
            pid: 1234,
            parentPID: 1,
            user: "alice",
            name: "ssh",
            command: "/usr/bin/ssh -NR 127.0.0.1:2222:localhost:22 ubuntu@example",
            cpuPercent: 0,
            memoryBytes: 5_000_000
        )

        #expect(classifier.classify(process).level == .review)
        #expect(classifier.canTerminate(process))
    }

    @Test("Groups helpers under their application")
    func groupsApplicationHelpers() {
        let command = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper --type=renderer"
        #expect(ProcessClassifier.displayName(command: command, fallback: "Helper") == "Google Chrome")
    }

    @Test("Separates backend development projects")
    func separatesBackendProjects() {
        let command = "/project/shop/backend/.venv/bin/python /project/shop/backend-TASK-1254/.venv/bin/gunicorn -c gunicorn.conf.py main:app"
        #expect(ProcessClassifier.displayName(command: command, fallback: "python") == "Gunicorn · backend-TASK-1254")
    }

    @Test("Names frontend development services by project")
    func namesFrontendProjects() {
        let command = "/project/web/acme-frontend/node_modules/.pnpm/@esbuild+darwin-arm64/node_modules/@esbuild/darwin-arm64/bin/esbuild --service=0.21.4"
        #expect(ProcessClassifier.displayName(command: command, fallback: "esbuild") == "前端开发 · acme-frontend")
    }

    @Test("Names reverse SSH tunnels clearly")
    func namesReverseTunnel() {
        let command = "/usr/bin/ssh -NR 127.0.0.1:2222:localhost:22 ubuntu@example"
        #expect(ProcessClassifier.displayName(command: command, fallback: "ssh") == "SSH 反向隧道")
    }

    @Test("Does not terminate another user's process")
    func refusesOtherUsersProcess() {
        let process = ProcessSnapshot(
            pid: 321,
            parentPID: 1,
            user: "root",
            name: "third-party-daemon",
            command: "/Library/PrivilegedHelperTools/third-party-daemon",
            cpuPercent: 5,
            memoryBytes: 10_000_000
        )

        #expect(classifier.canTerminate(process) == false)
    }

    @Test("Recognizes development servers but excludes infrastructure")
    func identifiesSafeDevelopmentServers() {
        let dev = ProcessSnapshot(
            pid: 555,
            parentPID: 1,
            user: "alice",
            name: "gunicorn",
            command: "/work/backend-TASK-1882/.venv/bin/gunicorn main:app --bind 127.0.0.1:5882",
            cpuPercent: 0,
            memoryBytes: 20_000_000
        )
        let database = ProcessSnapshot(
            pid: 556,
            parentPID: 1,
            user: "alice",
            name: "postgres",
            command: "/opt/homebrew/bin/postgres -D /opt/homebrew/var/postgresql",
            cpuPercent: 0,
            memoryBytes: 20_000_000
        )

        #expect(classifier.isAutoClosableDevelopmentServer(dev))
        #expect(classifier.isAutoClosableDevelopmentServer(database) == false)
    }
}

@Suite("Development port discovery")
struct DevelopmentPortTests {
    @Test("Parses listening sockets and marks active clients")
    func parsesLsofOutput() {
        let output = """
        p120
        cpython
        n127.0.0.1:5882
        p121
        cnode
        n*:8882
        n[::1]:8883
        """

        let sockets = PortScanner.parseListeningSockets(output, activePIDs: [121])

        #expect(sockets.count == 3)
        #expect(sockets[0].pid == 120)
        #expect(sockets[0].port == 5882)
        #expect(sockets[0].hasEstablishedConnection == false)
        #expect(sockets[1].port == 8882)
        #expect(sockets[1].hasEstablishedConnection)
        #expect(sockets[2].address == "[::1]")
    }

    @Test("Only auto closes idle unconnected development ports")
    func evaluatesAutoClosePolicy() {
        let policy = DevelopmentPortPolicy(minimumIdleDuration: 1_800)

        #expect(policy.shouldAutoClose(isDevelopmentServer: true, hasEstablishedConnection: false, idleDuration: 1_801))
        #expect(policy.shouldAutoClose(isDevelopmentServer: true, hasEstablishedConnection: false, idleDuration: 1_799) == false)
        #expect(policy.shouldAutoClose(isDevelopmentServer: true, hasEstablishedConnection: true, idleDuration: 9_999) == false)
        #expect(policy.shouldAutoClose(isDevelopmentServer: false, hasEstablishedConnection: false, idleDuration: 9_999) == false)
    }

    @Test("Propagates active connections across a multi-process service")
    func propagatesGroupActivity() {
        let sockets = [
            ListeningSocket(pid: 10, processName: "gunicorn", address: "*", port: 5000, hasEstablishedConnection: false),
            ListeningSocket(pid: 11, processName: "gunicorn", address: "*", port: 5000, hasEstablishedConnection: true),
        ]
        let result = PortScanner.propagateActiveConnections(in: sockets, groupByPID: [10: "backend", 11: "backend"])

        #expect(result.allSatisfy { $0.hasEstablishedConnection })
    }
}

@Suite("AI cache cleanup safety")
struct AICacheCleanupTests {
    @Test("Catalog contains cache paths but never Claude VM data")
    func catalogIsStrictlyAllowlisted() {
        let paths = AICacheCleaner.catalog.map(\.relativePath)

        #expect(paths.contains("Library/Application Support/Claude/Cache"))
        #expect(paths.contains("Library/Caches/com.openai.codex"))
        #expect(paths.contains(where: { $0.localizedCaseInsensitiveContains("vm_bundles") }) == false)
    }

    @Test("Rejects cleanup outside the allowlist")
    func rejectsUnknownPaths() {
        let cleaner = AICacheCleaner(homeDirectory: URL(fileURLWithPath: "/Users/test"))

        #expect(cleaner.isAllowed(URL(fileURLWithPath: "/Users/test/Library/Caches/Codex")))
        #expect(cleaner.isAllowed(URL(fileURLWithPath: "/Users/test/Documents")) == false)
        #expect(cleaner.isAllowed(URL(fileURLWithPath: "/Users/test/Library/Application Support/Claude/vm_bundles")) == false)
    }
}

@Suite("CPU history")
struct CPUHistoryTests {
    @Test("Keeps only the newest samples")
    func limitsHistoryCapacity() {
        var history = CPUHistoryBuffer(capacity: 3)
        let start = Date(timeIntervalSince1970: 1_000)

        for index in 0..<5 {
            history.append(CPUHistorySample(
                timestamp: start.addingTimeInterval(Double(index)),
                totalPercent: Double(index),
                userPercent: Double(index) / 2,
                systemPercent: Double(index) / 2
            ))
        }

        #expect(history.samples.count == 3)
        #expect(history.samples.map(\.totalPercent) == [2, 3, 4])
    }

    @Test("Uses a minimum capacity of one")
    func enforcesMinimumCapacity() {
        var history = CPUHistoryBuffer(capacity: 0)
        history.append(.init(timestamp: Date(timeIntervalSince1970: 1), totalPercent: 1, userPercent: 1, systemPercent: 0))
        history.append(.init(timestamp: Date(timeIntervalSince1970: 2), totalPercent: 2, userPercent: 1, systemPercent: 1))

        #expect(history.capacity == 1)
        #expect(history.samples.map(\.totalPercent) == [2])
    }
}

@Suite("Live metrics sampling")
struct MetricsSamplerTests {
    @Test("Uses Activity Monitor-style system memory accounting")
    func computesUsedMemoryPages() {
        // 已使用 = 总量 − 空闲 − 可清除 − 文件缓存；不在任何分类里的内核/显卡内存计入已使用。
        #expect(MetricsSampler.usedMemoryPages(totalPages: 1_000, free: 50, purgeable: 30, external: 120) == 800)
        #expect(MetricsSampler.usedMemoryPages(totalPages: 100, free: 60, purgeable: 30, external: 20) == 0)
    }

    @Test("Smooths displayed CPU over recent samples")
    func smoothsCPU() {
        var smoother = CPUSmoother(window: 3)
        func sample(_ total: Double) -> CPUHistorySample {
            CPUHistorySample(timestamp: Date(), totalPercent: total, userPercent: total / 2, systemPercent: total / 2)
        }

        #expect(smoother.add(sample(30)).totalPercent == 30)
        #expect(smoother.add(sample(60)).totalPercent == 45)
        #expect(smoother.add(sample(0)).totalPercent == 30)
        // 超出窗口的最早一次（30）被丢弃：(60 + 0 + 90) / 3
        #expect(smoother.add(sample(90)).totalPercent == 50)
    }

    @Test("Reads swap usage")
    func readsSwap() throws {
        let swap = try #require(MetricsSampler.swapUsage())
        #expect(swap.used <= swap.total || swap.total == 0)
    }

    @Test("Returns bounded system metrics and running processes")
    func samplesCurrentSystem() throws {
        let snapshot = try MetricsSampler().sample()

        #expect(snapshot.cpuPercent >= 0)
        #expect(snapshot.cpuPercent <= 100)
        #expect(snapshot.userCPUPercent >= 0)
        #expect(snapshot.systemCPUPercent >= 0)
        #expect(snapshot.idleCPUPercent >= 0)
        #expect(abs(snapshot.cpuPercent + snapshot.idleCPUPercent - 100) < 0.01)
        #expect(snapshot.totalMemoryBytes > 0)
        #expect(snapshot.usedMemoryBytes <= snapshot.totalMemoryBytes)
        #expect(snapshot.groups.isEmpty == false)
    }
}
