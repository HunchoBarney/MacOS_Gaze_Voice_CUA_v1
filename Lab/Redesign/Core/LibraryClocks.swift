import BorderBeamKit
import Orb
import SwiftUI
import ThinkingOrbsKit
import VoiceCore
import VoiceGlowKit

/// One clock for every vendored library, so library motion follows the
/// stage: slowed in the lab's slow motion, exact in rendered clips, paused
/// when the stage pauses. See Lab/Vendor/*/VENDOR.md for each patch.
@MainActor
public final class LibraryClocks {
    public private(set) var time = 0.0
    let voice = VoiceClock()
    let glow = VoiceGlowClock()

    public init() {}

    func set(_ t: Double) {
        time = t
        voice.time = t
        glow.time = t
    }
}

extension View {
    func libraryClocks(_ clocks: LibraryClocks) -> some View {
        self
            .orbClock(clocks.time)
            .orbFrozenTime(clocks.time)
            .environment(\.beamFrozenTime, clocks.time)
            .environment(\.voiceClock, clocks.voice)
            .environment(\.voiceGlowClock, clocks.glow)
    }
}

/// The stage's direction drawn on the fixture desktop, cropped to the
/// component's region (or the whole desktop for scenes).
public struct StageView: View {
    @ObservedObject var stage: Stage
    var crop: CGRect?
    var backdrop: Bool

    public init(stage: Stage, crop: CGRect? = nil, backdrop: Bool = true) {
        self.stage = stage
        self.crop = crop
        self.backdrop = backdrop
    }

    public var body: some View {
        let region = crop ?? stage.component.crop
        ZStack(alignment: .topLeading) {
            if backdrop {
                MacDesktop(scheme: stage.scheme, showsMail: stage.component.showsMail,
                           reduceTransparency: stage.reduceTransparency)
            }
            stage.content()
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
        .offset(x: -region.minX, y: -region.minY)
        .frame(width: region.width, height: region.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, stage.scheme)
        .libraryClocks(stage.clocks)
    }
}
