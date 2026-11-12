import Foundation

public struct ListeningSocket: Identifiable, Hashable, Sendable {
    public let pid: Int32
    public let processName: String
    public let address: String
    public let port: Int
    public let hasEstablishedConnection: Bool

    public var id: String { "\(pid):\(address):\(port)" }

    public init(pid: Int32, processName: String, address: String, port: Int, hasEstablishedConnection: Bool) {
        self.pid = pid
        self.processName = processName
        self.address = address
        self.port = port
        self.hasEstablishedConnection = hasEstablishedConnection
    }
}

public struct DevelopmentPortPolicy: Sendable {
    public let minimumIdleDuration: TimeInterval

    public init(minimumIdleDuration: TimeInterval = 30 * 60) {
        self.minimumIdleDuration = minimumIdleDuration
    }

    public func shouldAutoClose(
        isDevelopmentServer: Bool,
        hasEstablishedConnection: Bool,
        idleDuration: TimeInterval
    ) -> Bool {
        isDevelopmentServer
            && !hasEstablishedConnection
            && idleDuration >= minimumIdleDuration
    }
}

public enum PortScannerError: Error, LocalizedError {
    case lsofFailed

    public var errorDescription: String? { "无法读取监听端口" }
}

public struct PortScanner: Sendable {
    public init() {}

    public func scan() throws -> [ListeningSocket] {
        let activePIDs = try runLsof(arguments: ["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-Fp"])
            .split(separator: "\n")
            .compactMap { line -> Int32? in
                guard line.first == "p" else { return nil }
                return Int32(line.dropFirst())
            }
        let listeners = try runLsof(arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"])
        return Self.parseListeningSockets(listeners, activePIDs: Set(activePIDs))
    }

    public static func parseListeningSockets(_ text: String, activePIDs: Set<Int32>) -> [ListeningSocket] {
        var pid: Int32?
        var processName = ""
        var result: [ListeningSocket] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let prefix = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch prefix {
            case "p":
                pid = Int32(value)
                processName = ""
            case "c":
                processName = value
            case "n":
                guard let pid, let endpoint = parseEndpoint(value) else { continue }
                result.append(ListeningSocket(
                    pid: pid,
                    processName: processName,
                    address: endpoint.address,
                    port: endpoint.port,
                    hasEstablishedConnection: activePIDs.contains(pid)
                ))
            default:
                continue
            }
        }
        return result.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    public static func propagateActiveConnections(
        in sockets: [ListeningSocket],
        groupByPID: [Int32: String]
    ) -> [ListeningSocket] {
        let activeGroups = Set(sockets.compactMap { socket -> String? in
            guard socket.hasEstablishedConnection else { return nil }
            return groupByPID[socket.pid]
        })
        return sockets.map { socket in
            ListeningSocket(
                pid: socket.pid,
                processName: socket.processName,
                address: socket.address,
                port: socket.port,
                hasEstablishedConnection: socket.hasEstablishedConnection
                    || groupByPID[socket.pid].map(activeGroups.contains) == true
            )
        }
    }

    private static func parseEndpoint(_ value: String) -> (address: String, port: Int)? {
        guard let separator = value.lastIndex(of: ":"),
              let port = Int(value[value.index(after: separator)...]) else { return nil }
        return (String(value[..<separator]), port)
    }

    private func runLsof(arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw PortScannerError.lsofFailed
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
