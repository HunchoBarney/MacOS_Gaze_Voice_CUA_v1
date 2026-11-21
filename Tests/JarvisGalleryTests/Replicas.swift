import AppKit
import SwiftUI
@testable import Jarvis

// Harness replicas for surfaces whose real view reads private state that a
// test can't set (VoiceController's private(set) status, FirstRunView's
// private @StateObject) or that only the window server draws (NSMenu,
// NSStatusItem). Each copies its source's view code line for line, with
// the controller reads swapped for fixture values; GalleryRenderTests
// checks the indicator and first-run replicas pixel for pixel against the
// real views in the states the harness can reach, so drift shows up.

/// ListeningIndicator.swift:65-254 with fixture inputs.
struct IndicatorFixture {
    enum Ask { case review(String), confirm(String), answer(String), approval(String), question(String) }
    var phase: IndicatorPhase
    var transcript = ""
    var partialLive = false
    var level: Float = 0
    var workLabel = ""
    var guideStep: GuideStep?
    var gazeTracking = false
    var ask: Ask?
    var problem = ""
    var detail = ""
    var canOpenSettings = false
    var notice = ""
}

struct IndicatorReplica: View {
    let fixture: IndicatorFixture
    private var phase: IndicatorPhase { fixture.phase }
    private var guideStep: GuideStep? { phase == .working ? fixture.guideStep : nil }

    private var line: String {
        switch phase {
        case .hearing:
            return fixture.transcript.isEmpty ? "Listening" : fixture.transcript
        case .working:
            if let guideStep { return GuideTab.counter(guideStep) }
            let label = fixture.workLabel
            return (label.isEmpty ? "Working" : label) + "…"
        case .asking:
            if case .review = fixture.ask { return "Is this right?" }
            return "Which one?"
        case .problem:
            return "Something went wrong"
        case .notice:
            return fixture.notice
        case .hidden:
            return ""
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            tab
            if phase == .asking { askCard }
            if phase == .problem { problemCard }
        }
        .fixedSize()
        .colorScheme(.dark)
    }

    private var tab: some View {
        HStack(spacing: 9) {
            switch phase {
            case .hearing:
                LevelMeter(level: fixture.level)
            case .working:
                Image(systemName: "ellipsis").foregroundStyle(Color(red: 0.48, green: 0.64, blue: 1))
            case .asking:
                Image(systemName: "questionmark.circle").foregroundStyle(Color(red: 0.73, green: 0.61, blue: 1))
            case .problem:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
            case .notice:
                Image(systemName: "info.circle").foregroundStyle(.white.opacity(0.75))
            case .hidden:
                EmptyView()
            }
            Text(line)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(fixture.partialLive ? 0.75 : 1))
                .lineLimit(phase == .notice ? 3 : 1)
                .truncationMode(phase == .notice ? .tail : .head)
                .frame(width: phase == .notice ? 420 : nil, alignment: .leading)
                .frame(maxWidth: 440, alignment: .leading)
            if fixture.gazeTracking {
                Image(systemName: "eye").font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
            }
            if guideStep != nil {
                HStack(spacing: 6) {
                    ForEach(GuideTab.buttons, id: \.title) { button in
                        Button(button.title) {}
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 26)
                            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                            .fixedSize()
                    }
                }
            } else if phase == .working {
                Button {} label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, phase == .notice ? 8 : 0)
        .frame(minWidth: 150, minHeight: 34)
        .background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
    }

    private var problemCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(fixture.problem).font(.system(size: 15)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if !fixture.detail.isEmpty, fixture.detail != fixture.problem {
                Text(OutcomeWording.readable(fixture.detail)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if fixture.canOpenSettings {
                    Button("Open Settings") {}.buttonStyle(.borderedProminent)
                }
                Button("Dismiss") {}.keyboardShortcut(.cancelAction)
                Spacer()
            }
            .controlSize(.large)
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
    }

    private var askCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch fixture.ask {
            case .review(let text):
                prompt(text)
                buttons(primary: "Continue", secondary: "Cancel")
            case .confirm(let text):
                prompt(text)
                buttons(primary: "Go ahead", secondary: "Cancel")
            case .answer(let question):
                prompt(question)
                buttons(primary: nil, secondary: "Cancel")
            case .approval(let text):
                prompt(text)
                buttons(primary: "Go ahead", secondary: "Cancel")
            case .question(let text):
                prompt(text)
            case nil:
                EmptyView()
            }
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
    }

    private func prompt(_ text: String) -> some View {
        Text(text).font(.system(size: 15)).foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func buttons(primary: String?, secondary: String) -> some View {
        HStack {
            if let primary { Button(primary) {}.buttonStyle(.borderedProminent) }
            Button(secondary) {}.keyboardShortcut(.cancelAction)
            Spacer()
        }
        .controlSize(.large)
    }
}

/// FirstRun.swift:99-300 with the model injected instead of owned, so
/// every step and grant can be shown. Probes never touch the system.
struct FirstRunReplica: View {
    @ObservedObject var model: FirstRunModel
    @ObservedObject var config: Config

    private var title: String {
        switch model.step {
        case .listening: return "How should Jarvis listen?"
        case .standbyIntro: return "Jarvis listens for “Hey \(config.assistantName)”"
        case .microphone: return "Let Jarvis hear you"
        case .accessibility: return "Let Jarvis use your Mac"
        case .tryIt: return model.triedIt ? "That worked" : "Try it"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let position = model.position {
                Text("Step \(position.number) of \(position.of)")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.bottom, 10)
            }
            content
            Spacer(minLength: 24)
            footer
        }
        .padding(32)
        .frame(width: 520, height: 440, alignment: .topLeading)
    }

    @ViewBuilder private var content: some View {
        Text(title).font(.system(size: 26, weight: .semibold)).padding(.bottom, 12)
        switch model.step {
        case .listening:
            VStack(spacing: 10) {
                ForEach(model.policy.offeredModes, id: \.self) { mode in
                    ListeningChoiceReplica(mode: mode, name: config.assistantName,
                                           recommended: mode == model.policy.defaultMode,
                                           selected: model.listeningMode == mode)
                }
            }
            if model.listeningMode == .standby {
                AssistantNameField(config: config).padding(.top, 12)
            }
            Text(model.listeningMode.disclosure(name: config.assistantName))
                .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        case .standbyIntro:
            HStack(spacing: 10) {
                Circle().fill(Color.orange).frame(width: 12, height: 12)
                Text("This orange dot in the menu bar means the microphone is on.")
                    .font(.system(size: 15))
            }
            .padding(.bottom, 8)
            paragraph("Jarvis listens on your Mac for “Hey \(config.assistantName)”. Nothing leaves your Mac until you say it.")
        case .microphone:
            switch model.microphone {
            case .refused:
                paragraph("Jarvis can't hear you yet. In System Settings, open Privacy & Security, then Microphone, and switch on Jarvis.")
            case .waiting:
                paragraph("Choose Allow in the box that just opened.")
            case .notAsked, .granted:
                paragraph("Jarvis needs the microphone to hear what you ask.")
            }
        case .accessibility:
            switch model.accessibility {
            case .waiting, .refused:
                paragraph("In System Settings, switch on Jarvis in the Accessibility list. This page moves on by itself when you do.")
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to switch it on…").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .padding(.top, 10)
            case .notAsked, .granted:
                paragraph("To click, type and open apps for you, Jarvis needs Accessibility. macOS will ask you to switch it on in System Settings.")
            }
        case .tryIt:
            if model.triedIt {
                paragraph("You're all set. Say “help” any time to hear what Jarvis can do.")
            } else {
                paragraph(config.handsFreeEnabled
                     ? "Say “Open Calculator”."
                     : "Say “Hey \(config.assistantName), open Calculator”.")
                if config.handsFreeEnabled {
                    paragraph("Jarvis is listening now. If you'd rather it waited for “Hey \(config.assistantName)”, change that in Settings.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).font(.system(size: 15)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var footer: some View {
        HStack {
            switch model.step {
            case .microphone where model.microphone == .refused:
                Button("Check again") {}
                Spacer()
                Button("Open System Settings") {}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .accessibility where model.accessibility != .notAsked:
                Button("Check again") {}
                Spacer()
                Button("Open System Settings") {}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .tryIt:
                if !model.triedIt { Button("Skip") {} }
                Spacer()
                Button("Done") {}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .listening, .standbyIntro:
                Spacer()
                Button("Continue") {}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            default:
                Button("Not now") {}
                Spacer()
                Button("Allow") {}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }
}

/// FirstRun.swift:259-300.
private struct ListeningChoiceReplica: View {
    let mode: ListeningMode
    let name: String
    let recommended: Bool
    let selected: Bool

    var body: some View {
        Button {} label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(mode.title(name: name)).font(.system(size: 16, weight: .semibold))
                        if recommended {
                            Text("Recommended")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                        }
                    }
                    Text(mode.detail).font(.system(size: 14)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(selected ? Color.accentColor.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.35),
                              lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// The status-bar menu as main.swift:64-98, :532-575 and :598-600 build it. NSMenu
/// draws only through the window server, so this is a drawn replica of a
/// macOS 26 menu with the real titles and visibility rules.
struct MenuReplica: View {
    struct Item: Hashable {
        var title: String
        var key = ""
        var enabled = true
        var separator = false
    }

    let items: [Item]

    static func items(eyes: String, paused: Bool, stoppable: Bool) -> [Item] {
        var items = [Item(title: "Settings…", key: "⌘,"), Item(title: "Activity"), Item(title: "Agents"),
                     Item(title: paused ? "Resume Listening" : "Pause Listening")]
        if stoppable { items.append(Item(title: "Stop")) }
        items.append(Item(title: "", separator: true))
        switch eyes {
        case "running":
            items += [Item(title: "Eyes — Tracking", enabled: false), Item(title: "Pause Tracking"),
                      Item(title: "Recalibrate")]
        case "failed":
            items += [Item(title: "Eyes — Stopped (camera is in use by another app)", enabled: false),
                      Item(title: "Restart Eye Tracking")]
        default:
            items += [Item(title: "Eyes — Off", enabled: false), Item(title: "Enable Eye Tracking")]
        }
        items += [Item(title: "Eye Tracking Settings…"), Item(title: "", separator: true),
                  Item(title: "Export Logs…"), Item(title: "", separator: true), Item(title: "Quit Jarvis", key: "⌘Q")]
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if item.separator {
                    Divider().padding(.horizontal, 10).padding(.vertical, 5)
                } else {
                    HStack {
                        Text(item.title).foregroundStyle(item.enabled ? Color.primary : Color.secondary)
                        Spacer(minLength: 28)
                        Text(item.key).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 14)
                    .frame(height: 24)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// The status item (main.swift:556-574): an SF Symbol template image in
/// the menu bar plus the parked-ask badge text.
struct StatusItemReplica: View {
    let symbol: String
    var badge = 0

    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: symbol).font(.system(size: 14, weight: .regular))
            if badge > 0 { Text(" ·\(badge)").font(.system(size: 13)) }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
    }
}
