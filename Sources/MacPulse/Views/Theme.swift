import AppKit
import MacPulseCore
import SwiftUI

/// 全局视觉常量：圆角、间距、字号集中在这里，各页面不再各写一套数字。
enum Theme {
    static let outerPadding: CGFloat = 14
    static let cardRadius: CGFloat = 14
    static let rowRadius: CGFloat = 9
    static let cardFill = Color(nsColor: .controlBackgroundColor).opacity(0.62)
    static let cardStroke = Color.primary.opacity(0.06)
    static let subtleFill = Color.primary.opacity(0.045)
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

func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
}

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

/// 圆环仪表：数值 0–100。
struct RingGauge: View {
    let value: Double
    let tint: Color
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(Theme.subtleFill, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 100) / 100)
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.55), tint], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(Int(value.rounded()))")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
        }
        .animation(.smooth(duration: 0.45), value: value)
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
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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

struct ContentPanel<Header: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header().padding(.horizontal, 12).padding(.vertical, 10)
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(spacing: 2) { content() }
                    .padding(6)
            }
        }
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.cardStroke))
        .padding(.horizontal, Theme.outerPadding)
        .frame(maxHeight: .infinity)
    }
}

/// 列表行容器：悬停高亮，取代逐行分隔线。
struct HoverRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                hovering ? Theme.subtleFill : .clear,
                in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// 行首的圆角图标。
struct RowIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 行尾的结束 / 关闭按钮。
struct RowCloseButton: View {
    let enabled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 0.65 : 0.15)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct PanelTitle: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(detail).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

struct EmptyPanel: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: 44, height: 44)
                .background(Theme.subtleFill, in: Circle())
            Text(title).font(.system(size: 12, weight: .medium))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

/// 面板内的提示条。
struct Banner: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 9.5))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
    }
}

/// 危险操作按钮：执行期间显示进度，避免用户以为没有响应。
struct TrashButton: View {
    let title: String
    let isBusy: Bool
    var prominent = false
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            if isBusy {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("正在移动…")
                }
            } else {
                Text(title)
            }
        }
        .controlSize(.small)
        .tint(.red)
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
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
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.cardStroke))
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

/// 非模态的结果提示：显示在面板底部，不阻塞其他操作。
struct NoticeBanner: View {
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.cardStroke))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .padding(.horizontal, Theme.outerPadding)
        .padding(.top, 8)
    }
}
