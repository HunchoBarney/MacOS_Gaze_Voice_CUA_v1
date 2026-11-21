import AppKit
import JarvisRedesign
import SwiftUI

// Renders the redesign's clips and stills offscreen (Lab/README.md).
//   JarvisRedesignRender probe <dir> [component]   ten stills from each direction's flow
//   JarvisRedesignRender render <renders-dir> [--only a,b] [--variants dark,light] [--scale 1.5] [--fps 60]
// render writes <renders-dir>/redesign/<component>/<direction>/<state>.<variant>.mp4 with a
// .jpg poster, and manifest.redesign.native.json, which gallery/site/scripts/collect.mjs merges.

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
                    try writePNG(image, to: URL(fileURLWithPath: out + "/\(component)-\(entry.directions[d].info.id)-\(shot)-\(stage.state.id).png"))
                }
                shot += 1
            }
        }
    }
}

struct Variant {
    var key: String
    var scheme: ColorScheme
    var reduceMotion: Bool
}

let allVariants = [Variant(key: "dark", scheme: .dark, reduceMotion: false), Variant(key: "light", scheme: .light, reduceMotion: false),
                   Variant(key: "dark-rm", scheme: .dark, reduceMotion: true), Variant(key: "light-rm", scheme: .light, reduceMotion: true)]

struct Options {
    var out = URL(fileURLWithPath: "build/gallery/renders")
    var only: Set<String>?
    var variants = allVariants
    var scale: CGFloat = 1.5
    var fps = 60.0
}

/// Renders `seconds` of the stage into one MP4 and its poster (the last frame).
@MainActor
func clip(_ stage: Stage, seconds: Double, options: Options, mp4: URL, poster: URL) throws {
    let renderer = ImageRenderer(content: StageView(stage: stage))
    renderer.scale = options.scale
    let size = stage.component.crop.size
    let writer = try ClipWriter(url: mp4, width: Int(size.width * options.scale), height: Int(size.height * options.scale), fps: options.fps)
    let count = Int((seconds * options.fps).rounded())
    var last: CGImage?
    for i in 0..<count {
        if i > 0 { stage.advance(1 / options.fps) }
        renderer.content = StageView(stage: stage)
        guard let image = renderer.cgImage else { throw RenderError("no frame \(i) for \(mp4.lastPathComponent)") }
        try writer.append(image)
        last = image
    }
    try writer.finish()
    if let last { try writeJPEG(last, to: poster) }
}

/// The state a state's clip starts from: the one before it in the flow.
@MainActor
func predecessor(of id: String, in entry: ComponentEntry) -> String? {
    let flow = entry.flow
    if let i = flow.firstIndex(of: id) { return i > 0 ? flow[i - 1] : (flow.count > 1 ? flow[flow.count - 2] : nil) }
    return flow.count > 1 ? flow[flow.count / 2] : nil
}

@MainActor
func render(_ options: Options) throws {
    let lead = 0.35
    let started = Date()
    for entry in Redesign.components where options.only?.contains(entry.id) ?? true {
        for d in entry.directions.indices {
            let dir = entry.directions[d].info.id
            for variant in options.variants {
                for (index, state) in entry.states.enumerated() {
                    let stage = Stage(entry, direction: d)
                    stage.scheme = variant.scheme
                    stage.reduceMotion = variant.reduceMotion
                    let from = predecessor(of: state.id, in: entry).flatMap { entry.index(of: $0) } ?? index
                    stage.settle(at: from)
                    let base = options.out.appendingPathComponent("redesign/\(entry.id)/\(dir)/\(state.id).\(variant.key)")
                    let stageRef = stage
                    let switchAt = lead
                    // Hold the previous state briefly, then change state live so the clip shows the transition.
                    var switched = false
                    let renderer = ImageRenderer(content: StageView(stage: stage))
                    renderer.scale = options.scale
                    let size = entry.crop.size
                    let writer = try ClipWriter(url: base.appendingPathExtension("mp4"), width: Int(size.width * options.scale),
                                                height: Int(size.height * options.scale), fps: options.fps)
                    let count = Int(((lead + state.duration) * options.fps).rounded())
                    var last: CGImage?
                    for i in 0..<count {
                        if i > 0 { stageRef.advance(1 / options.fps) }
                        if !switched, Double(i) / options.fps >= switchAt {
                            stageRef.go(to: index)
                            stageRef.advance(0)
                            switched = true
                        }
                        renderer.content = StageView(stage: stageRef)
                        guard let image = renderer.cgImage else { throw RenderError("no frame for \(base.lastPathComponent)") }
                        try writer.append(image)
                        if i == Int(((lead + state.duration * 0.6) * options.fps).rounded()) { last = image }
                    }
                    try writer.finish()
                    if let last { try writeJPEG(last, to: base.appendingPathExtension("jpg")) }
                }
                let stage = Stage(entry, direction: d)
                stage.scheme = variant.scheme
                stage.reduceMotion = variant.reduceMotion
                if let first = entry.flow.first.flatMap({ entry.index(of: $0) }) { stage.settle(at: first) }
                stage.playFlow()
                let base = options.out.appendingPathComponent("redesign/\(entry.id)/\(dir)/flow.\(variant.key)")
                try clip(stage, seconds: stage.flowDuration, options: options, mp4: base.appendingPathExtension("mp4"),
                         poster: base.appendingPathExtension("jpg"))
                print("rendered \(entry.id) \(dir) \(variant.key) at \(Int(Date().timeIntervalSince(started)))s")
            }
        }
    }
    if options.only == nil || options.only?.contains("scenes") == true { try renderScenes(options) }
    try writeManifest(options)
}

@MainActor
func renderScenes(_ options: Options) throws {
    for scene in Scenes.all {
        for variant in options.variants {
            let stage = SceneStage(scene, scheme: variant.scheme, reduceMotion: variant.reduceMotion)
            let base = options.out.appendingPathComponent("redesign/scenes/\(scene.id).\(variant.key)")
            let renderer = ImageRenderer(content: stage.view())
            renderer.scale = options.scale
            let writer = try ClipWriter(url: base.appendingPathExtension("mp4"), width: Int(Desk.size.width * options.scale),
                                        height: Int(Desk.size.height * options.scale), fps: options.fps)
            var poster: CGImage?
            let count = Int((scene.duration * options.fps).rounded())
            for i in 0..<count {
                if i > 0 { stage.advance(1 / options.fps) }
                renderer.content = stage.view()
                guard let image = renderer.cgImage else { throw RenderError("no frame for \(base.lastPathComponent)") }
                try writer.append(image)
                if abs(stage.time - 9.0) < 0.5 / options.fps { poster = image }
            }
            try writer.finish()
            if let poster { try writeJPEG(poster, to: base.appendingPathExtension("jpg")) }
            print("rendered scene \(scene.id) \(variant.key)")
        }
    }
}

@MainActor
func writeManifest(_ options: Options) throws {
    let fm = FileManager.default
    func mediaSet(_ path: String, crop: CGRect, duration: Double) -> [String: Any] {
        var set: [String: Any] = [:]
        for variant in allVariants {
            let src = "\(path).\(variant.key).mp4"
            guard fm.fileExists(atPath: options.out.appendingPathComponent(src).path) else { continue }
            set[variant.key] = ["kind": "clip", "src": src, "poster": "\(path).\(variant.key).jpg",
                                "width": Int(crop.width), "height": Int(crop.height), "fps": Int(options.fps),
                                "duration": (duration * 100).rounded() / 100]
        }
        return set
    }
    let perfURL = URL(fileURLWithPath: "Lab/perf.json")
    let perf = (try? JSONSerialization.jsonObject(with: Data(contentsOf: perfURL))) as? [String: [String: [String: String]]] ?? [:]
    var components: [[String: Any]] = []
    for entry in Redesign.components {
        var directions: [[String: Any]] = []
        for direction in entry.directions {
            let info = direction.info
            let root = "redesign/\(entry.id)/\(info.id)"
            var d: [String: Any] = [
                "id": info.id, "name": info.name, "axis": info.axis, "pitch": info.pitch, "cost": info.cost,
                "libraries": info.libraries.map { ["name": $0.name, "version": $0.version, "license": $0.license, "url": $0.url, "role": $0.role] },
                "custom": info.custom,
                "skills": info.skills.map { ["skill": $0.skill, "change": $0.change] },
                "states": entry.states.map { state in
                    ["id": state.id, "title": state.title, "caption": state.caption,
                     "media": mediaSet("\(root)/\(state.id)", crop: entry.crop, duration: 0.35 + state.duration)] as [String: Any]
                },
            ]
            let flowDuration = entry.flow.compactMap { entry.index(of: $0) }.reduce(0) { $0 + entry.states[$1].duration }
            let flow = mediaSet("\(root)/flow", crop: entry.crop, duration: flowDuration)
            if !flow.isEmpty { d["flow"] = flow }
            if let p = perf[entry.id]?[info.id] { d["perf"] = p }
            directions.append(d)
        }
        components.append(["id": entry.id, "batch": entry.batch, "title": entry.title, "summary": entry.summary,
                           "current": ["componentIds": entry.currentIDs, "note": entry.currentNote], "directions": directions])
    }
    let scenes: [[String: Any]] = Scenes.all.compactMap { scene in
        let media = mediaSet("redesign/scenes/\(scene.id)", crop: Desk.full, duration: scene.duration)
        guard !media.isEmpty else { return nil }
        return ["id": scene.id, "title": scene.title, "caption": scene.caption, "picks": scene.picks, "media": media]
    }
    let manifest: [String: Any] = [
        "producer": "native", "commit": gitHead(), "generatedAt": ISO8601DateFormatter().string(from: Date()),
        "components": components, "scenes": scenes,
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try fm.createDirectory(at: options.out, withIntermediateDirectories: true)
    try data.write(to: options.out.appendingPathComponent("manifest.redesign.native.json"))
    print("wrote manifest.redesign.native.json with \(components.count) components")
}

/// Offscreen render cost of each always-on direction in its busiest state,
/// without the backdrop, minus the cost of rendering the same stage idle.
/// A proxy for the overlay's cost, not on-screen compositor numbers.
@MainActor
func perf(frames: Int = 240) throws {
    func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    func measure(_ stage: Stage) -> (cpu: Double, wall: Double) {
        let renderer = ImageRenderer(content: StageView(stage: stage, backdrop: false))
        renderer.scale = 2
        for _ in 0..<20 {
            stage.advance(1.0 / 60)
            renderer.content = StageView(stage: stage, backdrop: false)
            _ = renderer.cgImage
        }
        let c0 = cpuSeconds(), w0 = Date()
        for _ in 0..<frames {
            stage.advance(1.0 / 60)
            renderer.content = StageView(stage: stage, backdrop: false)
            _ = renderer.cgImage
        }
        return ((cpuSeconds() - c0) / Double(frames) * 1000, Date().timeIntervalSince(w0) / Double(frames) * 1000)
    }
    let busiest = ["voice-island": "hearing", "gaze-highlight": "locked"]
    var out: [String: [String: [String: String]]] = [:]
    for entry in Redesign.components {
        guard let busy = busiest[entry.id], let index = entry.index(of: busy),
              let idle = entry.flow.first.flatMap({ entry.index(of: $0) }) else { continue }
        for (d, direction) in entry.directions.enumerated() where direction.info.alwaysOn {
            let idleStage = Stage(entry, direction: d)
            idleStage.settle(at: idle)
            let base = measure(idleStage)
            let stage = Stage(entry, direction: d)
            stage.settle(at: index)
            let cost = measure(stage)
            let cpu = max(0, cost.cpu - base.cpu), wall = max(0, cost.wall - base.wall)
            let id = direction.info.id
            out[entry.id, default: [:]][id] = [
                "cpu": String(format: "%.1f ms/frame CPU (%.0f%% of a core at 60 fps)", cpu, cpu * 6),
                "gpu": String(format: "%.1f ms/frame offscreen render incl. GPU", wall),
                "idle": "0: the view is removed when idle",
                "note": "Offscreen ImageRenderer at 2x on an M1 (shared with other builds), \(busy) state, minus the idle stage. A proxy, not on-screen compositor cost; the on-device check is the lab with Activity Monitor.",
            ]
            print(String(format: "%@ %@ %@: cpu %.2f ms, wall %.2f ms (idle cpu %.2f, wall %.2f)", entry.id, id, busy, cpu, wall, base.cpu, base.wall))
        }
    }
    let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: "Lab/perf.json"))
}

/// Re-renders every poster without encoding clips: steps the same stage to
/// the poster's instant (60% into the state, or the middle of the flow) and
/// renders that one frame.
@MainActor
func posters(_ options: Options) throws {
    let lead = 0.35
    func shoot(_ stage: Stage, until seconds: Double, to url: URL) throws {
        var t = 0.0
        while t + 1e-9 < seconds { stage.advance(1 / options.fps); t += 1 / options.fps }
        let renderer = ImageRenderer(content: StageView(stage: stage))
        renderer.scale = options.scale
        guard let image = renderer.cgImage else { throw RenderError("no poster for \(url.lastPathComponent)") }
        try writeJPEG(image, to: url)
    }
    for entry in Redesign.components where options.only?.contains(entry.id) ?? true {
        for d in entry.directions.indices {
            let dir = entry.directions[d].info.id
            for variant in options.variants {
                for (index, state) in entry.states.enumerated() {
                    let stage = Stage(entry, direction: d)
                    stage.scheme = variant.scheme
                    stage.reduceMotion = variant.reduceMotion
                    stage.settle(at: predecessor(of: state.id, in: entry).flatMap { entry.index(of: $0) } ?? index)
                    var t = 0.0
                    while t + 1e-9 < lead { stage.advance(1 / options.fps); t += 1 / options.fps }
                    stage.go(to: index)
                    stage.advance(0)
                    try shoot(stage, until: state.duration * 0.6,
                              to: options.out.appendingPathComponent("redesign/\(entry.id)/\(dir)/\(state.id).\(variant.key).jpg"))
                }
                let stage = Stage(entry, direction: d)
                stage.scheme = variant.scheme
                stage.reduceMotion = variant.reduceMotion
                if let first = entry.flow.first.flatMap({ entry.index(of: $0) }) { stage.settle(at: first) }
                stage.playFlow()
                let flowPoster = entry.flow.prefix(entry.flow.count / 2 + 1).compactMap { entry.index(of: $0) }
                    .reduce(0) { $0 + entry.states[$1].duration } - 0.5
                try shoot(stage, until: max(0, flowPoster),
                          to: options.out.appendingPathComponent("redesign/\(entry.id)/\(dir)/flow.\(variant.key).jpg"))
            }
            print("posters \(entry.id) \(dir)")
        }
    }
}

/// Reduce Motion check: each direction, one state per component, every
/// channel settled, rendered at two instants 1 s apart under Reduce Motion.
/// Anything still moving (a beam travelling its border, an orb turning) makes
/// the frames differ and the check fail. Writes both frames of a failure to
/// `out` when given.
@MainActor
func rmcheck(out: String?) -> Bool {
    let states = [("gaze-highlight", "locked"), ("flashes", "confirm"), ("agent-presence", "shelf"),
                  ("agent-presence", "large"), ("guide-callout", "consequential"), ("guide-callout", "large")]
    func pixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }
    var ok = true
    for (id, stateID) in states {
        guard let entry = Redesign.components.first(where: { $0.id == id }), let index = entry.index(of: stateID) else { continue }
        for d in entry.directions.indices {
            for scheme in [ColorScheme.dark, .light] {
                let stage = Stage(entry, direction: d)
                stage.scheme = scheme
                stage.reduceMotion = true
                stage.settle(at: index)
                for _ in 0..<120 { stage.advance(1.0 / 60) }
                let renderer = ImageRenderer(content: StageView(stage: stage, backdrop: false))
                renderer.scale = 1
                guard let a = renderer.cgImage else { continue }
                for _ in 0..<60 { stage.advance(1.0 / 60) }
                renderer.content = StageView(stage: stage, backdrop: false)
                guard let b = renderer.cgImage else { continue }
                let pa = pixels(a), pb = pixels(b)
                var changed = 0
                for i in stride(from: 0, to: min(pa.count, pb.count), by: 4)
                where abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1])) + abs(Int(pa[i + 2]) - Int(pb[i + 2])) + abs(Int(pa[i + 3]) - Int(pb[i + 3])) > 8 {
                    changed += 1
                }
                let name = "\(id) \(entry.directions[d].info.id) \(stateID) \(scheme == .dark ? "dark" : "light")"
                print("\(changed == 0 ? "PASS" : "FAIL") \(name): \(changed) pixels changed between t and t+1s")
                if changed > 0 {
                    ok = false
                    if let out {
                        let base = out + "/\(id)-\(entry.directions[d].info.id)-\(stateID)-\(scheme == .dark ? "dark" : "light")"
                        try? writePNG(a, to: URL(fileURLWithPath: base + "-t0.png"))
                        try? writePNG(b, to: URL(fileURLWithPath: base + "-t1.png"))
                    }
                }
            }
        }
    }
    return ok
}

func gitHead() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
}

func parse(_ args: ArraySlice<String>) -> Options {
    var options = Options()
    var rest = Array(args)
    if let first = rest.first, !first.hasPrefix("--") { options.out = URL(fileURLWithPath: first); rest.removeFirst() }
    var i = 0
    while i + 1 < rest.count {
        let value = rest[i + 1]
        switch rest[i] {
        case "--only": options.only = Set(value.split(separator: ",").map(String.init))
        case "--variants":
            let keys = Set(value.split(separator: ",").map(String.init))
            options.variants = allVariants.filter { keys.contains($0.key) }
        case "--scale": options.scale = CGFloat(Double(value) ?? 1.5)
        case "--fps": options.fps = Double(value) ?? 60
        default: break
        }
        i += 2
    }
    return options
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    let args = CommandLine.arguments
    do {
        switch args.dropFirst().first {
        case "probe": try probe(args[2], component: args.count > 3 ? args[3] : "voice-island")
        case "render": try render(parse(args.dropFirst(2)))
        case "manifest": try writeManifest(parse(args.dropFirst(2)))
        case "perf": try perf()
        case "posters": try posters(parse(args.dropFirst(2)))
        case "rmcheck": if !rmcheck(out: args.count > 2 ? args[2] : nil) { exit(1) }
        default: print("usage: JarvisRedesignRender probe <dir> [component] | render <renders-dir> [--only ids] [--variants keys] [--scale s] [--fps n]")
        }
    } catch {
        print("error: \(error)")
        exit(1)
    }
}
