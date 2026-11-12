import AppKit
import MacPulseCore
import SwiftUI

struct AppUninstallView: View {
    @ObservedObject var cleanup: CleanupModel
    let searchText: String

    @State private var showingConfirmation = false

    private var displayedApps: [InstalledApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return cleanup.apps }
        return cleanup.apps.filter {
            $0.name.lowercased().contains(query) || ($0.bundleID?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        Group {
            if let app = cleanup.selectedApp {
                detail(app)
            } else {
                appList
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardWillClose)) { _ in
            showingConfirmation = false
        }
        .onAppear {
            if cleanup.appsState == .idle { cleanup.loadApps() }
        }
    }

    private var appList: some View {
        let apps = displayedApps
        return ContentPanel {
            HStack {
                PanelTitle(title: "软件卸载", detail: "\(apps.count) 个应用 · 系统自带应用不显示")
                Spacer()
                HeaderButton(symbol: "arrow.clockwise", help: "重新读取", isBusy: cleanup.appsState == .loading) {
                    cleanup.loadApps()
                }
                .disabled(cleanup.appsState == .loading)
            }
        } content: {
            ForEach(cleanup.appWarnings, id: \.self) { warning in
                Banner(symbol: "exclamationmark.triangle", text: warning, tint: .orange)
            }
            switch cleanup.appsState {
            case .idle, .loading:
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取应用").font(.system(size: 12, weight: .medium))
                    Text("统计 /Applications 与 ~/Applications").font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            case .failed(let message):
                VStack(spacing: 10) {
                    EmptyPanel(title: "读取失败", symbol: "exclamationmark.triangle", detail: message)
                    Button("重试") { cleanup.loadApps() }.controlSize(.small)
                }
            case .loaded:
                if apps.isEmpty {
                    EmptyPanel(
                        title: searchText.isEmpty ? "没有可卸载的应用" : "没有匹配结果",
                        symbol: "app.dashed",
                        detail: "可搜索应用名称或 Bundle ID"
                    )
                } else {
                    ForEach(apps) { app in
                        AppRow(app: app, isRunning: cleanup.runningReason(for: app) != nil) { cleanup.select(app) }
                        if app.id != apps.last?.id { Divider().padding(.leading, 43) }
                    }
                }
            }
        }
    }

    private func detail(_ app: InstalledApp) -> some View {
        let leftovers = cleanup.leftovers.filter { cleanup.leftoverSelection.contains($0.id) }
        let total = leftovers.reduce(app.sizeBytes) { $0 + $1.sizeBytes }
        let runningReason = cleanup.runningReason(for: app)

        return ContentPanel {
            HStack(spacing: 8) {
                Button { cleanup.select(nil) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("返回应用列表")
                .accessibilityLabel("返回应用列表")
                .disabled(cleanup.isTrashing)
                PanelTitle(title: app.name, detail: "共 \(diskByteString(total)) · 残留 \(leftovers.count) 项")
                Spacer()
                TrashButton(title: "卸载", isBusy: cleanup.isTrashing) { showingConfirmation = true }
                    .disabled(cleanup.isTrashing || cleanup.leftoversState != .loaded || runningReason != nil)
            }
        } content: {
            Group {
                if let runningReason {
                    HStack {
                        Banner(symbol: "exclamationmark.triangle", text: runningReason, tint: .orange)
                        Button("退出 \(app.name)") { cleanup.quit(app) }
                            .controlSize(.small)
                            .padding(.trailing, 12)
                    }
                }
                if let warning = app.warning {
                    Banner(symbol: "exclamationmark.triangle", text: warning, tint: .orange)
                }
                ForEach(cleanup.leftoverWarnings, id: \.self) { warning in
                    Banner(symbol: "exclamationmark.triangle", text: warning, tint: .orange)
                }
                LeftoverRow(
                    title: "应用本体",
                    subtitle: abbreviatedPath(app.url),
                    size: app.sizeBytes,
                    caution: nil,
                    isRequired: true,
                    isSelected: .constant(true)
                )
                switch cleanup.leftoversState {
                case .idle, .loading:
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在查找残留文件").font(.system(size: 12, weight: .medium))
                        Text("只按 Bundle ID 与应用名精确匹配").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 100)
                case .failed(let message):
                    EmptyPanel(title: "查找失败", symbol: "exclamationmark.triangle", detail: message)
                case .loaded:
                    if cleanup.leftovers.isEmpty {
                        EmptyPanel(
                            title: "没有发现残留文件",
                            symbol: "checkmark.seal",
                            detail: cleanup.leftoverWarnings.isEmpty ? "~/Library 中没有与该应用精确匹配的数据" : "部分目录无法读取，见上方提示"
                        )
                    } else {
                        ForEach(cleanup.leftovers) { leftover in
                            Divider().padding(.leading, 36)
                            LeftoverRow(
                                title: leftover.url.lastPathComponent,
                                subtitle: leftover.location,
                                size: leftover.sizeBytes,
                                caution: leftover.caution,
                                isRequired: false,
                                isSelected: selectionBinding(leftover)
                            )
                        }
                    }
                    Text("读取 ~/Library/Containers 时系统可能请求授权；拒绝后对应目录会在上方提示无法读取。")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
            .disabled(cleanup.isTrashing)
        }
        .confirmationDialog("卸载 \(app.name)？", isPresented: $showingConfirmation, titleVisibility: .visible) {
            Button("移到废纸篓", role: .destructive) { cleanup.uninstallSelectedApp() }
            Button("取消", role: .cancel) { }
        } message: {
            Text(confirmationDetail(app: app, leftovers: leftovers, total: total))
        }
    }

    private func selectionBinding(_ leftover: AppLeftover) -> Binding<Bool> {
        Binding(
            get: { cleanup.leftoverSelection.contains(leftover.id) },
            set: { isOn in
                if isOn { cleanup.leftoverSelection.insert(leftover.id) } else { cleanup.leftoverSelection.remove(leftover.id) }
            }
        )
    }

    private func confirmationDetail(app: InstalledApp, leftovers: [AppLeftover], total: UInt64) -> String {
        var lines = ["· \(app.url.lastPathComponent)（\(diskByteString(app.sizeBytes))）"]
        lines += leftovers.prefix(5).map { leftover in
            let flag = leftover.caution == nil ? "" : "，需确认"
            return "· \(leftover.location)/\(leftover.url.lastPathComponent)（\(diskByteString(leftover.sizeBytes))\(flag)）"
        }
        if leftovers.count > 5 { lines.append("…… 另有 \(leftovers.count - 5) 项") }
        lines.append("合计 \(diskByteString(total))。应用本体移除失败时，残留文件不会被处理。清空废纸篓后才会真正释放空间。")
        return lines.joined(separator: "\n")
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let isRunning: Bool
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                AppIconView(url: app.url)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    Text([app.version, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                if isRunning { StatusPill(text: "运行中", color: .orange) }
                Text(diskByteString(app.sizeBytes))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(isHovering ? Color.primary.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(app.name)，\(diskByteString(app.sizeBytes))")
    }
}

/// 应用图标异步加载并缓存在视图状态中，避免每次重绘同步调用 IconServices。
private struct AppIconView: View {
    let url: URL
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable()
            } else {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
            }
        }
        .frame(width: 22, height: 22)
        .task(id: url) {
            let path = url.path
            icon = await Task.detached(priority: .utility) {
                IconBox(image: NSWorkspace.shared.icon(forFile: path))
            }.value.image
        }
    }
}

/// NSImage 不是 Sendable；图标在后台创建后只交给主线程使用，不会并发修改。
private struct IconBox: @unchecked Sendable {
    let image: NSImage
}

private struct LeftoverRow: View {
    let title: String
    let subtitle: String
    let size: UInt64
    let caution: String?
    let isRequired: Bool
    @Binding var isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            if isRequired {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            } else {
                Toggle(title, isOn: $isSelected)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if isRequired { StatusPill(text: "必选", color: .secondary) }
                    if caution != nil { StatusPill(text: "需确认", color: .orange) }
                }
                Text(caution.map { "\($0) · \(subtitle)" } ?? subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(caution == nil ? Color.secondary.opacity(0.7) : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(diskByteString(size))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { if !isRequired { isSelected.toggle() } }
        .accessibilityElement(children: .combine)
    }
}
