import Foundation

struct ClipboardShortcutCycleState {
    enum Phase: Equatable {
        case idle
        case opening
        case cycling
    }

    enum Action: Equatable {
        case none
        case show
        case close
        case moveNext
        case pasteSelected
    }

    private(set) var phase = Phase.idle

    mutating func press(panelIsVisible: Bool) -> Action {
        guard panelIsVisible else {
            phase = .opening
            return .show
        }
        switch phase {
        case .idle:
            return .close
        case .opening, .cycling:
            phase = .cycling
            return .moveNext
        }
    }

    mutating func modifiersReleased() -> Action {
        defer { phase = .idle }
        return phase == .cycling ? .pasteSelected : .none
    }

    mutating func reset() {
        phase = .idle
    }
}
