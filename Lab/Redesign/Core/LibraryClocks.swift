import BorderBeamKit
import Orb
import SwiftUI
import ThinkingOrbsKit
import VoiceCore

/// One clock for every vendored library, so library motion follows the
/// stage: slowed in the lab's slow motion, exact in rendered clips, paused
/// when the stage pauses. See Lab/Vendor/*/VENDOR.md for each patch.
@MainActor
public final class LibraryClocks {
    public private(set) var time = 0.0
    let voice = VoiceClock()

    public init() {}

    func set(_ t: Double) {
        time = t
        voice.time = t
    }
}

extension VoiceStyle {
    /// The default ring style, held still under Reduce Motion: VoiceCanvas
    /// reads the system setting, which the lab's toggle and -rm renders can't set.
    static func ring(paused: Bool) -> VoiceStyle {
        var style = VoiceStyle()
        style.paused = paused
        return style
    }
}

extension View {
    func libraryClocks(_ clocks: LibraryClocks, reduceMotion: Bool) -> some View {
        self
            .orbClock(clocks.time)
            .orbFrozenTime(reduceMotion ? nil : clocks.time)
            .environment(\.beamFrozenTime, clocks.time)
            .environment(\.voiceClock, clocks.voice)
    }
}

/// The stage's direction drawn on the fixture desktop, cropped to the
/// component's region (or the whole desktop for scenes).
public struct StageView: View {
    @ObservedObject var stage: Stage
    var crop: CGRect?
    var backdrop: Bool
    /// The stage clock when this value was made. ImageRenderer re-renders a
    /// reassigned content only when the view value differs, and a Stage is the
    /// same reference every frame, so without this a frame where nothing else
    /// changes the view's inputs (most often under Reduce Motion) repeats the
    /// last image.
    private let time: Double

    public init(stage: Stage, crop: CGRect? = nil, backdrop: Bool = true) {
        self.stage = stage
        self.crop = crop
        self.backdrop = backdrop
        time = stage.time
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
        .libraryClocks(stage.clocks, reduceMotion: stage.reduceMotion)
    }
}
