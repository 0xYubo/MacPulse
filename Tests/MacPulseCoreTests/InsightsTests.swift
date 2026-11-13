import Foundation
import Testing
@testable import MacPulseCore

@Suite("Ports: dedupe and exposure")
struct PortInsightTests {
    @Test("Collapses IPv4 and IPv6 listeners that look identical")
    func dedupesDualStackListeners() {
        let output = """
        p645
        crapportd
        n*:49152
        n*:49152
        n127.0.0.1:49153
        """
        let sockets = PortScanner.parseListeningSockets(output, activePIDs: [])
        #expect(sockets.map(\.port) == [49152, 49153])
        #expect(Set(sockets.map(\.id)).count == sockets.count)
    }

    @Test("Flags databases listening on every interface")
    func flagsExposedDatabases() {
        #expect(PortExposure.isExposed(address: "*"))
        #expect(PortExposure.isExposed(address: "[::]"))
        #expect(PortExposure.isExposed(address: "127.0.0.1") == false)
        #expect(PortExposure.exposedSensitiveService(port: 3306, address: "*") == "MySQL")
        #expect(PortExposure.exposedSensitiveService(port: 6379, address: "0.0.0.0") == "Redis")
        #expect(PortExposure.exposedSensitiveService(port: 3306, address: "127.0.0.1") == nil)
        #expect(PortExposure.exposedSensitiveService(port: 8080, address: "*") == nil)
    }
}

@Suite("Process grouping for test runners")
struct TestRunnerGroupingTests {
    @Test("Groups jest workers under their project")
    func groupsJestWorkers() {
        let worker = "/Users/a/.fnm/node /work/web-app/node_modules/.pnpm/jest-worker@29.7.0/node_modules/jest-worker/build/workers/processChild.js"
        #expect(ProcessClassifier.displayName(command: worker, fallback: "node") == "测试 · web-app")
        let runner = "node ./node_modules/.bin/../jest/bin/jest.js"
        #expect(ProcessClassifier.displayName(command: runner, fallback: "node").hasPrefix("测试 · "))
    }

    @Test("Groups pytest under its project")
    func groupsPytest() {
        let command = "/work/api/.venv/bin/python /work/api/.venv/bin/pytest tests"
        #expect(ProcessClassifier.displayName(command: command, fallback: "python") == "测试 · api")
    }
}

@Suite("Group memory alerts")
struct GroupMemoryAlertTests {
    @Test("Alerts once per group until it drops below 80% of the threshold")
    func alertsOncePerGroup() {
        var tracker = GroupMemoryAlertTracker(thresholdBytes: 1_000)
        #expect(tracker.update([("jest", 500)]).isEmpty)
        #expect(tracker.update([("jest", 1_200), ("docker", 1_500)]).map(\.name) == ["docker", "jest"])
        #expect(tracker.update([("jest", 1_300), ("docker", 1_500)]).isEmpty)
        #expect(tracker.update([("jest", 900)]).isEmpty)          // 仍高于 80%，不重置
        #expect(tracker.update([("jest", 1_100)]).isEmpty)
        #expect(tracker.update([("jest", 700)]).isEmpty)          // 低于 80%，重置
        #expect(tracker.update([("jest", 1_100)]).map(\.name) == ["jest"])
    }
}

@Suite("Docker output parsing")
struct DockerParsingTests {
    @Test("Parses docker size strings")
    func parsesSizes() {
        #expect(DockerClient.parseSize("512B") == 512)
        #expect(DockerClient.parseSize("435.3MiB") == UInt64(435.3 * 1_048_576))
        #expect(DockerClient.parseSize(" 7.651GiB") == UInt64(7.651 * 1_073_741_824))
        #expect(DockerClient.parseSize("18.7MB") == 18_700_000)
        #expect(DockerClient.parseSize("abc") == nil)
    }

    @Test("Parses containers and stats JSON lines")
    func parsesContainersAndStats() {
        let ps = """
        {"ID":"aaa","Names":"web","Image":"nginx:1","State":"exited","Status":"Exited (0) 2 hours ago","Ports":""}
        {"ID":"bbb","Names":"db","Image":"mysql:8.0","State":"running","Status":"Up 13 minutes","Ports":"127.0.0.1:3323->3306/tcp"}
        not json
        """
        let containers = DockerClient.parseContainers(ps)
        #expect(containers.map(\.name) == ["db", "web"])     // 运行中的排前面
        #expect(containers.first?.isRunning == true)

        let stats = DockerClient.parseStats(#"{"Name":"db","CPUPerc":"1.25%","MemUsage":"435.3MiB / 7.651GiB","MemPerc":"5.56%"}"#)
        #expect(stats["db"]?.cpuPercent == 1.25)
        #expect(stats["db"]?.memoryBytes == UInt64(435.3 * 1_048_576))
    }

    @Test("Reports a missing docker binary as not installed")
    func reportsNotInstalled() {
        #expect(DockerClient(executable: nil).status() == .notInstalled)
    }
}

@Suite("Diagnostic reports")
struct DiagnosticReportTests {
    @Test("Classifies report files by name")
    func classifiesFiles() throws {
        func kind(_ name: String) -> DiagnosticEvent.Kind? {
            DiagnosticReportReader.event(for: URL(fileURLWithPath: "/r/\(name)"))?.kind
        }
        #expect(kind("JetsamEvent-2026-11-12-084400.ips") == .memoryExhausted)
        #expect(kind("shutdown_stall_2026-11-12-135614_Mac.shutdownStall") == .shutdownStall)
        #expect(kind("node_2026-11-11-113915_Mac.cpu_resource.diag") == .cpuResource)
        #expect(kind("Finder-2026-11-10-141700.ips") == .crash)
        #expect(kind("ExcUserFault_Mail-2026-11-10-141700.ips") == nil)
        #expect(kind("random.txt") == nil)

        let event = try #require(DiagnosticReportReader.event(for: URL(fileURLWithPath: "/r/node_2026-11-11-113915_Mac.cpu_resource.diag")))
        #expect(event.processName == "node")
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: event.date)
        #expect([parts.year, parts.month, parts.day, parts.hour, parts.minute] == [2026, 11, 11, 11, 39])
    }

    @Test("Sums jetsam memory by process name and lists killed processes")
    func parsesJetsam() {
        let report = """
        {"bug_type":"298"}
        {"memoryStatus":{"pageSize":16384},"processes":[
          {"name":"node","rpages":100},{"name":"node","rpages":50},
          {"name":"com.apple.Virtualization.Virtual","rpages":120},{"name":"Agent","rpages":1,"reason":"per-process-limit"}]}
        """
        let result = DiagnosticReportReader.parseJetsam(Data(report.utf8))
        #expect(result.top.first?.name == "node")
        #expect(result.top.first?.bytes == 150 * 16_384)
        #expect(result.top.first?.count == 2)
        #expect(result.killed == ["Agent（per-process-limit）"])
        #expect(result.top.contains { $0.name == "虚拟机（Docker 等）" })
        #expect(DiagnosticReportReader.parseJetsam(Data("garbage".utf8)).top.isEmpty)
    }

    @Test("Filters events older than the window")
    func filtersOldEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["Finder-2026-11-10-141700.ips", "Finder-2026-01-01-000000.ips"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        let now = try #require(DateComponents(calendar: .current, year: 2026, month: 11, day: 12).date)
        let events = DiagnosticReportReader(directories: [directory]).recentEvents(days: 14, now: now)
        #expect(events.count == 1)
    }
}

@Suite("Virtual machine naming")
struct VirtualMachineNamingTests {
    @Test("Names the Virtualization.framework VM readably")
    func namesVirtualMachine() {
        let command = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
        #expect(ProcessClassifier.displayName(command: command, fallback: "com.apple.Virtualization.VirtualMachine") == "虚拟机（Docker 等）")
    }
}
