// The Mac's menu bar talks to the screens through this: what is selected, and the commands a
// person issues from a menu (New List, Got It, Edit, Clear Got Items), counted so the screen in
// front can act on them. The phone has no menu bar and never makes one.
#if os(macOS)
import Observation

@MainActor @Observable
final class MacNav {
    /// Counters bumped by the menu; the screen in front reacts to the change.
    var newList = 0
    var toggleSelected = 0
    var editSelected = 0
    var clear = 0
    /// Bumped by a list's card glyph: the sidebar selects Cards.
    var showCards = 0
    /// Whether a list is in front with a selected row, for enabling the menu items.
    var hasSelectedEntry = false
    var hasStruck = false
    var listInFront = false
}
#endif
