import MacPulseCore
import SwiftUI

struct DockerPage: View {
    @ObservedObject var docker: DockerModel
    @ObservedObject var model: MonitorModel
    @State private var confirmingStopAll = false

    var body: some View {
        ContentPanel {
            HStack {
                PanelTitle(title: "Docker", detail: subtitle)
                Spacer()
                HeaderButton(symbol: "arrow.clockwise", help: "刷新", isBusy: docker.isLoading) { docker.refresh() }
                    .disabled(docker.isLoading)
                if case .running(let overview) = docker.status, !overview.runningContainers.isEmpty {
                    Button("全部停止") { confirmingStopAll = true }
                        .controlSize(.small)
                }
            }
        } content: {
            if let error = docker.lastError {
                Banner(symbol: "info.circle", text: error, tint: .orange)
            }
            switch docker.status {
            case nil:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 140)
            case .notInstalled:
                EmptyPanel(title: "未检测到 Docker", symbol: "shippingbox", detail: "在常见位置没有找到 docker 命令（Docker Desktop、OrbStack、Homebrew）")
            case .daemonUnavailable(let message):
                VStack(spacing: 10) {
                    EmptyPanel(title: "Docker 未运行", symbol: "shippingbox", detail: message)
                    Button("启动 Docker Desktop") { docker.openDockerApp() }
                        .controlSize(.small)
                }
            case .running(let overview):
                DockerSummary(overview: overview, vmBytes: virtualMachineBytes)
                if overview.containers.isEmpty {
                    EmptyPanel(title: "没有容器", symbol: "shippingbox", detail: "docker ps -a 没有返回任何容器")
                } else {
                    ForEach(overview.containers) { container in
                        ContainerRow(
                            container: container,
                            isBusy: docker.busyContainerIDs.contains(container.id)
                        ) { docker.setRunning(!container.isRunning, container: container) }
                    }
                }
            }
        }
        .onAppear { docker.refresh() }
        // 只在停留在 Docker 页时轮询：docker stats 每次要 1–2 秒，不值得后台常驻。
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in docker.refresh() }
        .confirmationDialog("停止全部容器？", isPresented: $confirmingStopAll, titleVisibility: .visible) {
            Button("全部停止", role: .destructive) { docker.stopAll() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将对所有运行中的容器执行 docker stop，数据卷不受影响，之后可在这里逐个启动。")
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardWillClose)) { _ in confirmingStopAll = false }
    }

    private var subtitle: String {
        switch docker.status {
        case .running(let overview): "\(overview.runningContainers.count) 个运行中 · 共 \(overview.containers.count) 个容器"
        case .daemonUnavailable: "未运行"
        case .notInstalled: "未安装"
        case nil: "正在读取"
        }
    }

    /// Docker 虚拟机进程的实际内存占用：容器合计之外还有内核、页缓存，往往高出不少。
    private var virtualMachineBytes: UInt64? {
        let groups = model.snapshot?.groups ?? []
        let vm = groups.filter { group in
            group.processes.contains { $0.command.contains("Virtualization.VirtualMachine") || $0.command.contains("com.docker.virtualization") }
        }
        let total = vm.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        return total > 0 ? total : nil
    }
}

private struct DockerSummary: View {
    let overview: DockerOverview
    let vmBytes: UInt64?

    var body: some View {
        HStack(spacing: 0) {
            stat("容器合计", bytes(overview.containerMemoryBytes))
            Divider().frame(height: 28)
            stat("虚拟机实际", vmBytes.map(bytes) ?? "—")
            Divider().frame(height: 28)
            stat("内存上限", overview.memoryLimitBytes.map(bytes) ?? "—")
            Divider().frame(height: 28)
            stat("CPU", overview.cpuCount.map { "\($0) 核" } ?? "—")
        }
        .padding(.vertical, 8)
        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .padding(.bottom, 4)
        .help("内存上限在 Docker Desktop → Settings → Resources 中调整；虚拟机会逐渐占满上限，建议 4–6 GB。")
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ContainerRow: View {
    let container: DockerContainer
    let isBusy: Bool
    let toggle: () -> Void

    var body: some View {
        HoverRow {
            HStack(spacing: 10) {
                RowIcon(symbol: "shippingbox.fill", tint: container.isRunning ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(container.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        if container.ports.contains("0.0.0.0:") {
                            StatusPill(text: "对外开放", color: .orange)
                        }
                    }
                    Text(verbatim: "\(container.image) · \(container.status)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if container.isRunning {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(container.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        Text(container.memoryBytes.map(bytes) ?? "—")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 62, alignment: .trailing)
                }
                Button(action: toggle) {
                    if isBusy {
                        ProgressView().controlSize(.mini).frame(width: 15, height: 15)
                    } else {
                        Image(systemName: container.isRunning ? "stop.circle.fill" : "play.circle.fill")
                            .font(.system(size: 15))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(container.isRunning ? Color.secondary : Color.green)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .help(container.isRunning ? "停止容器" : "启动容器")
            }
        }
        .help(container.ports.isEmpty ? container.name : "端口：\(container.ports)")
    }
}

struct DiagnosticsPage: View {
    @ObservedObject var diagnostics: DiagnosticsModel
    @State private var expanded: Set<String> = []

    var body: some View {
        ContentPanel {
            HStack {
                PanelTitle(title: "卡顿复盘", detail: "近 14 天系统记录的内存耗尽、无响应与崩溃")
                Spacer()
                HeaderButton(symbol: "arrow.clockwise", help: "重新读取", isBusy: diagnostics.isLoading) { diagnostics.refresh() }
                    .disabled(diagnostics.isLoading)
            }
        } content: {
            if diagnostics.events.isEmpty {
                EmptyPanel(
                    title: diagnostics.isLoading ? "正在读取" : "近 14 天没有异常记录",
                    symbol: "checkmark.seal",
                    detail: "报告来自 /Library/Logs/DiagnosticReports，由 macOS 自动写入"
                )
            } else {
                if let latest = diagnostics.events.first(where: { $0.kind == .memoryExhausted && !$0.topProcesses.isEmpty }) {
                    LatestExhaustionCard(event: latest)
                }
                ForEach(diagnostics.events) { event in
                    EventRow(event: event, isExpanded: expanded.contains(event.id)) {
                        withAnimation(.smooth(duration: 0.2)) {
                            if expanded.contains(event.id) { expanded.remove(event.id) } else { expanded.insert(event.id) }
                        }
                    } reveal: { diagnostics.reveal(event) }
                }
            }
        }
        .onAppear { diagnostics.refresh() }
    }
}

private struct EventRow: View {
    let event: DiagnosticEvent
    let isExpanded: Bool
    let toggle: () -> Void
    let reveal: () -> Void

    var body: some View {
        HoverRow {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    RowIcon(symbol: symbol, tint: tint)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(event.kind.rawValue).font(.system(size: 11.5, weight: .medium))
                            if event.processName != event.kind.rawValue {
                                Text(event.processName).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Text(event.date.formatted(.relative(presentation: .named)) + " · " + event.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !event.topProcesses.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    Button(action: reveal) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("在访达中显示报告")
                }
                .contentShape(Rectangle())
                .onTapGesture { if !event.topProcesses.isEmpty { toggle() } }

                if isExpanded {
                    JetsamDetail(event: event)
                }
            }
        }
    }

    private var symbol: String {
        switch event.kind {
        case .memoryExhausted: "memorychip.fill"
        case .shutdownStall: "power"
        case .cpuResource: "cpu.fill"
        case .diskWrites: "internaldrive.fill"
        case .hang: "hourglass"
        case .crash: "exclamationmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .memoryExhausted: .red
        case .shutdownStall, .hang: .orange
        case .cpuResource, .diskWrites: .yellow
        case .crash: .pink
        }
    }
}

/// 置顶摘要：最近一次内存耗尽时谁占得最多——卡死之后最想知道的就是这个。
private struct LatestExhaustionCard: View {
    let event: DiagnosticEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("最近一次内存耗尽 · \(event.date.formatted(.relative(presentation: .named)))", systemImage: "memorychip.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
            Text(summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .padding(.bottom, 4)
    }

    private var summary: String {
        let top = event.topProcesses.prefix(3).map { usage in
            usage.count > 1 ? "\(usage.name) ×\(usage.count)（\(bytes(usage.bytes))）" : "\(usage.name)（\(bytes(usage.bytes))）"
        }
        return "当时占用最多：\(top.joined(separator: "、"))。展开下方记录可看完整排行。"
    }
}

private struct JetsamDetail: View {
    let event: DiagnosticEvent

    var body: some View {
        let maxBytes = event.topProcesses.first?.bytes ?? 1
        VStack(alignment: .leading, spacing: 5) {
            Text("当时占用最多的进程").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(event.topProcesses, id: \.name) { usage in
                HStack(spacing: 8) {
                    Text(usage.count > 1 ? "\(usage.name) ×\(usage.count)" : usage.name)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 170, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule().fill(Color.red.opacity(0.45))
                            .frame(width: max(proxy.size.width * Double(usage.bytes) / Double(max(maxBytes, 1)), 2))
                    }
                    .frame(height: 4)
                    Text(bytes(usage.bytes))
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 64, alignment: .trailing)
                }
            }
            if !event.killedProcesses.isEmpty {
                Text("被系统结束：\(event.killedProcesses.joined(separator: "、"))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 38)
    }
}
