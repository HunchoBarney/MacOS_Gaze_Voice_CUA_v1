import AppKit
import JarvisRedesign
import SwiftUI

// Renders the redesign's clips and stills offscreen (Lab/README.md).
//   JarvisRedesignRender probe <dir>       a few stills from the voice flow
//   JarvisRedesignRender render <out>      every component, state and flow

@MainActor
func probe(_ out: String, component: String) throws {
    guard let entry = Redesign.components.first(where: { $0.id == component }) else { return }
    for d in entry.directions.indices {
        let stage = Stage(entry, direction: d)
        stage.playFlow()
        let renderer = ImageRenderer(content: StageView(stage: stage))
        renderer.scale = 2
        var t = 0.0
        var shot = 0
        let total = stage.flowDuration
        let marks = stride(from: 0.4, to: total, by: total / 10).map { $0 }
        while t < total, shot < marks.count {
            stage.advance(1.0 / 60)
            t += 1.0 / 60
            if t >= marks[shot] {
                renderer.content = StageView(stage: stage)
                if let image = renderer.cgImage {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: out + "/\(component)-\(entry.directions[d].info.id)-\(shot)-\(stage.state.id).png"))
                }
                shot += 1
            }
        }
    }
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    let args = CommandLine.arguments
    do {
        switch args.dropFirst().first {
        case "probe": try probe(args[2], component: args.count > 3 ? args[3] : "voice-island")
        default: print("usage: JarvisRedesignRender probe <dir> [component]")
        }
    } catch {
        print("error: \(error)")
        exit(1)
    }
}
