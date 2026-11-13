import Foundation

public struct DockerContainer: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    public let state: String
    public let status: String
    public let ports: String
    public var cpuPercent: Double?
    public var memoryBytes: UInt64?

    public var isRunning: Bool { state.lowercased() == "running" }
}

public struct DockerOverview: Equatable, Sendable {
    public let containers: [DockerContainer]
    /// Docker 虚拟机可用的内存上限（`docker info` 的 MemTotal）。
    public let memoryLimitBytes: UInt64?
    public let cpuCount: Int?

    public var runningContainers: [DockerContainer] { containers.filter(\.isRunning) }
    public var containerMemoryBytes: UInt64 { containers.compactMap(\.memoryBytes).reduce(0, +) }
}

public enum DockerStatus: Equatable, Sendable {
    case notInstalled
    /// Docker 已安装但守护进程没在运行（或启动失败）。
    case daemonUnavailable(String)
    case running(DockerOverview)
}

public struct DockerClient: Sendable {
    public let executable: URL?

    public static let candidatePaths = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
        "~/.orbstack/bin/docker",
        "~/.docker/bin/docker",
    ]

    /// 菜单栏应用不继承终端的 PATH，只能按常见安装位置查找。
    public init(executable: URL? = DockerClient.locate()) {
        self.executable = executable
    }

    public static func locate() -> URL? {
        candidatePaths
            .map { ($0 as NSString).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public func status() -> DockerStatus {
        guard let executable else { return .notInstalled }
        let ps = Self.run(executable, ["ps", "-a", "--no-trunc", "--format", "{{json .}}"])
        guard ps.status == 0 else {
            let message = ps.error.trimmingCharacters(in: .whitespacesAndNewlines)
            return .daemonUnavailable(message.isEmpty ? "Docker 未运行" : message)
        }
        var containers = Self.parseContainers(ps.output)
        if containers.contains(where: \.isRunning) {
            let stats = Self.parseStats(Self.run(executable, ["stats", "--no-stream", "--format", "{{json .}}"], timeout: 15).output)
            containers = containers.map { container in
                var copy = container
                if let stat = stats[container.name] {
                    copy.cpuPercent = stat.cpuPercent
                    copy.memoryBytes = stat.memoryBytes
                }
                return copy
            }
        }
        let info = Self.run(executable, ["info", "--format", "{{.MemTotal}} {{.NCPU}}"]).output.split(separator: " ")
        return .running(DockerOverview(
            containers: containers,
            memoryLimitBytes: info.first.flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
            cpuCount: info.dropFirst().first.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        ))
    }

    /// 启动或停止容器。返回错误信息，成功时为 nil。
    public func setRunning(_ running: Bool, containerID: String) -> String? {
        guard let executable else { return "未找到 docker 命令" }
        let result = Self.run(executable, [running ? "start" : "stop", containerID], timeout: 60)
        guard result.status != 0 else { return nil }
        let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "docker \(running ? "start" : "stop") 失败" : message
    }

    // MARK: - 解析（纯函数，便于测试）

    public static func parseContainers(_ text: String) -> [DockerContainer] {
        jsonLines(text).compactMap { object in
            guard let id = object["ID"] as? String, let name = object["Names"] as? String else { return nil }
            return DockerContainer(
                id: id,
                name: name,
                image: object["Image"] as? String ?? "",
                state: object["State"] as? String ?? "",
                status: object["Status"] as? String ?? "",
                ports: object["Ports"] as? String ?? ""
            )
        }
        .sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }
    }

    public static func parseStats(_ text: String) -> [String: (cpuPercent: Double?, memoryBytes: UInt64?)] {
        var result: [String: (cpuPercent: Double?, memoryBytes: UInt64?)] = [:]
        for object in jsonLines(text) {
            guard let name = object["Name"] as? String else { continue }
            let cpu = (object["CPUPerc"] as? String).flatMap { Double($0.replacingOccurrences(of: "%", with: "")) }
            let memory = (object["MemUsage"] as? String)
                .flatMap { $0.components(separatedBy: "/").first }
                .flatMap(parseSize)
            result[name] = (cpu, memory)
        }
        return result
    }

    /// 解析 docker 的大小写法：`435.3MiB`、`7.651GiB`、`18.7MB`、`512B`。
    public static func parseSize(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [
            ("KiB", 1_024), ("MiB", 1_048_576), ("GiB", 1_073_741_824), ("TiB", 1_099_511_627_776),
            ("kB", 1_000), ("KB", 1_000), ("MB", 1_000_000), ("GB", 1_000_000_000), ("TB", 1_000_000_000_000),
            ("B", 1),
        ]
        for (suffix, factor) in units where trimmed.hasSuffix(suffix) {
            guard let value = Double(trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) else { return nil }
            return UInt64(value * factor)
        }
        return nil
    }

    private static func jsonLines(_ text: String) -> [[String: Any]] {
        text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    /// 带超时：守护进程卡住时 docker 命令可能长时间不返回，不能把刷新拖死。
    private static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 8) -> (status: Int32, output: String, error: String) {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch { return (-1, "", error.localizedDescription) }
        let deadline = DispatchTime.now() + timeout
        final class Buffer: @unchecked Sendable { var out = Data(); var err = Data() }
        let buffer = Buffer()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            buffer.out = output.fileHandleForReading.readDataToEndOfFile()
            buffer.err = error.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return (-1, "", "docker 命令超时")
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: buffer.out, as: UTF8.self), String(decoding: buffer.err, as: UTF8.self))
    }
}
