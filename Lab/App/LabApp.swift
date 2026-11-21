import JarvisRedesign
import SwiftUI

/// The internal tuning tool: every redesigned component, each direction live
/// on the fixture desktop, with the same stage the clip renderer uses.
struct LabApp: App {
    var body: some Scene {
        WindowGroup("Jarvis UI Lab") {
            LabView()
                .frame(minWidth: 1100, minHeight: 640)
        }
    }
}

@MainActor
final class LabModel: ObservableObject {
    @Published var componentIndex = 0 { didSet { rebuild() } }
    @Published var direction = 0 { didSet { stage.select(direction: direction) } }
    @Published var speed = 1.0
    @Published var paused = false
    @Published var scheme: ColorScheme = .dark { didSet { stage.scheme = scheme } }
    @Published var reduceMotion = false { didSet { stage.reduceMotion = reduceMotion } }
    @Published var reduceTransparency = false { didSet { stage.reduceTransparency = reduceTransparency } }
    @Published private(set) var stage: Stage
    private var last: Date?

    init() { stage = Stage(Redesign.components[0]) }

    var component: ComponentEntry { Redesign.components[componentIndex] }

    func rebuild() {
        stage = Stage(component, direction: min(direction, component.directions.count - 1))
        stage.scheme = scheme
        stage.reduceMotion = reduceMotion
        stage.reduceTransparency = reduceTransparency
    }

    func tick(_ now: Date) {
        defer { last = now }
        guard let last, !paused else { return }
        stage.advance(min(1.0 / 20, now.timeIntervalSince(last)) * speed)
    }

    func step(_ delta: Int) {
        stage.stopFlow()
        stage.go(to: (stage.stateIndex + delta + component.states.count) % component.states.count)
    }
}

struct LabView: View {
    @StateObject private var model = LabModel()

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.componentIndex }, set: { model.componentIndex = $0 ?? 0 })) {
                ForEach(Array(Redesign.components.enumerated()), id: \.offset) { index, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                        Text("Batch \(entry.batch)").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(index)
                }
            }
            .navigationSplitViewColumnWidth(220)
        } detail: {
            VStack(spacing: 0) {
                toolbar
                Divider()
                TimelineView(.animation(paused: model.paused)) { context in
                    let _ = model.tick(context.date)
                    GeometryReader { proxy in
                        let crop = model.component.crop
                        let scale = min(proxy.size.width / crop.width, proxy.size.height / crop.height)
                        StageView(stage: model.stage)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: crop.width * scale, height: crop.height * scale, alignment: .topLeading)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(16)
                Divider()
                info
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Picker("Direction", selection: $model.direction) {
                ForEach(Array(model.component.directions.enumerated()), id: \.offset) { index, d in
                    Text("\(d.info.id) \(d.info.name)").tag(index)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            Button { model.step(-1) } label: { Image(systemName: "chevron.left") }.keyboardShortcut(.leftArrow, modifiers: [])
            Text(model.stage.state.title).frame(minWidth: 120)
            Button { model.step(1) } label: { Image(systemName: "chevron.right") }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("Play flow") { model.stage.playFlow() }.keyboardShortcut("f", modifiers: [])
            Button { model.paused.toggle() } label: { Image(systemName: model.paused ? "play.fill" : "pause.fill") }
                .keyboardShortcut(.space, modifiers: [])
            Picker("Speed", selection: $model.speed) {
                Text("1×").tag(1.0)
                Text("½×").tag(0.5)
                Text("¼×").tag(0.25)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            Spacer()
            Picker("Appearance", selection: $model.scheme) {
                Text("Dark").tag(ColorScheme.dark)
                Text("Light").tag(ColorScheme.light)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            Toggle("Reduce Motion", isOn: $model.reduceMotion)
            Toggle("Reduce Transparency", isOn: $model.reduceTransparency)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var info: some View {
        let d = model.stage.info
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(d.id) · \(d.name): \(d.axis)").font(.headline)
            Text(d.pitch)
            Text("Cost: \(d.cost)").foregroundStyle(.secondary)
            Text("Libraries: " + d.libraries.map { "\($0.name) \($0.version)" }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
            Text(model.stage.state.caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}
