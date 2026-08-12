import AppKit
import SwiftUI

enum ClipboardTypography {
    static let search = Font.system(size: 15.5, weight: .regular, design: .default)
    static let row = Font.system(size: rowPointSize, weight: .medium, design: .default)
    static let selectedRow = Font.system(
        size: rowPointSize,
        weight: .semibold,
        design: .default
    )
    static let matchLabel = Font.system(size: 10.5, weight: .semibold, design: .default)
    static let matchContext = Font.system(
        size: matchContextPointSize,
        weight: .regular,
        design: .default
    )
    static let shortcut = Font.system(size: 11.5, weight: .semibold, design: .rounded)
    static let preview = Font.system(size: 15, weight: .regular, design: .default)

    static let rowPointSize: CGFloat = 15
    static let matchContextPointSize: CGFloat = 11.5
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let noteText = Color(nsColor: .systemRed)
}
