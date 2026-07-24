import SwiftUI

enum OpenFindInterfaceSize: String, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case large

    static let persistenceKey = "OpenFind.interfaceSizeV1"

    var id: Self { self }

    static func resolve(_ persistedValue: String) -> Self {
        Self(rawValue: persistedValue) ?? .standard
    }

    var localizedName: String {
        switch self {
        case .compact: L("Interface Size Compact")
        case .standard: L("Interface Size Standard")
        case .large: L("Interface Size Large")
        }
    }

    var systemImage: String {
        switch self {
        case .compact: "textformat.size.smaller"
        case .standard: "textformat.size"
        case .large: "textformat.size.larger"
        }
    }

    var scale: CGFloat {
        switch self {
        case .compact: 0.88
        case .standard: 1
        case .large: 1.12
        }
    }

    var controlSize: ControlSize {
        switch self {
        case .compact: .small
        case .standard: .regular
        case .large: .large
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .compact: .medium
        case .standard: .large
        case .large: .xLarge
        }
    }

    var outerHorizontalPadding: CGFloat { 16 * scale }
    var compactSpacing: CGFloat { 8 * scale }
    var regularSpacing: CGFloat { 16 * scale }
    var filterControlHeight: CGFloat { 30 * scale }
    var statusBarHeight: CGFloat { 42 * scale }
}

private struct OpenFindInterfaceSizeKey: EnvironmentKey {
    static let defaultValue = OpenFindInterfaceSize.standard
}

extension EnvironmentValues {
    var openFindInterfaceSize: OpenFindInterfaceSize {
        get { self[OpenFindInterfaceSizeKey.self] }
        set { self[OpenFindInterfaceSizeKey.self] = newValue }
    }
}

private struct OpenFindInterfaceSizingModifier: ViewModifier {
    @AppStorage(OpenFindInterfaceSize.persistenceKey)
    private var persistedValue = OpenFindInterfaceSize.standard.rawValue

    func body(content: Content) -> some View {
        let size = OpenFindInterfaceSize.resolve(persistedValue)
        content
            .environment(\.openFindInterfaceSize, size)
            .controlSize(size.controlSize)
            .dynamicTypeSize(size.dynamicTypeSize)
    }
}

extension View {
    func openFindInterfaceSizing() -> some View {
        modifier(OpenFindInterfaceSizingModifier())
    }

    func openFindInterfaceSizing(_ size: OpenFindInterfaceSize) -> some View {
        environment(\.openFindInterfaceSize, size)
            .controlSize(size.controlSize)
            .dynamicTypeSize(size.dynamicTypeSize)
    }
}
