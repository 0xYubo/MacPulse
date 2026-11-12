import Foundation
import Testing
@testable import MacPulseCore

@Suite("Memory pressure and health")
struct MemoryHealthTests {
    @Test("Maps kernel pressure levels and rejects unknown values")
    func mapsKernelLevels() {
        #expect(MemoryPressure(kernelLevel: 1) == .normal)
        #expect(MemoryPressure(kernelLevel: 2) == .warning)
        #expect(MemoryPressure(kernelLevel: 4) == .critical)
        #expect(MemoryPressure(kernelLevel: 0) == nil)
        #expect(MemoryPressure(kernelLevel: 3) == nil)
    }

    @Test("Reads a live pressure level")
    func readsLivePressure() throws {
        _ = try #require(MetricsSampler.memoryPressure())
    }

    @Test("Breaks memory down the way Activity Monitor does")
    func breaksDownMemory() {
        let breakdown = MemoryBreakdown.fromPages(
            pageSize: 10, anonymous: 500, purgeable: 20, wired: 150,
            compressor: 80, external: 200, free: 30, speculative: 5
        )
        #expect(breakdown.appBytes == 4_800)        // (500 − 20) × 10
        #expect(breakdown.wiredBytes == 1_500)
        #expect(breakdown.compressedBytes == 800)
        #expect(breakdown.cachedBytes == 2_200)     // (200 + 20) × 10
        #expect(breakdown.freeBytes == 350)
        // 可清除页大于匿名页时不得下溢。
        #expect(MemoryBreakdown.fromPages(pageSize: 1, anonymous: 5, purgeable: 9, wired: 0, compressor: 0, external: 0, free: 0, speculative: 0).appBytes == 0)
    }

    @Test("High used percentage with normal pressure is calm")
    func highUsageNormalPressureIsCalm() {
        // 已使用 69%、交换 2.5G/16G 的实测场景：此前会因「≥ 75%」判成负载中等。
        let health = SystemHealth.evaluate(cpuPercent: 20, pressure: .normal, swapRatio: 0.16)
        #expect(health.level == .calm)
        #expect(health.text == "运行平稳")
    }

    @Test("Critical pressure outranks a quiet CPU")
    func criticalPressureIsHigh() {
        let health = SystemHealth.evaluate(cpuPercent: 5, pressure: .critical, swapRatio: 0.1)
        #expect(health.level == .high)
        #expect(health.text.contains("内存"))
    }

    @Test("Warning pressure, heavy swap and busy CPU are moderate")
    func moderateCases() {
        #expect(SystemHealth.evaluate(cpuPercent: 10, pressure: .warning, swapRatio: 0).level == .moderate)
        #expect(SystemHealth.evaluate(cpuPercent: 10, pressure: .normal, swapRatio: 0.5).level == .moderate)
        #expect(SystemHealth.evaluate(cpuPercent: 55, pressure: .normal, swapRatio: nil).level == .moderate)
        #expect(SystemHealth.evaluate(cpuPercent: 85, pressure: .normal, swapRatio: nil).level == .high)
        #expect(SystemHealth.evaluate(cpuPercent: 10, pressure: nil, swapRatio: nil).level == .calm)
    }

    @Test("Alerts once per pressure episode")
    func alertsOncePerEpisode() {
        var tracker = PressureAlertTracker(threshold: .critical)
        #expect(tracker.update(.normal) == nil)
        #expect(tracker.update(.warning) == nil)
        #expect(tracker.update(.critical) == .critical)
        #expect(tracker.update(.critical) == nil)
        #expect(tracker.update(.warning) == nil)      // 未回到正常，不重新计数
        #expect(tracker.update(.critical) == nil)
        #expect(tracker.update(.normal) == nil)
        #expect(tracker.update(.critical) == .critical)
        #expect(tracker.update(nil) == nil)

        var warningTracker = PressureAlertTracker(threshold: .warning)
        #expect(warningTracker.update(.warning) == .warning)
        #expect(warningTracker.update(.critical) == .critical) // 进一步恶化要再提醒
        #expect(warningTracker.update(.warning) == nil)
    }

    @Test("Snapshot carries pressure and a consistent breakdown")
    func snapshotIncludesMemoryDetails() throws {
        let snapshot = try MetricsSampler().sample()
        #expect(snapshot.memoryPressure != nil)
        let breakdown = try #require(snapshot.memoryBreakdown)
        let accounted = breakdown.appBytes + breakdown.wiredBytes + breakdown.compressedBytes
        #expect(accounted > 0)
        #expect(accounted <= snapshot.totalMemoryBytes)
        #expect(breakdown.cachedBytes + breakdown.freeBytes <= snapshot.totalMemoryBytes)
    }

    @Test("History buffer keeps the most recent samples")
    func historyBufferIsBounded() {
        var buffer = MemoryHistoryBuffer(capacity: 2)
        for value in [10.0, 20, 30] {
            buffer.append(MemoryHistorySample(timestamp: Date(), usedPercent: value, pressure: .normal))
        }
        #expect(buffer.samples.map(\.usedPercent) == [20, 30])
    }
}
