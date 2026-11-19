import AppKit
import ApplicationServices
import Foundation
import JarvisCore
import ScreenCaptureKit
import Vision

/// B2 — the scorer's candidate set around a fixation, built on the
/// coverage ladder: windows (the floor, host-side CGWindowList) → AX
/// elements of the window under gaze → its traffic lights → the menu
/// bar strip → agent cursors/shelf chips → the browser DOM probe →
/// Vision OCR only when nothing actionable answered. Every frame is in
/// global top-left screen points, and every reach into the world is an
/// injected seam so tests never touch AX, the driver, or the screen.
struct GazeCandidateFeed: Sendable {

    /// One CGWindowList row — the host-side window truth, no driver call.
    /// Rows arrive front-to-back; that order IS the z-order.
    struct WindowRow: Sendable, Equatable {
        var id: Int
        var pid: pid_t
        var layer: Int
        var app: String
        var title: String
        /// Global top-left points (CGWindowList's own space).
        var bounds: CGRect
    }

    /// What one enumeration produced — the candidates plus which window
    /// sits under the gaze (the feed gate's change signal). A nil
    /// `windowID` means the point is on the desktop/menu bar.
    struct Batch: Sendable, Equatable {
        var candidates: [IntentCandidate] = []
        var windowID: Int?
        static let empty = Batch()
    }

    /// The driver call seam — the DOM probe's `page execute_javascript`
    /// is mutation-class on the wire, so it keeps the primary transport.
    /// Nil disables driver-backed sources; the window floor still stands.
    var call: (@Sendable (String, [String: JSONValue]) async throws -> JSONValue)?
    /// Read-only sibling of `call` — `get_window_state` rides it when
    /// present so an in-flight dispatch can't starve the feed's snapshot.
    /// Nil falls through to `call`, preserving single-transport callers.
    var readCall: (@Sendable (String, [String: JSONValue]) async throws -> JSONValue)?
    var session = "voice-gaze"
    /// Our own pid — own windows never claim a gaze referent.
    var ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    /// On-screen window inventory — CGWindowList in production.
    var windowRows: @Sendable () -> [WindowRow] = { Self.onScreenWindows() }
    /// The gazed window's element snapshot — nil routes through `call`.
    var elementSnapshot: (@Sendable (pid_t, Int) async throws -> JSONValue)?
    /// Traffic-light buttons on the AX window matching a screen frame.
    var trafficLights: @MainActor @Sendable (pid_t, CGRect) -> [WindowControls.Button] = { pid, frame in
        GazeAXWindow.buttons(pid: pid, matching: frame)
    }
    /// Menu-bar items — only walked when the point sits in the bar band.
    var menuBarItems: @MainActor @Sendable () -> [MenuBarAX.Item] = { MenuBarAX.items() }
    /// Agent surfaces — cursor chips AND shelf chips (slug, name, rect).
    var agentCursors: @MainActor @Sendable () -> [(slug: String, name: String, frame: CGRect)] = { [] }
    /// pid → bundle id for the browser check.
    var bundleID: @MainActor @Sendable (pid_t) -> String? = { pid in
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
    /// DOM probe seam — tests inject rect-carrying candidates; nil routes
    /// through `call` with the `page` tool's execute_javascript.
    var domProbe: (@Sendable (pid_t, Int) async -> [IntentCandidate])?
    /// Vision OCR fallback — runs ONLY when nothing actionable surfaced
    /// near the point.
    var ocrRegions: @Sendable (CGPoint) async -> [(frame: CGRect, label: String)] = { point in
        await GazeOCR.regions(around: point)
    }
    /// The menu-bar band test — the strip at the top of the containing
    /// display's top-left frame.
    var inMenuBand: @MainActor @Sendable (CGPoint) -> Bool = { point in
        guard let screen = ScreenGeometry.display(containing: point) else { return false }
        let top = ScreenGeometry.topLeftFrame(of: screen).minY
        return point.y <= top + NSStatusBar.system.thickness + 6
    }
    /// AX permission gate — traffic-light and menu walks skip honestly.
    var axTrusted: @MainActor @Sendable () -> Bool = { AXIsProcessTrusted() }

    /// The window under `point` — topmost front-to-back row containing it.
    /// Own-pid and non-layer-0 rows never claim gaze. Cheap enough to run
    /// per tick (host-side, no driver call) — the gate's change signal.
    func windowUnder(_ point: CGPoint) -> WindowRow? {
        Self.topmost(at: point, in: filteredRows())
    }

    /// Enumerate the full candidate set for a fixation at `point`.
    /// MainActor — the AX/menu/cursor seams read AppKit state.
    @MainActor
    func enumerate(around point: CGPoint) async -> Batch {
        let rows = filteredRows()
        var out: [IntentCandidate] = []
        // The window floor — a fixated window is always a referent even
        // when its AX tree is empty.
        for (z, row) in rows.enumerated() {
            out.append(IntentCandidate(
                id: "win:\(row.id)", kind: .window,
                frame: row.bounds, motorRect: row.bounds,
                role: "window",
                label: row.title.isEmpty ? row.app : row.title,
                pid: row.pid, windowID: row.id,
                appName: row.app, windowTitle: row.title,
                specificity: 0.1, zOrder: z))
        }
        if inMenuBand(point) {
            for item in menuBarItems() where item.pid != ownPID {
                out.append(IntentCandidate(
                    id: "menu:\(item.pid):\(item.title)", kind: .menuBar,
                    frame: item.frame, motorRect: item.frame,
                    role: "menu bar item", label: item.title,
                    pid: item.pid, specificity: 0.9, zOrder: 0))
            }
        }
        for agent in agentCursors() {
            out.append(IntentCandidate(
                id: "agent:\(agent.slug)", kind: .agentCursor,
                frame: agent.frame, motorRect: agent.frame,
                role: "agent cursor", label: agent.name,
                specificity: 0.98, zOrder: 0))
        }
        guard let top = Self.topmost(at: point, in: rows) else {
            return Batch(candidates: out, windowID: nil)
        }
        // Native AX frames already use global top-left screen points.
        // The snapshot and the DOM probe
        // are independent driver reads — overlap them; the traffic-light
        // AX walk runs while both are in flight. `dom` rides `call`
        // (execute_javascript is mutation-class) while the snapshot
        // takes `readCall`, so the two can actually overlap.
        let trusted = axTrusted()
        let isBrowser = trusted && BrowserSupport.isBrowser(bundleID: bundleID(top.pid))
        async let snapFetch: JSONValue? = try? await snapshot(pid: top.pid, wid: top.id)
        async let domFetch: [IntentCandidate] = isBrowser
            ? await domCandidates(pid: top.pid, wid: top.id, row: top)
            : []
        let lights: [WindowControls.Button] = trusted
            ? trafficLights(top.pid, top.bounds) : []
        if let snap = await snapFetch {
            out += Self.elementCandidates(snap, row: top)
        }
        for button in lights {
            out.append(IntentCandidate(
                id: "traffic:\(top.pid):\(top.id):\(button.kind.rawValue)",
                kind: .trafficLight,
                // frame AND motorRect are the button rect — the
                // whole-window frame made all three lights a
                // permanent top-2 tie (every AX-matched window
                // deadlocked .ambiguous). The actuation's
                // window-match key lives on `windowID` (see
                // `windowBounds(_:)`), never on `frame`.
                frame: button.frame, motorRect: button.frame,
                role: "AXButton", label: button.kind.spokenName,
                pid: top.pid, windowID: top.id,
                appName: top.app, windowTitle: top.title,
                specificity: 0.95, zOrder: 0))
        }
        // Browser DOM — the rect-carrying refs AX never reaches. A
        // probe failure (legacy flag off, setup refusal, not a real
        // page) yields nothing; AX stands as the page-content source.
        out += await domFetch
        // The OCR floor fires only when nothing actionable is within
        // reach — games and AX-less UIs, not a second opinion on a
        // button the AX tree already named.
        let actionableNear = out.contains {
            [.axElement, .trafficLight, .dom].contains($0.kind)
                && $0.edgeDistance(to: point) < 80
        }
        if !actionableNear {
            for (frame, label) in await ocrRegions(point).prefix(16) {
                out.append(IntentCandidate(
                    id: "ocr:\(top.id):\(Int(frame.minX)):\(Int(frame.minY))",
                    kind: .ocr, frame: frame, motorRect: frame,
                    role: "text", label: label,
                    pid: top.pid, windowID: top.id,
                    appName: top.app, windowTitle: top.title,
                    specificity: 0.3, zOrder: 0))
            }
        }
        return Batch(candidates: out, windowID: top.id)
    }

    /// Live window rows minus our own and non-layer-0 (dock, overlays).
    private func filteredRows() -> [WindowRow] {
        windowRows().filter {
            $0.pid != ownPID && $0.layer == 0
                && $0.bounds.width > 8 && $0.bounds.height > 8
        }
    }

    private func snapshot(pid: pid_t, wid: Int) async throws -> JSONValue {
        if let elementSnapshot { return try await elementSnapshot(pid, wid) }
        // The read lane first — the DOM probe stays on `call` because
        // execute_javascript is mutation-class, but a plain snapshot is
        // the read-only case the second transport exists for.
        guard let call = readCall ?? call else { throw DriverConnectionError.unavailable }
        // include_screenshot:false — candidates never pay the PNG cost.
        // Hazard: every publish retires the window's prior element
        // tokens, so a feed tick between a commit and its actuation (or
        // an in-flight DriveLoop turn) invalidates that turn's tokens.
        // The driver exposes no observe-only flag (mcp-tools.mdx
        // get_window_state args), so the DriveLoop side retries stale
        // tokens instead.
        return try await call("get_window_state", [
            "pid": .number(Double(pid)), "window_id": .number(Double(wid)),
            "include_screenshot": .bool(false), "max_elements": .number(400),
            "max_depth": .number(20), "session": .string(session)])
    }

    // MARK: - Parsing

    /// Topmost row containing the point — rows are already front-to-back.
    static func topmost(at point: CGPoint, in rows: [WindowRow]) -> WindowRow? {
        rows.first { $0.bounds.contains(point) }
    }

    /// `get_window_state` → `.axElement` candidates. Native AX frames
    /// are already global top-left points. Non-actionable roles never enter the
    /// feed — a label-less group can't be a referent worth a ring.
    static func elementCandidates(_ snap: JSONValue, row: WindowRow) -> [IntentCandidate] {
        let content = snap["structuredContent"] ?? snap
        let windowArea = max(1, row.bounds.width * row.bounds.height)
        return DriveLoop.elements(from: content).filter(actionable).compactMap { e in
            guard let frame = DriveLoop.nativeAXScreenRect(e) else { return nil }
            // Meta's specificity: smaller/deeper beats the container — a
            // toolbar-wide group never outranks the button inside it.
            let cover = min(0.8, Double(frame.width * frame.height) / Double(windowArea))
            return IntentCandidate(
                id: "ax:\(row.pid):\(row.id):\(e.token ?? "_idx_\(e.index)")",
                kind: .axElement, frame: frame, motorRect: frame,
                role: e.role,
                label: e.label.isEmpty ? (e.value ?? "") : e.label,
                pid: row.pid, windowID: row.id,
                appName: row.app, windowTitle: row.title,
                specificity: max(0.2, 1 - cover), zOrder: 0)
        }
    }

    /// The roles a gaze referent can act on — the feed's actionable set,
    /// mirroring the overlay's own gate: buttons, links, fields, menus,
    /// tabs, anything carrying a label.
    static func actionable(_ e: DriveLoop.Element) -> Bool {
        let r = e.role.lowercased()
        if r.contains("button") || r.contains("link") || r.contains("menu")
            || r.contains("checkbox") || r.contains("radio") || r.contains("tab")
            || r.contains("cell") || r.contains("combo") { return true }
        if r.contains("textfield") || r.contains("textarea")
            || r.contains("search") || r.contains("field") { return true }
        return !e.label.isEmpty
    }

    // MARK: - DOM probe

    /// The browser-window DOM probe — `page execute_javascript` returns
    /// the interactive elements' rects in viewport CSS px plus the
    /// viewport's screen origin, and Swift converts to top-left points.
    /// `sx/sy` use the driver's own convention (see `click_element`'s
    /// probe in platform-macos page.rs): screenX/Y in DIPs, viewport
    /// offset by the chrome size.
    private func domCandidates(pid: pid_t, wid: Int,
                               row: WindowRow) async -> [IntentCandidate] {
        if let domProbe { return await domProbe(pid, wid) }
        guard let call, let raw = try? await call("page", [
            "action": .string("execute_javascript"),
            "pid": .number(Double(pid)), "window_id": .number(Double(wid)),
            "javascript": .string(Self.domProbeJS),
            "session": .string(session)])
        else { return [] }
        return Self.domCandidates(from: raw, pid: pid, wid: wid, row: row)
    }

    /// Probe JS: interactive element rects in viewport CSS px + the
    /// viewport's screen origin + pinch-zoom scale. At 100% zoom a CSS
    /// px is a point; visualViewport.scale carries any pinch zoom.
    static let domProbeJS = #"""
(() => {
  const sel = 'a[href],button,[role="button"],[role="link"],input,select,textarea,[role="menuitem"],[role="tab"],[role="checkbox"],[role="radio"],summary,[onclick]';
  const s = window.visualViewport ? window.visualViewport.scale : 1;
  const sx = window.screenX + (window.outerWidth - window.innerWidth) / 2;
  const sy = window.screenY + (window.outerHeight - window.innerHeight);
  const out = [];
  for (const el of document.querySelectorAll(sel)) {
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) continue;
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none') continue;
    const label = (el.innerText || el.getAttribute('aria-label') || el.title || el.getAttribute('placeholder') || '').trim().slice(0, 80);
    const href = el.tagName === 'A' ? el.href : (el.getAttribute('href') || null);
    out.push({x: r.left, y: r.top, w: r.width, h: r.height,
              role: el.getAttribute('role') || el.tagName.toLowerCase(),
              label, href});
    if (out.length >= 60) break;
  }
  return JSON.stringify({sx, sy, s, elements: out});
})()
"""#

    /// Probe JSON → `.dom` candidates. The wire is CSS px relative to a
    /// screen origin in DIPs — at unit zoom both are points; the pinch
    /// scale multiplies sizes/offsets toward points.
    static func domCandidates(from result: JSONValue, pid: pid_t, wid: Int,
                              row: WindowRow) -> [IntentCandidate] {
        // execute_javascript's return text lands in one of these slots —
        // structuredContent.result, a content block, or a bare string.
        let text = result["structuredContent"]?["result"]?.string
            ?? result["structuredContent"]?["output"]?.string
            ?? result["result"]?.string
            ?? result["content"]?.array?.compactMap({ $0["text"]?.string }).first
            ?? result["text"]?.string
        guard let text,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sx = (obj["sx"] as? NSNumber)?.doubleValue,
              let sy = (obj["sy"] as? NSNumber)?.doubleValue,
              let elements = obj["elements"] as? [[String: Any]]
        else { return [] }
        let s = (obj["s"] as? NSNumber)?.doubleValue ?? 1
        return elements.enumerated().compactMap { i, e in
            guard let x = (e["x"] as? NSNumber)?.doubleValue,
                  let y = (e["y"] as? NSNumber)?.doubleValue,
                  let w = (e["w"] as? NSNumber)?.doubleValue,
                  let h = (e["h"] as? NSNumber)?.doubleValue
            else { return nil }
            let frame = CGRect(x: sx + x * s, y: sy + y * s,
                               width: w * s, height: h * s)
            let label = e["label"] as? String ?? ""
            let role = e["role"] as? String ?? "link"
            return IntentCandidate(
                id: "dom:\(pid):\(wid):\(i)", kind: .dom,
                frame: frame, motorRect: frame,
                role: role, label: label,
                url: e["href"] as? String,
                pid: pid, windowID: wid,
                appName: row.app, windowTitle: row.title,
                specificity: 0.85, zOrder: 0)
        }
    }

    // MARK: - Wire geometry

    /// Live on-screen windows, front-to-back — CGWindowList order is the
    /// compositor's z-order, so the enumerator never needs list_windows.
    static func onScreenWindows() -> [WindowRow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { w in
            guard let id = (w[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber).map({ pid_t($0.int32Value) }),
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: b as CFDictionary)
            else { return nil }
            return WindowRow(
                id: id, pid: pid,
                layer: (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                app: w[kCGWindowOwnerName as String] as? String ?? "",
                title: w[kCGWindowName as String] as? String ?? "",
                bounds: bounds)
        }
    }

    /// CGWindowList bounds for one window id — the actuation-side
    /// lookup a traffic-light commit needs: `frame` is the button rect
    /// now, so the AX window-match key lives on `windowID`, not `frame`.
    static func windowBounds(_ windowID: Int) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
            let entry = list.first,
            let b = entry[kCGWindowBounds as String] as? [String: Any]
        else { return nil }
        return CGRect(dictionaryRepresentation: b as CFDictionary)
    }

    /// JSONValue fractional-number extraction — `integer` is exact-Int
    /// only; bounds and scale arrive fractional.
    private static func num(_ v: JSONValue?) -> Double? {
        if case .number(let d)? = v { return d }
        return nil
    }
}

// MARK: - AX helpers

/// AXPosition/AXSize → a CGRect in global top-left points — the same
/// read WindowControls does privately, shared by the feed's own walks.
private func axFrame(of element: AXUIElement) -> CGRect? {
    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let positionRef, let sizeRef else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
          AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: position, size: size)
}

/// The AX window element matching a screen frame, then its traffic
/// lights — WindowControls' private lookup opened to the feed's
/// per-window probe. ~4pt of tolerance absorbs shadow/Dock drift.
enum GazeAXWindow {
    static func buttons(pid: pid_t, matching frame: CGRect) -> [WindowControls.Button] {
        guard let window = element(pid: pid, matching: frame) else { return [] }
        return WindowControls.buttons(on: window)
    }

    static func element(pid: pid_t, matching target: CGRect) -> AXUIElement? {
        guard !target.isEmpty else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return nil }
        return windows.first { window in
            guard let f = axFrame(of: window) else { return false }
            return abs(f.minX - target.minX) < 4 && abs(f.minY - target.minY) < 4
                && abs(f.width - target.width) < 4 && abs(f.height - target.height) < 4
        }
    }
}

/// The menu bar as candidates — the frontmost app's menus plus the
/// extras/status bar. Read host-side; only walked when the gaze point
/// sits in the bar band, so the walk's cost is never idle.
enum MenuBarAX {
    struct Item: Sendable, Equatable {
        var title: String
        /// Global top-left points.
        var frame: CGRect
        var pid: pid_t
    }

    static func items() -> [Item] {
        var out: [Item] = []
        // The active app's menu bar.
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let app = AXUIElementCreateApplication(pid)
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &ref) == .success,
               let barRef = ref {
                let bar = barRef as! AXUIElement
                var kids: CFTypeRef?
                if AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &kids) == .success,
                   let elements = kids as? [AXUIElement] {
                    for element in elements {
                        guard let frame = axFrame(of: element), !frame.isEmpty else { continue }
                        out.append(Item(title: axString(element, kAXTitleAttribute) ?? "",
                                        frame: frame, pid: pid))
                    }
                }
            }
        }
        // Status items / extras bar — each item reports its own owner pid.
        let system = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, "AXExtrasMenuBar" as CFString, &ref) == .success,
           let barRef = ref {
            let bar = barRef as! AXUIElement
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &kids) == .success,
               let elements = kids as? [AXUIElement] {
                for element in elements {
                    var itemPID: pid_t = 0
                    AXUIElementGetPid(element, &itemPID)
                    guard let frame = axFrame(of: element), !frame.isEmpty else { continue }
                    out.append(Item(
                        title: axString(element, kAXTitleAttribute)
                            ?? axString(element, kAXDescriptionAttribute) ?? "",
                        frame: frame, pid: itemPID))
                }
            }
        }
        return out
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let s = ref as? String else { return nil }
        return s
    }
}

// MARK: - OCR floor

/// Vision text regions around a gaze point — the coverage floor for
/// AX-blind surfaces (games, custom-drawn UIs). A small crop keeps
/// VNRecognizeText at interactive latency; output rects return in
/// top-left screen points. Runs only when nothing actionable answered.
enum GazeOCR {
    /// Screen-capture permission gate — no grant, no floor (not an error).
    static var preflight: @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }

    /// Crop radius in points — ~640pt covers a dialog's worth of page
    /// while keeping the recognition cost in the tens of ms.
    static let cropRadius: CGFloat = 320

    static func regions(around point: CGPoint,
                        radius: CGFloat = cropRadius) async -> [(frame: CGRect, label: String)] {
        guard preflight(),
              let screen = ScreenGeometry.display(containing: point),
              let content = try? await SCShareableContent.current,
              let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                               as? NSNumber).map({ CGDirectDisplayID($0.uint32Value) }),
              let scDisplay = content.displays.first(where: { $0.displayID == displayID })
        else { return [] }
        let displayFrame = ScreenGeometry.topLeftFrame(of: screen)
        let cropGlobal = CGRect(x: point.x - radius, y: point.y - radius,
                                width: radius * 2, height: radius * 2)
            .intersection(displayFrame)
        guard cropGlobal.width > 8, cropGlobal.height > 8 else { return [] }

        let own = NSRunningApplication.current
        let ours = content.applications.filter { $0.bundleIdentifier == own.bundleIdentifier }
        let filter = SCContentFilter(display: scDisplay, excludingApplications: ours,
                                     exceptingWindows: [])
        // This SDK's captureImage has no rect form — shoot the display
        // and crop the CGImage; image pixels ↔ display-local points by
        // the captured size's own ratio.
        let cropLocal = cropGlobal.offsetBy(dx: -displayFrame.minX,
                                            dy: -displayFrame.minY)
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.width = Int(displayFrame.width * scale)
        config.height = Int(displayFrame.height * scale)
        config.showsCursor = false
        guard let whole = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
        else { return [] }
        let px = Double(whole.width) / Double(displayFrame.width)
        let py = Double(whole.height) / Double(displayFrame.height)
        let pixelCrop = CGRect(
            x: cropLocal.minX * px, y: cropLocal.minY * py,
            width: cropLocal.width * px, height: cropLocal.height * py)
            .integral.intersection(CGRect(x: 0, y: 0,
                                          width: whole.width, height: whole.height))
        guard pixelCrop.width > 8, pixelCrop.height > 8,
              let image = whole.cropping(to: pixelCrop)
        else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil else { return [] }
        let observations = request.results ?? []

        return observations.compactMap { obs in
            guard let label = obs.topCandidates(1).first?.string,
                  !label.isEmpty else { return nil }
            // VN boxes are normalized bottom-left in the crop image —
            // back to top-left global points.
            let b = obs.boundingBox
            let frame = CGRect(
                x: cropGlobal.minX + b.minX * cropGlobal.width,
                y: cropGlobal.minY + (1 - b.maxY) * cropGlobal.height,
                width: b.width * cropGlobal.width,
                height: b.height * cropGlobal.height)
            guard frame.width >= 12, frame.height >= 8 else { return nil }
            return (frame, label)
        }
    }
}
