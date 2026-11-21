import SwiftUI

public struct AuroraGlow: View {
  public var profile: Profile
  public var cornerRadius: CGFloat = 55
  public var borderWidth: CGFloat = 6
  public var glowSize: CGFloat = 28
  public var speed: Double = 0.12
  public var burstsOnAppear: Bool = true
  public var introOnAppear: Bool = true
  public var washSweepDuration: Float = 0.12
  public var washPulseWidth: Float = 0.80
  public var washPeak: Float = 0.10
  public var direction: Direction = .topToBottom
  public var introStyle: IntroStyle = .borderFill
  public var introDuration: Float = 0.5
  public var palette: Palette = .appleIntelligence
  public var isVisible: Bool = true
  public var outroStyle: OutroStyle = .dissolve
  public var outroDuration: Float = 0.4
  public var burster: Burster?

  @State private var startDate = Date()
  @State private var burstStartDate: Date? = nil
  @State private var introStartDate: Date? = nil
  @State private var outroStartDate: Date? = nil

  public init(_ style: Style = .standard) {
    self.profile = style.profile
  }

  public init(profile: Profile) {
    self.profile = profile
  }

  @Environment(\.auroraTimes) private var times

  public var body: some View {
    GeometryReader { proxy in
      if let times {
        glowRect(in: proxy.size, times: times)
      } else {
        TimelineView(.animation) { context in
          glowRect(in: proxy.size, at: context.date)
        }
      }
    }
    .compositingGroup()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .onAppear {
      let now = Date()
      if introOnAppear { introStartDate = now }
      if burstsOnAppear { burstStartDate = now }
    }
    .onChange(of: burster?.lastFiredAt) { _, newValue in
      if let newValue { burstStartDate = newValue }
    }
    .onChange(of: isVisible) { _, nowVisible in
      let now = Date()
      if nowVisible {
        outroStartDate = nil
        if introOnAppear { introStartDate = now }
        if burstsOnAppear { burstStartDate = now }
      } else {
        outroStartDate = now
      }
    }
  }
  
  private func glowRect(in size: CGSize, at now: Date) -> some View {
    glowRect(in: size, times: Times(
      elapsed: now.timeIntervalSince(startDate),
      burst: burstStartDate.map { now.timeIntervalSince($0) } ?? -1.0,
      intro: introStartDate.map { now.timeIntervalSince($0) } ?? -1.0,
      outro: outroStartDate.map { now.timeIntervalSince($0) } ?? -1.0))
  }

  private func glowRect(in size: CGSize, times: Times) -> some View {
    let elapsed = times.elapsed
    let burstElapsed = times.burst
    let introElapsed = times.intro
    let outroElapsed = times.outro
    let t = profile
    return Rectangle()
      .colorEffect(
        ShaderLibrary.aurora.auroraGlow(
          .float2(size),
          .float(elapsed * speed),
          .float(cornerRadius),
          .float(borderWidth),
          .float(glowSize),
          .float(burstElapsed),
          .float(introElapsed),
          .float(outroElapsed),
          .float2(
            CGFloat(introDuration),
            CGFloat(introStyle.shaderValue)
          ),
          .float2(
            CGFloat(outroDuration),
            CGFloat(outroStyle.shaderValue)
          ),
          .float4(
            CGFloat(t.anchorAmpBoost),
            CGFloat(t.anchorSpeedBoost),
            CGFloat(t.flameAmpBoost),
            CGFloat(t.brightnessPop)
          ),
          .float4(
            CGFloat(t.decayRate),
            CGFloat(t.flameBaseline),
            0.0,
            0.0
          ),
          .float3(
            CGFloat(washSweepDuration),
            CGFloat(washPulseWidth),
            CGFloat(washPeak)
          ),
          .float2(
            CGFloat(direction.vector.x),
            CGFloat(direction.vector.y)
          ),
          .float3(
            CGFloat(palette.base.x),
            CGFloat(palette.base.y),
            CGFloat(palette.base.z)
          ),
          .float3(
            CGFloat(palette.anchors[0].x),
            CGFloat(palette.anchors[0].y),
            CGFloat(palette.anchors[0].z)
          ),
          .float3(
            CGFloat(palette.anchors[1].x),
            CGFloat(palette.anchors[1].y),
            CGFloat(palette.anchors[1].z)
          ),
          .float3(
            CGFloat(palette.anchors[2].x),
            CGFloat(palette.anchors[2].y),
            CGFloat(palette.anchors[2].z)
          ),
          .float3(
            CGFloat(palette.anchors[3].x),
            CGFloat(palette.anchors[3].y),
            CGFloat(palette.anchors[3].z)
          )
        )
      )
  }
}

// JARVIS PATCH: an injectable clock. Upstream reads TimelineView's wall
// clock and Dates stamped in onAppear/onChange; ImageRenderer advances
// neither. With auroraTimes set, the glow draws exactly these seconds
// (each -1 when that envelope hasn't started), so the gallery renders exact
// frames and the lab's slow motion slows the glow too.
extension AuroraGlow {
  public struct Times: Sendable, Equatable {
    public var elapsed: Double
    public var burst: Double
    public var intro: Double
    public var outro: Double
    public init(elapsed: Double, burst: Double = -1, intro: Double = -1, outro: Double = -1) {
      self.elapsed = elapsed
      self.burst = burst
      self.intro = intro
      self.outro = outro
    }
  }
}

private struct AuroraTimesKey: EnvironmentKey {
  static let defaultValue: AuroraGlow.Times? = nil
}

extension EnvironmentValues {
  public var auroraTimes: AuroraGlow.Times? {
    get { self[AuroraTimesKey.self] }
    set { self[AuroraTimesKey.self] = newValue }
  }
}
