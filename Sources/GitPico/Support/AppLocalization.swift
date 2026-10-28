import Foundation
import GitCore
import SwiftUI

/// App-owned errors must resolve in the app catalog before crossing the GitCore error boundary.
func appFailure(_ message: String.LocalizationValue) -> GitFailure {
    GitFailure(verbatim: String(localized: message, bundle: #bundle))
}

enum AppLocalization {
    static var layoutDirection: LayoutDirection {
        layoutDirection(for: Bundle.main.preferredLocalizations.first ?? "en")
    }

    static func layoutDirection(for language: String) -> LayoutDirection {
        Locale.Language(identifier: language).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }
}

func splitColumnWidth(start: CGFloat, translation: CGFloat, minimum: CGFloat, availableWidth: CGFloat, direction: LayoutDirection) -> CGFloat {
    let delta = direction == .rightToLeft ? -translation : translation
    return min(max(start + delta, minimum), max(minimum, availableWidth - 350))
}
