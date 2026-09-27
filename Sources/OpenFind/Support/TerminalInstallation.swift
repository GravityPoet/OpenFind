import AppKit
import Foundation

/// Reading an app's metadata and scripting dictionary never launches it or
/// requests Automation permission. Execution is checked separately by a test.
struct TerminalInstallation: Identifiable, Sendable {
    let target: TerminalCommandTarget
    let url: URL?
    let version: String?
    let error: TerminalCommandError?
    var id: TerminalCommandTarget { target }

    init(target: TerminalCommandTarget, url: URL?) {
        self.target = target
        self.url = url
        guard let url, let bundle = Bundle(url: url),
              bundle.bundleIdentifier == target.bundleIdentifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            version = nil
            error = .terminalUnavailable
            return
        }
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let versionError = Self.compatibilityError(target: target, version: version) {
            error = versionError
            return
        }
        guard let name = bundle.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String,
              let dictionaryURL = bundle.resourceURL?.appendingPathComponent(name),
              let data = try? Data(contentsOf: dictionaryURL),
              let dictionary = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let nodes = try? dictionary.nodes(forXPath: "//command/@name") else {
            error = .scriptingUnavailable(LD(target.titleKey))
            return
        }
        let required: Set<String>
        switch target {
        case .terminal: required = ["do script"]
        case .ghostty: required = ["new tab", "new window", "input text", "send key"]
        case .iterm2: required = ["create tab with default profile", "create window with default profile", "write"]
        case .systemDefault: required = []
        }
        let commands = Set(nodes.compactMap(\.stringValue))
        error = required.isSubset(of: commands) ? nil : .scriptingUnavailable(LD(target.titleKey))
    }

    static func compatibilityError(
        target: TerminalCommandTarget, version: String?
    ) -> TerminalCommandError? {
        let minimum: String?
        switch target {
        case .terminal: minimum = nil
        case .ghostty: minimum = "1.3"
        case .iterm2: minimum = "3.0"
        case .systemDefault: return nil
        }
        let name = LD(target.titleKey)
        if let minimum {
            let components = (version ?? "").split(separator: ".")
            guard components.count >= 2, Int(components[0]) != nil, Int(components[1]) != nil,
                  (version ?? "").compare(minimum, options: .numeric) != .orderedAscending else {
                return .updateRequired(name, minimum)
            }
        }
        return nil
    }

    @MainActor
    static func detected() -> [Self] {
        TerminalCommandTarget.directTargets.map { target in
            Self(target: target, url: target.bundleIdentifier.flatMap {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            })
        }
    }
}
