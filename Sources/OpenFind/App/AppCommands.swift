import AppKit
import SwiftUI

struct AppCommands: Commands {
    let viewModel: SearchViewModel
    let clipboardStore: ClipboardHistoryStore

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(L("Settings")) {
                FileActions.openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .appInfo) {
            Button(L("Check for Updates...")) {
                (NSApp.delegate as? AppDelegate)?.checkForUpdates(nil)
            }
            .disabled((NSApp.delegate as? AppDelegate)?.canCheckForUpdates != true)
        }

        CommandGroup(replacing: .newItem) {
            Button(L("Show OpenFind")) {
                (NSApp.delegate as? AppDelegate)?.showOpenFindWindow(nil)
            }
            .keyboardShortcut("n", modifiers: .command)
        }

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

            Divider()

            Menu(L("Search Examples")) {
                Button(L("Example PDF briefing")) {
                    applyExample("*.pdf briefing", target: .name)
                }

                Button(L("Example path scoped demo")) {
                    applyExample("in:/Users demo !.psd", target: .name)
                }

                Button(L("Example large zip")) {
                    applyExample("*.zip size:>100MB", target: .name)
                }

                Button(L("Example modified today")) {
                    applyExample("dm:today", target: .name)
                }

                Button(L("Example tag project")) {
                    applyExample("tag:ProjectA", target: .name)
                }

                Button(L("Example content budget")) {
                    applyExample("content:\"Q4 budget\"", target: .both)
                }
            }
        }

        CommandMenu(L("Clipboard")) {
            Button(L("Clipboard Actions")) {
                clipboardStore.isActionPanelPresented.toggle()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!clipboardStore.isPanelPresented)

            Button(L("Save for Reuse")) {
                guard let selected = clipboardStore.selectedEntry else { return }
                clipboardStore.saveForReuse(selected)
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!clipboardStore.isPanelPresented || clipboardStore.selectedEntry == nil)
        }
    }

    private func applyExample(_ query: String, target: SearchTarget) {
        viewModel.options.query = query
        viewModel.options.target = target
        viewModel.scheduleSearch(delay: .zero)
    }
}
