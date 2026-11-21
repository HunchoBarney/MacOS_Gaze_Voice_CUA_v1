import SwiftUI

/// Live words: each word focuses in (blur to sharp, a 3 pt rise) as it
/// arrives. Long transcripts keep their newest words and fade the oldest
/// edge out instead of an ellipsis that flickers as words arrive (LI-4).
struct WordStream: View {
    var words: [(text: String, age: Double)]
    var size: CGFloat
    var weight: Font.Weight = .medium
    var color: Color
    var maxWidth: CGFloat
    var reduceMotion: Bool

    var body: some View {
        let spacing = size * 0.27
        let nsWeight: NSFont.Weight = weight == .semibold ? .semibold : .medium
        var kept: [(text: String, age: Double)] = []
        var used: CGFloat = 0
        for word in words.reversed() {
            let w = TextMetrics.width(word.text, size: size, weight: nsWeight) + spacing
            if used + w > maxWidth, !kept.isEmpty { break }
            kept.insert(word, at: 0)
            used += w
        }
        let clipped = kept.count < words.count
        return HStack(spacing: spacing) {
            ForEach(Array(kept.enumerated()), id: \.offset) { _, word in
                let p = reduceMotion ? min(1, word.age / 0.15) : min(1, word.age / 0.26)
                let e = 1 - pow(1 - p, 3)
                Text(word.text)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color)
                    .opacity(e)
                    .blur(radius: reduceMotion ? 0 : (1 - e) * 5)
                    .offset(y: reduceMotion ? 0 : (1 - e) * 3)
                    .fixedSize()
            }
        }
        .mask(
            LinearGradient(stops: [.init(color: .black.opacity(clipped ? 0 : 1), location: 0),
                                   .init(color: .black, location: clipped ? 0.12 : 0)],
                           startPoint: .leading, endPoint: .trailing)
        )
    }
}

/// A label with a light band sweeping across it, for work in progress.
/// Custom: a gradient mask over Text (no library covers it natively).
struct ShimmerText: View {
    var text: String
    var size: CGFloat
    var t: Double
    var base: Color
    var highlight: Color
    var reduceMotion: Bool

    var body: some View {
        let label = Text(text).font(.system(size: size, weight: .medium))
        if reduceMotion {
            label.foregroundStyle(base)
        } else {
            let phase = (t / 1.6).truncatingRemainder(dividingBy: 1) * 1.8 - 0.4
            label.foregroundStyle(base)
                .overlay(
                    LinearGradient(stops: [.init(color: highlight.opacity(0), location: phase - 0.18),
                                           .init(color: highlight, location: phase),
                                           .init(color: highlight.opacity(0), location: phase + 0.18)],
                                   startPoint: .leading, endPoint: .trailing)
                        .mask(label)
                )
        }
    }
}

/// A tiny key hint next to an action: what saying or pressing does.
struct KeyHint: View {
    var key: String
    var dark: Bool = true
    var body: some View {
        Text(key)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(dark ? Color.white.opacity(0.55) : Color.black.opacity(0.5))
            .padding(.horizontal, 5)
            .frame(height: 17)
            .background(dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Unit-square path drawn in a frame.
struct UnitPath: Shape {
    var points: [CGPoint]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for (i, point) in points.enumerated() {
            let q = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        return p
    }
}

struct Check: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 2.2
    var body: some View {
        UnitPath(points: [CGPoint(x: 0.16, y: 0.54), CGPoint(x: 0.41, y: 0.78), CGPoint(x: 0.86, y: 0.25)])
            .trim(from: 0, to: progress)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, self)) }
}
