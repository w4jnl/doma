// Mark is doma's mark, from the 24-unit geometry of assets/brand/gen.py: the frame's two
// brackets at 1.6, and the house, roof, walls and chimney in one line at 1.9, in the mark's
// colour. Thin frame, light house, nothing else.
import SwiftUI

struct Mark: View {
    var size: CGFloat = 22
    var color: Color = Tokens.mark

    var body: some View {
        Canvas { ctx, s in
            let k = s.width / 24
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
            var brackets = Path()
            for (outer, inner) in [(3.8, 8.0), (20.2, 16.0)] {
                let r = 2.2, dir: CGFloat = outer < 12 ? 1 : -1
                brackets.move(to: p(inner, 3.2))
                brackets.addLine(to: p(outer + dir * r, 3.2))
                brackets.addQuadCurve(to: p(outer, 3.2 + r), control: p(outer, 3.2))
                brackets.addLine(to: p(outer, 18.6))
                brackets.addQuadCurve(to: p(outer + dir * r, 20.8), control: p(outer, 20.8))
                brackets.addLine(to: p(inner, 20.8))
            }
            ctx.stroke(brackets, with: .color(color), style: StrokeStyle(lineWidth: 1.6 * k, lineCap: .round, lineJoin: .round))
            var house = Path()
            house.move(to: p(7.7, 11.8))
            house.addLine(to: p(12, 7.5))
            house.addLine(to: p(16.3, 11.8))
            house.addLine(to: p(16.3, 15.3))
            house.addQuadCurve(to: p(15.3, 16.3), control: p(16.3, 16.3))
            house.addLine(to: p(8.7, 16.3))
            house.addQuadCurve(to: p(7.7, 15.3), control: p(7.7, 16.3))
            house.closeSubpath()
            house.move(to: p(14.4, 9.9))
            house.addLine(to: p(14.4, 7.8))
            ctx.stroke(house, with: .color(color), style: StrokeStyle(lineWidth: 1.9 * k, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
