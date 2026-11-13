import AppKit
import Foundation
import MacPulseCore

@MainActor
final class DockerModel: ObservableObject {
    @Published private(set) var status: DockerStatus?
    @Published private(set) var isLoading = false
    @Published private(set) var busyContainerIDs: Set<String> = []
    @Published private(set) var lastError: String?

    private let client = DockerClient()

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let client = client
        Task {
            status = await Task.detached(priority: .utility) { client.status() }.value
            isLoading = false
        }
    }

    func setRunning(_ running: Bool, container: DockerContainer) {
        guard !busyContainerIDs.contains(container.id) else { return }
        busyContainerIDs.insert(container.id)
        lastError = nil
        let client = client
        Task {
            let error = await Task.detached(priority: .userInitiated) {
                client.setRunning(running, containerID: container.id)
            }.value
            busyContainerIDs.remove(container.id)
            lastError = error.map { "\(container.name)：\($0)" }
            refresh()
        }
    }

    func stopAll() {
        guard case .running(let overview) = status else { return }
        overview.runningContainers.forEach { setRunning(false, container: $0) }
    }

    func openDockerApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.docker.docker") else {
            lastError = "未找到 Docker Desktop"
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
        lastError = "正在启动 Docker，稍后点刷新"
    }
}

@MainActor
final class DiagnosticsModel: ObservableObject {
    @Published private(set) var events: [DiagnosticEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadedAt: Date?

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            events = await Task.detached(priority: .utility) { DiagnosticReportReader().recentEvents() }.value
            loadedAt = Date()
            isLoading = false
        }
    }

    func reveal(_ event: DiagnosticEvent) {
        NSWorkspace.shared.activateFileViewerSelecting([event.url])
    }
}
