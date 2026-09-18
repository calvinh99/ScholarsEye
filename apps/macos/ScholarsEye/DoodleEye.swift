import SwiftUI

/// The native companion to the crayon app icon. It has no image decoding or
/// repeating rendering timer: a sleeping task wakes only for a short blink.
/// Pass `blinking: false` during capture so the mark is completely static.
struct DoodleEye: View {
    var blinking: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var openness: CGFloat = 1

    private var shouldBlink: Bool { blinking && !reduceMotion }
    private var charcoal: Color { colorScheme == .dark ? Color(white: 0.91) : Color(red: 0.13, green: 0.13, blue: 0.12) }

    var body: some View {
        DoodleEyeDrawing(openness: openness, ink: charcoal)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityLabel("ScholarsEye")
            .task(id: shouldBlink) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { openness = 1 }
                guard shouldBlink else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(6.2)) } catch { return }
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeIn(duration: 0.085)) { openness = 0.04 }
                    do { try await Task.sleep(for: .milliseconds(115)) } catch { return }
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.14)) { openness = 1 }
                }
            }
    }
}

private struct DoodleEyeDrawing: View, Animatable {
    var openness: CGFloat
    var ink: Color
    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let edge = min(size.width, size.height)
            let origin = CGPoint(x: (size.width - edge) / 2, y: (size.height - edge) / 2)
            let aperture = max(0.04, min(1, openness))
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                let closedCurve = 0.60 - 0.32 * (x - 0.5) * (x - 0.5)
                return CGPoint(x: origin.x + edge * x, y: origin.y + edge * (closedCurve + (y - closedCurve) * aperture))
            }
            var outline = Path()
            outline.move(to: point(0.12, 0.57))
            outline.addCurve(to: point(0.29, 0.34), control1: point(0.105, 0.48), control2: point(0.205, 0.375))
            outline.addCurve(to: point(0.55, 0.29), control1: point(0.375, 0.295), control2: point(0.46, 0.278))
            outline.addCurve(to: point(0.80, 0.41), control1: point(0.66, 0.285), control2: point(0.77, 0.355))
            outline.addCurve(to: point(0.88, 0.59), control1: point(0.84, 0.46), control2: point(0.895, 0.52))
            outline.addCurve(to: point(0.73, 0.73), control1: point(0.88, 0.655), control2: point(0.815, 0.707))
            outline.addCurve(to: point(0.40, 0.77), control1: point(0.63, 0.775), control2: point(0.525, 0.785))
            outline.addCurve(to: point(0.12, 0.57), control1: point(0.24, 0.755), control2: point(0.13, 0.70))

            var upperLashes = Path()
            var lowerLashes = Path()
            let strokes: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (0.24, 0.38, 0.19, 0.28), (0.365, 0.315, 0.33, 0.17),
                (0.505, 0.29, 0.51, 0.13), (0.665, 0.32, 0.72, 0.205),
                (0.795, 0.405, 0.875, 0.315), (0.305, 0.745, 0.26, 0.83),
                (0.51, 0.778, 0.515, 0.87), (0.735, 0.73, 0.795, 0.805)
            ]
            for (index, stroke) in strokes.enumerated() {
                let (x1, y1, x2, y2) = stroke
                let start = point(x1, y1)
                if index < 5 {
                    upperLashes.move(to: start)
                    upperLashes.addQuadCurve(to: point(x2, y2), control: point((x1 + x2) / 2 + 0.005, (y1 + y2) / 2 - 0.006))
                } else {
                    var end = point(x2, y2)
                    end.y += edge * (y2 - y1) * (1 - aperture) * 0.8
                    lowerLashes.move(to: start)
                    lowerLashes.addLine(to: end)
                }
            }

            // Offset pencil passes preserve the uneven handmade line without a
            // texture bitmap or continuous noise animation.
            for pass in 0..<4 {
                var pencil = context
                let dx: [CGFloat] = [-0.005, 0.004, 0.001, -0.002]
                let dy: [CGFloat] = [0.002, -0.004, 0.005, -0.001]
                pencil.translateBy(x: edge * dx[pass], y: edge * dy[pass])
                let stroke = StrokeStyle(lineWidth: edge * (pass == 0 ? 0.047 : 0.034), lineCap: .round, lineJoin: .round)
                pencil.stroke(outline, with: .color(ink.opacity(pass == 0 ? 0.70 : 0.40)), style: stroke)
                pencil.stroke(upperLashes, with: .color(ink.opacity((pass == 0 ? 0.78 : 0.43) * Double(aperture))), style: stroke)
                pencil.stroke(lowerLashes, with: .color(ink.opacity(pass == 0 ? 0.78 : 0.43)), style: stroke)
            }

            let center = point(0.492, 0.534)
            var pupil = Path()
            let pupilPoints = 27
            for index in 0..<pupilPoints {
                let angle = Double(index) / Double(pupilPoints) * .pi * 2
                let wobble = 1 + 0.045 * sin(Double(index) * 2.3) + 0.025 * cos(Double(index) * 4.1)
                let p = CGPoint(x: center.x + edge * 0.112 * wobble * cos(angle),
                                y: center.y + edge * 0.118 * wobble * sin(angle) * aperture)
                if index == 0 { pupil.move(to: p) } else { pupil.addLine(to: p) }
            }
            pupil.closeSubpath()
            context.fill(pupil, with: .color(ink.opacity(min(1, Double(aperture * 3)))))

            // Small deterministic grain flecks make the edge less geometric at
            // hero size. A fixed pattern avoids both flicker and random work.
            var grain = Path()
            for index in 0..<58 {
                let angle = Double(index) * 2.399963229728653
                let radius = 0.104 + 0.013 * sin(Double(index) * 1.77)
                let x = center.x + edge * radius * cos(angle)
                let y = center.y + edge * radius * sin(angle) * aperture
                grain.addEllipse(in: CGRect(x: x, y: y, width: edge * 0.008, height: edge * 0.007))
            }
            context.fill(grain, with: .color(ink.opacity(Double(aperture) * 0.42)))
        }
    }
}
