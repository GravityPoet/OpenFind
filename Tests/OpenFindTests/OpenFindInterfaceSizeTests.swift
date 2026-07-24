import Testing
@testable import OpenFind

@Suite("Interface Size and Responsive Density Tests")
struct OpenFindInterfaceSizeTests {
    @Test func malformedPersistenceFallsBackToStandard() {
        #expect(OpenFindInterfaceSize.resolve("future-value") == .standard)
        #expect(OpenFindInterfaceSize.resolve("compact") == .compact)
        #expect(OpenFindInterfaceSize.resolve("large") == .large)
    }

    @Test func allSharedMetricsGrowMonotonically() {
        #expect(OpenFindInterfaceSize.compact.scale < OpenFindInterfaceSize.standard.scale)
        #expect(OpenFindInterfaceSize.standard.scale < OpenFindInterfaceSize.large.scale)
        #expect(
            OpenFindInterfaceSize.compact.filterControlHeight
                < OpenFindInterfaceSize.standard.filterControlHeight
        )
        #expect(
            OpenFindInterfaceSize.standard.statusBarHeight
                < OpenFindInterfaceSize.large.statusBarHeight
        )
    }

    @Test func minimumMainWindowUsesCompactToolbars() {
        let minimumWindowContentWidth = 800.0
        let innerWidth = minimumWindowContentWidth
            - (OpenFindInterfaceSize.standard.outerHorizontalPadding * 2)

        #expect(
            FilterBarLayoutMode.resolve(
                availableWidth: innerWidth,
                interfaceSize: .standard
            ) == .compact
        )
        #expect(
            StatusBarLayoutMode.resolve(
                availableWidth: minimumWindowContentWidth,
                interfaceSize: .standard
            ) == .compact
        )
    }

    @Test func roomyWindowRestoresFullLabels() {
        #expect(
            FilterBarLayoutMode.resolve(
                availableWidth: 1_000,
                interfaceSize: .standard
            ) == .regular
        )
        #expect(
            StatusBarLayoutMode.resolve(
                availableWidth: 1_100,
                interfaceSize: .standard
            ) == .regular
        )
    }

    @Test func largeInterfaceNeedsMoreRoomBeforeExpandingLabels() {
        #expect(
            FilterBarLayoutMode.resolve(
                availableWidth: 850,
                interfaceSize: .standard
            ) == .regular
        )
        #expect(
            FilterBarLayoutMode.resolve(
                availableWidth: 850,
                interfaceSize: .large
            ) == .compact
        )
    }
}
