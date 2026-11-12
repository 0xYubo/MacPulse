import AppKit
import Foundation
import MacPulseNative

public struct TrashTarget: Sendable {
    public let url: URL
    public let sizeBytes: UInt64

    public init(url: URL, sizeBytes: UInt64) {
        self.url = url
        self.sizeBytes = sizeBytes
    }
}

public enum TrashOutcome: Sendable {
    case trashed(URL, UInt64)
    case skipped(URL, String)
    case failed(URL, String)

    public var url: URL {
        switch self {
        case .trashed(let url, _), .skipped(let url, _), .failed(let url, _): url
        }
    }
}

public struct SizeMeasurement: Sendable {
    public let bytes: UInt64
    public let unreadableCount: Int
}

/// 文件系统安全工具：所有删除路径共用，避免各功能各自实现一套「是否在白名单内」的判断。
public enum PathSafety {
    public enum EntryState: Equatable, Sendable {
        case missing
        case symbolicLink
        case present
        /// 存在与否无法确认（例如 macOS 隐私保护拒绝访问），调用方必须按「不能删除」处理。
        case unreadable(String)
    }

    /// 不跟随符号链接读取条目状态；读不到时区分「不存在」与「无权限」，不把后者误报成前者。
    public static func state(of url: URL) -> EntryState {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.type] as? FileAttributeType == .typeSymbolicLink ? .symbolicLink : .present
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .missing
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// 读不到属性时同样视为「可能是链接」：这个判断用于拒绝删除，失败时必须偏向保守。
    public static func isSymbolicLink(_ url: URL) -> Bool {
        switch state(of: url) {
        case .symbolicLink, .unreadable: true
        case .missing, .present: false
        }
    }

    /// 只要条目存在（包括悬空的符号链接）就返回 true；`fileExists` 会跟随链接，悬空链接会被误判为不存在。
    public static func exists(_ url: URL) -> Bool {
        state(of: url) != .missing
    }

    /// 解析父目录中的符号链接，但保留最后一级本身。
    /// 删除时作用的是最后一级条目本身：若它是链接，删除的只是链接；而父目录被替换成链接时，真实位置会被暴露出来。
    public static func resolvedLocation(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(standardized.lastPathComponent)
    }

    /// 统计占用的磁盘空间（分配大小，而非逻辑大小），不跟随符号链接；无法读取的条目单独计数，不静默忽略。
    public static func allocatedSize(of url: URL) -> SizeMeasurement {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        switch state(of: url) {
        case .missing, .symbolicLink: return SizeMeasurement(bytes: 0, unreadableCount: 0)
        case .unreadable: return SizeMeasurement(bytes: 0, unreadableCount: 1)
        case .present: break
        }

        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return SizeMeasurement(bytes: UInt64(max(values.totalFileAllocatedSize ?? values.fileSize ?? 0, 0)), unreadableCount: 0)
        }

        final class ErrorCounter: @unchecked Sendable { var count = 0 }
        let errors = ErrorCounter()
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in
                errors.count += 1
                return true
            }
        ) else {
            return SizeMeasurement(bytes: 0, unreadableCount: 1)
        }

        var total: UInt64 = 0
        var visited = 0
        for case let fileURL as URL in enumerator {
            visited += 1
            // 大目录（DerivedData、pnpm store）统计耗时较长；任务被取消时提前结束，由调用方的取消检查抛出。
            if visited % 1_000 == 0, Task.isCancelled { break }
            guard let values = try? fileURL.resourceValues(forKeys: keys) else {
                errors.count += 1
                continue
            }
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            total += UInt64(max(values.totalFileAllocatedSize ?? values.fileSize ?? 0, 0))
        }
        return SizeMeasurement(bytes: total, unreadableCount: errors.count)
    }
}

/// 移到废纸篓前的统一守卫。每个目标都会得到明确结果：已移入、跳过（带原因）或失败（带原因）。
public struct SafeTrash: Sendable {
    public typealias Remover = @Sendable (URL) throws -> Void

    /// ~/Library 下这些子树存放钥匙串、iCloud、邮件等账号数据，任何清理功能都不应进入。
    static let forbiddenLibrarySubtrees = [
        "Keychains", "Mobile Documents", "CloudStorage", "Mail", "Messages", "Accounts", "Calendars",
        "Application Support/AddressBook", "Application Support/MobileSync",
    ]

    private let allowedRoots: [String]
    /// 小写形式：默认的 APFS 不区分大小写，「~/library/caches」与「~/Library/Caches」是同一目录。
    private let protectedPaths: Set<String>
    private let forbiddenSubtrees: [String]
    private let trashDirectory: String
    private let initializationError: String?

    /// - Parameters:
    ///   - homeDirectory: 用户主目录，始终是允许的根。
    ///   - extraRoots: 额外允许的根（例如卸载时的 /Applications），根本身始终受保护。
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, extraRoots: [URL] = []) {
        let home = homeDirectory.resolvingSymlinksInPath().standardizedFileURL
        let library = home.appendingPathComponent("Library")
        let roots = [home] + extraRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        allowedRoots = roots.map(\.path)

        var protected = Set(roots.map(\.path))
        protected.insert(library.path)
        var initializationError: String?
        // ~/Library 下的一级目录（Caches、Preferences、Containers……）是系统约定的容器，只允许删除其中的条目。
        // 列不出这些目录时守卫无法判断，宁可拒绝全部删除。
        do {
            let children = try FileManager.default.contentsOfDirectory(atPath: library.path)
            children.forEach { protected.insert(library.appendingPathComponent($0).path) }
        } catch {
            initializationError = "无法读取 ~/Library，已停止删除：\(error.localizedDescription)"
        }
        for name in ["Documents", "Desktop", "Downloads", "Applications", "Movies", "Music", "Pictures", "Public", ".Trash"] {
            protected.insert(home.appendingPathComponent(name).path)
        }
        protectedPaths = Set(protected.map { $0.lowercased() })
        forbiddenSubtrees = Self.forbiddenLibrarySubtrees.map { library.appendingPathComponent($0).path.lowercased() }
        trashDirectory = home.appendingPathComponent(".Trash").path.lowercased()
        self.initializationError = initializationError
    }

    /// 返回拒绝原因；nil 表示允许移入废纸篓。
    public func rejectionReason(for url: URL) -> String? {
        if let initializationError { return initializationError }
        let location = PathSafety.resolvedLocation(url).path
        let folded = location.lowercased()
        if protectedPaths.contains(folded) {
            return "受保护的目录本身不能删除"
        }
        if folded == trashDirectory || folded.hasPrefix(trashDirectory + "/") {
            return "已在废纸篓中"
        }
        if forbiddenSubtrees.contains(where: { folded == $0 || folded.hasPrefix($0 + "/") }) {
            return "账号或同步数据目录，不允许清理"
        }
        // 根目录用区分大小写的前缀比较：大小写不一致时直接拒绝，只会更保守。
        guard allowedRoots.contains(where: { location.hasPrefix($0 + "/") }) else {
            return "实际位置不在允许清理的范围内"
        }
        return nil
    }

    public func trash(
        _ targets: [TrashTarget],
        remover: Remover = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> [TrashOutcome] {
        targets.map { target in
            switch PathSafety.state(of: target.url) {
            case .missing:
                return .skipped(target.url, "已不存在")
            case .unreadable(let message):
                return .skipped(target.url, "无法读取：\(message)")
            case .present, .symbolicLink:
                break
            }
            if let reason = rejectionReason(for: target.url) {
                return .skipped(target.url, reason)
            }
            do {
                try remover(target.url)
                return .trashed(target.url, target.sizeBytes)
            } catch {
                return .failed(target.url, error.localizedDescription)
            }
        }
    }
}

public func diskByteString(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}

public struct TrashSummary: Sendable {
    public let trashedCount: Int
    public let trashedBytes: UInt64
    public let trashedURLs: [URL]
    public let skipped: [(URL, String)]
    public let failed: [(URL, String)]

    public init(_ outcomes: [TrashOutcome]) {
        var urls: [URL] = []
        var bytes: UInt64 = 0
        var skipped: [(URL, String)] = []
        var failed: [(URL, String)] = []
        for outcome in outcomes {
            switch outcome {
            case .trashed(let url, let size):
                urls.append(url)
                bytes += size
            case .skipped(let url, let reason): skipped.append((url, reason))
            case .failed(let url, let reason): failed.append((url, reason))
            }
        }
        trashedCount = urls.count
        trashedBytes = bytes
        trashedURLs = urls
        self.skipped = skipped
        self.failed = failed
    }

    /// 面向用户的结果说明：跳过与失败都逐项列出原因（最多 3 条），不做静默处理。
    public var message: String {
        var lines = ["已移到废纸篓 \(trashedCount) 项，约 \(diskByteString(trashedBytes))。"]
        if !skipped.isEmpty {
            lines.append("跳过 \(skipped.count) 项：")
            lines += skipped.prefix(3).map { "· \($0.0.lastPathComponent)：\($0.1)" }
        }
        if !failed.isEmpty {
            lines.append("失败 \(failed.count) 项：")
            lines += failed.prefix(3).map { "· \($0.0.lastPathComponent)：\($0.1)" }
        }
        if trashedCount > 0 {
            lines.append("清空废纸篓后才会真正释放空间。")
        }
        return lines.joined(separator: "\n")
    }
}

/// 读取当前所有进程的命令行。返回 nil 表示无法确认运行状态，调用方必须中止删除，而不是当作「无进程运行」。
public enum RunningCommands {
    public static func read() -> [String]? {
        RunningProcesses.read()?.commands
    }
}

/// 进程快照：命令行 + 当前用户进程的工作目录。
/// 只看命令行会漏掉 `npm run dev`、`python manage.py runserver` 这类用相对路径启动的进程，所以同时读取工作目录。
public struct RunningProcesses: Sendable {
    public let commands: [String]
    public let workingDirectories: [String]

    public static func read() -> RunningProcesses? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            var commands: [String] = []
            var directories: [String] = []
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            for line in text.split(separator: "\n") {
                let trimmed = line.drop(while: { $0 == " " })
                guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
                commands.append(String(trimmed[trimmed.index(after: space)...]))
                // 其他用户的进程读不到工作目录（权限所限），它们也不会使用当前用户的项目目录。
                if mp_read_process_cwd(pid, &buffer, UInt32(buffer.count)) == 0 {
                    let directory = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if directory != "/" { directories.append(directory) }
                }
            }
            return RunningProcesses(commands: commands, workingDirectories: directories)
        } catch {
            return nil
        }
    }
}

public enum WorkspaceRecycler {
    /// 先用 FileManager 移入废纸篓；遇到权限不足（例如 root 拥有的 App）时交给 NSWorkspace，由系统处理授权。
    /// 必须在非主线程调用：这里会同步等待 NSWorkspace 的回调，而回调在主线程上执行。
    public static func recycle(_ url: URL) throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return
        } catch {
            guard isPermissionError(error) else { throw error }
        }

        final class Box: @unchecked Sendable { var error: Error? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.recycle([url]) { _, error in
            box.error = error
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 120) == .timedOut {
            // 超时不代表失败：用户可能稍后才在授权框里确认。以文件是否还在为准。
            guard PathSafety.exists(url) else { return }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "等待系统授权超时"])
        }
        if let error = box.error { throw error }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.fileWriteNoPermission.rawValue { return true }
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError) ?? nsError
        return underlying.domain == NSPOSIXErrorDomain && (underlying.code == Int(EACCES) || underlying.code == Int(EPERM))
    }
}
