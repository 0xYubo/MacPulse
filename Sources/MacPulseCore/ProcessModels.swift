import Foundation

public struct ProcessSnapshot: Identifiable, Hashable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let user: String
    public let name: String
    public let command: String
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let isEstimated: Bool
    public let startTime: UInt64

    public var id: Int32 { pid }

    public init(
        pid: Int32,
        parentPID: Int32,
        user: String,
        name: String,
        command: String,
        cpuPercent: Double,
        memoryBytes: UInt64,
        isEstimated: Bool = false,
        startTime: UInt64 = 0
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.user = user
        self.name = name
        self.command = command
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.isEstimated = isEstimated
        self.startTime = startTime
    }
}

public enum SafetyLevel: Int, Comparable, Sendable {
    case recommended
    case review
    case protected

    public static func < (lhs: SafetyLevel, rhs: SafetyLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ProcessClassification: Sendable {
    public let level: SafetyLevel
    public let label: String
    public let reason: String

    public init(level: SafetyLevel, label: String, reason: String) {
        self.level = level
        self.label = label
        self.reason = reason
    }
}

public struct ProcessGroup: Identifiable, Sendable {
    public let name: String
    public let processes: [ProcessSnapshot]
    public let classification: ProcessClassification

    public var id: String { name }
    public var cpuPercent: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
    public var memoryBytes: UInt64 { processes.reduce(0) { $0 + $1.memoryBytes } }
    public var processCount: Int { processes.count }
    public var isEstimated: Bool { processes.contains(where: \.isEstimated) }

    public init(name: String, processes: [ProcessSnapshot], classification: ProcessClassification) {
        self.name = name
        self.processes = processes
        self.classification = classification
    }
}

public extension Collection where Element == ProcessSnapshot {
    /// 以 rootPID 为根的进程子树（含根本身），按 parentPID 逐层展开。
    /// 关闭端口时只处理这棵子树，不能按显示名称整组结束：同名分组（如 node、python）会混入其他项目的进程。
    func subtree(rootedAt rootPID: Int32) -> [ProcessSnapshot] {
        let childrenByParent = Dictionary(grouping: self, by: \.parentPID)
        guard let root = first(where: { $0.pid == rootPID }) else { return [] }
        var result = [root]
        var visited: Set<Int32> = [root.pid]
        var queue = [root.pid]
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            for child in childrenByParent[parent] ?? [] where visited.insert(child.pid).inserted {
                result.append(child)
                queue.append(child.pid)
            }
        }
        return result
    }
}

public struct SystemSnapshot: Sendable {
    public let cpuPercent: Double
    public let userCPUPercent: Double
    public let systemCPUPercent: Double
    public let idleCPUPercent: Double
    public let usedMemoryBytes: UInt64
    public let totalMemoryBytes: UInt64
    /// 读取失败时为 nil。
    public let swapUsedBytes: UInt64?
    public let swapTotalBytes: UInt64?
    /// 读取失败时为 nil，界面显示「未知」。
    public let memoryPressure: MemoryPressure?
    public let memoryBreakdown: MemoryBreakdown?
    public let groups: [ProcessGroup]
    public let sampledAt: Date

    public var memoryPercent: Double {
        guard totalMemoryBytes > 0 else { return 0 }
        return Double(usedMemoryBytes) / Double(totalMemoryBytes) * 100
    }

    /// 交换用量占物理内存的比例；读不到交换信息时为 nil。
    public var swapRatio: Double? {
        guard let swapUsedBytes, totalMemoryBytes > 0 else { return nil }
        return Double(swapUsedBytes) / Double(totalMemoryBytes)
    }

    public init(
        cpuPercent: Double,
        userCPUPercent: Double = 0,
        systemCPUPercent: Double = 0,
        idleCPUPercent: Double = 0,
        usedMemoryBytes: UInt64,
        totalMemoryBytes: UInt64,
        swapUsedBytes: UInt64? = nil,
        swapTotalBytes: UInt64? = nil,
        memoryPressure: MemoryPressure? = nil,
        memoryBreakdown: MemoryBreakdown? = nil,
        groups: [ProcessGroup],
        sampledAt: Date = Date()
    ) {
        self.memoryPressure = memoryPressure
        self.memoryBreakdown = memoryBreakdown
        self.cpuPercent = cpuPercent
        self.userCPUPercent = userCPUPercent
        self.systemCPUPercent = systemCPUPercent
        self.idleCPUPercent = idleCPUPercent
        self.usedMemoryBytes = usedMemoryBytes
        self.totalMemoryBytes = totalMemoryBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.groups = groups
        self.sampledAt = sampledAt
    }
}
