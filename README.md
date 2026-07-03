# OpenFind

OpenFind is a modern, high-performance macOS search tool designed as a clean-room reimplementation of the classic EasyFind concept. It provides instant, index-free file and content search on macOS.

## Key Features

1. **Instant Search:** Stream results in real-time as you type, without database indexing overhead.
2. **Accurate Results:** Search system folders, hidden items, package contents, and exact text matches.
3. **Advanced Modes:** Regular expression matching, wildcard expansion, whole word filters, and case-sensitive options.
4. **CLI Mode:** Command-line executable support for headless, scriptable searches.
5. **Privacy First:** Entirely local search operations with sandboxed access.

## Compilation and Build

Due to platform SDK lookup dynamics on macOS terminal environments, always build with the explicit SDK path modifier:

```bash
# Debug build
xcrun --sdk macosx swift build

# Run debug CLI
xcrun --sdk macosx swift run OpenFind --search "query"
```

## Packaging

To package the project into a native macOS app bundle (`OpenFind.app`), execute the packaging automation script:

```bash
bash Scripts/build_app.sh
```

This compiles a production build, generates the application icon from the bundled source asset, moves localization assets into the bundle structures, and performs ad-hoc signing. The resulting package is output to `dist/OpenFind.app`.

## Architecture & Layers

OpenFind is built using Swift 6 / SwiftUI and adheres to a unidirectional architecture:

```
Views -> State (ViewModel) -> Engine -> Models
```

- **Models:** Value types, query match options.
- **Engine:** Directory walking and content matching utilizing structured concurrency.
- **State:** Persistent settings and state management.
- **Views:** SwiftUI-based minimal and responsive visual components.
- **App:** Entry dispatcher handling both command-line arguments and GUI scenes.

## License

OpenFind is licensed under the GNU Affero General Public License v3.0. See [LICENSE](LICENSE).
