import Foundation

public struct ProcessClassifier: Sendable {
    private let currentPID: Int32
    private let currentUser: String

    private static let protectedNames: Set<String> = [
        "MacPulse", "WindowServer", "kernel_task", "launchd", "loginwindow",
        "runningboardd", "fseventsd", "mds", "mdworker", "Dock", "Finder",
        "SystemUIServer", "coreaudiod", "airportd", "bluetoothd", "opendirectoryd"
    ]

    // 开发服务不放在这里：「智能优化」不检查活跃连接，开发服务只能走端口页的连接/闲置规则。
    private static let recommendedTokens = [
        "wpscloudsvr"
    ]

    private static let remoteAccessTokens = [
        "awesun", "sunlogin", "screensharing", "ssh"
    ]

    private static let developmentServerTokens = [
        "gunicorn", "uvicorn", "flask run", "django", "manage.py runserver",
        "vite", "webpack-dev-server", "forkeddev.js", " max dev", "npm run dev",
        "pnpm dev", "yarn dev", "next dev", "nuxt dev", "esbuild --service"
    ]

    private static let infrastructureTokens = [
        "postgres", "mysqld", "mariadbd", "redis-server", "mongod",
        "docker", "com.docker", "podman", "colima", "orbstack",
        "clash", "surge", "v2ray", "xray", "tailscale", "wireguard",
        "ssh -", "sshd", "nginx", "caddy", "traefik"
    ]

    public init(currentPID: Int32, currentUser: String) {
        self.currentPID = currentPID
        self.currentUser = currentUser
    }

    public func classify(_ process: ProcessSnapshot) -> ProcessClassification {
        let lowerName = process.name.lowercased()
        let lowerCommand = process.command.lowercased()

        if process.pid <= 1 || process.pid == currentPID {
            return .init(level: .protected, label: "系统保护", reason: "不能结束系统入口或 MacPulse 自身")
        }

        if Self.protectedNames.contains(process.name)
            || lowerCommand.hasPrefix("/system/")
            || lowerCommand.hasPrefix("/usr/libexec/")
            || lowerCommand.hasPrefix("/usr/sbin/")
            || lowerCommand.hasPrefix("/sbin/") {
            return .init(level: .protected, label: "系统保护", reason: "macOS 关键服务")
        }

        if process.user != currentUser {
            return .init(level: .protected, label: "权限保护", reason: "属于其他用户或系统账户")
        }

        if Self.remoteAccessTokens.contains(where: { lowerName.contains($0) || lowerCommand.contains($0) }) {
            return .init(level: .review, label: "远程访问", reason: "结束后可能中断远程连接")
        }

        if Self.recommendedTokens.contains(where: { lowerName.contains($0) || lowerCommand.contains($0) }) {
            return .init(level: .recommended, label: "可选后台", reason: "常见云服务或开发残留")
        }

        if lowerCommand.contains(".app/") {
            return .init(level: .review, label: "正在运行", reason: "退出前请确认内容已保存")
        }

        return .init(level: .review, label: "需要确认", reason: "无法自动判断是否仍被使用")
    }

    public func canTerminate(_ process: ProcessSnapshot) -> Bool {
        process.user == currentUser && classify(process).level != .protected
    }

    /// 数据库、Docker、代理等基础设施：即使由开发服务拉起，也不能随开发服务一起结束。
    public func isInfrastructure(_ process: ProcessSnapshot) -> Bool {
        let value = "\(process.name) \(process.command)".lowercased()
        return Self.infrastructureTokens.contains(where: value.contains)
    }

    /// 监听端口的可能只是 worker（如 gunicorn），只结束 worker 会被 master 立即重启、端口并未关闭。
    /// 沿父进程链向上，找到同一套开发服务的最上层进程，关闭端口时结束它的整棵子树。
    public func serviceRootPID(for pid: Int32, in processByPID: [Int32: ProcessSnapshot]) -> Int32 {
        var rootPID = pid
        var visited: Set<Int32> = [pid]
        while let current = processByPID[rootPID],
              let parent = processByPID[current.parentPID],
              parent.pid > 1,
              visited.insert(parent.pid).inserted,
              isAutoClosableDevelopmentServer(parent) {
            rootPID = parent.pid
        }
        return rootPID
    }

    public func isAutoClosableDevelopmentServer(_ process: ProcessSnapshot) -> Bool {
        guard canTerminate(process) else { return false }
        let value = "\(process.name) \(process.command)".lowercased()
        guard !Self.infrastructureTokens.contains(where: value.contains) else { return false }
        return Self.developmentServerTokens.contains(where: value.contains)
    }

    public static func displayName(command: String, fallback: String) -> String {
        let lowerCommand = command.lowercased()

        if lowerCommand.contains("wpscloudsvr") {
            return "WPS 云服务"
        }

        if lowerCommand.contains("/ssh ") && (lowerCommand.contains(" -nr ") || lowerCommand.contains(" -r ")) {
            return "SSH 反向隧道"
        }

        if lowerCommand.contains("gunicorn") {
            return "Gunicorn · \(projectComponent(in: command) ?? "后端服务")"
        }

        if lowerCommand.contains("esbuild")
            || lowerCommand.contains("forkeddev.js")
            || lowerCommand.contains(" max dev")
            || lowerCommand.hasSuffix("/umi") {
            return "前端开发 · \(projectComponent(in: command) ?? "开发服务")"
        }

        if lowerCommand.contains("run.py") {
            return "Python · \(projectComponent(in: command) ?? "开发服务")"
        }

        if let range = command.range(of: ".app/") {
            let appPath = String(command[..<range.lowerBound])
            if let component = appPath.split(separator: "/").last {
                return String(component)
            }
        }

        let cleaned = URL(fileURLWithPath: fallback).lastPathComponent
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func projectComponent(in command: String) -> String? {
        let paths = command.split(separator: " ").filter { $0.contains("/") }
        for path in paths.reversed() {
            let components = path.split(separator: "/")
            if let marker = components.firstIndex(where: {
                $0 == "node_modules" || $0 == ".venv" || $0 == "run.py"
            }), marker > components.startIndex {
                return String(components[components.index(before: marker)])
            }
        }
        return nil
    }
}
