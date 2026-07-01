import SwiftUI

struct OpenFindApp: App {
    @State private var viewModel = SearchViewModel()

    var body: some Scene {
        WindowGroup("OpenFind") {
            ContentView(viewModel: viewModel)
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            AppCommands(viewModel: viewModel)
        }

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}
