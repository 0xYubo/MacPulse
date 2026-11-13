import AppKit
import Darwin
import MacPulseCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model = MonitorModel()
    private let cleanup = CleanupModel()
    private let docker = DockerModel()
    private let diagnostics = DiagnosticsModel()
    private var timer: Timer?
    private var outsideClickMonitor: Any?
    private var singleInstanceLockFD: Int32 = -1

    func applicationWillFinishLaunching(_ notification: Notification) {
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("com.mayubo.macpulse.instance.lock")
        let fileDescriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            NSApp.terminate(nil)
            return
        }
        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fileDescriptor)
            NSApp.terminate(nil)
            return
        }
        singleInstanceLockFD = fileDescriptor
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()
        model.didUpdate = { [weak self] snapshot in
            self?.updateStatusTitle(snapshot)
        }
        cleanup.report = { [weak self] message in
            self?.model.notice = message
        }
        model.didResize = { [weak self] size in
            self?.popover.contentSize = size
        }
        if model.pressureAlertsEnabled { model.requestNotificationAuthorization() }
        model.refresh()
        // 诊断报告启动时读一次，标签上的提醒点才有依据；之后在诊断页按需刷新。
        diagnostics.refresh()
        scheduleTimer(interval: 15)
        Timer.scheduledTimer(
            timeInterval: 0.8,
            target: self,
            selector: #selector(showInitialPopover),
            userInfo: nil,
            repeats: false
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        removeOutsideClickMonitor()
        if singleInstanceLockFD >= 0 {
            flock(singleInstanceLockFD, LOCK_UN)
            Darwin.close(singleInstanceLockFD)
            singleInstanceLockFD = -1
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "MacPulse")
        button.imagePosition = .imageLeading
        button.title = " --%"
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentSize = NSSize(width: model.dashboardWidth, height: model.dashboardHeight)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: DashboardView(model: model, cleanup: cleanup, docker: docker, diagnostics: diagnostics, quit: { NSApp.terminate(nil) })
        )
    }

    @objc private func refreshMetrics() {
        model.refresh()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            showPopover(from: button)
        }
    }

    @objc private func showInitialPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        showPopover(from: button)
    }

    /// `activate(ignoringOtherApps:)` 自 macOS 14 起已废弃且可能不生效；面板窗口拿不到焦点时，
    /// 第一次点击只用于激活窗口，表现为按钮「点了没反应」。这里改用新 API 并显式让面板窗口成为关键窗口。
    private func showPopover(from button: NSStatusBarButton) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installOutsideClickMonitor()
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) {
        installOutsideClickMonitor()
        scheduleTimer(interval: 3)
    }

    func popoverWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .dashboardWillClose, object: nil)
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        scheduleTimer(interval: 15)
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard self?.popover.isShown == true else { return }
                self?.popover.performClose(nil)
            }
        }
    }

    private func removeOutsideClickMonitor() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            timeInterval: interval,
            target: self,
            selector: #selector(refreshMetrics),
            userInfo: nil,
            repeats: true
        )
    }

    /// 菜单栏数字仍是 CPU；内存压力偏高 / 紧张时图标换成内存芯片并着橙 / 红色，面板收起时也能看到。
    private func updateStatusTitle(_ snapshot: SystemSnapshot) {
        guard let button = statusItem.button else { return }
        let cpu = String(format: "%.0f%%", model.displayCPU?.totalPercent ?? snapshot.cpuPercent)
        let memory = String(format: "%.0f%%", snapshot.memoryPercent)
        switch model.menuBarDisplay {
        case .cpu: button.title = " \(cpu)"
        case .memory: button.title = " \(memory)"
        case .both: button.title = " \(cpu) · \(memory)"
        case .icon: button.title = ""
        }
        let pressure = snapshot.memoryPressure ?? .normal
        let symbol = pressure == .normal ? "waveform.path.ecg" : "memorychip"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacPulse")
        switch pressure {
        case .normal: button.contentTintColor = nil
        case .warning: button.contentTintColor = .systemOrange
        case .critical: button.contentTintColor = .systemRed
        }
        let pressureText = snapshot.memoryPressure?.label ?? "未知"
        button.toolTip = model.health.map { "MacPulse · \($0.text) · 内存压力\(pressureText)" } ?? "MacPulse"
    }
}
