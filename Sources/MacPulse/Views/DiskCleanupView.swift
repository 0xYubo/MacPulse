import AppKit
import MacPulseCore
import SwiftUI

struct DiskCleanupView: View {
    @ObservedObject var cleanup: CleanupModel
    let searchText: String
    let openSettings: () -> Void

    @State private var showingConfirmation = false

    private var displayedItems: [CleanupItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return cleanup.diskItems }
        return cleanup.diskItems.filter {
            $0.name.lowercased().contains(query) || $0.url.path.lowercased().contains(query)
        }
    }

    var body: some View {
        let items = displayedItems
        let selected = cleanup.selectedDiskItems(in: items)
        let selectedBytes = selected.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let hiddenSelectedCount = cleanup.selectedDiskItems(in: cleanup.diskItems).count - selected.count

        ContentPanel {
            HStack {
                PanelTitle(
                    title: "磁盘清理",
                    detail: "已选 \(selected.count) 项 · \(diskByteString(selectedBytes))"
                        + (hiddenSelectedCount > 0 ? " · \(hiddenSelectedCount) 项不在搜索结果中，不会处理" : "")
                )
                Spacer()
                if cleanup.diskState == .loading {
                    Button("取消") { cleanup.cancelDiskScan() }
                        .controlSize(.small)
                } else {
                    HeaderButton(symbol: "arrow.clockwise", help: "重新扫描") { cleanup.scanDisk() }
                        .disabled(cleanup.isTrashing)
                }
                TrashButton(title: "移到废纸篓", isBusy: cleanup.isTrashing) { showingConfirmation = true }
                    .disabled(selected.isEmpty || cleanup.isTrashing || cleanup.diskState == .loading)
            }
        } content: {
            Group {
                statusBanners
                content(items)
            }
            .disabled(cleanup.isTrashing)
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardWillClose)) { _ in
            showingConfirmation = false
        }
        .onAppear {
            if cleanup.diskState == .idle, cleanup.diskScannedAt == nil { cleanup.scanDisk() }
        }
        .confirmationDialog(
            "将 \(selected.count) 项（\(diskByteString(selectedBytes))）移到废纸篓？",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) { cleanup.trashDiskItems(selected) }
            Button("取消", role: .cancel) { }
        } message: {
            Text(confirmationDetail(selected))
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
        if cleanup.diskState == .loading, !cleanup.diskItems.isEmpty {
            Banner(symbol: "arrow.triangle.2.circlepath", text: "正在更新：\(cleanup.diskPhase ?? "准备中")…", tint: .secondary)
        }
        if cleanup.diskResultsOutdated {
            Banner(symbol: "exclamationmark.arrow.circlepath", text: "工作区目录已修改，重新扫描后生效", tint: .orange)
        }
        ForEach(cleanup.diskWarnings, id: \.self) { warning in
            Banner(symbol: "exclamationmark.triangle", text: warning, tint: .orange)
        }
        if cleanup.diskUnreadableCount > 0 {
            HStack(spacing: 6) {
                Banner(
                    symbol: "lock.trianglebadge.exclamationmark",
                    text: "\(cleanup.diskUnreadableCount) 个文件没有读取权限，未计入大小",
                    tint: .orange
                )
                // macOS 不允许应用自行申请完全磁盘访问权限，只能引导用户去系统设置里勾选。
                Button("去授权") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.mini)
                .help("在「隐私与安全性 → 完全磁盘访问权限」中加入 MacPulse")
            }
        }
        if let scannedAt = cleanup.diskScannedAt, cleanup.diskState == .loaded {
            Text("上次扫描 \(scannedAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 12)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func content(_ items: [CleanupItem]) -> some View {
        switch cleanup.diskState {
        case .idle where cleanup.diskItems.isEmpty:
            VStack(spacing: 10) {
                EmptyPanel(title: "尚未扫描", symbol: "internaldrive", detail: "统计开发缓存、应用缓存、日志与下载目录")
                Button("开始扫描") { cleanup.scanDisk() }
                    .controlSize(.small)
            }
        case .loading where cleanup.diskItems.isEmpty:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在扫描：\(cleanup.diskPhase ?? "准备中")").font(.system(size: 12, weight: .medium))
                Text("通常需要 10–30 秒，可随时取消").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case .failed(let message):
            VStack(spacing: 10) {
                EmptyPanel(title: "扫描失败", symbol: "exclamationmark.triangle", detail: message)
                Button("重试") { cleanup.scanDisk() }
                    .controlSize(.small)
            }
        default:
            if items.isEmpty {
                EmptyPanel(
                    title: searchText.isEmpty ? "没有发现可清理项" : "没有匹配结果",
                    symbol: "checkmark.seal",
                    detail: searchText.isEmpty ? emptyDetail : "可搜索名称或路径"
                )
                if searchText.isEmpty, cleanup.workspaceRoots.isEmpty {
                    Button("设置开发工作区目录…", action: openSettings)
                        .controlSize(.small)
                }
            } else {
                ForEach(CleanupCategory.allCases) { category in
                    let rows = items.filter { $0.category == category }
                    if !rows.isEmpty {
                        CategoryHeader(
                            category: category,
                            rows: rows,
                            sources: rows.filter { !$0.isInUse }.map(selectionBinding)
                        )
                        ForEach(rows) { item in
                            CleanupItemRow(item: item, isSelected: selectionBinding(item))
                        }
                    }
                }
            }
        }
    }

    private var emptyDetail: String {
        cleanup.workspaceRoots.isEmpty
            ? "扫描已完成。尚未配置开发工作区目录，项目中的依赖与构建产物未参与扫描"
            : "扫描已完成，当前没有符合规则的文件"
    }

    private func selectionBinding(_ item: CleanupItem) -> Binding<Bool> {
        Binding(
            get: { cleanup.diskSelection.contains(item.id) },
            set: { cleanup.setSelection([item], selected: $0) }
        )
    }

    private func confirmationDetail(_ items: [CleanupItem]) -> String {
        var lines = items.prefix(5).map { item in
            "· \(item.name) — \(abbreviatedPath(item.url.deletingLastPathComponent()))（\(diskByteString(item.sizeBytes))）"
        }
        if items.count > 5 { lines.append("…… 另有 \(items.count - 5) 项") }
        let userFiles = items.filter(\.category.isUserFiles).count
        if userFiles > 0 { lines.append("其中 \(userFiles) 项是下载或桌面中的用户文件。") }
        lines.append("删除前会再次检查是否正在使用。清空废纸篓后才会真正释放空间。")
        return lines.joined(separator: "\n")
    }
}

private struct CategoryHeader: View {
    let category: CleanupCategory
    let rows: [CleanupItem]
    /// 分类内可勾选的条目；系统 Toggle 会据此显示全选、未选或部分选中三种状态。
    let sources: [Binding<Bool>]

    var body: some View {
        HStack(spacing: 6) {
            Toggle(category.label, sources: sources, isOn: \.self)
                .toggleStyle(.checkbox)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .disabled(sources.isEmpty)
            if category.isUserFiles {
                Text("用户文件，默认未勾选，请逐项确认")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text(diskByteString(rows.reduce(UInt64(0)) { $0 + $1.sizeBytes }))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 3)
    }
}

private struct CleanupItemRow: View {
    let item: CleanupItem
    @Binding var isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            if item.isInUse {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 16)
            } else {
                Toggle(item.name, isOn: $isSelected)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(item.isInUse || item.note != nil ? Color.orange : Color.secondary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(diskByteString(item.sizeBytes))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { if !item.isInUse { isSelected.toggle() } }
        .help(item.inUseReason.map { "\($0)\n\(item.url.path)" } ?? item.url.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
    }

    private var subtitle: String {
        if let reason = item.inUseReason { return "\(reason) · 已保护" }
        if let note = item.note { return note }
        return abbreviatedPath(item.url)
    }
}

func abbreviatedPath(_ url: URL) -> String {
    (url.path as NSString).abbreviatingWithTildeInPath
}
