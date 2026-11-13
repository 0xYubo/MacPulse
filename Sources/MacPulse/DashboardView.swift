import AppKit
import MacPulseCore
import SwiftUI

struct DashboardView: View {
    enum Page: String, CaseIterable, Identifiable {
        case resources = "资源"
        case ports = "端口"
        case docker = "Docker"
        case cleanup = "清理"
        case diagnostics = "诊断"

        var id: Self { self }
        var symbol: String {
            switch self {
            case .resources: "square.stack.3d.up"
            case .ports: "network"
            case .docker: "shippingbox"
            case .cleanup: "sparkles"
            case .diagnostics: "stethoscope"
            }
        }

        var isSearchable: Bool { self == .resources || self == .ports || self == .cleanup }
    }

    enum CleanupSection: String, CaseIterable, Identifiable {
        case aiCache = "AI 缓存"
        case disk = "磁盘清理"
        case apps = "软件卸载"

        var id: Self { self }
    }

    @ObservedObject var model: MonitorModel
    @ObservedObject var cleanup: CleanupModel
    @ObservedObject var docker: DockerModel
    @ObservedObject var diagnostics: DiagnosticsModel
    let quit: () -> Void

    @State private var page: Page = .resources
    @State private var sortMetric: SortMetric = .cpu
    @State private var cleanupSection: CleanupSection = .aiCache
    @State private var historyMetric: HistoryMetric = .cpu
    @State private var searchText = ""
    @State private var pendingGroup: ProcessGroup?
    @State private var pendingPort: MonitorModel.PortItem?
    @State private var showingOptimizeConfirmation = false
    @State private var showingPortCleanupConfirmation = false
    @State private var showingCacheCleanupConfirmation = false
    @State private var showingSettings = false

    /// 0 字节的缓存（应用没装或刚清过）不占一行。
    private var displayedCaches: [AICacheUsage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nonEmpty = model.aiCaches.filter { $0.sizeBytes > 0 }
        guard !query.isEmpty else { return nonEmpty }
        return nonEmpty.filter {
            $0.definition.name.lowercased().contains(query)
                || $0.definition.relativePath.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            OverviewCard(model: model, historyMetric: $historyMetric)
            tabBar
            if page == .cleanup { cleanupSectionPicker }
            if page.isSearchable { searchBar }
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
        .frame(width: model.dashboardWidth, height: model.dashboardHeight)
        .background(.ultraThinMaterial)
        .preferredColorScheme(model.appearanceMode.colorScheme)
        .overlay(alignment: .bottomTrailing) {
            DashboardResizeHandle(model: model).padding(4)
        }
        .confirmationDialog(
            "结束进程？",
            isPresented: Binding(get: { pendingGroup != nil }, set: { if !$0 { pendingGroup = nil } }),
            titleVisibility: .visible,
            presenting: pendingGroup
        ) { group in
            Button("正常结束 \(group.name)", role: .destructive) {
                model.terminate(group)
                pendingGroup = nil
            }
            Button("取消", role: .cancel) { pendingGroup = nil }
        } message: { group in
            Text("\(group.name) · \(group.processCount) 个进程 · \(bytes(group.memoryBytes))。\(group.classification.reason)")
        }
        .confirmationDialog(
            "关闭端口？",
            isPresented: Binding(get: { pendingPort != nil }, set: { if !$0 { pendingPort = nil } }),
            titleVisibility: .visible,
            presenting: pendingPort
        ) { port in
            Button("结束对应开发服务", role: .destructive) {
                model.closePort(port)
                pendingPort = nil
            }
            Button("取消", role: .cancel) { pendingPort = nil }
        } message: { port in
            Text("端口 \(String(port.socket.port))：将结束 \(port.target?.name ?? "PID \(port.socket.pid)") 及其子进程（\(port.target?.processCount ?? 1) 个），未保存的状态可能丢失。")
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
        .onChange(of: cleanupSection) { _, _ in searchText = "" }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("MacPulse").font(.system(size: 14.5, weight: .semibold, design: .rounded))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(model.health?.text ?? "正在读取系统状态")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(statusColor == .green ? .secondary : statusColor)
                }
            }
            Spacer()
            HeaderButton(symbol: "arrow.clockwise", help: "立即刷新", isBusy: model.isRefreshing) { model.refresh() }
                .disabled(model.isRefreshing)
            HeaderButton(symbol: "gearshape", help: "设置") { showingSettings = true }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var statusColor: Color {
        switch model.health?.level {
        case nil: .secondary
        case .calm: .green
        case .moderate: .orange
        case .high: .red
        }
    }

    // MARK: - 标签栏

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Page.allCases) { item in
                Button {
                    withAnimation(.smooth(duration: 0.22)) { page = item }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .overlay(alignment: .topTrailing) {
                                if let badge = badge(for: item) {
                                    Circle().fill(badge).frame(width: 6, height: 6).offset(x: 5, y: -2)
                                }
                            }
                        Text(item.rawValue).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(page == item ? Color.accentColor : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if page == item {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(3)
        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, Theme.outerPadding)
        .padding(.bottom, 9)
    }

    /// 标签上的小红点：有需要注意的事情时才出现。
    private func badge(for page: Page) -> Color? {
        switch page {
        case .resources:
            return model.oversizedGroups.isEmpty ? nil : .red
        case .ports:
            let exposed = model.ports.contains { PortExposure.exposedSensitiveService(port: $0.socket.port, address: $0.socket.address) != nil }
            return exposed ? .orange : nil
        case .diagnostics:
            let recent = diagnostics.events.contains { $0.kind == .memoryExhausted && $0.date > Date().addingTimeInterval(-3 * 86_400) }
            return recent ? .red : nil
        case .docker, .cleanup:
            return nil
        }
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
        .padding(.horizontal, Theme.outerPadding)
        .padding(.bottom, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
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
        .frame(height: 28)
        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, Theme.outerPadding)
        .padding(.bottom, 8)
    }

    // MARK: - 内容

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .resources:
            ResourcesPage(model: model, searchText: searchText, sortMetric: $sortMetric) { pendingGroup = $0 }
        case .ports:
            PortsPage(model: model, searchText: searchText) { pendingPort = $0 } requestCleanup: {
                showingPortCleanupConfirmation = true
            }
        case .docker:
            DockerPage(docker: docker, model: model)
        case .cleanup:
            Group {
                switch cleanupSection {
                case .aiCache: aiCachePanel
                case .disk: DiskCleanupView(cleanup: cleanup, searchText: searchText) { showingSettings = true }
                case .apps: AppUninstallView(cleanup: cleanup, searchText: searchText)
                }
            }
            .frame(maxHeight: .infinity)
        case .diagnostics:
            DiagnosticsPage(diagnostics: diagnostics)
        }
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
                    .controlSize(.small)
                    .disabled(model.aiCaches.allSatisfy { $0.isInUse || $0.sizeBytes == 0 })
            }
        } content: {
            if displayedCaches.isEmpty {
                EmptyPanel(
                    title: model.isScanningCaches ? "正在计算" : (searchText.isEmpty ? "缓存都是空的" : "没有匹配结果"),
                    symbol: "externaldrive.badge.checkmark",
                    detail: "可搜索缓存名称或目录"
                )
            } else {
                ForEach(displayedCaches) { cache in
                    CacheRow(cache: cache)
                }
            }
        }
    }

    private var isSearchDisabled: Bool {
        page == .cleanup && cleanupSection == .apps && cleanup.selectedApp != nil
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
        case .docker, .diagnostics: ""
        }
    }

    // MARK: - 底栏

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
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 34)
        .padding(.vertical, 10)
    }

    private var bottomStatus: String {
        switch page {
        case .resources: "\(model.recommendedGroups.count) 项可选后台"
        case .ports: model.autoClosePortsEnabled ? "闲置开发端口自动清理：开" : "闲置开发端口自动清理：关"
        case .docker: "停止容器不会删除数据卷"
        case .cleanup:
            switch cleanupSection {
            case .aiCache: "账号、对话与配置不会删除"
            case .disk: "只移到废纸篓，可从废纸篓还原"
            case .apps: "应用与所选数据移到废纸篓，可还原"
            }
        case .diagnostics: "只读取报告，不做任何修改"
        }
    }

    private var bottomStatusSymbol: String {
        switch page {
        case .resources: "leaf"
        case .ports: model.autoClosePortsEnabled ? "checkmark.circle.fill" : "pause.circle"
        case .docker: "externaldrive"
        case .cleanup: cleanupSection == .aiCache ? "lock.shield" : "trash"
        case .diagnostics: "eye"
        }
    }
}

private struct CacheRow: View {
    let cache: AICacheUsage

    var body: some View {
        HoverRow {
            HStack(spacing: 10) {
                RowIcon(symbol: cache.isInUse ? "lock.fill" : "externaldrive.fill", tint: cache.isInUse ? .orange : .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cache.definition.name).font(.system(size: 11.5, weight: .medium))
                    Text(cache.isInUse ? "应用运行中，退出后才能清理" : "可安全重建")
                        .font(.system(size: 9.5))
                        .foregroundStyle(cache.isInUse ? Color.orange : .secondary)
                }
                Spacer()
                Text(diskByteString(cache.sizeBytes))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
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
                        model.resizeDashboard(width: model.dashboardWidth, height: model.dashboardHeight, persist: true)
                        startingSize = nil
                    }
            )
            .help("拖动调整窗口大小")
    }
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
