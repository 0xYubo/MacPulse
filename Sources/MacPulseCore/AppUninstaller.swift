import Foundation

public struct InstalledApp: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let bundleID: String?
    public let version: String?
    public let sizeBytes: UInt64
    /// 读取信息时遇到的问题（例如 Info.plist 无法解析），需要展示给用户。
    public let warning: String?

    public var id: String { url.path }

    public init(url: URL, name: String, bundleID: String?, version: String?, sizeBytes: UInt64, warning: String? = nil) {
        self.url = url
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.sizeBytes = sizeBytes
        self.warning = warning
    }
}

public struct AppListResult: Sendable {
    public let apps: [InstalledApp]
    /// 应用目录无法读取等问题；不能把「读不到」显示成「没有应用」。
    public let warnings: [String]
}

public struct AppLeftover: Identifiable, Hashable, Sendable {
    public enum Match: Sendable {
        /// 按 bundle id 精确匹配。
        case bundleID
        /// 按 App 名称匹配，可能与其他软件同名。
        case appName
    }

    public let url: URL
    public let location: String
    public let sizeBytes: UInt64
    public let match: Match
    public let selectedByDefault: Bool
    /// 默认不勾选的原因，界面上需要展示。
    public let caution: String?

    public var id: String { url.path }
}

public struct LeftoverScanResult: Sendable {
    public let leftovers: [AppLeftover]
    public let warnings: [String]
}

public struct AppUninstaller: Sendable {
    private let home: URL
    private let applicationRoots: [URL]
    private let excludedBundleIDs: Set<String>

    public static func defaultApplicationRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationRoots: [URL]? = nil,
        excludedBundleIDs: Set<String> = []
    ) {
        home = homeDirectory.standardizedFileURL
        self.applicationRoots = applicationRoots ?? Self.defaultApplicationRoots(home: homeDirectory)
        self.excludedBundleIDs = Set(excludedBundleIDs.map { $0.lowercased() })
    }

    /// 删除守卫：允许的根包含主目录与应用目录，根目录本身受保护。
    public var safeTrash: SafeTrash {
        SafeTrash(homeDirectory: home, extraRoots: applicationRoots)
    }

    /// bundle id 来自 App 自带的 Info.plist，不可信：含「/」或「..」时拼出的路径会指向任意目录。
    static func isValidBundleID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255, !value.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return value.unicodeScalars.allSatisfy(allowed.contains)
            && value.first.map { $0.isLetter || $0.isNumber } == true
    }

    /// 只列出应用目录一级的 .app；系统自带应用（com.apple.*）与排除列表中的应用不出现。
    public func listApplications() -> AppListResult {
        var warnings: [String] = []
        let apps = applicationRoots.flatMap { root -> [InstalledApp] in
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return []
            } catch {
                warnings.append("无法读取 \(root.path)：\(error.localizedDescription)")
                return []
            }
            return children.compactMap { url -> InstalledApp? in
                guard url.pathExtension == "app" else { return nil }
                switch PathSafety.state(of: url) {
                case .present: break
                case .symbolicLink, .missing: return nil
                case .unreadable(let message):
                    warnings.append("无法读取 \(url.lastPathComponent)：\(message)")
                    return nil
                }
                let fileName = url.deletingPathExtension().lastPathComponent
                let info = Self.infoDictionary(of: url)
                var warning = info.error
                var bundleID = info.values["CFBundleIdentifier"] as? String
                if let id = bundleID {
                    let lower = id.lowercased()
                    guard !lower.hasPrefix("com.apple."), !excludedBundleIDs.contains(lower) else { return nil }
                    if !Self.isValidBundleID(id) {
                        warning = "Bundle ID 格式异常，只按应用名称查找残留"
                        bundleID = nil
                    }
                }
                let size = PathSafety.allocatedSize(of: url)
                if warning == nil, size.unreadableCount > 0 {
                    warning = "\(size.unreadableCount) 个文件无法读取，大小可能偏小"
                }
                return InstalledApp(
                    url: url,
                    name: (info.values["CFBundleDisplayName"] as? String) ?? fileName,
                    bundleID: bundleID,
                    version: info.values["CFBundleShortVersionString"] as? String,
                    sizeBytes: size.bytes,
                    warning: warning
                )
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return AppListResult(apps: apps, warnings: warnings)
    }

    /// 残留文件只做精确的名称匹配，不做模糊/包含匹配，避免把其他软件的数据当作残留。
    /// - Parameter installedApps: 当前已安装的应用；同一 bundle id 还有其他安装时，残留可能是共用数据，全部默认不勾选。
    public func leftovers(for app: InstalledApp, installedApps: [InstalledApp] = []) -> LeftoverScanResult {
        let library = home.appendingPathComponent("Library")
        var warnings: [String] = []
        var candidates: [(URL, AppLeftover.Match, String?)] = []

        if let bundleID = app.bundleID, Self.isValidBundleID(bundleID) {
            let exactPaths: [(String, String?)] = [
                ("Application Support/\(bundleID)", nil),
                ("Caches/\(bundleID)", nil),
                ("Preferences/\(bundleID).plist", nil),
                ("Saved Application State/\(bundleID).savedState", nil),
                ("Containers/\(bundleID)", "沙盒容器，可能包含文档等用户数据"),
                ("HTTPStorages/\(bundleID)", nil),
                ("HTTPStorages/\(bundleID).binarycookies", nil),
                ("WebKit/\(bundleID)", nil),
                ("Cookies/\(bundleID).binarycookies", nil),
            ]
            candidates += exactPaths.map { (library.appendingPathComponent($0.0), .bundleID, $0.1) }
            candidates += matchingChildren(of: library.appendingPathComponent("Group Containers"), warnings: &warnings) {
                $0 == bundleID || $0.hasSuffix(".\(bundleID)")
            }.map { ($0, .bundleID, "共享容器，可能被同一开发者的其他应用使用") }
            candidates += matchingChildren(of: library.appendingPathComponent("LaunchAgents"), warnings: &warnings) {
                $0 == "\(bundleID).plist" || ($0.hasPrefix("\(bundleID).") && $0.hasSuffix(".plist"))
            }.map { ($0, .bundleID, nil) }
        }

        let appName = app.url.deletingPathExtension().lastPathComponent
        // 过短的名称（如「Go」）容易与其他软件重名，不参与名称匹配。
        if appName.count >= 3, !appName.contains("/"), !appName.hasPrefix(".") {
            candidates += [
                library.appendingPathComponent("Application Support/\(appName)"),
                library.appendingPathComponent("Logs/\(appName)"),
            ].map { ($0, .appName, "按名称匹配，可能属于其他同名软件") }
        }

        let sharedInstall = installedApps.contains {
            $0.id != app.id && $0.bundleID != nil && $0.bundleID?.lowercased() == app.bundleID?.lowercased()
        }

        var seen = Set<String>()
        let leftovers = candidates.compactMap { url, match, caution -> AppLeftover? in
            let standardized = url.standardizedFileURL
            // 候选必须正好是 ~/Library/<容器目录>/<条目>，防止任何拼接结果逃出预期位置。
            guard standardized.deletingLastPathComponent().deletingLastPathComponent().path == library.path else { return nil }
            switch PathSafety.state(of: standardized) {
            case .missing: return nil
            case .unreadable(let message):
                warnings.append("无法检查 \(standardized.lastPathComponent)：\(message)")
                return nil
            case .present, .symbolicLink: break
            }
            guard seen.insert(standardized.path).inserted else { return nil }
            let size = PathSafety.allocatedSize(of: standardized)
            if size.unreadableCount > 0 {
                warnings.append("\(standardized.lastPathComponent) 中有 \(size.unreadableCount) 个条目无法读取，大小可能偏小")
            }
            let effectiveCaution = sharedInstall ? "还有其他安装使用同一 Bundle ID，可能是共用数据" : caution
            return AppLeftover(
                url: standardized,
                location: String(standardized.deletingLastPathComponent().path.dropFirst(home.path.count + 1)),
                sizeBytes: size.bytes,
                match: match,
                selectedByDefault: effectiveCaution == nil,
                caution: effectiveCaution
            )
        }
        return LeftoverScanResult(leftovers: leftovers, warnings: warnings)
    }

    private func matchingChildren(of directory: URL, warnings: inout [String], where predicate: (String) -> Bool) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter(predicate)
                .map { directory.appendingPathComponent($0) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            warnings.append("无法读取 \(directory.lastPathComponent)（可能需要在系统设置中授权）：\(error.localizedDescription)")
            return []
        }
    }

    private static func infoDictionary(of appURL: URL) -> (values: [String: Any], error: String?) {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        do {
            let data = try Data(contentsOf: plist)
            guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                return ([:], "Info.plist 格式异常，只按应用名称查找残留")
            }
            return (dictionary, nil)
        } catch {
            return ([:], "无法读取 Info.plist，只按应用名称查找残留")
        }
    }
}
