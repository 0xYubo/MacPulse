import MacPulseCore
import SwiftUI

enum SortMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "内存"
    var id: Self { self }
}

struct ResourcesPage: View {
    @ObservedObject var model: MonitorModel
    let searchText: String
    @Binding var sortMetric: SortMetric
    let requestTerminate: (ProcessGroup) -> Void

    private var displayedGroups: [ProcessGroup] {
        guard let groups = model.snapshot?.groups else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return groups
            .filter { $0.cpuPercent >= 0.1 || $0.memoryBytes >= 20 * 1_024 * 1_024 }
            .filter { group in
                query.isEmpty
                    || group.name.lowercased().contains(query)
                    || group.processes.contains { process in
                        process.command.lowercased().contains(query)
                            || process.name.lowercased().contains(query)
                            || String(process.pid).contains(query)
                    }
            }
            .sorted { sortMetric == .cpu ? $0.cpuPercent > $1.cpuPercent : $0.memoryBytes > $1.memoryBytes }
            .prefix(16)
            .map { $0 }
    }

    var body: some View {
        ContentPanel {
            HStack {
                PanelTitle(title: "资源占用", detail: "按应用和服务归组 · 悬停查看进程数")
                Spacer()
                Picker("排序", selection: $sortMetric) {
                    ForEach(SortMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 100)
                .controlSize(.small)
            }
        } content: {
            if searchText.isEmpty {
                if !model.oversizedGroups.isEmpty {
                    OversizedGroupsAdvice(
                        groups: model.oversizedGroups,
                        threshold: MonitorModel.thresholdLabel(model.groupAlertThresholdGB),
                        terminate: requestTerminate
                    )
                } else if let pressure = model.snapshot?.memoryPressure, pressure >= .warning {
                    PressureAdvice(
                        pressure: pressure,
                        topGroups: model.topMemoryGroups(),
                        isSortedByMemory: sortMetric == .memory
                    ) {
                        withAnimation(.smooth(duration: 0.2)) { sortMetric = .memory }
                    }
                }
            }
            if displayedGroups.isEmpty {
                EmptyPanel(
                    title: searchText.isEmpty ? "正在读取" : "没有匹配结果",
                    symbol: searchText.isEmpty ? "waveform" : "magnifyingglass",
                    detail: searchText.isEmpty ? "稍候即可看到进程排行" : "可搜索应用、进程、命令或 PID"
                )
            } else {
                let maxMemory = displayedGroups.map(\.memoryBytes).max() ?? 1
                ForEach(displayedGroups) { group in
                    ProcessRow(group: group, memoryShare: Double(group.memoryBytes) / Double(max(maxMemory, 1))) {
                        requestTerminate(group)
                    }
                }
            }
        }
    }
}

private struct ProcessRow: View {
    let group: ProcessGroup
    /// 相对本列表最大占用的比例，用于行内的占用条。
    let memoryShare: Double
    let terminate: () -> Void

    var body: some View {
        HoverRow {
            HStack(spacing: 10) {
                RowIcon(symbol: symbolName, tint: badgeColor)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(group.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        if group.processCount > 1 {
                            Text("×\(group.processCount)").font(.system(size: 9.5, design: .rounded)).foregroundStyle(.tertiary)
                        }
                    }
                    GeometryReader { proxy in
                        Capsule().fill(Theme.subtleFill)
                            .overlay(alignment: .leading) {
                                Capsule().fill(badgeColor.opacity(0.55))
                                    .frame(width: max(proxy.size.width * memoryShare, 2))
                            }
                    }
                    .frame(height: 3)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%@%.1f%%", group.isEstimated ? "≈" : "", group.cpuPercent))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    Text(bytes(group.memoryBytes)).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary)
                }
                .frame(width: 66, alignment: .trailing)
                RowCloseButton(
                    enabled: group.classification.level != .protected,
                    help: group.classification.level == .protected ? "系统保护" : "结束进程",
                    action: terminate
                )
            }
        }
        .help("\(group.classification.label) · \(group.classification.reason)")
    }

    private var badgeColor: Color {
        switch group.classification.level {
        case .recommended: .green
        case .review: .blue
        case .protected: .secondary
        }
    }

    private var symbolName: String {
        if group.name.hasPrefix("测试 · ") { return "testtube.2" }
        switch group.classification.level {
        case .recommended: return "leaf.fill"
        case .review: return "app.fill"
        case .protected: return "lock.fill"
        }
    }
}

/// 单组应用内存超过阈值：直接给出结束按钮。
private struct OversizedGroupsAdvice: View {
    let groups: [ProcessGroup]
    let threshold: String
    let terminate: (ProcessGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("以下应用占用超过 \(threshold)", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
            ForEach(groups) { group in
                HStack(spacing: 8) {
                    Text(group.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    if group.processCount > 1 {
                        Text("×\(group.processCount)").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(bytes(group.memoryBytes)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                    Button("结束") { terminate(group) }
                        .controlSize(.mini)
                        .disabled(group.classification.level == .protected)
                }
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .padding(.bottom, 4)
    }
}

/// 内存压力偏高 / 紧张：说明原因并列出占用最多的应用。
private struct PressureAdvice: View {
    let pressure: MemoryPressure
    let topGroups: [ProcessGroup]
    let isSortedByMemory: Bool
    let sortByMemory: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RowIcon(symbol: "exclamationmark.triangle.fill", tint: Optional(pressure).tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("内存压力\(pressure.label)").font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if !isSortedByMemory {
                Button("按内存排序", action: sortByMemory).controlSize(.mini)
            }
        }
        .padding(10)
        .background(Optional(pressure).tint.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .padding(.bottom, 4)
    }

    private var detail: String {
        let top = topGroups.map { "\($0.name) \(bytes($0.memoryBytes))" }.joined(separator: "、")
        let advice = pressure == .critical ? "系统可能卡顿，请尽快关闭不用的应用、测试或容器。" : "建议关闭不用的应用。"
        return top.isEmpty ? advice : "占用最多：\(top)。\(advice)"
    }
}

struct PortsPage: View {
    @ObservedObject var model: MonitorModel
    let searchText: String
    let requestClose: (MonitorModel.PortItem) -> Void
    let requestCleanup: () -> Void

    private var displayedPorts: [MonitorModel.PortItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.ports }
        return model.ports.filter { item in
            String(item.socket.port).contains(query)
                || item.socket.address.lowercased().contains(query)
                || item.socket.processName.lowercased().contains(query)
                || item.group?.name.lowercased().contains(query) == true
                || item.process?.command.lowercased().contains(query) == true
                || item.process.map { String($0.pid).contains(query) } == true
        }
    }

    private var exposedSensitive: [MonitorModel.PortItem] {
        model.ports.filter { PortExposure.exposedSensitiveService(port: $0.socket.port, address: $0.socket.address) != nil }
    }

    var body: some View {
        ContentPanel {
            HStack {
                PanelTitle(title: "监听端口", detail: "\(displayedPorts.count) 个端口 · \(model.safePortCandidates.count) 个开发服务可清理")
                Spacer()
                Button("一键清理", action: requestCleanup)
                    .controlSize(.small)
                    .disabled(model.safePortCandidates.isEmpty)
            }
        } content: {
            if searchText.isEmpty, !exposedSensitive.isEmpty {
                let names = exposedSensitive.compactMap { PortExposure.exposedSensitiveService(port: $0.socket.port, address: $0.socket.address) }
                Banner(
                    symbol: "network.badge.shield.half.filled",
                    text: "\(Set(names).sorted().joined(separator: "、")) 监听在所有网卡上，同一局域网的设备可以直接连接。若不需要，可改为只监听 127.0.0.1。",
                    tint: .red
                )
            }
            if displayedPorts.isEmpty {
                EmptyPanel(title: searchText.isEmpty ? "没有监听端口" : "没有匹配结果", symbol: "network", detail: "可搜索端口、应用或 PID")
            } else {
                ForEach(displayedPorts) { item in
                    PortRow(item: item) { requestClose(item) }
                }
            }
        }
    }
}

private struct PortRow: View {
    let item: MonitorModel.PortItem
    let close: () -> Void

    var body: some View {
        HoverRow {
            HStack(spacing: 10) {
                // verbatim：普通插值会按本地化格式显示成「24,031」。
                Text(verbatim: String(item.socket.port))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(item.isDevelopmentServer ? Color.accentColor : .primary)
                    .frame(width: 50)
                    .padding(.vertical, 5)
                    .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.group?.name ?? item.socket.processName)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: addressLine)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 5)
                if let service = PortExposure.exposedSensitiveService(port: item.socket.port, address: item.socket.address) {
                    StatusPill(text: "\(service) 对外", color: .red)
                } else if PortExposure.isExposed(address: item.socket.address) {
                    StatusPill(text: "对外开放", color: .orange)
                }
                StatusPill(text: portStatus, color: portColor)
                RowCloseButton(
                    enabled: item.isSafeOneClickCandidate,
                    help: item.isSafeOneClickCandidate ? "结束对应开发服务" : "只能关闭无活跃连接的开发服务",
                    action: close
                )
            }
        }
    }

    private var addressLine: String {
        let address = item.socket.address == "*" ? "所有网卡" : item.socket.address
        return "\(address) · PID \(item.socket.pid)"
    }

    private var portStatus: String {
        item.socket.hasEstablishedConnection ? "使用中" : (item.isDevelopmentServer ? "开发" : "保留")
    }

    private var portColor: Color {
        item.socket.hasEstablishedConnection ? .blue : (item.isDevelopmentServer ? .green : .secondary)
    }
}
