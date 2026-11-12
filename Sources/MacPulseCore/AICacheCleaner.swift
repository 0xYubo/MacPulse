import Foundation

public enum AICacheCleanerError: Error, LocalizedError {
    case processListUnavailable

    public var errorDescription: String? { "无法确认 AI 应用是否仍在运行，已取消清理" }
}

public struct AICacheDefinition: Identifiable, Hashable, Sendable {
    public let name: String
    public let relativePath: String
    public let runningTokens: [String]

    public var id: String { relativePath }

    public init(name: String, relativePath: String, runningTokens: [String]) {
        self.name = name
        self.relativePath = relativePath
        self.runningTokens = runningTokens
    }
}

public struct AICacheUsage: Identifiable, Sendable {
    public let definition: AICacheDefinition
    public let sizeBytes: UInt64
    public let isInUse: Bool

    public var id: String { definition.id }

    public init(definition: AICacheDefinition, sizeBytes: UInt64, isInUse: Bool) {
        self.definition = definition
        self.sizeBytes = sizeBytes
        self.isInUse = isInUse
    }
}

public struct AICacheCleanResult: Sendable {
    public var cleanedCount = 0
    public var reclaimedBytes: UInt64 = 0
    public var skipped: [(String, String)] = []
    public var failed: [(String, String)] = []

    public init() {}

    public var message: String {
        var lines = ["已清理 \(cleanedCount) 项，释放 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: reclaimedBytes), countStyle: .file))。"]
        if !skipped.isEmpty {
            lines.append("跳过 \(skipped.count) 项：")
            lines += skipped.prefix(3).map { "· \($0.0)：\($0.1)" }
        }
        if !failed.isEmpty {
            lines.append("失败 \(failed.count) 项：")
            lines += failed.prefix(3).map { "· \($0.0)：\($0.1)" }
        }
        return lines.joined(separator: "\n")
    }
}

public struct AICacheCleaner: Sendable {
    public static let catalog: [AICacheDefinition] = [
        .init(name: "Claude 网页缓存", relativePath: "Library/Application Support/Claude/Cache", runningTokens: ["claude.app"]),
        .init(name: "Claude 代码缓存", relativePath: "Library/Application Support/Claude/Code Cache", runningTokens: ["claude.app"]),
        .init(name: "Claude 图形缓存", relativePath: "Library/Application Support/Claude/GPUCache", runningTokens: ["claude.app"]),
        .init(name: "Claude Dawn 缓存", relativePath: "Library/Application Support/Claude/DawnCache", runningTokens: ["claude.app"]),
        .init(name: "Claude DawnGraphite 缓存", relativePath: "Library/Application Support/Claude/DawnGraphiteCache", runningTokens: ["claude.app"]),
        .init(name: "Claude Desktop 缓存", relativePath: "Library/Caches/com.anthropic.claudefordesktop", runningTokens: ["claude.app"]),
        .init(name: "Claude CLI 缓存", relativePath: "Library/Caches/claude-cli-nodejs", runningTokens: ["/claude", "claude "]),
        .init(name: "Codex 缓存", relativePath: "Library/Caches/com.openai.codex", runningTokens: ["codex.app"]),
        .init(name: "Codex 应用缓存", relativePath: "Library/Caches/Codex", runningTokens: ["codex.app"]),
        .init(name: "Otty 缓存", relativePath: "Library/Caches/io.appmakes.otty", runningTokens: ["otty.app", "otty-cli"]),
    ]

    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    public func scan(runningCommands: [String]) -> [AICacheUsage] {
        let lowerCommands = runningCommands.map { $0.lowercased() }
        return Self.catalog.compactMap { definition in
            let url = homeDirectory.appendingPathComponent(definition.relativePath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let isInUse = definition.runningTokens.contains { token in
                lowerCommands.contains(where: { $0.contains(token.lowercased()) })
            }
            return AICacheUsage(definition: definition, sizeBytes: PathSafety.allocatedSize(of: url).bytes, isInUse: isInUse)
        }
    }

    public func clean(_ usages: [AICacheUsage]) throws -> AICacheCleanResult {
        guard let commands = RunningCommands.read() else {
            throw AICacheCleanerError.processListUnavailable
        }
        let runningCommands = commands.map { $0.lowercased() }
        var result = AICacheCleanResult()
        for usage in usages where !usage.isInUse {
            let name = usage.definition.name
            let isNowInUse = usage.definition.runningTokens.contains { token in
                runningCommands.contains(where: { $0.contains(token.lowercased()) })
            }
            guard !isNowInUse else {
                result.skipped.append((name, "应用刚刚启动，已跳过"))
                continue
            }
            let directory = homeDirectory.appendingPathComponent(usage.definition.relativePath).standardizedFileURL
            if let reason = rejectionReason(for: directory) {
                result.skipped.append((name, reason))
                continue
            }
            let before = PathSafety.allocatedSize(of: directory).bytes
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            } catch {
                result.failed.append((name, error.localizedDescription))
                continue
            }
            var failures = 0
            var firstError: String?
            // removeItem 作用于子项本身：子项是符号链接时只删除链接，不会进入链接目标。
            for child in children {
                do {
                    try FileManager.default.removeItem(at: child)
                } catch {
                    failures += 1
                    firstError = firstError ?? error.localizedDescription
                }
            }
            let after = PathSafety.allocatedSize(of: directory).bytes
            result.reclaimedBytes += before > after ? before - after : 0
            if let firstError {
                result.failed.append((name, "\(failures) 个条目删除失败：\(firstError)"))
            } else {
                result.cleanedCount += 1
            }
        }
        return result
    }

    /// 白名单判断之外，再确认目录真实位置没有被符号链接改向：
    /// 目录本身或任一父目录被替换为链接时，删除子项会作用到链接目标，因此必须拒绝。
    func rejectionReason(for directory: URL) -> String? {
        guard isAllowed(directory) else { return "不在缓存白名单内" }
        guard !PathSafety.isSymbolicLink(directory) else { return "缓存目录是符号链接，已跳过" }
        let expected = homeDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(String(directory.path.dropFirst(homeDirectory.path.count + 1)))
            .standardizedFileURL.path
        guard PathSafety.resolvedLocation(directory).path == expected else {
            return "缓存目录的上级路径是符号链接，已跳过"
        }
        return nil
    }

    public func isAllowed(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL.path
        return Self.catalog.contains {
            homeDirectory.appendingPathComponent($0.relativePath).standardizedFileURL.path == candidate
        }
    }
}
