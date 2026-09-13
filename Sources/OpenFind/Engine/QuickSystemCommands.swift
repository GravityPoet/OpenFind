import AppKit
import Foundation
import IOKit.pwr_mgt

enum QuickSystemAction: String, Hashable, Sendable {
    case lockScreen
    case screenSaver
    case sleep
}

enum QuickSystemCommands {
    private struct Command {
        let title: String
        let aliases: [String]
        let action: QuickSystemAction
    }

    private static let commands = [
        Command(title: "Lock Screen", aliases: ["lock", "锁定屏幕"], action: .lockScreen),
        Command(title: "Start Screen Saver", aliases: ["screensaver", "screen saver", "屏幕保护"], action: .screenSaver),
        Command(title: "Sleep Mac", aliases: ["sleep", "睡眠"], action: .sleep)
    ]

    static func results(for query: String, limit: Int = 50) -> [QuickSearchItem] {
        let needle = ApplicationSearchName.normalize(query)
        return commands.filter { needle.isEmpty || ApplicationSearchName.normalize($0.title).contains(needle)
            || $0.aliases.map(ApplicationSearchName.normalize).contains { $0.contains(needle) } }
            .prefix(max(1, limit)).map {
                QuickSearchItem(url: URL(string: "openfind-system://" + $0.action.rawValue)!,
                                name: LD($0.title), location: LD("System Commands"), kind: .command,
                                action: .system($0.action))
            }
    }

    @MainActor
    static func run(
        _ action: QuickSystemAction,
        performer: any SessionActivityPerforming = SystemSessionActivityPerformer(),
        openScreenSaver: (URL) -> Bool = { NSWorkspace.shared.open($0) },
        sleepSystem: () -> Bool = {
            let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
            guard connection != 0 else { return false }
            defer { IOServiceClose(connection) }
            return IOPMSleepSystem(connection) == kIOReturnSuccess
        }
    ) throws {
        switch action {
        case .lockScreen:
            guard performer.isAccessibilityTrusted else { throw QuickSystemCommandError.accessibilityRequired }
            performer.lockScreen()
        case .screenSaver:
            guard openScreenSaver(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
            else { throw QuickSystemCommandError.failed }
        case .sleep:
            guard sleepSystem() else { throw QuickSystemCommandError.failed }
        }
    }
}

enum QuickSystemCommandError: Error {
    case accessibilityRequired, failed
}
