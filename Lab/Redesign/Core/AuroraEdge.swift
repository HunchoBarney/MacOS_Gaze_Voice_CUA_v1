import Aurora
import SwiftUI

/// The Aurora shader sized for a control rather than a screen: the shader
/// paints its edge light inward, so on a control it is clipped to the
/// control's shape (a thin inner rim) and a blurred copy behind it throws the
/// light outward. The control's label stays clear.
struct AuroraEdge: View {
    var size: CGSize
    var radius: Double
    var border: Double = 2.5
    var rim: Double = 5
    var bloom: Double = 1
    var times: AuroraGlow.Times
    var reduceTransparency = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let glow = AuroraGlow(.subtle)
            .cornerRadius(radius)
            .borderWidth(border)
            .glowSize(rim)
            .palette(.appleIntelligence)
            .frame(width: size.width, height: size.height)
            .environment(\.auroraTimes, times)
        ZStack {
            if !reduceTransparency, bloom > 0.01 {
                glow
                    .clipShape(shape)
                    .blur(radius: 9)
                    .opacity(0.9 * bloom)
            }
            glow.clipShape(shape)
        }
        .frame(width: size.width, height: size.height)
    }
}
