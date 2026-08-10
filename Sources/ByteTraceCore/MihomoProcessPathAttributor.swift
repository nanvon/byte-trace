import Foundation

public struct MihomoProcessPathAttributor: Sendable {
    public static let unknownAppKey = "mihomo:unknown-process"

    private let attributor: ProcessAttributor

    public init(attributor: ProcessAttributor = ProcessAttributor()) {
        self.attributor = attributor
    }

    public func attribute(processPath rawPath: String?) -> AttributedProcess {
        guard let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty,
              rawPath.hasPrefix("/") else {
            return Self.unknownProcess
        }

        let executablePath = URL(fileURLWithPath: rawPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard !executablePath.isEmpty else { return Self.unknownProcess }

        let bundle = outermostAppBundle(containing: executablePath)
        let fallbackName = URL(fileURLWithPath: executablePath).lastPathComponent
        return attributor.attribute(
            ProcessIdentity(
                pid: nil,
                nettopProcessName: fallbackName,
                executablePath: executablePath,
                bundleID: bundle?.bundleIdentifier,
                bundlePath: bundle?.bundleURL.path,
                displayName: bundleDisplayName(bundle) ?? fallbackName
            )
        )
    }

    private func outermostAppBundle(containing executablePath: String) -> Bundle? {
        let components = URL(fileURLWithPath: executablePath).pathComponents
        guard components.count > 1 else { return nil }

        var current = ""
        for component in components {
            if component == "/" {
                current = "/"
                continue
            }
            current = (current as NSString).appendingPathComponent(component)
            guard component.lowercased().hasSuffix(".app"),
                  executablePath.hasPrefix(current + "/Contents/"),
                  let bundle = Bundle(path: current) else {
                continue
            }
            return bundle
        }
        return nil
    }

    private func bundleDisplayName(_ bundle: Bundle?) -> String? {
        guard let bundle else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
    }

    private static let unknownProcess = AttributedProcess(
        appKey: unknownAppKey,
        displayName: "无法识别/其他",
        category: .unclassified,
        pid: nil,
        processStartTime: nil,
        nettopProcessName: "",
        executablePath: nil,
        bundleID: nil,
        bundlePath: nil
    )
}
