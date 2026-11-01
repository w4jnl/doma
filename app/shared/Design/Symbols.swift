// The custom SF Symbols: the shapes that are the brand's (the four flags, open and done, the
// home, the jar, the guest), exported by assets/icons/gen.py from the 16-grid pictograms into
// Symbols.xcassets as doma.<name>. Everything else is a system symbol (docs/design-system,
// Pictograms). Never a symbol without a word next to it or in its label.
import SwiftUI

enum Symbol: String, CaseIterable {
    case have, low, out, unknown, open, done, home, item, guest

    /// The asset catalogue's name.
    var name: String { "doma." + rawValue }

    var image: Image { Image(name) }
}
