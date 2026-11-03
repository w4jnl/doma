// How the apps move: three durations from the tokens and one rule for Reduce Motion. Reduced,
// nothing is displaced or scaled; what remains is a quick crossfade, and every haptic stays.
import SwiftUI

enum Motion {
    /// The animation to use: the full one, or the quick crossfade under Reduce Motion.
    static func of(_ reduce: Bool, _ full: Animation) -> Animation {
        reduce ? .easeOut(duration: Tokens.motionQuick) : full
    }

    /// Quick: a hover, a chip, a label changing.
    static let quick: Animation = .snappy(duration: Tokens.motionQuick, extraBounce: 0)
    /// Base: a row arriving or leaving, a count rolling, a badge.
    static let base: Animation = .snappy(duration: Tokens.motionBase, extraBounce: 0)
    /// Settle: rows closing a gap.
    static let settle: Animation = .smooth(duration: Tokens.motionSettle)

    /// A view arriving from an edge, or fading in when motion is reduced.
    static func arrive(_ reduce: Bool, from edge: Edge) -> AnyTransition {
        reduce ? .opacity : .asymmetric(insertion: .move(edge: edge).combined(with: .opacity), removal: .opacity)
    }
}
