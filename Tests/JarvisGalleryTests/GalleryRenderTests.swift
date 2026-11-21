import AppKit
import SwiftUI
import XCTest
@testable import Jarvis

/// Renders every visible Jarvis surface for the UI gallery (gallery/README.md).
/// Skipped unless JARVIS_GALLERY_OUT names an output folder: make gallery
/// sets it. Fixture data only; no microphone, camera, Keychain, network or
/// window ever reaches the real screen (VirtualScreen swaps ordering out).
@MainActor
final class GalleryRenderTests: XCTestCase {
    func testRenderGallery() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["JARVIS_GALLERY_OUT"], !path.isEmpty else {
            throw XCTSkip("Set JARVIS_GALLERY_OUT (make gallery) to render the UI gallery.")
        }
        VirtualScreen.install()
        let run = try GalleryRun(out: URL(fileURLWithPath: path))
        try await run.renderAll()
        try run.writer.writeManifest(commit: environment["JARVIS_GALLERY_COMMIT"] ?? "unknown")
        let encoded = try ClipEncoder.encodeFrameFolders(under: URL(fileURLWithPath: path))
        try run.log.joined(separator: "\n").appending("\nencoded frame folders: \(encoded)\n")
            .write(to: URL(fileURLWithPath: path).appendingPathComponent("native-log.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(run.failures.isEmpty, run.failures.joined(separator: "\n"))
    }
}

private struct FixtureRoster: AgentRosterProviding {
    let list: [CompanionAgent]
    func agents() async -> [CompanionAgent] { list }
}

@MainActor
final class GalleryRun {
    let writer: GalleryWriter
    let screen = Compositor()
    var clock = AnimationClock()
    var log: [String] = []
    var failures: [String] = []
    let overlay = TargetOverlay.shared
    let cursorLabels = AgentCursorLabels()
    private var rm = false

    init(out: URL) throws { writer = try GalleryWriter(out: out) }

    // MARK: Plumbing

    func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func reset(reduceMotion: Bool) {
        rm = reduceMotion
        overlay.reduceMotion = { reduceMotion }
        overlay.now = { ProcessInfo.processInfo.systemUptime }
        DeicticFlash.shared.reduceMotion = { reduceMotion }
        overlay.hideAll()
        overlay.agentChips([])
        overlay.gazeLost(false)
        overlay.showsDwellProgress = false
        overlay.guideCallout.textScale = 1
        AgentShelfOverlay.shared.hide()
        cursorLabels.hideAll()
        screen.statusItem = ("waveform", 0)
        VirtualScreen.clear()
        clock = AnimationClock()
    }

    var roots: [CALayer] { VirtualScreen.stack.compactMap { $0.contentView?.layer } }

    func stamp(_ time: Double) { clock.stamp(roots, at: time) }

    /// A borderless panel holding a SwiftUI view, ordered onto the
    /// virtual screen at a top-left origin (or under the notch).
    @discardableResult
    func place<V: View>(_ view: V, topLeft: CGPoint? = nil, level: NSWindow.Level = .statusBar,
                        scheme: Scheme = .dark) -> NSPanel {
        let host = NSHostingView(rootView: view)
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = level
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.appearance = scheme.appearance
        panel.contentView = host
        let size = host.fittingSize
        let frame: NSRect
        if let topLeft {
            frame = NSRect(x: topLeft.x, y: VirtualScreen.primaryHeight - topLeft.y - size.height,
                           width: size.width, height: size.height)
        } else {
            frame = AppWindows.frame(contentSize: size, visibleFrame: screen.desktop.visibleFrame)
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        spin(0.03)
        return panel
    }

    /// One SwiftUI view, hosted offscreen, at 2x.
    func hosted<V: View>(_ view: V, scheme: Scheme, size: CGSize? = nil) -> CGImage? {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size ?? CGSize(width: 10, height: 10)),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = scheme.appearance
        host.appearance = scheme.appearance
        window.contentView = host
        let fitted = size ?? host.fittingSize
        window.setContentSize(fitted)
        host.frame = NSRect(origin: .zero, size: fitted)
        host.layoutSubtreeIfNeeded()
        spin(0.05)
        host.layoutSubtreeIfNeeded()
        let image = WindowRenderer.cached(host, scale: writer.scale)
        window.contentView = nil
        return image
    }

    func record(_ body: () throws -> Void, _ what: String) {
        do { try body() } catch { failures.append("\(what): \(error)") }
    }

    /// Renders an overlay state on the fixture desktop, light and dark,
    /// Reduce Motion off and on. \(at) is the virtual time of the still.
    func overlayState(_ component: String, _ state: String, _ title: String, note: String? = nil,
                      crop: @escaping () -> CGRect, at: Double = 5, withMail: Bool = true,
                      setup: () -> Void) {
        for scheme in Scheme.allCases {
            for reduce in [false, true] {
                reset(reduceMotion: reduce)
                setup()
                stamp(0)
                _ = screen.background(scheme, withMail: withMail)
                let image = screen.compose(scheme, withMail: withMail, clock: clock, time: at, crop: crop())
                record({ try writer.still(image, component: component, state: state, title: title, note: note,
                                          scheme: scheme, reduceMotion: reduce, backdrop: "desktop") },
                       "\(component)/\(state)")
            }
        }
        reset(reduceMotion: false)
    }

    /// A clip on a virtual clock: actions run at their times and stamp the
    /// animations they add; frames sample every 1/60 s.
    func overlayClip(_ component: String, _ state: String, _ title: String, note: String? = nil,
                     caption: String, scheme: Scheme = .dark, reduceMotion: Bool, duration: Double,
                     crop: CGRect, actions: [(Double, () -> Void)]) {
        reset(reduceMotion: reduceMotion)
        var pending = actions.sorted { $0.0 < $1.0 }
        var frames: [ClipFrame] = []
        var t = 0.0
        while t <= duration + 1e-9 {
            while let next = pending.first, next.0 <= t + 1e-9 {
                pending.removeFirst()
                next.1()
                stamp(next.0)
            }
            frames.append(ClipFrame(time: t, image: screen.compose(scheme, clock: clock, time: t, crop: crop)))
            t += 1.0 / 60
        }
        record({ try writer.clip(frames, component: component, state: state, title: title, note: note,
                                 scheme: scheme, reduceMotion: reduceMotion, caption: caption) }, "clip \(component)/\(state)")
        reset(reduceMotion: false)
    }

    /// Pads a rect by \(dx), \(dy) and keeps it on the desktop.
    func around(_ rect: CGRect, _ dx: CGFloat = 80, _ dy: CGFloat = 60) -> CGRect {
        rect.insetBy(dx: -dx, dy: -dy).intersection(CGRect(origin: .zero, size: screen.desktop.size)).integral
    }

    func candidate(_ name: String, kind: IntentCandidate.Kind = .axElement, role: String = "AXButton",
                   frame: CGRect? = nil) -> IntentCandidate {
        let rect = frame ?? screen.mail.target(name)
        return IntentCandidate(id: "fixture:\(name)", kind: kind, frame: rect, motorRect: rect, role: role, label: name)
    }

    func step(_ number: Int, of total: Int?, target name: String, instruction: String,
              consequence: String? = nil) -> GuideStep {
        let frame = screen.mail.target(name)
        let element = GuideElement(role: "AXButton", label: name.capitalized, frame: frame)
        return GuideStep(number: number, total: total, action: .element(element), target: element,
                         windowFrame: screen.mail.frame, name: "the \(name.capitalized) button",
                         instruction: instruction, detail: instruction, slow: instruction,
                         consequenceLine: consequence, consequence: nil, expect: .anyChange)
    }

    // MARK: Everything

    func renderAll() async throws {
        log.append("desktop \(screen.desktop.size) menu bar \(screen.desktop.menuBarHeight) notch \(String(describing: screen.desktop.notch)) drawn \(screen.desktop.drawnNotch) layer flip \(WindowRenderer.layerNeedsFlip())")
        indicator()
        menuBar()
        gazeHighlight()
        halo()
        pressGlow()
        flashes()
        chips()
        cheatSheet()
        guideCallout()
        agentsOverlays()
        try await windows()
        firstRun()
        scenes()
        proposals()
    }

    // MARK: Proposed

    var notchSize: CGSize { screen.desktop.notch?.size ?? CGSize(width: 185, height: 32) }

    func placeTop<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        place(view, topLeft: CGPoint(x: ((screen.desktop.size.width - size.width) / 2).rounded(), y: 0))
    }

    func proposals() {
        let note = "Proposed: one black island that grows out of the notch (DynamicNotchKit), a voice orb that follows the smoothed level (Orb by metasidd, springs from Wave), words that fade at the leading edge, and the ask growing out of the same surface. A SwiftUI mockup rendered by the harness, not shipped code."
        let n = notchSize
        let cases: [(String, String, IslandFixture)] = [
            ("proposed-hearing", "Proposed: hearing", IslandFixture(mode: .hearing, text: "Reply to Alex and say the deck is ready", level: 0.6, notch: n)),
            ("proposed-working", "Proposed: working", IslandFixture(mode: .working, text: "Opening the Q3 deck in Keynote", notch: n)),
            ("proposed-guide", "Proposed: guide step", IslandFixture(mode: .guide, text: "Click Send", detail: "2 of 3", notch: n)),
            ("proposed-confirm", "Proposed: asking", IslandFixture(mode: .confirm, text: "Send the reply to Alex Rivera?", detail: "Mail · Q3 planning deck", notch: n)),
            ("proposed-problem", "Proposed: problem", IslandFixture(mode: .problem, text: "I couldn't reach OpenAI just now.", detail: "Check your internet connection, then try again.", notch: n)),
        ]
        let crop: () -> CGRect = { [self] in CGRect(x: (screen.desktop.size.width - 640) / 2, y: 0, width: 640, height: 300) }
        for (id, title, fixture) in cases {
            for scheme in Scheme.allCases {
                for reduce in [false, true] {
                    reset(reduceMotion: reduce)
                    placeTop(IslandProposal(fixture: fixture))
                    _ = screen.background(scheme, withMail: true)
                    let image = screen.compose(scheme, crop: crop())
                    record({ try writer.still(image, component: "listening-indicator", state: id, title: title, note: note, kind: "proposed",
                                              scheme: scheme, reduceMotion: reduce, backdrop: "desktop") }, "proposal (id)")
                }
            }
        }
        reset(reduceMotion: false)
        placeTop(IslandProposal(fixture: IslandFixture(mode: .hearing, text: "Click that", level: 0.5, notch: n)))
        overlay.intentEvent(.acquire(candidate("send")))
        stamp(0)
        record({ try writer.scene(screen.compose(.dark, clock: clock, time: 5), id: "listening-gaze-proposed",
                                  title: "Listening while looking at Send (proposed island)",
                                  summary: "The same moment as \"Listening while looking at Send\" with the proposed notch island.",
                                  components: ["listening-indicator", "gaze-highlight"], kind: "proposed", scheme: .dark) }, "proposed scene")
        reset(reduceMotion: false)
    }

    // MARK: Listening indicator

    func indicatorFixtures() -> [(String, String, String?, IndicatorFixture)] {
        let guide = step(2, of: 3, target: "send", instruction: "Click the Send button, at the top of the window.")
        return [
            ("hearing", "Hearing, before words", nil, IndicatorFixture(phase: .hearing, level: 0.35)),
            ("hearing-partial", "Hearing, live words", "Partial transcript at 75% white while the words are still changing.",
             IndicatorFixture(phase: .hearing, transcript: "Reply to Alex and say the deck is", partialLive: true, level: 0.55)),
            ("hearing-long", "Hearing, long sentence", "Truncates from the head so the newest words stay visible (max 440 pt).",
             IndicatorFixture(phase: .hearing, transcript: "Open the Q3 planning deck in Keynote, go to the hiring slide and make the chart a bar chart instead of a pie", level: 0.6)),
            ("hearing-eyes", "Hearing, eye tracking on", "The eye glyph appears whenever eye tracking is on.",
             IndicatorFixture(phase: .hearing, transcript: "Click that", level: 0.5, gazeTracking: true)),
            ("working", "Working", "Task label plus an ellipsis glyph and a Stop (×) button.",
             IndicatorFixture(phase: .working, workLabel: "Opening the Q3 deck in Keynote")),
            ("working-guide", "Guide step", "Step N of M plus three text buttons that match the spoken commands.",
             IndicatorFixture(phase: .working, guideStep: guide)),
            ("asking-confirm", "Asking to confirm", nil,
             IndicatorFixture(phase: .asking, ask: .confirm("Send the reply to Alex Rivera?"))),
            ("asking-review", "Check what I heard", nil,
             IndicatorFixture(phase: .asking, ask: .review("Reply to Alex and say the deck is ready"))),
            ("asking-question", "A question", "An open question has only Cancel; the answer is spoken.",
             IndicatorFixture(phase: .asking, ask: .answer("Which deck: Q3 planning or Q3 review?"))),
            ("asking-approval", "Task approval", nil,
             IndicatorFixture(phase: .asking, ask: .approval("Move 14 receipts from Downloads into Expenses?"))),
            ("problem", "Problem", "Shown when something failed that the person has to read.",
             IndicatorFixture(phase: .problem, problem: "I couldn't reach OpenAI just now.",
                              detail: "Check your internet connection, then try again.", canOpenSettings: true)),
        ]
    }

    func indicator() {
        writer.declare("listening-indicator", title: "Listening indicator", area: "Voice",
                       summary: "The black tab that drops from the notch while Jarvis hears, works, asks or hits a problem, with its ask and problem cards.",
                       sources: ["Sources/Jarvis/UI/ListeningIndicator.swift:65", "Sources/Jarvis/UI/AppWindows.swift:73",
                                 "Sources/Jarvis/UI/Components.swift:19"])
        let replicaNote = "Rendered from the harness replica of ListeningIndicator.swift (VoiceController's state is private(set)); the replica is checked pixel for pixel against the real view in the Problem state."
        for (id, title, note, fixture) in indicatorFixtures() {
            let crop: () -> CGRect = { [self] in
                let w: CGFloat = 640
                return CGRect(x: (screen.desktop.size.width - w) / 2, y: 0, width: w, height: 300)
            }
            overlayState("listening-indicator", id, title, note: [note, replicaNote].compactMap { $0 }.joined(separator: " "),
                         crop: crop) {
                var f = fixture
                if rm, f.phase == .hearing { f.level = 0.4375 }
                place(IndicatorReplica(fixture: f))
            }
        }
        verifyIndicator()
        // The level meter: speech-like levels at 20 Hz, as the audio tap reports them.
        for reduce in [false, true] {
            reset(reduceMotion: reduce)
            var frames: [ClipFrame] = []
            let crop = CGRect(x: (screen.desktop.size.width - 640) / 2, y: 0, width: 640, height: 120)
            var t = 0.0
            while t <= 2.0 {
                let envelope = Float(max(0, sin(t * 2.6) * 0.5 + 0.35 + 0.25 * sin(t * 17)))
                VirtualScreen.clear()
                var f = IndicatorFixture(phase: .hearing, transcript: t < 0.6 ? "" : "Reply to Alex and say the deck is ready",
                                         partialLive: t < 1.6, level: reduce ? 0.4375 : envelope)
                if t < 0.6 { f.transcript = "" }
                place(IndicatorReplica(fixture: f))
                frames.append(ClipFrame(time: t, image: screen.compose(.dark, crop: crop)))
                t += 1.0 / 20
            }
            record({ try writer.clip(frames, component: "listening-indicator", state: "hearing-partial",
                                     title: "Hearing, live words", scheme: .dark, reduceMotion: reduce,
                                     caption: reduce ? "Reduce Motion: the meter holds still" : "Level meter at the 20 Hz audio rate; words and width change without animation") },
                   "indicator clip")
        }
        reset(reduceMotion: false)
    }

    /// The real ListeningIndicatorView in the one state a fixture
    /// controller reaches without a microphone (a failed setup), against
    /// the replica.
    func verifyIndicator() {
        let config = Fixtures.config()
        let controller = Fixtures.controller(config, missing: [])
        controller.showSetup("I couldn't reach OpenAI just now.")
        spin(0.05)
        guard IndicatorPhase.current(controller) == .problem else {
            failures.append("indicator check: controller did not reach .problem")
            return
        }
        var message = controller.detail
        if case .error(let text) = controller.status { message = text }
        let fixture = IndicatorFixture(phase: .problem, problem: message, detail: controller.detail,
                                       canOpenSettings: !controller.missingPermissions.isEmpty || config.needsKeys)
        guard let real = hosted(ListeningIndicatorView(controller: controller), scheme: .dark),
              let replica = hosted(IndicatorReplica(fixture: fixture), scheme: .dark) else {
            failures.append("indicator check: render failed"); return
        }
        let same = Self.difference(real, replica)
        log.append("indicator replica vs real (problem): \(same)")
        record({ try writer.still(real, component: "listening-indicator", state: "problem-real", title: "Problem (real view)",
                                  note: "The real ListeningIndicatorView driven by a fixture controller (showSetup). Replica check: \(same).",
                                  scheme: .dark, reduceMotion: false, backdrop: "transparent") }, "indicator real")
    }

    static func difference(_ a: CGImage, _ b: CGImage) -> String {
        guard a.width == b.width, a.height == b.height else { return "size differs \(a.width)x\(a.height) vs \(b.width)x\(b.height)" }
        guard let da = a.dataProvider?.data, let db = b.dataProvider?.data,
              let pa = CFDataGetBytePtr(da), let pb = CFDataGetBytePtr(db) else { return "unreadable" }
        let n = min(CFDataGetLength(da), CFDataGetLength(db))
        var differing = 0
        for i in stride(from: 0, to: n, by: 4) where abs(Int(pa[i]) - Int(pb[i])) > 8 || abs(Int(pa[i + 3]) - Int(pb[i + 3])) > 8 {
            differing += 1
        }
        return differing == 0 ? "identical" : "\(differing) of \(n / 4) pixels differ"
    }

    // MARK: Menu bar

    func menuBar() {
        writer.declare("menu-bar-item", title: "Menu bar item", area: "Menu bar",
                       summary: "Jarvis's status item: one SF Symbol per resting listening state, plus a dot count when asks are parked.",
                       sources: ["Sources/Jarvis/main.swift:556", "Sources/Jarvis/main.swift:547"])
        let states: [(String, String, String, Int)] = [
            ("standby", "Waiting for the wake word", "ear", 0), ("listening", "Listening", "waveform", 0),
            ("paused", "Paused", "pause.circle", 0), ("no-mic", "Can't hear (no microphone access)", "mic.slash", 0),
            ("asks-parked", "Two asks parked", "ear", 2)]
        for (id, title, symbol, badge) in states {
            overlayState("menu-bar-item", id, title,
                         note: "Drawn replica: NSStatusItem renders only through the window server. Symbol \"\(symbol)\" at the menu-bar point size.",
                         crop: { [self] in around(screen.statusItemFrame, 120, 0).intersection(CGRect(x: 0, y: 0, width: screen.desktop.size.width, height: 60)) },
                         withMail: false) {
                screen.statusItem = (symbol, badge)
            }
        }
        writer.declare("menu-bar-menu", title: "Menu bar menu", area: "Menu bar",
                       summary: "The status item's menu: windows, Pause and Stop, the Eyes section, logs and Quit.",
                       sources: ["Sources/Jarvis/main.swift:64", "Sources/Jarvis/main.swift:532", "Sources/Jarvis/main.swift:598"])
        let menus: [(String, String, [MenuReplica.Item])] = [
            ("idle", "Eyes off, nothing running", MenuReplica.items(eyes: "off", paused: false, stoppable: false)),
            ("task-running", "A task is running (Stop shows)", MenuReplica.items(eyes: "off", paused: false, stoppable: true)),
            ("eyes-on", "Eye tracking running", MenuReplica.items(eyes: "running", paused: false, stoppable: false)),
            ("eyes-failed", "Eye tracker stopped", MenuReplica.items(eyes: "failed", paused: true, stoppable: false)),
        ]
        for (id, title, items) in menus {
            for scheme in Scheme.allCases {
                for reduce in [false, true] {
                    reset(reduceMotion: reduce)
                    let origin = CGPoint(x: min(screen.statusItemFrame.minX, screen.desktop.size.width - 300),
                                         y: screen.desktop.menuBarHeight + 4)
                    place(MenuReplica(items: items).environment(\.colorScheme, scheme == .dark ? .dark : .light),
                          topLeft: origin, level: .popUpMenu, scheme: scheme)
                    let crop = CGRect(x: origin.x - 40, y: 0, width: 360, height: 470)
                        .intersection(CGRect(origin: .zero, size: screen.desktop.size))
                    let image = screen.compose(scheme, withMail: false, crop: crop)
                    record({ try writer.still(image, component: "menu-bar-menu", state: id, title: title,
                                              note: "Drawn replica of NSMenu with the real titles and visibility rules from main.swift.",
                                              scheme: scheme, reduceMotion: reduce, backdrop: "desktop") }, "menu \(id)")
                }
            }
        }
        reset(reduceMotion: false)
    }

    // MARK: Gaze highlight

    func gazeHighlight() {
        writer.declare("gaze-highlight", title: "Gaze highlight", area: "Gaze",
                       summary: "The ring the scorer puts on the control you're looking at: lifts out of the control, glides between controls, fades on release; sweeps a dwell countdown when Click by looking is on.",
                       sources: ["Sources/Jarvis/UI/TargetOverlay.swift:583", "Sources/Jarvis/UI/TargetOverlay.swift:611",
                                 "Sources/Jarvis/UI/TargetOverlay.swift:706"], owner: "JARA-55")
        let mail = screen.mail
        let crop = { [self] in around(screen.mail.frame.insetBy(dx: 0, dy: 0), 30, 30) }
        let cases: [(String, String, String?, () -> Void)] = [
            ("toolbar-button", "On a toolbar button", "A 40×28 control reads as a capsule.", { [self] in
                overlay.intentEvent(.acquire(candidate("send"))) }),
            ("push-button", "On a push button", nil, { [self] in
                overlay.intentEvent(.acquire(candidate("sendBottom"))) }),
            ("traffic-light", "On a window button", "Traffic lights circle the button itself.", { [self] in
                let close = CGRect(x: mail.origin.x + 20, y: mail.origin.y + 20, width: 12, height: 12)
                overlay.intentEvent(.acquire(candidate("close", kind: .trafficLight, frame: close))) }),
            ("large-text", "On a paragraph", "JARA-55 symptom (b): a large non-control frame gets a full rounded-rect highlight.", { [self] in
                overlay.intentEvent(.acquire(candidate("body", role: "AXStaticText"))) }),
            ("dwell-30", "Dwell countdown 30%", "Only with Click by looking on.", { [self] in
                overlay.showsDwellProgress = true
                let c = candidate("send")
                overlay.intentEvent(.acquire(c)); overlay.intentEvent(.hold(c, progress: 0.3)) }),
            ("dwell-80", "Dwell countdown 80%", "Past halfway the whole ring fades toward 65%.", { [self] in
                overlay.showsDwellProgress = true
                let c = candidate("send")
                overlay.intentEvent(.acquire(c)); overlay.intentEvent(.hold(c, progress: 0.8)) }),
            ("agent-dimmed", "Standing down for an agent", "Dims to 30% while an agent acts on the same element.", { [self] in
                let c = candidate("send")
                overlay.intentEvent(.acquire(c)); overlay.agentChips([c.frame]) }),
        ]
        for (id, title, note, setup) in cases {
            overlayState("gaze-highlight", id, title, note: note, crop: crop, setup: setup)
        }
        let send = candidate("send"), bottom = candidate("sendBottom")
        for reduce in [false, true] {
            overlayClip("gaze-highlight", "toolbar-button", "On a toolbar button", caption: reduce
                        ? "Reduce Motion: fades only, jumps between controls"
                        : "Acquire (80 ms lift), glide to the next control (100 ms), release (120 ms fade)",
                        reduceMotion: reduce, duration: 1.4, crop: around(mail.frame, 20, 20), actions: [
                            (0.1, { [self] in overlay.intentEvent(.acquire(send)) }),
                            (0.6, { [self] in overlay.intentEvent(.acquire(bottom)) }),
                            (1.1, { [self] in overlay.intentEvent(.release(bottom)) }),
                        ])
        }
    }

    func halo() {
        writer.declare("listening-halo", title: "Listening halo", area: "Gaze",
                       summary: "A frosted HUD rectangle with a blue border armed on the gazed element while you speak; a second, unscored highlight.",
                       sources: ["Sources/Jarvis/UI/TargetOverlay.swift:333", "Sources/Jarvis/Drive/VoiceTaskCoordinator.swift:2473"])
        let note = "NSVisualEffectView (.hudWindow, behind-window) is approximated from the fixture desktop: only the window server can blur what is behind a window."
        overlayState("listening-halo", "on-button", "On the Send button", note: note,
                     crop: { [self] in around(screen.mail.target("send"), 140, 70) }) { [self] in
            overlay.showHalo(frame: screen.mail.target("send"))
        }
        overlayState("listening-halo", "dimmed", "Standing down for an agent", note: note,
                     crop: { [self] in around(screen.mail.target("send"), 140, 70) }) { [self] in
            overlay.showHalo(frame: screen.mail.target("send"))
            overlay.agentChips([screen.mail.target("send")])
        }
        overlayState("listening-halo", "with-ring", "Halo and gaze ring together", note: "Both highlights at once: JARA-55 fix plan item 4 (one highlight).",
                     crop: { [self] in around(screen.mail.target("send"), 140, 70) }) { [self] in
            overlay.showHalo(frame: screen.mail.target("attach"))
            overlay.intentEvent(.acquire(candidate("send")))
        }
    }

    func pressGlow() {
        writer.declare("press-glow", title: "Press glow", area: "Gaze",
                       summary: "The gaze ring held for 1.2 s on a control Jarvis presses because you named it (\"click Send\"), then released.",
                       sources: ["Sources/Jarvis/UI/TargetOverlay.swift:370"])
        overlayState("press-glow", "pressed", "Pressed Send", crop: { [self] in around(screen.mail.target("sendBottom"), 120, 60) }) { [self] in
            overlay.glowPress(frame: screen.mail.target("sendBottom"))
        }
        let target = screen.mail.target("sendBottom")
        for reduce in [false, true] {
            overlayClip("press-glow", "pressed", "Pressed Send", caption: "Glow, hold 1.2 s, release", reduceMotion: reduce,
                        duration: 1.6, crop: around(target, 140, 70), actions: [
                            (0.05, { [self] in overlay.glowPress(frame: target) }),
                            (1.25, { [self] in overlay.intentEvent(.release(candidate("sendBottom"))) }),
                        ])
        }
    }

    func flashes() {
        writer.declare("confirm-flash", title: "Action confirmation flash", area: "Gaze",
                       summary: "A blue ring that grows from 8 to 36 pt and fades over 400 ms where a verified action landed.",
                       sources: ["Sources/Jarvis/UI/TargetOverlay.swift:811", "Sources/Jarvis/UI/TargetOverlay.swift:848"])
        let send = screen.mail.target("sendBottom")
        let point = CGPoint(x: send.midX, y: send.midY)
        overlayState("confirm-flash", "mid-flash", "Mid flash (120 ms)", crop: { [self] in around(send, 60, 40) }, at: 0.12) { [self] in
            overlay.flash(at: point)
        }
        for reduce in [false, true] {
            overlayClip("confirm-flash", "mid-flash", "Mid flash (120 ms)", caption: reduce ? "Reduce Motion: fade only" : "Grow and fade, ease-out, 400 ms",
                        reduceMotion: reduce, duration: 0.6, crop: around(send, 60, 40),
                        actions: [(0.05, { [self] in overlay.flash(at: point) })])
        }
        writer.declare("deictic-flash", title: "\"This\" flash", area: "Gaze",
                       summary: "A ring that settles onto the element \"this\" resolved to, holds 350 ms and fades.",
                       sources: ["Sources/Jarvis/Gaze/DeicticFlash.swift:49"])
        let body = screen.mail.target("Subject:")
        overlayState("deictic-flash", "settled", "Settled on the subject", crop: { [self] in around(body, 60, 50) }, at: 0.2) {
            DeicticFlash.shared.flash(frame: body)
        }
        for reduce in [false, true] {
            overlayClip("deictic-flash", "settled", "Settled on the subject", caption: reduce ? "Reduce Motion: no settle, fades only" : "Settle from 108% (120 ms), hold 350 ms, fade 200 ms",
                        reduceMotion: reduce, duration: 0.85, crop: around(body, 60, 50), actions: [
                            (0.05, { DeicticFlash.shared.flash(frame: body) }),
                            (0.05 + DeicticFlash.settleSeconds + DeicticFlash.holdSeconds, { [self] in
                                spin(DeicticFlash.settleSeconds + DeicticFlash.holdSeconds + 0.03) }),
                        ])
        }
    }

    func chips() {
        writer.declare("target-chips", title: "Number, name and radial chips", area: "Gaze",
                       summary: "Dark pills that label targets for voice picks: numbers on every target, names, or a micro-radial fanned around an ambiguous gaze.",
                       sources: ["Sources/Jarvis/UI/TargetOverlay.swift:425", "Sources/Jarvis/UI/TargetOverlay.swift:501",
                                 "Sources/Jarvis/UI/TargetOverlay.swift:518", "Sources/Jarvis/UI/TargetOverlay.swift:534"])
        let names = ["send", "attach", "format", "photo", "To:", "Subject:", "later", "sendBottom"]
        let crop = { [self] in around(screen.mail.frame, 30, 30) }
        overlayState("target-chips", "numbers", "Numbers", note: "\"show numbers\": one chip per target, 1-based, on its top-left corner.", crop: crop) { [self] in
            overlay.showNumbers(targets: names.map { (screen.mail.target($0), $0) }) { _ in }
        }
        overlayState("target-chips", "names", "Names", crop: crop) { [self] in
            overlay.showNames(targets: [("send", "Send"), ("attach", "Attach"), ("format", "Format"), ("photo", "Photos"),
                                        ("later", "Send Later…"), ("sendBottom", "Send")].map { (screen.mail.target($0.0), $0.1) })
        }
        let send = screen.mail.target("send")
        overlayState("target-chips", "radial", "Which one? radial", note: "Fanned on the tracker's error band (radius 60 pt here) when gaze is ambiguous.",
                     crop: { [self] in around(send, 160, 110) }) { [self] in
            overlay.showRadial(labels: ["Send", "Attach", "Format"], near: CGPoint(x: send.midX + 30, y: send.midY), radius: 60) { _ in }
        }
        overlayState("target-chips", "radial-gaze-lost", "Radial while gaze is lost", note: "Dims to 40% when the gaze feed goes stale.",
                     crop: { [self] in around(send, 160, 110) }) { [self] in
            overlay.showRadial(labels: ["Send", "Attach", "Format"], near: CGPoint(x: send.midX + 30, y: send.midY), radius: 60) { _ in }
            overlay.gazeLost(true)
        }
    }

    func cheatSheet() {
        writer.declare("cheat-sheet", title: "Things you can say", area: "Voice",
                       summary: "The \"what can I say\" sheet under the menu bar; the same panel shows L7's \"Type this?\" drafts.",
                       sources: ["Sources/Jarvis/UI/TargetOverlay.swift:868", "Sources/Jarvis/Drive/VoiceTaskCoordinator.swift:2758"])
        let crop = { [self] in CGRect(x: (screen.desktop.size.width - 700) / 2, y: 0, width: 700, height: 520) }
        overlayState("cheat-sheet", "eyes-off", "Eye tracking off", crop: crop) { [self] in
            overlay.showSheet(lines: VoiceTaskCoordinator.cheatSheet(gaze: false))
        }
        overlayState("cheat-sheet", "eyes-on", "Eye tracking on", crop: crop) { [self] in
            overlay.showSheet(lines: VoiceTaskCoordinator.cheatSheet(gaze: true))
        }
        overlayState("cheat-sheet", "type-this", "Type this? draft", note: "L7 writing by instruction reuses the sheet for drafts.", crop: crop) { [self] in
            overlay.showSheet(lines: ["Type this?", "The Q3 deck is ready. Hiring is on slide 4 and the revenue bridge is on slide 9.", "Say “type it” or “change it”."])
        }
    }

    func guideCallout() {
        writer.declare("guide-callout", title: "Guide callout", area: "Guide",
                       summary: "The step's words in a dark label beside the glowing target, placed below, above, right or left, whichever fits.",
                       sources: ["Sources/Jarvis/UI/GuideCallout.swift:8", "Sources/Jarvis/UI/GuideCallout.swift:175"])
        let crop = { [self] in around(screen.mail.frame, 40, 40) }
        overlayState("guide-callout", "below", "Below the target", crop: crop) { [self] in
            let s = step(2, of: 3, target: "send", instruction: "Click the Send button, at the top of the window.")
            overlay.intentEvent(.acquire(candidate("send")))
            overlay.guideCallout.show(s)
        }
        overlayState("guide-callout", "consequential", "A consequential step", note: "A consequential step leads with its effect.", crop: crop) { [self] in
            let s = step(3, of: 3, target: "sendBottom", instruction: "Click Send.",
                         consequence: "This one sends it. Click the Send button when you're ready.")
            overlay.intentEvent(.acquire(candidate("sendBottom")))
            overlay.guideCallout.show(s)
        }
        overlayState("guide-callout", "large-text", "Larger text (1.5×)", crop: crop) { [self] in
            overlay.guideCallout.textScale = 1.5
            let s = step(1, of: 3, target: "attach", instruction: "Click the paperclip button, at the top of the window, to attach the deck.")
            overlay.intentEvent(.acquire(candidate("attach")))
            overlay.guideCallout.show(s)
        }
        // AppKit animates the window alpha itself, so this clip samples in real time.
        let s = step(2, of: 3, target: "send", instruction: "Click the Send button, at the top of the window.")
        for reduce in [false, true] {
            reset(reduceMotion: reduce)
            var frames: [ClipFrame] = []
            let start = Date()
            var pulsed = false, shown = false
            while Date().timeIntervalSince(start) < 1.6 {
                let t = Date().timeIntervalSince(start)
                if !shown, t >= 0.1 {
                    shown = true
                    overlay.intentEvent(.acquire(candidate("send"))); overlay.guideCallout.show(s); stamp(t)
                }
                if !pulsed, t >= 0.8 { pulsed = true; overlay.guideCallout.pulse(); stamp(t) }
                frames.append(ClipFrame(time: t, image: screen.compose(.dark, clock: clock, time: t, crop: around(screen.mail.target("send"), 220, 110))))
                spin(1.0 / 60)
            }
            record({ try writer.clip(frames, component: "guide-callout", state: "below", title: "Below the target", scheme: .dark,
                                     reduceMotion: reduce, caption: reduce ? "Reduce Motion: appears and re-points instantly" : "150 ms fade in, one 700 ms pulse on a re-point (real-time capture)") },
                   "callout clip")
        }
        reset(reduceMotion: false)
    }

    func agentsOverlays() {
        writer.declare("agent-cursor", title: "Agent cursor label", area: "Agents",
                       summary: "A coloured dot plus a name chip at an agent's action point, one per agent.",
                       sources: ["Sources/Jarvis/UI/AgentCursorOverlay.swift:7"])
        let p = screen.mail.target("format")
        overlayState("agent-cursor", "two-agents", "Two agents acting", crop: { [self] in around(screen.mail.target("send"), 220, 120) }) { [self] in
            let h = VirtualScreen.primaryHeight
            cursorLabels.show(AgentCursor(agentSlug: "inbox-desk", label: "Inbox Desk", colorHex: AgentCursor.palette(for: "inbox-desk")),
                              at: NSPoint(x: p.midX, y: h - p.midY))
            let q = screen.mail.target("To:")
            cursorLabels.show(AgentCursor(agentSlug: "receipts", label: "Receipts", colorHex: AgentCursor.palette(for: "receipts")),
                              at: NSPoint(x: q.minX + 40, y: h - q.midY))
        }
        writer.declare("agent-shelf", title: "Agent shelf", area: "Agents",
                       summary: "Fixed top-right chips for every live agent: colour, name, and a glyph when it is acting or asking.",
                       sources: ["Sources/Jarvis/UI/AgentShelfOverlay.swift:15", "Sources/Jarvis/UI/AgentShelfOverlay.swift:118"])
        overlayState("agent-shelf", "three-agents", "Acting, asking, idle",
                     crop: { [self] in CGRect(x: screen.desktop.size.width - 360, y: 0, width: 360, height: 160) }) { [self] in
            AgentShelfOverlay.shared.update([
                .init(slug: "inbox-desk", name: "Inbox Desk", colorHex: AgentCursor.palette(for: "inbox-desk"), state: .acting),
                .init(slug: "receipts", name: "Receipts", colorHex: AgentCursor.palette(for: "receipts"), state: .asking),
                .init(slug: "calendar", name: "Calendar Prep", colorHex: AgentCursor.palette(for: "calendar"), state: .idle),
            ], displayTopLeft: CGRect(origin: .zero, size: screen.desktop.size))
        }
    }

    // MARK: Windows

    func windowShot(_ content: CGImage, title: String, scheme: Scheme) -> CGImage {
        let scale = writer.scale
        let w = CGFloat(content.width) / scale, h = CGFloat(content.height) / scale
        let titleBar: CGFloat = 28, margin: CGFloat = 40
        let size = CGSize(width: w + margin * 2, height: h + titleBar + margin * 2)
        let ctx = WindowRenderer.context(Int(size.width * scale), Int(size.height * scale))!
        ctx.scaleBy(x: scale, y: scale)
        let background = screen.background(scheme, withMail: false)
        let desk = screen.desktop.size, below = desk.height - max(screen.desktop.menuBarHeight, screen.desktop.notch?.maxY ?? 0) - 16
        let fill = max(1, size.width / desk.width, size.height / below)
        ctx.draw(background, in: CGRect(x: (size.width - desk.width * fill) / 2, y: (size.height - below * fill) / 2,
                                        width: desk.width * fill, height: desk.height * fill))
        let frame = CGRect(x: margin, y: margin, width: w, height: h + titleBar)
        let shape = CGPath(roundedRect: frame, cornerWidth: 16, cornerHeight: 16, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor.black.withAlphaComponent(scheme == .dark ? 0.6 : 0.3).cgColor)
        ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        var bar = NSColor.windowBackgroundColor.cgColor
        scheme.appearance.performAsCurrentDrawingAppearance { bar = NSColor.windowBackgroundColor.cgColor }
        ctx.setFillColor(bar); ctx.fill(frame)
        ctx.draw(content, in: CGRect(x: margin, y: margin, width: w, height: h))
        ctx.restoreGState()
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: margin + 14 + CGFloat(i) * 20, y: frame.maxY - 20, width: 12, height: 12))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        scheme.appearance.performAsCurrentDrawingAppearance {
            let text = NSAttributedString(string: title, attributes: [.font: NSFont.titleBarFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
            text.draw(at: NSPoint(x: frame.midX - text.size().width / 2, y: frame.maxY - 21))
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.addPath(shape)
        ctx.setStrokeColor(NSColor(white: scheme == .dark ? 1 : 0, alpha: 0.14).cgColor)
        ctx.setLineWidth(1); ctx.strokePath()
        return ctx.makeImage()!
    }

    /// Replaces a fixture microphone row with a plausible built-in name;
    /// real device names never render.
    func scrubPopups(_ view: NSView) {
        for sub in view.subviews {
            if let popup = sub as? NSPopUpButton, let item = popup.selectedItem, item.title == "Microphone not connected" {
                item.title = "Mac default (MacBook Pro Microphone)"
                popup.synchronizeTitleAndSelectedItem()
            }
            scrubPopups(sub)
        }
    }

    func trimBottom(_ image: CGImage) -> CGImage {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return image }
        let row = image.bytesPerRow
        func same(_ y: Int) -> Bool {
            let base = y * row, last = (image.height - 1) * row
            for x in stride(from: 0, to: image.width * 4, by: 16) where abs(Int(bytes[base + x]) - Int(bytes[last + x])) > 3 { return false }
            return true
        }
        var y = image.height - 1
        while y > 200, same(y) { y -= 1 }
        let keep = min(image.height, y + 1 + Int(40 * writer.scale))
        return image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: keep)) ?? image
    }

    func windows() async throws {
        writer.declare("settings-window", title: "Settings window", area: "Windows",
                       summary: "The one Settings page (Listening, Replies, Doing things, Eye tracking, Permissions, General, Advanced) and the Activity page.",
                       sources: ["Sources/Jarvis/UI/SettingsView.swift:24", "Sources/Jarvis/UI/ContentView.swift:44", "Sources/Jarvis/UI/Components.swift:4"])
        let roster = FixtureRoster(list: [
            CompanionAgent(slug: "inbox-desk", name: "Inbox Desk", role: "Triage and summarise email", description: "",
                           workspacePath: "/tmp/fixture", codexHomePath: "/tmp/fixture",
                           routines: [Routine(everyMinutes: 60, task: "Summarise new mail")]),
            CompanionAgent(slug: "receipts", name: "Receipts", role: "File receipts into Expenses", description: "",
                           workspacePath: "/tmp/fixture", codexHomePath: "/tmp/fixture"),
        ])
        let cases: [(String, String, String?, Bool, [Permission], SettingsNavigation.Section, Bool)] = [
            ("settings-top", "Settings, as it opens", nil, false, [], .voice, false),
            ("settings-full", "Settings, whole page", "The whole scroll height in one image.", false, [], .voice, true),
            ("settings-eyes-on", "Eye tracking on", nil, true, [], .voice, true),
            ("settings-missing-permissions", "Permissions missing", nil, true, [.microphone, .camera, .accessibility], .voice, true),
            ("activity-empty", "Activity, nothing yet", nil, false, [], .activity, false),
            ("activity-feed", "Activity with history", nil, false, [], .activity, true),
        ]
        for (id, title, note, gaze, missing, section, tall) in cases {
            for scheme in Scheme.allCases {
                let config = Fixtures.config()
                config.gazeTracking = gaze
                let controller = Fixtures.controller(config, missing: missing)
                if id == "activity-feed" {
                    let feed = controller.cua.feed
                    feed.add(.heard, "Reply to Alex and say the deck is ready")
                    feed.add(.route, "Writing by instruction → Mail")
                    feed.add(.dispatch, "Type the reply into the message body")
                    feed.add(.verify, "The reply text is in the message body")
                    feed.add(.consent, "Asked before sending: Send the reply to Alex Rivera?")
                    feed.add(.outcome, "Sent")
                    feed.add(.error, "Keynote didn't open in 10 seconds")
                }
                let navigation = SettingsNavigation()
                navigation.section = section
                let agents = AgentsViewModel(roster: roster)
                await agents.refresh()
                let view = SettingsView(controller: controller, config: config, microphones: MicrophoneCatalog(), navigation: navigation)
                    .environmentObject(agents)
                let size = CGSize(width: 820, height: tall ? 2600 : 640)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                                      backing: .buffered, defer: true)
                window.appearance = scheme.appearance
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                spin(0.3)
                scrubPopups(host)
                host.layoutSubtreeIfNeeded()
                guard var image = WindowRenderer.cached(host, scale: writer.scale) else { failures.append("settings \(id)"); continue }
                if tall { image = trimBottom(image) }
                let shot = windowShot(image, title: "Jarvis", scheme: scheme)
                record({ try writer.still(shot, component: "settings-window", state: id, title: title,
                                          note: [note, "Rendered from the real SettingsView with a fixture Config and controller. A test build has no wake-word engine, so the Assistant name field (packaged app only) is absent."].compactMap { $0 }.joined(separator: " "),
                                          scheme: scheme, reduceMotion: false, backdrop: "window") }, "settings \(id)")
                record({ try writer.still(shot, component: "settings-window", state: id, title: title, scheme: scheme,
                                          reduceMotion: true, backdrop: "window") }, "settings \(id) rm")
                window.contentView = nil
            }
        }

        writer.declare("agents-window", title: "Agents window", area: "Windows",
                       summary: "Persistent helper agents: a roster on the left and a chat with the selected agent.",
                       sources: ["Sources/Jarvis/UI/AgentsView.swift:27", "Sources/Jarvis/UI/AgentChatView.swift:4"])
        for (id, title, list) in [("empty", "No agents yet", [CompanionAgent]()), ("roster", "Two agents", roster.list)] {
            for scheme in Scheme.allCases {
                let model = AgentsViewModel(roster: FixtureRoster(list: list))
                await model.refresh()
                guard let image = hosted(AgentsView(model: model), scheme: scheme, size: CGSize(width: 880, height: 560)) else {
                    failures.append("agents \(id)"); continue
                }
                let shot = windowShot(image, title: "Agents", scheme: scheme)
                for reduce in [false, true] {
                    record({ try writer.still(shot, component: "agents-window", state: id, title: title, scheme: scheme,
                                              reduceMotion: reduce, backdrop: "window") }, "agents \(id)")
                }
            }
        }
    }

    // MARK: First run

    func firstRun() {
        writer.declare("first-run", title: "First run", area: "Onboarding",
                       summary: "The setup window: how Jarvis listens, microphone, Accessibility, then try a command.",
                       sources: ["Sources/Jarvis/UI/FirstRun.swift:99", "Sources/Jarvis/UI/FirstRun.swift:259"])
        func model(_ configure: (FirstRunModel) -> Void) -> FirstRunModel {
            let m = FirstRunModel(policy: .current)
            m.microphoneGrant = { .notAsked }
            m.accessibilityGranted = { false }
            m.requestMicrophone = {}
            m.requestAccessibility = {}
            m.openSystemSettings = { _ in }
            configure(m)
            return m
        }
        func go(_ m: FirstRunModel, to step: FirstRunModel.Step) { while m.step != step, m.steps.last != m.step { m.advance() } }
        var cases: [(String, String, (Config) -> FirstRunModel)] = []
        cases.append(("listening", "How should Jarvis listen?", { _ in model { _ in } }))
        cases.append(("microphone", "Microphone, not asked", { _ in model { go($0, to: .microphone) } }))
        cases.append(("microphone-waiting", "Microphone, system prompt open", { _ in model { go($0, to: .microphone); $0.allow() } }))
        cases.append(("microphone-refused", "Microphone refused", { _ in model { $0.microphoneGrant = { .refused }; go($0, to: .microphone); $0.refresh() } }))
        cases.append(("accessibility", "Accessibility, not asked", { _ in model { go($0, to: .accessibility) } }))
        cases.append(("accessibility-waiting", "Accessibility, waiting", { _ in model { go($0, to: .accessibility); $0.allow() } }))
        cases.append(("try-it", "Try it", { _ in model { go($0, to: .tryIt) } }))
        cases.append(("try-it-done", "That worked", { _ in model { go($0, to: .tryIt); $0.applicationLaunched(bundleID: "com.apple.calculator") } }))
        for (id, title, make) in cases {
            for scheme in Scheme.allCases {
                let config = Fixtures.config()
                let m = make(config)
                spin(0.02)
                guard let image = hosted(FirstRunReplica(model: m, config: config), scheme: scheme, size: CGSize(width: 520, height: 440)) else {
                    failures.append("first run \(id)"); continue
                }
                let shot = windowShot(image, title: "Set up Jarvis", scheme: scheme)
                for reduce in [false, true] {
                    record({ try writer.still(shot, component: "first-run", state: id, title: title,
                                              note: "Harness replica of FirstRunView with the model injected (the real view owns a private @StateObject); the Listening step is checked against the real view.",
                                              scheme: scheme, reduceMotion: reduce, backdrop: "window") }, "first run \(id)")
                }
            }
        }
        let config = Fixtures.config()
        if let real = hosted(FirstRunView(config: config, finish: {}), scheme: .light, size: CGSize(width: 520, height: 440)),
           let replica = hosted(FirstRunReplica(model: FirstRunModel(listeningMode: config.listeningMode), config: config),
                                scheme: .light, size: CGSize(width: 520, height: 440)) {
            let result = Self.difference(real, replica)
            log.append("first run replica vs real (listening): \(result)")
            record({ try writer.still(windowShot(real, title: "Set up Jarvis", scheme: .light), component: "first-run", state: "listening-real",
                                      title: "How should Jarvis listen? (real view)", note: "The real FirstRunView. Replica check: \(result).",
                                      scheme: .light, reduceMotion: false, backdrop: "window") }, "first run real")
        }
    }

    // MARK: Combined scenes

    func scenes() {
        let mail = screen.mail
        let guide = step(2, of: 3, target: "send", instruction: "Click the Send button, at the top of the window.")
        let list: [(String, String, String, [String], () -> Void)] = [
            ("listening-gaze", "Listening while looking at Send", "\"Click that\" while the gaze ring sits on Send.",
             ["listening-indicator", "gaze-highlight"], { [self] in
                place(IndicatorReplica(fixture: IndicatorFixture(phase: .hearing, transcript: "Click that", level: 0.5, gazeTracking: true)))
                overlay.intentEvent(.acquire(candidate("send"))) }),
            ("guide-step", "Guide mode, step 2 of 3", "The tab counts the step, the ring marks the control, the callout says what to do.",
             ["listening-indicator", "gaze-highlight", "guide-callout"], { [self] in
                place(IndicatorReplica(fixture: IndicatorFixture(phase: .working, guideStep: guide)))
                overlay.intentEvent(.acquire(candidate("send")))
                overlay.guideCallout.show(guide) }),
            ("double-highlight", "Halo and ring at once", "While you speak, the listening halo and the scorer's ring can mark two different things.",
             ["listening-indicator", "listening-halo", "gaze-highlight"], { [self] in
                place(IndicatorReplica(fixture: IndicatorFixture(phase: .hearing, transcript: "Click", partialLive: true, level: 0.4, gazeTracking: true)))
                overlay.showHalo(frame: mail.target("attach"))
                overlay.intentEvent(.acquire(candidate("send"))) }),
            ("ambiguity", "Which one?", "Ambiguous gaze: the radial fans out and the tab asks.",
             ["listening-indicator", "target-chips"], { [self] in
                place(IndicatorReplica(fixture: IndicatorFixture(phase: .asking, ask: .question("Which one: Send, Attach or Format?"))))
                let s = mail.target("send")
                overlay.showRadial(labels: ["Send", "Attach", "Format"], near: CGPoint(x: s.midX + 30, y: s.midY), radius: 60) { _ in } }),
            ("numbers", "Show numbers", "Number chips on every target while Jarvis listens for a number.",
             ["listening-indicator", "target-chips"], { [self] in
                place(IndicatorReplica(fixture: IndicatorFixture(phase: .hearing, transcript: "Show numbers", level: 0.3)))
                overlay.showNumbers(targets: ["send", "attach", "format", "photo", "To:", "Subject:", "later", "sendBottom"].map { (mail.target($0), $0) }) { _ in } }),
            ("agents-working", "Agents working while you write", "Two agents act; the shelf lists them and the tab shows Jarvis's own task.",
             ["listening-indicator", "agent-shelf", "agent-cursor", "confirm-flash"], { [self] in
                place(IndicatorReplica(fixture: IndicatorFixture(phase: .working, workLabel: "Filing 14 receipts")))
                AgentShelfOverlay.shared.update([
                    .init(slug: "inbox-desk", name: "Inbox Desk", colorHex: AgentCursor.palette(for: "inbox-desk"), state: .acting),
                    .init(slug: "receipts", name: "Receipts", colorHex: AgentCursor.palette(for: "receipts"), state: .asking)],
                    displayTopLeft: CGRect(origin: .zero, size: screen.desktop.size))
                let p = mail.target("format")
                cursorLabels.show(AgentCursor(agentSlug: "inbox-desk", label: "Inbox Desk", colorHex: AgentCursor.palette(for: "inbox-desk")),
                                  at: NSPoint(x: p.midX, y: VirtualScreen.primaryHeight - p.midY))
                let b = mail.target("sendBottom")
                overlay.flash(at: CGPoint(x: b.midX, y: b.midY)) }),
            ("problem", "Something went wrong", "The problem card over a working desktop.",
             ["listening-indicator"], { [self] in
                place(IndicatorReplica(fixture: IndicatorFixture(phase: .problem, problem: "I couldn't reach OpenAI just now.",
                                                                 detail: "Check your internet connection, then try again.", canOpenSettings: true))) }),
            ("cheat-sheet", "What can I say?", "The cheat sheet while the tab listens.",
             ["listening-indicator", "cheat-sheet"], { [self] in
                place(IndicatorReplica(fixture: IndicatorFixture(phase: .hearing, transcript: "What can I say", level: 0.3)))
                overlay.showSheet(lines: VoiceTaskCoordinator.cheatSheet(gaze: true)) }),
        ]
        for (id, title, summary, components, setup) in list {
            for scheme in Scheme.allCases {
                reset(reduceMotion: false)
                setup()
                stamp(0)
                let image = screen.compose(scheme, clock: clock, time: id == "agents-working" ? 0.12 : 5)
                record({ try writer.scene(image, id: scheme == .dark ? id : "\(id)-light", title: scheme == .dark ? title : "\(title) (light)",
                                          summary: summary, components: components, scheme: scheme) }, "scene \(id)")
            }
        }
        // One scene with motion: the ring follows the eyes from Send to the bottom Send while the tab listens.
        reset(reduceMotion: false)
        let send = candidate("send"), bottom = candidate("sendBottom")
        var frames: [ClipFrame] = []
        var actions: [(Double, () -> Void)] = [
            (0.0, { [self] in place(IndicatorReplica(fixture: IndicatorFixture(phase: .hearing, transcript: "Click that", level: 0.5, gazeTracking: true))) }),
            (0.2, { [self] in overlay.intentEvent(.acquire(send)) }),
            (0.8, { [self] in overlay.intentEvent(.acquire(bottom)) }),
            (1.4, { [self] in overlay.intentEvent(.release(bottom)) }),
        ]
        var t = 0.0
        let crop = CGRect(x: mail.frame.minX - 60, y: 0, width: mail.frame.width + 120, height: mail.frame.maxY + 40)
        while t <= 1.7 {
            while let next = actions.first, next.0 <= t + 1e-9 { actions.removeFirst(); next.1(); stamp(next.0) }
            frames.append(ClipFrame(time: t, image: screen.compose(.dark, clock: clock, time: t, crop: crop)))
            t += 1.0 / 60
        }
        let still = screen.compose(.dark, clock: clock, time: 1.0)
        record({ try writer.scene(still, id: "gaze-glide", title: "The ring follows your eyes", summary: "Acquire, glide to the next control, release, while the tab listens.",
                                  components: ["listening-indicator", "gaze-highlight"], clip: frames, scheme: .dark) }, "scene glide")
        reset(reduceMotion: false)
    }
}
