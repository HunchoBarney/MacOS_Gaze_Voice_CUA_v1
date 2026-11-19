import AppKit
import SwiftUI

@MainActor
final class HandsFreeIndicator {
    enum State: CaseIterable, Equatable {
        case notReady, starting, listening, processing, paused, unavailable

        @MainActor static func current(_ controller: VoiceController, obscured: Bool = false) -> Self? {
            resolve(controller.handsFreeState, enabled: controller.handsFreeEnabled,
                    userPaused: controller.config.handsFreePaused,
                    microphoneReady: controller.microphoneReady && !controller.missingPermissions.contains(.microphone),
                    processing: controller.quietHandsFreePresentation && (controller.status == .thinking || controller.status == .executing),
                    obscured: obscured || controller.isMicrophoneTest || controller.captureState != .idle)
        }

        static func resolve(_ conversation: ConversationListeningState, enabled: Bool,
                            userPaused: Bool, microphoneReady: Bool, processing: Bool,
                            obscured: Bool) -> Self? {
            guard enabled, !obscured else { return nil }
            if userPaused { return .paused }
            switch conversation {
            case .off: return .notReady
            case .preparing: return .starting
            case .listening: return microphoneReady ? (processing ? .processing : .listening) : .notReady
            case .paused: return .paused
            case .unavailable: return .unavailable
            }
        }

        var title: String {
            switch self {
            case .notReady: return "Not ready"
            case .starting: return "Starting"
            case .listening: return "Listening"
            case .processing: return "Processing"
            case .paused: return "Paused"
            case .unavailable: return "Unavailable"
            }
        }

        var symbol: String {
            switch self {
            case .notReady: return "mic.slash"
            case .starting: return "mic"
            case .listening: return "waveform"
            case .processing: return "ellipsis"
            case .paused: return "pause.fill"
            case .unavailable: return "exclamationmark.triangle"
            }
        }

        var tint: Color {
            switch self {
            case .notReady, .paused: return Color(red: 0.71, green: 0.76, blue: 0.83)
            case .starting, .processing: return Color(red: 0.68, green: 0.78, blue: 1)
            case .listening: return Color(red: 0.53, green: 0.89, blue: 0.78)
            case .unavailable: return Color(red: 1, green: 0.79, blue: 0.50)
            }
        }
    }

    private final class StatusPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    nonisolated static let size = CGSize(width: 114, height: 26)
    private var displayed: State?
    private lazy var panel: StatusPanel = {
        let panel = StatusPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Jev Voice Status"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        return panel
    }()

    func update(_ state: State?) {
        guard displayed != state else { return }
        displayed = state
        guard let state else {
            panel.orderOut(nil)
            return
        }
        panel.contentView = NSHostingView(rootView: Badge(state: state))
        refreshPlacement()
    }

    func refreshPlacement() {
        guard displayed != nil else { return }
        guard let screen = NSScreen.screens.first, let frame = Self.frame(in: screen.visibleFrame) else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    nonisolated static func frame(in visibleFrame: CGRect) -> CGRect? {
        let inset: CGFloat = 12
        guard visibleFrame.width >= size.width + 2 * inset,
              visibleFrame.height >= size.height + 2 * inset else { return nil }
        return CGRect(x: visibleFrame.maxX - size.width - inset, y: visibleFrame.minY + inset,
                      width: size.width, height: size.height)
    }

    struct Badge: View {
        let state: State

        var body: some View {
            HStack(spacing: 7) {
                Image(systemName: state.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(state.tint)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(state.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .accessibilityLabel("Jev Voice: \(state.title)")
            }
            .padding(.horizontal, 10)
            .frame(width: HandsFreeIndicator.size.width, height: HandsFreeIndicator.size.height, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(red: 0.13, green: 0.15, blue: 0.20))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color(red: 0.46, green: 0.51, blue: 0.60))
            }
            .allowsHitTesting(false)
        }
    }
}
