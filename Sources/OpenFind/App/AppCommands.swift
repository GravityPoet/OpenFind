import SwiftUI

struct AppCommands: Commands {
    let viewModel: SearchViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu(L("Search")) {
            Button(viewModel.isSearching ? L("Cancel Search") : L("Start Search")) {
                if viewModel.isSearching {
                    viewModel.cancel()
                } else {
                    viewModel.startSearch()
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!viewModel.canSearch && !viewModel.isSearching)

            Divider()

            Button(L("Add Folder...")) {
                let urls = FileActions.chooseDirectories()
                for url in urls {
                    viewModel.addScope(url)
                }
            }
            .keyboardShortcut("o", modifiers: .command)
        }
    }
}
