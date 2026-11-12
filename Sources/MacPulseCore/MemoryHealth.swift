import Foundation

/// 系统内存压力，与活动监视器「内存」页底部的「内存压力」曲线同源（`kern.memorystatus_vm_pressure_level`）。
/// 判断内存够不够要看它，而不是「已使用内存」百分比：macOS 会把空闲内存拿去做文件缓存、并压缩不常用的页，
/// 已使用 70% 而压力正常是常态；真正卡死时（例如多个 jest worker 把内存打满）压力会先变红。
public enum MemoryPressure: Int, Sendable, Comparable, CaseIterable {
    case normal = 1
    case warning = 2
    case critical = 4

    /// 内核值只有 1 / 2 / 4 三种；其他值视为读取异常，返回 nil，界面显示「未知」而不是假装正常。
    public init?(kernelLevel: Int32) {
        self.init(rawValue: Int(kernelLevel))
    }

    public var label: String {
        switch self {
        case .normal: "正常"
        case .warning: "偏高"
        case .critical: "紧张"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 内存构成，口径与活动监视器一致：
/// App 内存 = 匿名页 − 可清除页；联动 = 内核固定页；压缩 = 压缩器占用页；已缓存文件 = 文件页 + 可清除页。
/// 已缓存文件在有程序需要时会立即让出，所以不计入「已使用」。
public struct MemoryBreakdown: Sendable, Equatable {
    public let appBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedBytes: UInt64
    public let freeBytes: UInt64

    public init(appBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64, cachedBytes: UInt64, freeBytes: UInt64) {
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.freeBytes = freeBytes
    }

    public static func fromPages(
        pageSize: UInt64,
        anonymous: UInt64,
        purgeable: UInt64,
        wired: UInt64,
        compressor: UInt64,
        external: UInt64,
        free: UInt64,
        speculative: UInt64
    ) -> MemoryBreakdown {
        MemoryBreakdown(
            appBytes: (anonymous > purgeable ? anonymous - purgeable : 0) * pageSize,
            wiredBytes: wired * pageSize,
            compressedBytes: compressor * pageSize,
            cachedBytes: (external + purgeable) * pageSize,
            freeBytes: (free + speculative) * pageSize
        )
    }
}

public struct MemoryHistorySample: Identifiable, Equatable, Sendable {
    public let timestamp: Date
    public let usedPercent: Double
    public let pressure: MemoryPressure?

    public var id: Date { timestamp }

    public init(timestamp: Date, usedPercent: Double, pressure: MemoryPressure?) {
        self.timestamp = timestamp
        self.usedPercent = usedPercent
        self.pressure = pressure
    }
}

/// 顶部状态（运行平稳 / 负载中等 / 负载较高）的判定。
/// 内存一侧只看压力与交换：此前用「已使用 ≥ 75%」判中等负载，会把文件缓存占满的正常状态误报成负载，
/// 而压力真正变红时又没有专门提示。
public struct SystemHealth: Equatable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case calm, moderate, high
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let level: Level
    public let text: String

    /// 交换用量达到物理内存一半才计入：交换文件不会主动缩小，一次内存高峰后会残留数 GB，单看它会长期误报。
    public static func evaluate(cpuPercent: Double, pressure: MemoryPressure?, swapRatio: Double?) -> SystemHealth {
        if pressure == .critical { return SystemHealth(level: .high, text: "内存紧张，可能卡顿") }
        if cpuPercent >= 80 { return SystemHealth(level: .high, text: "CPU 负载较高") }
        if pressure == .warning { return SystemHealth(level: .moderate, text: "内存压力偏高") }
        if let swapRatio, swapRatio >= 0.5 { return SystemHealth(level: .moderate, text: "交换空间用量较大") }
        if cpuPercent >= 50 { return SystemHealth(level: .moderate, text: "CPU 负载中等") }
        return SystemHealth(level: .calm, text: "运行平稳")
    }
}

/// 内存压力升级提醒：只在从较低等级升上来时提醒一次，回落到正常后才重新计数，避免每次采样重复弹通知。
public struct PressureAlertTracker: Sendable {
    public let threshold: MemoryPressure
    private var alertedLevel: MemoryPressure?

    public init(threshold: MemoryPressure = .critical) {
        self.threshold = threshold
    }

    /// 返回需要提醒的压力等级；不需要提醒时返回 nil。
    public mutating func update(_ pressure: MemoryPressure?) -> MemoryPressure? {
        guard let pressure else { return nil }
        if pressure < threshold {
            if pressure == .normal { alertedLevel = nil }
            return nil
        }
        if let alertedLevel, alertedLevel >= pressure { return nil }
        alertedLevel = pressure
        return pressure
    }
}
