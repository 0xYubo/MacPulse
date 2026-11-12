import AppKit
import MacPulseCore
import Charts
import SwiftUI

struct DashboardView: View {
    enum Page: String, CaseIterable, Identifiable {
        case resources = "资源"
        case ports = "端口"
        case cleanup = "清理"

        var id: Self { self }
        var symbol: String {
            switch self {
            case .resources: "chart.bar.xaxis"
            case .ports: "network"
            case .cleanup: "sparkles"
            }
        }
    }

    enum SortMetric: String, CaseIterable, Identifiable {
        case cpu = "CPU"
        case memory = "内存"
        var id: Self { self }
    }

    enum CleanupSection: String, CaseIterable, Identifiable {
        case aiCache = "AI 缓存"
        case disk = "磁盘清理"
        case apps = "软件卸载"

        var id: Self { self }
    }

    @ObservedObject var model: MonitorModel
    @ObservedObject var cleanup: CleanupModel
    let quit: () -> Void

    @State private var page: Page = .resources
    @State private var sortMetric: SortMetric = .cpu
    @State private var cleanupSection: CleanupSection = .aiCache
    @State private var searchText = ""
    @State private var pendingGroup: ProcessGroup?
    @State private var pendingPort: MonitorModel.PortItem?
    @State private var showingOptimizeConfirmation = false
    @State private var showingPortCleanupConfirmation = false
    @State private var showingCacheCleanupConfirmation = false
    @State private var showingSettings = false
    @State private var historyMetric: HistoryMetric = .cpu

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
            .sorted {
                sortMetric == .cpu
                    ? $0.cpuPercent > $1.cpuPercent
                    : $0.memoryBytes > $1.memoryBytes
            }
            .prefix(14)
            .map { $0 }
    }

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

    private var displayedCaches: [AICacheUsage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.aiCaches }
        return model.aiCaches.filter {
            $0.definition.name.lowercased().contains(query)
                || $0.definition.relativePath.lowercased().contains(query)
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.08), .clear, Color.cyan.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                systemOverview
                pageSwitcher
                if page == .cleanup { cleanupSectionPicker }
                searchBar
                pageContent
                if let notice = model.notice {
                    NoticeBanner(text: notice) { model.notice = nil }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                bottomBar
            }
            // 设置页盖在主面板上时，主面板不应再接收点击和 Tab 焦点。
            .allowsHitTesting(!showingSettings)
            .accessibilityHidden(showingSettings)
        }
        .frame(width: model.dashboardWidth, height: model.dashboardHeight)
        .background(.ultraThinMaterial)
        .preferredColorScheme(model.appearanceMode.colorScheme)
        .overlay(alignment: .bottomTrailing) {
            DashboardResizeHandle(model: model)
                .padding(4)
        }
        .confirmationDialog(
            "结束进程？",
            isPresented: Binding(
                get: { pendingGroup != nil },
                set: { if !$0 { pendingGroup = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingGroup
        ) { group in
            Button("正常结束 \(group.name)", role: .destructive) {
                model.terminate(group)
                pendingGroup = nil
            }
            Button("取消", role: .cancel) { pendingGroup = nil }
        } message: { group in
            Text("\(group.name) · \(group.processCount) 个进程。\(group.classification.reason)")
        }
        .confirmationDialog(
            "关闭端口？",
            isPresented: Binding(
                get: { pendingPort != nil },
                set: { if !$0 { pendingPort = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingPort
        ) { port in
            Button("结束对应开发服务", role: .destructive) {
                model.closePort(port)
                pendingPort = nil
            }
            Button("取消", role: .cancel) { pendingPort = nil }
        } message: { port in
            Text("端口 \(port.socket.port)：将结束 \(port.target?.name ?? "PID \(port.socket.pid)") 及其子进程（\(port.target?.processCount ?? 1) 个），未保存的状态可能丢失。")
        }
        .confirmationDialog("智能优化", isPresented: $showingOptimizeConfirmation, titleVisibility: .visible) {
            Button("结束建议处理的后台", role: .destructive) { model.optimizeRecommended() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将向 \(model.recommendedGroups.count) 组可选后台发送正常退出请求。")
        }
        .confirmationDialog("一键清理开发端口", isPresented: $showingPortCleanupConfirmation, titleVisibility: .visible) {
            Button("关闭安全候选端口", role: .destructive) { model.closeSafePorts() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("有活跃连接、系统服务、数据库、Docker、代理和远程连接不会处理。")
        }
        .confirmationDialog("清理 AI 缓存", isPresented: $showingCacheCleanupConfirmation, titleVisibility: .visible) {
            Button("直接删除未使用的缓存", role: .destructive) { model.cleanAICaches() }
            Button("取消", role: .cancel) { }
        } message: {
            let candidates = model.aiCaches.filter { !$0.isInUse && $0.sizeBytes > 0 }
            Text("将清理 \(candidates.count) 项，约 \(diskByteString(candidates.reduce(0) { $0 + $1.sizeBytes }))。缓存会直接删除，不进废纸篓，应用下次启动时自动重建。不会删除账号、对话、项目、配置或 Claude VM 数据；运行中的应用会被跳过。")
        }
        // 设置页不用 sheet：popover 是点外部即关闭的，sheet 窗口不会随之关闭，
        // 再次打开面板时它可能不可见却仍处于模态状态，挡住面板上的全部按钮。
        .overlay {
            if showingSettings {
                SettingsView(model: model, cleanup: cleanup) { showingSettings = false }
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.smooth(duration: 0.2), value: showingSettings)
        .animation(.smooth(duration: 0.2), value: model.notice)
        .onReceive(NotificationCenter.default.publisher(for: .dashboardWillClose)) { _ in
            // 面板关闭时收起所有确认框，避免残留的模态状态在下次打开时阻塞点击。
            pendingGroup = nil
            pendingPort = nil
            showingOptimizeConfirmation = false
            showingPortCleanupConfirmation = false
            showingCacheCleanupConfirmation = false
            showingSettings = false
        }
        .onChange(of: page) { _, newPage in
            searchText = ""
            if newPage == .cleanup { model.refreshAICaches() }
        }
        .onChange(of: cleanupSection) { _, _ in
            searchText = ""
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
            .shadow(color: .blue.opacity(0.2), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text("MacPulse")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 5, height: 5)
                    Text(statusText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HeaderButton(symbol: "gearshape", help: "设置") { showingSettings = true }
            HeaderButton(symbol: "arrow.clockwise", help: "立即刷新", isBusy: model.isRefreshing) { model.refresh() }
                .disabled(model.isRefreshing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 11)
    }

    private var systemOverview: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                CompactMetric(
                    title: "处理器",
                    symbol: "cpu",
                    value: model.displayCPU?.totalPercent ?? 0,
                    detail: cpuDetail,
                    tint: .cyan
                )
                Divider().frame(height: 52).padding(.horizontal, 15)
                MemoryMetric(snapshot: model.snapshot)
            }
            HistoryChart(cpuSamples: model.cpuHistory, memorySamples: model.memoryHistory, metric: $historyMetric)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 11)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField(searchPlaceholder, text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .disabled(isSearchDisabled)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.quaternary.opacity(0.48), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 9)
    }

    private var pageSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(Page.allCases) { item in
                Button {
                    withAnimation(.smooth(duration: 0.22)) { page = item }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol).font(.system(size: 11, weight: .semibold))
                        Text(item.rawValue).font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(page == item ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if page == item {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.background.opacity(0.72))
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 11)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .resources: resourcePage
        case .ports: portPage
        case .cleanup: cleanupPage
        }
    }

    private var resourcePage: some View {
        ContentPanel {
            HStack {
                PanelTitle(title: "资源占用", detail: "按应用和服务归组")
                Spacer()
                Picker("排序", selection: $sortMetric) {
                    ForEach(SortMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 108)
                .controlSize(.small)
            }
        } content: {
            if let pressure = model.snapshot?.memoryPressure, pressure >= .warning, searchText.isEmpty {
                PressureAdvice(
                    pressure: pressure,
                    topGroups: model.topMemoryGroups(),
                    isSortedByMemory: sortMetric == .memory
                ) {
                    withAnimation(.smooth(duration: 0.2)) { sortMetric = .memory }
                }
                Divider()
            }
            if displayedGroups.isEmpty {
                EmptyPanel(
                    title: searchText.isEmpty ? "正在读取" : "没有匹配结果",
                    symbol: searchText.isEmpty ? "waveform" : "magnifyingglass",
                    detail: searchText.isEmpty ? "稍候即可看到进程排行" : "可搜索应用、进程、命令或 PID"
                )
            } else {
                ForEach(Array(displayedGroups.enumerated()), id: \.element.id) { index, group in
                    ProcessRow(group: group) { pendingGroup = group }
                    if index < displayedGroups.count - 1 { Divider().padding(.leading, 46) }
                }
            }
        }
    }

    private var portPage: some View {
        ContentPanel {
            HStack {
                PanelTitle(title: "监听端口", detail: "\(displayedPorts.count) 个结果 · \(model.safePortCandidates.count) 个可清理")
                Spacer()
                Button("一键清理") { showingPortCleanupConfirmation = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.safePortCandidates.isEmpty)
            }
        } content: {
            if displayedPorts.isEmpty {
                EmptyPanel(title: searchText.isEmpty ? "没有监听端口" : "没有匹配结果", symbol: "network", detail: "可搜索端口、应用或 PID")
            } else {
                ForEach(Array(displayedPorts.enumerated()), id: \.element.id) { index, item in
                    PortRow(item: item) { pendingPort = item }
                    if index < displayedPorts.count - 1 { Divider().padding(.leading, 62) }
                }
            }
        }
    }

    private var cleanupPage: some View {
        Group {
            switch cleanupSection {
            case .aiCache: aiCachePanel
            case .disk: DiskCleanupView(cleanup: cleanup, searchText: searchText) { showingSettings = true }
            case .apps: AppUninstallView(cleanup: cleanup, searchText: searchText)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var cleanupSectionPicker: some View {
        Picker("清理类型", selection: $cleanupSection) {
            ForEach(CleanupSection.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        // 删除进行中切换子栏会让进度与结果脱离上下文。
        .disabled(cleanup.isTrashing)
        .padding(.horizontal, 14)
        .padding(.bottom, 9)
    }

    private var isSearchDisabled: Bool {
        page == .cleanup && cleanupSection == .apps && cleanup.selectedApp != nil
    }

    private var aiCachePanel: some View {
        ContentPanel {
            HStack {
                PanelTitle(
                    title: "AI 缓存",
                    detail: "可释放 \(diskByteString(model.aiCaches.filter { !$0.isInUse }.reduce(0) { $0 + $1.sizeBytes }))"
                )
                Spacer()
                HeaderButton(symbol: "arrow.clockwise", help: "重新计算", isBusy: model.isScanningCaches) {
                    model.refreshAICaches()
                }
                Button("清理") { showingCacheCleanupConfirmation = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.aiCaches.allSatisfy { $0.isInUse || $0.sizeBytes == 0 })
            }
        } content: {
            if displayedCaches.isEmpty {
                EmptyPanel(
                    title: model.isScanningCaches ? "正在计算" : (searchText.isEmpty ? "没有发现缓存" : "没有匹配结果"),
                    symbol: "externaldrive.badge.checkmark",
                    detail: "可搜索缓存名称或目录"
                )
            } else {
                ForEach(Array(displayedCaches.enumerated()), id: \.element.id) { index, cache in
                    CacheRow(cache: cache)
                    if index < displayedCaches.count - 1 { Divider().padding(.leading, 36) }
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button("退出") { quit() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
            Label(bottomStatus, systemImage: bottomStatusSymbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if page == .resources {
                Button("智能优化") { showingOptimizeConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.recommendedGroups.isEmpty)
            } else {
                Button("设置") { showingSettings = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 34)
        .padding(.vertical, 11)
        .background(.bar.opacity(0.52))
    }

    private var panelBackground: some ShapeStyle {
        Color(nsColor: .controlBackgroundColor).opacity(0.68)
    }

    private var bottomStatus: String {
        switch page {
        case .resources: "\(model.recommendedGroups.count) 项建议"
        case .ports: model.autoClosePortsEnabled ? "自动清理已开启" : "自动清理已关闭"
        case .cleanup:
            switch cleanupSection {
            case .aiCache: "账号、对话与配置不会删除"
            case .disk: "只移到废纸篓，可从废纸篓还原"
            case .apps: "应用与所选数据移到废纸篓，可还原"
            }
        }
    }

    private var bottomStatusSymbol: String {
        switch page {
        case .resources: "leaf"
        case .ports: model.autoClosePortsEnabled ? "checkmark.circle.fill" : "pause.circle"
        case .cleanup: cleanupSection == .aiCache ? "lock.shield" : "trash"
        }
    }

    private var searchPlaceholder: String {
        switch page {
        case .resources: "搜索应用、进程、命令或 PID"
        case .ports: "搜索端口、应用或 PID"
        case .cleanup:
            switch cleanupSection {
            case .aiCache: "搜索缓存名称或目录"
            case .disk: "搜索文件名称或路径"
            case .apps: "搜索应用名称或 Bundle ID"
            }
        }
    }

    private var statusText: String {
        model.health?.text ?? "正在读取系统状态"
    }

    private var statusColor: Color {
        switch model.health?.level {
        case nil: .secondary
        case .calm: .green
        case .moderate: .orange
        case .high: .red
        }
    }

    private var cpuDetail: String {
        guard let cpu = model.displayCPU else { return "等待采样" }
        return String(format: "用户 %.0f · 系统 %.0f", cpu.userPercent, cpu.systemPercent)
    }

}

struct HeaderButton: View {
    let symbol: String
    let help: String
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .rotationEffect(.degrees(isBusy ? 360 : 0))
                .animation(isBusy ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: isBusy)
        }
        .buttonStyle(.plain)
        // 点击后按钮保留键盘焦点，焦点环画在所有图层之上：打开设置页后，齿轮按钮的蓝框会叠在「完成」旁边。
        .focusEffectDisabled()
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct CompactMetric: View {
    let title: String
    let symbol: String
    let value: Double
    let detail: String
    let tint: Color
    var note: (text: String, color: Color)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.rounded()))%")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
            }
            ProgressView(value: min(max(value, 0), 100), total: 100)
                .tint(tint)
                .controlSize(.small)
            HStack(spacing: 6) {
                Text(detail)
                    .foregroundStyle(.tertiary)
                if let note {
                    Text("·").foregroundStyle(.tertiary)
                    Text(note.text).foregroundStyle(note.color)
                }
            }
            .font(.system(size: 9.5, design: .rounded))
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

enum HistoryMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "内存"
    var id: Self { self }
}

extension Optional where Wrapped == MemoryPressure {
    /// 读不到压力时用中性色，不冒充「正常」的绿色。
    var tint: Color {
        switch self {
        case .none: .secondary
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// 内存卡片：百分比与「已使用内存」口径一致，但颜色看内存压力；进度条按构成分段，悬停显示明细。
private struct MemoryMetric: View {
    let snapshot: SystemSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("内存", systemImage: "memorychip")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((snapshot?.memoryPercent ?? 0).rounded()))%")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
            }
            MemoryCompositionBar(snapshot: snapshot)
            HStack(spacing: 5) {
                if let snapshot {
                    Text("\(bytes(snapshot.usedMemoryBytes)) / \(bytes(snapshot.totalMemoryBytes))")
                        .foregroundStyle(.tertiary)
                    Text("·").foregroundStyle(.tertiary)
                    Text("压力\(snapshot.memoryPressure?.label ?? "未知")")
                        .foregroundStyle(snapshot.memoryPressure.tint)
                        .fontWeight(.semibold)
                    if let swap = snapshot.swapUsedBytes, swap > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("交换 \(bytes(swap))").foregroundStyle(swapColor(snapshot))
                    }
                } else {
                    Text("等待采样").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 9.5, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .help(breakdownHelp)
    }

    /// 交换文件不会主动缩小，一次高峰后会残留数 GB；只有达到物理内存一半才提示。
    private func swapColor(_ snapshot: SystemSnapshot) -> Color {
        guard let ratio = snapshot.swapRatio else { return .secondary }
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
            .background(.quaternary.opacity(0.7))
            .clipShape(Capsule())
        }
        .frame(height: 5)
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
            Segment(id: "cached", bytes: parts.cachedBytes, color: Color.secondary.opacity(0.22)),
        ]
    }

    private func fraction(_ value: UInt64) -> CGFloat {
        guard let total = snapshot?.totalMemoryBytes, total > 0 else { return 0 }
        return CGFloat(Double(value) / Double(total))
    }
}

private struct HistoryChart: View {
    let cpuSamples: [CPUHistorySample]
    let memorySamples: [MemoryHistorySample]
    @Binding var metric: HistoryMetric

    private struct Point: Identifiable {
        let timestamp: Date
        let value: Double
        var id: Date { timestamp }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Picker("历史指标", selection: $metric) {
                    ForEach(HistoryMetric.allCases) { Text("\($0.rawValue) 历史").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .fixedSize()
                Spacer()
                if metric == .memory, let peak = memorySamples.map(\.usedPercent).max() {
                    Text(String(format: "峰值 %.0f%%", peak))
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.tertiary)
                } else if metric == .cpu, let peak = cpuSamples.map(\.totalPercent).max() {
                    Text(String(format: "峰值 %.0f%%", peak))
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                Text(historyRange)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Chart(points) { point in
                AreaMark(x: .value("时间", point.timestamp), y: .value(metric.rawValue, point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(
                        colors: [tint.opacity(0.25), tint.opacity(0.015)],
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
            .chartYAxis(.hidden)
            .frame(height: 42)
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

    /// 内存曲线按最新压力着色，与卡片颜色一致。
    private var tint: Color {
        switch metric {
        case .cpu: .cyan
        case .memory: (memorySamples.last?.pressure).tint
        }
    }

    private var historyRange: String {
        let stamps = points.map(\.timestamp)
        guard let first = stamps.first, let last = stamps.last else { return "最近" }
        let seconds = max(last.timeIntervalSince(first), 0)
        if seconds < 60 { return "最近 \(Int(seconds)) 秒" }
        return "最近 \(Int(seconds / 60)) 分钟"
    }
}

private struct DashboardResizeHandle: View {
    @ObservedObject var model: MonitorModel
    @State private var startingSize: CGSize?

    var body: some View {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if startingSize == nil {
                            startingSize = CGSize(width: model.dashboardWidth, height: model.dashboardHeight)
                        }
                        guard let startingSize else { return }
                        model.resizeDashboard(
                            width: startingSize.width + value.translation.width,
                            height: startingSize.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        model.resizeDashboard(
                            width: model.dashboardWidth,
                            height: model.dashboardHeight,
                            persist: true
                        )
                        startingSize = nil
                    }
            )
            .help("拖动调整窗口大小")
    }
}

struct ContentPanel<Header: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header().padding(.horizontal, 12).padding(.vertical, 10)
            Divider().opacity(0.55)
            ScrollView {
                LazyVStack(spacing: 0) { content() }
                    .padding(.vertical, 2)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.68))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.07))
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
    }
}

struct PanelTitle: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(detail).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(2)
        }
    }
}

struct EmptyPanel: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 12, weight: .medium))
            Text(detail).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

private struct ProcessRow: View {
    let group: ProcessGroup
    let terminate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(badgeColor)
                .frame(width: 26, height: 26)
                .background(badgeColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(group.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    if group.processCount > 1 {
                        Text("×\(group.processCount)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Text(group.classification.label).font(.system(size: 9.5)).foregroundStyle(badgeColor)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%@%.1f%%", group.isEstimated ? "≈" : "", group.cpuPercent))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                Text(bytes(group.memoryBytes)).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .frame(width: 64, alignment: .trailing)
            Button(action: terminate) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .disabled(group.classification.level == .protected)
            .opacity(group.classification.level == .protected ? 0.18 : 0.62)
            .help(group.classification.level == .protected ? "系统保护" : "结束进程")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }

    private var badgeColor: Color {
        switch group.classification.level {
        case .recommended: .green
        case .review: .orange
        case .protected: .secondary
        }
    }

    private var symbolName: String {
        switch group.classification.level {
        case .recommended: "leaf.fill"
        case .review: "app.fill"
        case .protected: "lock.fill"
        }
    }
}

/// 内存压力偏高 / 紧张时显示在资源列表顶部：说明原因并列出占用最多的应用。
private struct PressureAdvice: View {
    let pressure: MemoryPressure
    let topGroups: [ProcessGroup]
    let isSortedByMemory: Bool
    let sortByMemory: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Optional(pressure).tint)
                .frame(width: 26, height: 26)
                .background(Optional(pressure).tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                Text("内存压力\(pressure.label)")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if !isSortedByMemory {
                Button("按内存排序", action: sortByMemory)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Optional(pressure).tint.opacity(0.05))
    }

    private var detail: String {
        let top = topGroups.map { "\($0.name) \(bytes($0.memoryBytes))" }.joined(separator: "、")
        let advice = pressure == .critical ? "系统可能卡顿，请尽快关闭不用的应用、测试或容器。" : "建议关闭不用的应用。"
        return top.isEmpty ? advice : "占用最多：\(top)。\(advice)"
    }
}

private struct PortRow: View {
    let item: MonitorModel.PortItem
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(item.socket.port)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(item.isDevelopmentServer ? Color.accentColor : .secondary)
                .frame(width: 42)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.group?.name ?? item.socket.processName)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(item.socket.address)
                }
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Color.secondary.opacity(0.7))
            }
            Spacer(minLength: 5)
            StatusPill(text: portStatus, color: portColor)
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .disabled(!item.isSafeOneClickCandidate)
            .opacity(item.isSafeOneClickCandidate ? 0.62 : 0.18)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }

    private var portStatus: String {
        item.socket.hasEstablishedConnection ? "使用中" : (item.isDevelopmentServer ? "开发" : "保留")
    }

    private var portColor: Color {
        item.socket.hasEstablishedConnection ? .orange : (item.isDevelopmentServer ? .green : .secondary)
    }
}

private struct CacheRow: View {
    let cache: AICacheUsage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: cache.isInUse ? "lock.fill" : "externaldrive.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(cache.isInUse ? .orange : .blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(cache.definition.name).font(.system(size: 11.5, weight: .medium))
                Text(cache.isInUse ? "应用运行中，已保护" : "可安全重建")
                    .font(.system(size: 9.5))
                    .foregroundStyle(cache.isInUse ? Color.orange : Color.secondary.opacity(0.7))
            }
            Spacer()
            Text(diskByteString(cache.sizeBytes))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
    }
}

private struct SettingsView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var cleanup: CleanupModel
    let close: () -> Void

    private func chooseWorkspaceFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "添加"
        NSApp.activate()
        if panel.runModal() == .OK {
            cleanup.addWorkspaceRoots(panel.urls)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("设置").font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text("外观、自动化与清理").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    SettingsCard(title: "外观与窗口", symbol: "circle.lefthalf.filled", tint: .cyan) {
                        Picker("主题", selection: $model.appearanceMode) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            SettingsHint("拖动主面板右下角可调整尺寸，范围 400×560 至 600×800。")
                            Spacer()
                            Button("恢复默认") { model.resetDashboardSize() }
                                .controlSize(.small)
                        }
                    }
                    SettingsCard(title: "内存提醒", symbol: "memorychip", tint: .red) {
                        Toggle("内存压力变「紧张」时发送系统通知", isOn: $model.pressureAlertsEnabled)
                        SettingsHint("与活动监视器底部的「内存压力」同源。每次升到紧张只提醒一次，回落到正常后才会再次提醒；通知正文会列出占用最多的应用。")
                    }
                    SettingsCard(title: "端口管理", symbol: "network", tint: .blue) {
                        Toggle("自动关闭闲置超过 30 分钟的开发端口", isOn: $model.autoClosePortsEnabled)
                        SettingsHint("只处理当前用户、无活跃连接的明确开发服务；数据库、Docker、代理及系统服务始终保护。")
                    }
                    SettingsCard(title: "磁盘清理 · 开发工作区目录", symbol: "internaldrive", tint: .orange) {
                        if cleanup.workspaceRoots.isEmpty {
                            SettingsHint("尚未添加。不添加时不会扫描项目中的依赖与构建产物。")
                        }
                        ForEach(cleanup.workspaceRoots, id: \.self) { path in
                            HStack(spacing: 8) {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((path as NSString).abbreviatingWithTildeInPath)
                                        .font(.system(size: 11.5))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let problem = cleanup.workspaceProblem(path) {
                                        Text("\(problem)，扫描时会忽略").font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Button {
                                    cleanup.removeWorkspaceRoot(path)
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("移除")
                                .accessibilityLabel("移除 \(path)")
                            }
                        }
                        HStack {
                            Button("添加文件夹…") { chooseWorkspaceFolders() }
                                .controlSize(.small)
                            Spacer()
                        }
                        SettingsHint("项目 30 天内没有任何文件改动时，其中的 node_modules、.build、DerivedData 会列为可清理项；.venv 默认不勾选。")
                    }
                }
                .padding(16)
            }
        }
        .background(.regularMaterial)
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.68), in: RoundedRectangle(cornerRadius: 13))
    }
}

struct SettingsHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
}

private extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension Notification.Name {
    /// 主面板即将关闭。所有确认框都要收起，否则残留的模态状态会在下次打开时挡住点击。
    static let dashboardWillClose = Notification.Name("MacPulse.dashboardWillClose")
}

/// 非模态的结果提示：显示在面板底部，不阻塞其他操作。
private struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.accentColor)
            ScrollView {
                Text(text)
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 96)
            .fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭提示")
            .accessibilityLabel("关闭提示")
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.95), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}
