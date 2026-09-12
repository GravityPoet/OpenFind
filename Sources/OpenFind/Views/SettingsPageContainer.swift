import AppKit
import SwiftUI

/// AppKit's public no-tab mode retains each SwiftUI page's identity and local
/// state without creating a second native navigation bar.
struct SettingsPageContainer: NSViewControllerRepresentable {
    let selection: SettingsPane
    let content: (SettingsPane) -> AnyView

    func makeNSViewController(context: Context) -> Controller {
        Controller(selection: selection, content: content)
    }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.update(selection: selection, content: content)
    }

    final class Controller: NSTabViewController {
        private var hosts: [SettingsPane: NSHostingController<AnyView>] = [:]

        init(selection: SettingsPane, content: (SettingsPane) -> AnyView) {
            super.init(nibName: nil, bundle: nil)
            tabStyle = .unspecified
            tabView.tabViewType = .noTabsNoBorder
            transitionOptions = []
            canPropagateSelectedChildViewControllerTitle = false
            for pane in SettingsPane.navigationOrder {
                let host = NSHostingController(rootView: content(pane))
                host.sizingOptions = []
                let item = NSTabViewItem(viewController: host)
                item.identifier = pane.rawValue
                item.label = pane.label
                addTabViewItem(item)
                hosts[pane] = host
            }
            selectedTabViewItemIndex = SettingsPane.navigationOrder.firstIndex(of: selection) ?? 0
        }

        required init?(coder: NSCoder) { nil }

        func update(selection: SettingsPane, content: (SettingsPane) -> AnyView) {
            for pane in SettingsPane.navigationOrder {
                hosts[pane]?.rootView = content(pane)
            }
            let index = SettingsPane.navigationOrder.firstIndex(of: selection) ?? 0
            if selectedTabViewItemIndex != index { selectedTabViewItemIndex = index }
        }
    }
}
