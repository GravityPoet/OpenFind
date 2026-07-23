import AppKit
import SwiftUI

enum ClipboardTypography {
    static let search = Font.system(size: 16, weight: .medium, design: .default)
    static let row = Font.system(size: rowPointSize, weight: .medium, design: .default)
    static let shortcut = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let preview = Font.system(size: 15.5, weight: .medium, design: .default)

    static let rowPointSize: CGFloat = 15.5
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
}
