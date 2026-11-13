import AppKit
import SwiftUI

struct SettingsView: View {
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
                    Text("显示、提醒、自动化与清理").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    SettingsCard(title: "外观与菜单栏", symbol: "menubar.rectangle", tint: .cyan) {
                        Picker("主题", selection: $model.appearanceMode) {
                            ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Picker("菜单栏显示", selection: $model.menuBarDisplay) {
                            ForEach(MenuBarDisplay.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            SettingsHint("内存压力偏高 / 紧张时菜单栏图标会变橙 / 红。拖动主面板右下角可调整尺寸。")
                            Spacer()
                            Button("恢复默认尺寸") { model.resetDashboardSize() }
                                .controlSize(.small)
                        }
                    }
                    SettingsCard(title: "内存提醒", symbol: "memorychip", tint: .red) {
                        Toggle("内存压力变「紧张」时发送系统通知", isOn: $model.pressureAlertsEnabled)
                        Toggle("单个应用占用过高时发送系统通知", isOn: $model.groupAlertsEnabled)
                        HStack {
                            Text("阈值").font(.system(size: 12))
                            Slider(value: $model.groupAlertThresholdGB, in: 2...16, step: 1)
                                .disabled(!model.groupAlertsEnabled)
                            Text(MonitorModel.thresholdLabel(model.groupAlertThresholdGB))
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 48, alignment: .trailing)
                        }
                        SettingsHint("同名进程合计计算（例如 9 个 jest worker 算一组）。每次超限只提醒一次，降到阈值 80% 以下后才会再次提醒。")
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
