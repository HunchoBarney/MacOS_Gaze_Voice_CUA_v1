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
            card == nil ? self?.hide() : self?.show()
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let screen = NSScreen.main else { return }
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? CGSize(width: 480, height: 160)
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
        panel.contentView = NSHostingView(rootView: ProactiveCardView(engine: engine))
        return panel
    }
}

struct ProactiveCardView: View {
    @ObservedObject var engine: ProactiveEngine

    var body: some View {
        if let card = engine.card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Safety warning", systemImage: "exclamationmark.shield.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(card.sentence)
                    .font(.system(size: 22, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Dismiss", action: engine.dismissCard)
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
}
