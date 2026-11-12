import Darwin
import Foundation
import AppKit
import MacPulseNative

public struct ProcessTerminator: Sendable {
    private let classifier: ProcessClassifier

    public init(currentPID: Int32 = getpid(), currentUser: String = NSUserName()) {
        self.classifier = ProcessClassifier(currentPID: currentPID, currentUser: currentUser)
    }

    public func terminate(_ group: ProcessGroup) -> TerminationResult {
        var stopped = 0
        var refused = 0
        var failed = 0

        for process in group.processes {
            guard classifier.canTerminate(process) else {
                refused += 1
                continue
            }

            guard isSameProcess(process) else {
                refused += 1
                continue
            }

            if process.command.contains(".app/"),
               let application = NSRunningApplication(processIdentifier: process.pid),
               application.terminate() {
                stopped += 1
            } else if kill(process.pid, SIGTERM) == 0 {
                stopped += 1
            } else if errno == ESRCH {
                stopped += 1
            } else {
                failed += 1
            }
        }

        return TerminationResult(stopped: stopped, refused: refused, failed: failed)
    }

    private func isSameProcess(_ process: ProcessSnapshot) -> Bool {
        // 没有启动时间就无法排除 PID 复用，宁可拒绝也不能把信号发给一个新进程。
        guard process.startTime != 0 else { return false }
        var metrics = MPProcessMetrics()
        return mp_read_process_metrics(process.pid, &metrics) == 0
            && metrics.start_time == process.startTime
    }
}

public struct TerminationResult: Sendable {
    public let stopped: Int
    public let refused: Int
    public let failed: Int

    public init(stopped: Int, refused: Int, failed: Int) {
        self.stopped = stopped
        self.refused = refused
        self.failed = failed
    }
}
