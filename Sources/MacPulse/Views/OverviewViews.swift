import Charts
import MacPulseCore
import SwiftUI

enum HistoryMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "内存"
    var id: Self { self }
}

/// 顶部概览：CPU 与内存两个圆环 + 可切换的历史曲线。
struct OverviewCard: View {
    @ObservedObject var model: MonitorModel
    @Binding var historyMetric: HistoryMetric

    var body: some View {
        Card(padding: 11) {
            VStack(spacing: 9) {
                HStack(spacing: 12) {
                    CPUTile(sample: model.displayCPU)
                    Divider().frame(height: 46)
                    MemoryTile(snapshot: model.snapshot)
                }
                HistoryChart(cpuSamples: model.cpuHistory, memorySamples: model.memoryHistory, metric: $historyMetric)
            }
        }
        .padding(.horizontal, Theme.outerPadding)
        .padding(.bottom, 10)
    }
}

private struct CPUTile: View {
    let sample: CPUHistorySample?

    var body: some View {
        HStack(spacing: 10) {
            RingGauge(value: sample?.totalPercent ?? 0, tint: tint)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Label("处理器", systemImage: "cpu")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(sample.map { String(format: "%.0f%%", $0.totalPercent) } ?? "--")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Text(sample.map { String(format: "用户 %.0f · 系统 %.0f", $0.userPercent, $0.systemPercent) } ?? "等待采样")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var tint: Color {
        let value = sample?.totalPercent ?? 0
        return value >= 80 ? .red : (value >= 50 ? .orange : .cyan)
    }
}

/// 内存：百分比与活动监视器「已使用内存」一致，颜色看内存压力；分段条显示构成，悬停看明细。
private struct MemoryTile: View {
    let snapshot: SystemSnapshot?

    var body: some View {
        HStack(spacing: 10) {
            RingGauge(value: snapshot?.memoryPercent ?? 0, tint: snapshot?.memoryPressure.tint ?? .secondary)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Label("内存", systemImage: "memorychip")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let snapshot {
                        StatusPill(text: "压力\(snapshot.memoryPressure?.label ?? "未知")", color: snapshot.memoryPressure.tint)
                    }
                }
                Text(snapshot.map { "\(bytes($0.usedMemoryBytes))" } ?? "--")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                MemoryCompositionBar(snapshot: snapshot)
                Text(footnote)
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(swapColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .help(breakdownHelp)
    }

    private var footnote: String {
        guard let snapshot else { return "等待采样" }
        var parts = ["共 \(bytes(snapshot.totalMemoryBytes))"]
        if let swap = snapshot.swapUsedBytes, swap > 0 { parts.append("交换 \(bytes(swap))") }
        return parts.joined(separator: " · ")
    }

    /// 交换文件不会主动缩小，一次高峰后会残留数 GB；只有达到物理内存一半才提示。
    private var swapColor: Color {
        guard let ratio = snapshot?.swapRatio else { return .secondary }
        return ratio >= 0.75 ? .red : (ratio >= 0.5 ? .orange : .secondary)
    }

    private var breakdownHelp: String {
        guard let snapshot, let parts = snapshot.memoryBreakdown else { return "内存构成暂不可用" }
        return """
        App 内存 \(bytes(parts.appBytes))
        内核联动 \(bytes(parts.wiredBytes))（系统固定占用）
        已压缩 \(bytes(parts.compressedBytes))
        已缓存文件 \(bytes(parts.cachedBytes))（需要时立即让出，不计入已使用）
        空闲 \(bytes(parts.freeBytes))
        判断内存是否够用请看「压力」：正常即无需处理。
        """
    }
}

private struct MemoryCompositionBar: View {
    let snapshot: SystemSnapshot?

    private struct Segment: Identifiable {
        let id: String
        let bytes: UInt64
        let color: Color
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(proxy.size.width * fraction(segment.bytes), 0))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.subtleFill)
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .animation(.smooth(duration: 0.35), value: snapshot?.usedMemoryBytes)
    }

    private var segments: [Segment] {
        guard let snapshot else { return [] }
        let tint = snapshot.memoryPressure.tint
        guard let parts = snapshot.memoryBreakdown else {
            return [Segment(id: "used", bytes: snapshot.usedMemoryBytes, color: tint)]
        }
        return [
            Segment(id: "app", bytes: parts.appBytes, color: tint),
            Segment(id: "wired", bytes: parts.wiredBytes, color: tint.opacity(0.65)),
            Segment(id: "compressed", bytes: parts.compressedBytes, color: tint.opacity(0.4)),
            Segment(id: "cached", bytes: parts.cachedBytes, color: Color.secondary.opacity(0.25)),
        ]
    }

    private func fraction(_ value: UInt64) -> CGFloat {
        guard let total = snapshot?.totalMemoryBytes, total > 0 else { return 0 }
        return CGFloat(Double(value) / Double(total))
    }
}

struct HistoryChart: View {
    let cpuSamples: [CPUHistorySample]
    let memorySamples: [MemoryHistorySample]
    @Binding var metric: HistoryMetric

    private struct Point: Identifiable {
        let timestamp: Date
        let value: Double
        var id: Date { timestamp }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Picker("历史指标", selection: $metric) {
                    ForEach(HistoryMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .fixedSize()
                Spacer()
                if let peak = points.map(\.value).max() {
                    Text(String(format: "峰值 %.0f%%", peak))
                }
                Text(historyRange)
            }
            .font(.system(size: 9, design: .rounded))
            .foregroundStyle(.secondary)
            Chart(points) { point in
                AreaMark(x: .value("时间", point.timestamp), y: .value(metric.rawValue, point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(
                        colors: [tint.opacity(0.28), tint.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                LineMark(x: .value("时间", point.timestamp), y: .value(metric.rawValue, point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [50]) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                }
            }
            .frame(height: 30)
            .overlay {
                if points.count < 2 {
                    Text("正在积累采样")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .animation(.smooth(duration: 0.25), value: metric)
        }
    }

    private var points: [Point] {
        switch metric {
        case .cpu: cpuSamples.map { Point(timestamp: $0.timestamp, value: $0.totalPercent) }
        case .memory: memorySamples.map { Point(timestamp: $0.timestamp, value: $0.usedPercent) }
        }
    }

    /// 内存曲线按最新压力着色，与圆环颜色一致。
    private var tint: Color {
        switch metric {
        case .cpu: .cyan
        case .memory: (memorySamples.last?.pressure).tint
        }
    }

    private var historyRange: String {
        guard let first = points.first?.timestamp, let last = points.last?.timestamp else { return "最近" }
        let seconds = max(last.timeIntervalSince(first), 0)
        if seconds < 60 { return "最近 \(Int(seconds)) 秒" }
        return "最近 \(Int(seconds / 60)) 分钟"
    }
}
