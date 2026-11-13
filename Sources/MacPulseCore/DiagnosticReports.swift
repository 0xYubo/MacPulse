import Foundation

/// 读取系统诊断报告，复盘「上次卡顿 / 内存耗尽时谁占得最多」。
/// 报告由 macOS 自己写入 `/Library/Logs/DiagnosticReports` 与 `~/Library/Logs/DiagnosticReports`，无需任何设置。
public struct DiagnosticEvent: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case memoryExhausted = "内存耗尽"
        case shutdownStall = "关机卡住"
        case cpuResource = "CPU 超标"
        case diskWrites = "磁盘写入超标"
        case hang = "应用无响应"
        case crash = "应用崩溃"
    }

    public struct ProcessUsage: Equatable, Sendable {
        public let name: String
        public let bytes: UInt64
        public let count: Int
    }

    public let url: URL
    public let kind: Kind
    public let processName: String
    public let date: Date
    /// 仅内存耗尽事件：按进程名合计的占用，从大到小。
    public var topProcesses: [ProcessUsage] = []
    /// 仅内存耗尽事件：被系统结束的进程。
    public var killedProcesses: [String] = []

    public var id: String { url.path }
}

public struct DiagnosticReportReader: Sendable {
    public let directories: [URL]

    public init(directories: [URL] = [
        URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
    ]) {
        self.directories = directories
    }

    public func recentEvents(days: Int = 14, now: Date = Date()) -> [DiagnosticEvent] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var events: [DiagnosticEvent] = []
        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for url in files {
                guard var event = Self.event(for: url), event.date >= cutoff else { continue }
                if event.kind == .memoryExhausted, let data = try? Data(contentsOf: url) {
                    let detail = Self.parseJetsam(data)
                    event.topProcesses = detail.top
                    event.killedProcesses = detail.killed
                }
                events.append(event)
            }
        }
        return events.sorted { $0.date > $1.date }
    }

    // MARK: - 解析（纯函数，便于测试）

    /// 由文件名判断类型与时间，例如：
    /// `JetsamEvent-2026-11-12-084400.ips`、`node_2026-11-11-113915_Mac.cpu_resource.diag`、
    /// `shutdown_stall_2026-11-12-135614_Mac.shutdownStall`、`Finder-2026-11-10-141700.ips`。
    public static func event(for url: URL) -> DiagnosticEvent? {
        let name = url.lastPathComponent
        guard let match = name.range(of: #"[-_](\d{4}-\d{2}-\d{2}-\d{6})"#, options: .regularExpression) else { return nil }
        let stamp = String(name[match].dropFirst())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        guard let date = formatter.date(from: stamp) else { return nil }
        let process = String(name[..<match.lowerBound])

        let kind: DiagnosticEvent.Kind
        if process == "JetsamEvent" {
            kind = .memoryExhausted
        } else if name.hasSuffix(".shutdownStall") {
            kind = .shutdownStall
        } else if name.contains(".cpu_resource") {
            kind = .cpuResource
        } else if name.contains(".diskwrites_resource") {
            kind = .diskWrites
        } else if name.hasSuffix(".hang") || name.hasSuffix(".spin") {
            kind = .hang
        } else if name.hasSuffix(".ips"), !process.hasPrefix("ExcUserFault") {
            kind = .crash
        } else {
            return nil
        }
        return DiagnosticEvent(
            url: url,
            kind: kind,
            processName: kind == .memoryExhausted || kind == .shutdownStall ? kind.rawValue : process,
            date: date
        )
    }

    /// 报告里的进程名被内核截断到 32 个字符左右，几个常见的长名字换成易读的说法。
    static func friendlyName(_ name: String) -> String {
        if name.hasPrefix("com.apple.Virtualization") { return "虚拟机（Docker 等）" }
        if name.hasPrefix("com.apple.WebKit.WebContent") { return "网页内容（Safari 等）" }
        if name.hasPrefix("Google Chrome Helper") { return "Google Chrome Helper" }
        return name
    }

    /// Jetsam 报告：第一行是元数据 JSON，其余是正文 JSON。
    public static func parseJetsam(_ data: Data) -> (top: [DiagnosticEvent.ProcessUsage], killed: [String]) {
        guard let text = String(data: data, encoding: .utf8),
              let newline = text.firstIndex(of: "\n"),
              let body = text[text.index(after: newline)...].data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let processes = object["processes"] as? [[String: Any]] else { return ([], []) }
        let pageSize = ((object["memoryStatus"] as? [String: Any])?["pageSize"] as? NSNumber)?.uint64Value ?? 16_384
        var totals: [String: (bytes: UInt64, count: Int)] = [:]
        var killed: [String] = []
        for process in processes {
            let name = friendlyName(process["name"] as? String ?? "未知进程")
            let pages = (process["rpages"] as? NSNumber)?.uint64Value ?? 0
            let current = totals[name] ?? (0, 0)
            totals[name] = (current.bytes + pages * pageSize, current.count + 1)
            if let reason = process["reason"] as? String, !reason.isEmpty { killed.append("\(name)（\(reason)）") }
        }
        let top = totals
            .map { DiagnosticEvent.ProcessUsage(name: $0.key, bytes: $0.value.bytes, count: $0.value.count) }
            .sorted { $0.bytes > $1.bytes }
        return (Array(top.prefix(8)), killed)
    }
}
