import Darwin
import Foundation
import MacPulseNative

public final class MetricsSampler: @unchecked Sendable {
    private struct RawProcess {
        let pid: Int32
        let parentPID: Int32
        let user: String
        let name: String
        let command: String
        let cpuTimeNS: UInt64?
        let fallbackCPUPercent: Double
        let memoryBytes: UInt64
        let startTime: UInt64
    }

    private struct Capture {
        let processes: [RawProcess]
        let cpuTicks: MPCPUTicks
        let monotonicNS: UInt64
    }

    private let classifier: ProcessClassifier
    private let lock = NSLock()
    private var previousTimes: [Int32: UInt64] = [:]
    private var previousTicks: MPCPUTicks?
    private var previousMonotonicNS: UInt64?

    public init(currentPID: Int32 = getpid(), currentUser: String = NSUserName()) {
        self.classifier = ProcessClassifier(currentPID: currentPID, currentUser: currentUser)
    }

    /// 单个进程内存取 rusage 的 physical footprint（与活动监视器「内存」列一致）；
    /// 读不到的其他用户进程回退为 ps 的 RSS。此前每 5 秒调用一次 `top` 补齐这部分，单次约 0.7 秒系统 CPU，开销与收益不成比例，已移除。
    public func sample() throws -> SystemSnapshot {
        lock.lock()
        defer { lock.unlock() }

        if previousMonotonicNS == nil {
            storeBaseline(try capture())
            usleep(250_000)
        }

        let capture = try capture()
        return try makeSnapshot(from: capture)
    }

    private func capture() throws -> Capture {
        var ticks = MPCPUTicks()
        guard mp_read_cpu_ticks(&ticks) == 0 else {
            throw SamplingError.cpuStatisticsFailed
        }

        let metadata = try readProcessMetadata()
        let processes = metadata.map { item -> RawProcess in
            var metrics = MPProcessMetrics()
            let hasNativeMetrics = mp_read_process_metrics(item.pid, &metrics) == 0
            return RawProcess(
                pid: item.pid,
                parentPID: item.parentPID,
                user: item.user,
                name: item.name,
                command: item.command,
                cpuTimeNS: hasNativeMetrics ? metrics.user_time_ns &+ metrics.system_time_ns : nil,
                fallbackCPUPercent: item.fallbackCPUPercent,
                memoryBytes: hasNativeMetrics ? metrics.physical_footprint : item.fallbackMemoryBytes,
                startTime: hasNativeMetrics ? metrics.start_time : 0
            )
        }

        return Capture(
            processes: processes,
            cpuTicks: ticks,
            monotonicNS: DispatchTime.now().uptimeNanoseconds
        )
    }

    private func makeSnapshot(from capture: Capture) throws -> SystemSnapshot {
        let previousTime = previousMonotonicNS ?? capture.monotonicNS
        let elapsedNS = max(capture.monotonicNS &- previousTime, 1)
        let processSnapshots = capture.processes.map { raw in
            let nativeCPU: Double? = raw.cpuTimeNS.flatMap { current in
                guard let previous = previousTimes[raw.pid] else { return nil }
                let delta = current >= previous ? current - previous : 0
                return Double(delta) / Double(elapsedNS) * 100
            }
            return ProcessSnapshot(
                pid: raw.pid,
                parentPID: raw.parentPID,
                user: raw.user,
                name: raw.name,
                command: raw.command,
                cpuPercent: nativeCPU ?? raw.fallbackCPUPercent,
                memoryBytes: raw.memoryBytes,
                isEstimated: nativeCPU == nil,
                startTime: raw.startTime
            )
        }

        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let swap = Self.swapUsage()
        let cpu = cpuBreakdown(current: capture.cpuTicks, previous: previousTicks)
        let memory = try memoryStatistics(total: totalMemory)
        let snapshot = SystemSnapshot(
            cpuPercent: cpu.user + cpu.system,
            userCPUPercent: cpu.user,
            systemCPUPercent: cpu.system,
            idleCPUPercent: cpu.idle,
            usedMemoryBytes: memory.used,
            totalMemoryBytes: totalMemory,
            swapUsedBytes: swap?.used,
            swapTotalBytes: swap?.total,
            memoryPressure: Self.memoryPressure(),
            memoryBreakdown: memory.breakdown,
            groups: group(processes: processSnapshots)
        )
        storeBaseline(capture)
        return snapshot
    }

    private func storeBaseline(_ capture: Capture) {
        previousTimes = Dictionary(uniqueKeysWithValues: capture.processes.compactMap {
            guard let time = $0.cpuTimeNS else { return nil }
            return ($0.pid, time)
        })
        previousTicks = capture.cpuTicks
        previousMonotonicNS = capture.monotonicNS
    }

    private func cpuBreakdown(current: MPCPUTicks, previous: MPCPUTicks?) -> (user: Double, system: Double, idle: Double) {
        guard let previous else { return (0, 0, 100) }
        let user = tickDelta(current.user, previous.user)
        let system = tickDelta(current.system, previous.system)
        let idle = tickDelta(current.idle, previous.idle)
        let nice = tickDelta(current.nice, previous.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return (0, 0, 100) }
        return (
            Double(user + nice) / Double(total) * 100,
            Double(system) / Double(total) * 100,
            Double(idle) / Double(total) * 100
        )
    }

    private func tickDelta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    private func readProcessMetadata() throws -> [(pid: Int32, parentPID: Int32, user: String, name: String, command: String, fallbackCPUPercent: Double, fallbackMemoryBytes: UInt64)] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "user=,pid=,ppid=,%cpu=,rss=,command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SamplingError.processListFailed
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SamplingError.invalidProcessOutput
        }

        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 5, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard parts.count == 6,
                  let pid = Int32(parts[1]),
                  let parentPID = Int32(parts[2]),
                  let fallbackCPU = Double(parts[3]),
                  let fallbackRSS = UInt64(parts[4]) else { return nil }
            let command = String(parts[5])
            let executable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
            return (
                pid: pid,
                parentPID: parentPID,
                user: String(parts[0]),
                name: URL(fileURLWithPath: executable).lastPathComponent,
                command: command,
                fallbackCPUPercent: fallbackCPU,
                fallbackMemoryBytes: fallbackRSS * 1_024
            )
        }
    }

    private func group(processes: [ProcessSnapshot]) -> [ProcessGroup] {
        let grouped = Dictionary(grouping: processes) {
            ProcessClassifier.displayName(command: $0.command, fallback: $0.name)
        }
        return grouped.map { name, members in
            let classification = members
                .map(classifier.classify)
                .max(by: { $0.level < $1.level })
                ?? .init(level: .review, label: "需要确认", reason: "无法自动判断")
            return ProcessGroup(name: name, processes: members, classification: classification)
        }
        .sorted {
            if $0.cpuPercent == $1.cpuPercent { return $0.memoryBytes > $1.memoryBytes }
            return $0.cpuPercent > $1.cpuPercent
        }
    }

    /// 与活动监视器「已使用内存」一致：物理内存减去空闲页与可回收的文件缓存（已缓存文件 + 可清除）。
    /// 内核、显卡等不出现在 vm_statistics 任何分类里的内存也计入已使用；
    /// 旧算法（活跃+非活跃+联动+压缩−缓存）会漏掉这部分，实测比活动监视器少约 0.6–0.7 GB。
    /// 已使用量与构成取自同一次 vm_statistics 读取，保证两者对得上。
    private func memoryStatistics(total: UInt64) throws -> (used: UInt64, breakdown: MemoryBreakdown) {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw SamplingError.memoryStatisticsFailed }
        let pageSize = UInt64(getpagesize())
        let usedPages = Self.usedMemoryPages(
            totalPages: total / pageSize,
            free: UInt64(statistics.free_count),
            purgeable: UInt64(statistics.purgeable_count),
            external: UInt64(statistics.external_page_count)
        )
        let breakdown = MemoryBreakdown.fromPages(
            pageSize: pageSize,
            anonymous: UInt64(statistics.internal_page_count),
            purgeable: UInt64(statistics.purgeable_count),
            wired: UInt64(statistics.wire_count),
            compressor: UInt64(statistics.compressor_page_count),
            external: UInt64(statistics.external_page_count),
            free: UInt64(statistics.free_count),
            speculative: UInt64(statistics.speculative_count)
        )
        return (min(usedPages * pageSize, total), breakdown)
    }

    /// 读取失败返回 nil。
    static func memoryPressure() -> MemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return MemoryPressure(kernelLevel: level)
    }

    static func usedMemoryPages(totalPages: UInt64, free: UInt64, purgeable: UInt64, external: UInt64) -> UInt64 {
        let available = free + purgeable + external
        return totalPages > available ? totalPages - available : 0
    }

    /// 交换空间用量。返回 nil 表示读取失败，界面不显示交换信息（而不是显示 0）。
    static func swapUsage() -> (used: UInt64, total: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (usage.xsu_used, usage.xsu_total)
    }
}

public enum SamplingError: Error, LocalizedError {
    case processListFailed
    case invalidProcessOutput
    case cpuStatisticsFailed
    case memoryStatisticsFailed

    public var errorDescription: String? {
        switch self {
        case .processListFailed: "无法读取进程列表"
        case .invalidProcessOutput: "进程数据格式无效"
        case .cpuStatisticsFailed: "无法读取 CPU 统计"
        case .memoryStatisticsFailed: "无法读取内存统计"
        }
    }
}
