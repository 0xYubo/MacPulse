import Foundation

public struct CPUHistorySample: Identifiable, Equatable, Sendable {
    public let timestamp: Date
    public let totalPercent: Double
    public let userPercent: Double
    public let systemPercent: Double

    public var id: Date { timestamp }

    public init(timestamp: Date, totalPercent: Double, userPercent: Double, systemPercent: Double) {
        self.timestamp = timestamp
        self.totalPercent = totalPercent
        self.userPercent = userPercent
        self.systemPercent = systemPercent
    }
}

public typealias CPUHistoryBuffer = HistoryBuffer<CPUHistorySample>
public typealias MemoryHistoryBuffer = HistoryBuffer<MemoryHistorySample>

public struct HistoryBuffer<Sample: Sendable>: Sendable {
    public let capacity: Int
    public private(set) var samples: [Sample] = []

    public init(capacity: Int = 60) {
        self.capacity = max(capacity, 1)
    }

    public mutating func append(_ sample: Sample) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }
}

/// 界面显示用的 CPU 平滑：取最近几次采样的平均值。
/// 单次采样只覆盖 3 秒（面板收起时 15 秒），负载起伏大时与活动监视器（默认 5 秒、刷新时刻不同）会相差近 10 个百分点；
/// 平均约 9 秒后数字稳定，峰值仍保留在历史曲线中。
public struct CPUSmoother: Sendable {
    public let window: Int
    private var recent: [CPUHistorySample] = []

    public init(window: Int = 3) {
        self.window = max(window, 1)
    }

    public mutating func add(_ sample: CPUHistorySample) -> CPUHistorySample {
        recent.append(sample)
        if recent.count > window { recent.removeFirst(recent.count - window) }
        let count = Double(recent.count)
        return CPUHistorySample(
            timestamp: sample.timestamp,
            totalPercent: recent.reduce(0) { $0 + $1.totalPercent } / count,
            userPercent: recent.reduce(0) { $0 + $1.userPercent } / count,
            systemPercent: recent.reduce(0) { $0 + $1.systemPercent } / count
        )
    }
}
