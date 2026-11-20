import AppKit
import Combine
import SwiftUI

/// The large on-screen safety card used instead of speech during a call,
/// a screen share, a presentation or Focus. It never takes focus.
@MainActor
final class ProactiveCardPanel {
    private let engine: ProactiveEngine
    private var panel: NSPanel?
    private var subscription: AnyCancellable?

    init(engine: ProactiveEngine) {
        self.engine = engine
        subscription = engine.$card.sink { [weak self] card in
            if let card { self?.show(card) } else { self?.hide() }
        }
    }

    /// The panel's content for one card, sized from that card. `$card`
    /// publishes before `engine.card` changes, so the view is built from
    /// the published value rather than read back from the engine.
    static func content(for card: ProactiveAlert, dismiss: @escaping @MainActor () -> Void) -> NSHostingView<ProactiveCardView> {
        let view = NSHostingView(rootView: ProactiveCardView(card: card, dismiss: dismiss))
        view.setFrameSize(view.fittingSize)
        return view
    }

    private func show(_ card: ProactiveAlert) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let screen = NSScreen.main else { return }
        let content = Self.content(for: card) { [weak engine = self.engine] in engine?.dismissCard() }
        panel.contentView = content
        let size = content.frame.size
        let frame = screen.visibleFrame
        panel.setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 48,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

struct ProactiveCardView: View {
    let card: ProactiveAlert
    let dismiss: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Safety warning", systemImage: "exclamationmark.shield.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
            Text(card.sentence)
                .font(.system(size: 22, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Dismiss") { dismiss() }
                    .controlSize(.large)
            }
        }
        .padding(22)
        .frame(width: 480, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Jarvis safety warning: \(card.sentence)")
    }
}
