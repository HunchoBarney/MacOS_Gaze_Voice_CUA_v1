import AppKit
import CryptoKit
import Foundation
import ImageIO
import JarvisCore

enum VisualCaptureError: Error {
    case invalidCapture, unavailable, secureSurface, outsideImage, scopeChanged
}

struct VisualFrame: Sendable {
    let asset: JevImageAsset
    let captureID: String
    let window: WindowRef
    let session: String
    let bounds: CGRect
    let driverSize: CGSize
    let contentRect: CGRect
    let generation: UUID
    let imageHash: String
    var origin: CuaResultOrigin? = nil
    var snapshotID: String? = nil
    var capturedElementTools: Set<String> = []

    static func decode(_ result: CuaToolResult, window: WindowRef,
                       session: String) throws -> VisualFrame {
        if let origin = result.origin {
            guard origin.session == session, !origin.daemonSocket.isEmpty else {
                throw VisualCaptureError.scopeChanged
            }
        }
        let body = result.structured
        guard !session.isEmpty, body["pid"] == .number(Double(window.pid)),
              body["window_id"] == .number(Double(window.windowID)),
              body["screenshot_frame_valid"] == .bool(true),
              let captureID = body["capture_id"]?.string, !captureID.isEmpty,
              let rect = body["window_bounds"],
              let x = rect["x"]?.numberValue, let y = rect["y"]?.numberValue,
              let width = rect["width"]?.numberValue, let height = rect["height"]?.numberValue,
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0,
              (x + width).isFinite, (y + height).isFinite else {
            throw VisualCaptureError.invalidCapture
        }
        for row in body["elements"]?.array ?? [] {
            let roles = [row["role"]?.string ?? "", row["subrole"]?.string ?? ""]
                .joined(separator: " ").lowercased()
            let states = row["states"]?.array?.compactMap(\.string).map { $0.lowercased() } ?? []
            if roles.contains("securetextfield") || roles.contains("passwordfield")
                || states.contains("secure") || states.contains("protected") {
                throw VisualCaptureError.secureSurface
            }
        }
        let images = result.content.filter { $0["type"] == .string("image") }
        guard images.count == 1, images[0]["mimeType"] == .string("image/png"),
              let encoded = images[0]["data"]?.string,
              let data = Data(base64Encoded: encoded), data.count <= 16 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == "public.png",
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              body["screenshot_width"] == .number(Double(image.width)),
              body["screenshot_height"] == .number(Double(image.height)),
              image.width > 0, image.height > 0, image.width <= 1568, image.height <= 1568 else {
            throw VisualCaptureError.invalidCapture
        }
        let outputWidth = max(280, image.width), outputHeight = max(280, image.height)
        let left = (outputWidth - image.width) / 2
        let top = (outputHeight - image.height) / 2
        let prepared: Data
        if outputWidth == image.width, outputHeight == image.height {
            prepared = data
        } else {
            guard let context = CGContext(data: nil, width: outputWidth, height: outputHeight,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw VisualCaptureError.invalidCapture
            }
            context.setFillColor(CGColor(gray: 0.08, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
            context.draw(image, in: CGRect(x: left, y: outputHeight - top - image.height,
                                           width: image.width, height: image.height))
            guard let padded = context.makeImage(),
                  let png = NSBitmapImageRep(cgImage: padded).representation(using: .png, properties: [:])
            else { throw VisualCaptureError.invalidCapture }
            prepared = png
        }
        return VisualFrame(asset: try JevImageAsset(data: prepared, format: .png),
            captureID: captureID, window: window, session: session,
            bounds: CGRect(x: x, y: y, width: width, height: height),
            driverSize: CGSize(width: image.width, height: image.height),
            contentRect: CGRect(x: left, y: top, width: image.width, height: image.height),
            generation: UUID(), imageHash: SHA256.hash(data: prepared).map {
                String(format: "%02x", $0)
            }.joined(), origin: result.origin, snapshotID: body["snapshot_id"]?.string,
            capturedElementTools: result.capturedElementTools)
    }

    func driverPoint(for box: JevBox) throws -> CGPoint {
        let rect = CGRect(x: box.left * Double(asset.width), y: box.top * Double(asset.height),
                          width: (box.right - box.left) * Double(asset.width),
                          height: (box.bottom - box.top) * Double(asset.height))
        guard contentRect.contains(rect) else { throw VisualCaptureError.outsideImage }
        return CGPoint(x: rect.midX - contentRect.minX, y: rect.midY - contentRect.minY)
    }

    func nativePicture(in rect: CGRect) throws -> JevImageAsset {
        guard !rect.isEmpty, !rect.isNull,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              bounds.contains(rect) else { throw VisualCaptureError.outsideImage }
        let assetBounds = CGRect(x: 0, y: 0, width: asset.width, height: asset.height)
        guard [bounds.width, bounds.height, driverSize.width, driverSize.height,
               contentRect.minX, contentRect.minY, contentRect.width, contentRect.height]
                .allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0,
              contentRect.size == driverSize, assetBounds.contains(contentRect),
              SHA256.hash(data: asset.data).map({ String(format: "%02x", $0) }).joined() == imageHash,
              let source = CGImageSourceCreateWithData(asset.data as CFData, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
              original.width == asset.width, original.height == asset.height else {
            throw VisualCaptureError.invalidCapture
        }
        let pixels = CGRect(
            x: (rect.minX - bounds.minX) / bounds.width * driverSize.width + contentRect.minX,
            y: (rect.minY - bounds.minY) / bounds.height * driverSize.height + contentRect.minY,
            width: rect.width / bounds.width * driverSize.width,
            height: rect.height / bounds.height * driverSize.height)
            .integral.intersection(contentRect)
        guard !pixels.isEmpty, let crop = original.cropping(to: pixels) else {
            throw VisualCaptureError.outsideImage
        }
        // Crop images exist to locate an element inside the scene; beyond a
        // modest resolution they only spend request tokens. Bounds are
        // normalized, so downscaling loses no locating precision.
        let scale = min(1.0, 512.0 / Double(max(crop.width, crop.height)))
        let scaledW = floor(Double(crop.width) * scale)
        let scaledH = floor(Double(crop.height) * scale)
        let width = max(280, scaledW), height = max(280, scaledH)
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VisualCaptureError.invalidCapture
        }
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(crop, in: CGRect(x: (width - scaledW) / 2,
            y: (height - scaledH) / 2, width: scaledW, height: scaledH))
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw VisualCaptureError.invalidCapture
        }
        return try JevImageAsset(data: data, format: .png)
    }
}

enum VisualOperation: String, CaseIterable, Sendable {
    case click, typeText = "type_text", setValue = "set_value"
    case scrollUp = "scroll_up", scrollDown = "scroll_down"
    case key, verify, none

    var capturedTool: String? {
        switch self {
        case .click: return "click"
        case .typeText: return "type_text"
        case .setValue: return "set_value"
        case .key: return "press_key"
        case .scrollUp, .scrollDown: return "scroll"
        case .verify, .none: return nil
        }
    }
}

enum VisualControl: String, CaseIterable, Sendable {
    case navigation, editable, toggle, ordinary, scrollRegion = "scroll_region"
    case closeWindow = "close_window"
    case send, submit, delete, purchase, clipboard, credential, unknown

    var protected: Bool {
        [.send, .submit, .delete, .purchase, .clipboard, .closeWindow].contains(self)
    }

    var policyText: String { self == .purchase ? "purchase now" : rawValue }

    var criterion: String {
        switch self {
        case .navigation:
            return "Navigate a link, tab, menu or view without committing, sending or deleting data."
        case .editable:
            return "A genuinely editable non-secure text field, not a credential input."
        case .toggle:
            return "A visibly stateful switch, checkbox, radio or on/off setting control. "
                + "Not a plain push button merely because pressing it changes the screen."
        case .ordinary:
            return "An ordinary local push button, icon button or command. "
                + "Exclude every other listed category; do not assume an unidentified consequence is ordinary."
        case .scrollRegion:
            return "A scrollable content region, document view or web/canvas area that a "
                + "scroll or pan operation moves through — not a button, field, switch or "
                + "other listed control; the content itself carries no commit consequence."
        case .closeWindow:
            return "Close a window or document, potentially losing unsaved work."
        case .send:
            return "Send or publish a message, email, post or other content."
        case .submit:
            return "Submit a completed form or explicitly commit a submission, "
                + "not ordinary editing, navigation or a local document save."
        case .delete:
            return "Activate a delete, remove or discard control that destroys an item, document or file, "
                + "not ordinary text editing in an identified input."
        case .purchase:
            return "Purchase, pay, subscribe or authorize a financial transaction."
        case .clipboard:
            return "Read, copy, paste or expose clipboard contents."
        case .credential:
            return "Enter, reveal or operate on passwords, authentication codes or other credentials."
        case .unknown:
            return "The actual target or its consequence cannot be identified from the captured evidence."
        }
    }
}

struct VisualBinding: Sendable, Equatable {
    let task: TaskBrief
    let captureID: String
    let generation: UUID
    let session: String
    let origin: CuaResultOrigin?
    let imageData: Data
    let snapshotID: String?
    let capturedElementTools: Set<String>

    init(task: TaskBrief, frame: VisualFrame) {
        self.task = task
        captureID = frame.captureID
        generation = frame.generation
        session = frame.session
        origin = frame.origin
        imageData = frame.asset.data
        snapshotID = frame.snapshotID
        capturedElementTools = frame.capturedElementTools
    }

    func matches(_ observation: TaskObservation) -> Bool {
        guard task == observation.task, let image = observation.screenshot,
              let frame = image.frame, task.window == frame.window,
              image.captureID == captureID, frame.captureID == captureID,
              frame.generation == generation, frame.session == session,
              frame.origin == origin,
              frame.snapshotID == snapshotID, frame.capturedElementTools == capturedElementTools,
              image.data == imageData, frame.asset.data == imageData else { return false }
        return true
    }
}

struct VisualLiteral: Sendable, Equatable {
    enum Source: Sendable, Equatable { case value(String), answer(Int, String) }
    let source: Source
    let text: String

    func authorized(by observation: TaskObservation) -> Bool {
        switch source {
        case .value(let key):
            return observation.task.values[key]?.utf8.elementsEqual(text.utf8) == true
        case .answer(let step, let question):
            return observation.history.contains {
                $0.stepIndex == step && $0.askKind == .question
                    && $0.askQuestion == question
                    && $0.askAnswer?.utf8.elementsEqual(text.utf8) == true
            }
        }
    }
}

struct VisualNativeElement: Sendable, Equatable {
    let token: String
    let index: Int
    let snapshotID: String
    let role: String
    let label: String
    let rect: CGRect
    let probability: Double
    let probabilities: [String: Double]
    let corroborated: Bool

    static func candidates(_ observation: TaskObservation, operation: VisualOperation,
                           box: JevBox) -> [AXElement] {
        guard let frame = observation.screenshot?.frame,
              let tool = operation.capturedTool,
              operation == .setValue || frame.capturedElementTools.contains(tool),
              let snapshot = observation.axSnapshot, let sid = frame.snapshotID,
              sid == snapshot.snapshotID,
              sid.range(of: "^s[0-9a-f]{8}$", options: .regularExpression) != nil,
              let point = try? frame.driverPoint(for: box) else { return [] }
        let global = CGPoint(x: frame.bounds.minX + point.x / frame.driverSize.width * frame.bounds.width,
                             y: frame.bounds.minY + point.y / frame.driverSize.height * frame.bounds.height)
        let editing = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
        let scrolling = ["AXScrollArea", "AXWebArea", "AXTable", "AXOutline", "AXList", "AXBrowser"]
        let eligible = snapshot.elements.filter { element in
            guard element.index >= 0, element.token == "\(sid):\(element.index)",
                  let rect = element.frame, !rect.isEmpty,
                  [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
                  rect.contains(global) else { return false }
            switch operation {
            case .click: return element.actions.contains("AXPress")
            case .typeText, .setValue: return editing.contains(element.role)
            case .key: return editing.contains(element.role) || element.actions.contains("AXPress")
            case .scrollUp, .scrollDown: return scrolling.contains(element.role)
            case .verify, .none: return false
            }
        }
        let counts = Dictionary(grouping: eligible, by: \.index)
        return eligible.filter { counts[$0.index]?.count == 1 }
    }

    init?(element: AXElement, observation: TaskObservation, operation: VisualOperation,
          box: JevBox, probability: Double, probabilities: [String: Double],
          corroborated: Bool = false) {
        guard let token = element.token, let rect = element.frame,
              let sid = observation.screenshot?.frame?.snapshotID else { return nil }
        self.token = token
        index = element.index
        snapshotID = sid
        role = element.role
        label = element.label
        self.rect = rect
        self.probability = probability
        self.probabilities = probabilities
        self.corroborated = corroborated
        guard matches(observation, operation: operation, box: box) else { return nil }
    }

    // A referent-corroborated element cleared identity by unique
    // plurality over the candidate set plus a non-rejected match draw;
    // the single-draw .95 bar is replaced by that same corroboration
    // rule (non-rejection) here. Every structural check — snapshot
    // identity, tool eligibility, containment, uniqueness — is
    // unchanged.
    func matches(_ observation: TaskObservation, operation: VisualOperation, box: JevBox) -> Bool {
        let identityBar: ClosedRange<Double> = corroborated ? 0.5...1 : 0.95...1
        return probability.isFinite && identityBar.contains(probability)
            && probabilities["element_\(index)"].map { $0.isFinite && identityBar.contains($0) } == true
            && observation.screenshot?.frame?.snapshotID == snapshotID
            && Self.candidates(observation, operation: operation, box: box).contains {
                $0.token == token && $0.index == index && $0.role == role
                    && $0.label == label && $0.frame == rect
            }
    }
}

struct VisualTarget: Sendable, Equatable {
    static let refusalReason = "The visual input does not match the current task, capture, or authorized arguments."
    let binding: VisualBinding
    let operation: VisualOperation
    let box: JevBox
    let point: CGPoint
    let control: VisualControl?
    let literal: VisualLiteral?
    let key: String?
    let presence: Double
    let location: Double
    let authorization: Double
    let protectedProbability: Double
    let denyProbabilities: [Double]
    let boxConfidence: Double?
    let distributions: [String: [String: Double]]
    let elementText: String
    /// The on-screen labels under the click point, and nothing the model
    /// guessed: a press is judged by what is really there.
    let pressLabel: String
    let subjectAnchor: UUID
    let subjectProbability: Double?
    let nativeElement: VisualNativeElement?

    static let keys: [String: (String, [String])] = [
        "enter": ("enter", []), "tab": ("tab", []), "previous_field": ("tab", ["shift"]),
        "escape": ("escape", []), "left": ("left", []), "right": ("right", []),
        "up": ("up", []), "down": ("down", []), "home": ("home", []),
        "end": ("end", []), "pageup": ("pageup", []), "pagedown": ("pagedown", []),
        "doc_start": ("up", ["command"]), "doc_end": ("down", ["command"]),
        "backspace": ("backspace", []), "delete": ("delete", []),
        "select_all": ("a", ["command"]), "find": ("f", ["command"]),
        "location": ("l", ["command"]), "save": ("s", ["command"]),
        "undo": ("z", ["command"]), "redo": ("z", ["command", "shift"]),
        "next_tab": ("tab", ["control"]), "previous_tab": ("tab", ["control", "shift"]),
    ]

    static func judgmentsValid(control: VisualControl?, presence: Double, location: Double,
                               authorization: Double, protectedProbability: Double,
                               denyProbabilities: [Double], denyCount: Int,
                               boxConfidence: Double?) -> Bool {
        control.map { ![.credential, .unknown].contains($0) } ?? true
            && [presence, location, authorization].allSatisfy {
                $0.isFinite && (0.95...1).contains($0)
            }
            && protectedProbability.isFinite && (0...1).contains(protectedProbability)
            && (protectedProbability <= 0.05 || (control?.protected ?? false))
            && denyProbabilities.count == denyCount
            && denyProbabilities.allSatisfy { $0.isFinite && (0...0.05).contains($0) }
            && (boxConfidence.map { $0.isFinite && (0...1).contains($0) } ?? true)
    }

    static func subjectValid(_ observation: TaskObservation, anchorID: UUID,
                             probability: Double?) -> Bool {
        guard let frame = observation.screenshot?.frame else { return false }
        let anchor = observation.visualAnchor ?? frame
        guard anchor.generation == anchorID,
              anchor.window == frame.window, anchor.session == frame.session,
              anchor.origin == frame.origin else { return false }
        if anchor.generation == frame.generation { return probability == nil }
        // Identical captured bytes cannot depict different subjects —
        // the hash is proof and dominates any drawn hedge.
        if anchor.imageHash == frame.imageHash { return true }
        return probability.map { $0.isFinite && (0.95...1).contains($0) } == true
    }

    init?(observation: TaskObservation, operation: VisualOperation, box: JevBox,
          control: VisualControl?, literal: VisualLiteral?, key: String?,
          presence: Double, location: Double, authorization: Double,
          protectedProbability: Double, denyProbabilities: [Double],
          boxConfidence: Double?, distributions: [String: [String: Double]],
          subjectProbability: Double? = nil, nativeElement: VisualNativeElement? = nil) {
        guard let frame = observation.screenshot?.frame,
              observation.task.window == frame.window,
              ![.none, .verify].contains(operation),
              Self.judgmentsValid(control: control, presence: presence, location: location,
                authorization: authorization, protectedProbability: protectedProbability,
                denyProbabilities: denyProbabilities, denyCount: observation.task.deny.count,
                boxConfidence: boxConfidence),
              ![.typeText, .setValue].contains(operation)
                || (control == .editable && literal?.authorized(by: observation) == true),
              operation != .key || key.flatMap({ Self.keys[$0] }) != nil,
              let point = try? frame.driverPoint(for: box) else { return nil }
        subjectAnchor = (observation.visualAnchor ?? frame).generation
        guard Self.subjectValid(observation, anchorID: subjectAnchor,
                                probability: subjectProbability) else { return nil }
        binding = VisualBinding(task: observation.task, frame: frame)
        guard binding.matches(observation) else { return nil }
        self.operation = operation
        self.box = box
        self.point = point
        self.control = control
        self.literal = literal
        self.key = key
        self.presence = presence
        self.location = location
        self.authorization = authorization
        self.protectedProbability = protectedProbability
        self.denyProbabilities = denyProbabilities
        self.boxConfidence = boxConfidence
        self.distributions = distributions
        self.subjectProbability = subjectProbability
        guard nativeElement?.matches(observation, operation: operation, box: box) ?? true,
              operation != .setValue || nativeElement != nil else { return nil }
        self.nativeElement = nativeElement
        let global = CGPoint(x: frame.bounds.minX + point.x / frame.driverSize.width * frame.bounds.width,
                             y: frame.bounds.minY + point.y / frame.driverSize.height * frame.bounds.height)
        let labels = observation.axSnapshot?.elements.filter {
            $0.frame?.contains(global) == true
        }.map(\.label) ?? []
        elementText = ((control.map { [$0.policyText] } ?? []) + labels).joined(separator: " ")
        pressLabel = labels.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ")
    }

    var request: ActuationRequest {
        var args: [String: JSONValue] = [
            "capture_id": .string(binding.captureID),
            "delivery_mode": .string("foreground"),
        ]
        if let nativeElement {
            args["element_token"] = .string(nativeElement.token)
        } else {
            args["x"] = .number(point.x)
            args["y"] = .number(point.y)
        }
        let tool: String
        switch operation {
        case .click: tool = "click"
        case .typeText:
            tool = "type_text"
            args["text"] = literal.map { .string($0.text) }
        case .setValue:
            tool = "set_value"
            args["delivery_mode"] = nil
            args["capture_id"] = nil
            args["value"] = literal.map { .string($0.text) }
        case .scrollUp, .scrollDown:
            tool = "scroll"
            args["direction"] = .string(operation == .scrollUp ? "up" : "down")
            args["by"] = .string("page")
            args["amount"] = .number(1)
        case .key:
            tool = "press_key"
            if let key, let command = Self.keys[key] {
                args["key"] = .string(command.0)
                args["modifiers"] = .array(command.1.map(JSONValue.string))
            }
        case .verify, .none: tool = ""
        }
        return ActuationRequest(effect: .tool, tool: tool, args: args,
            visualTarget: self, elementText: elementText,
            summary: "\(operation.rawValue) \(control?.rawValue ?? "native")")
    }

    func validates(_ proposed: ActuationRequest, observation: TaskObservation) -> Bool {
        let expected = request
        guard binding.matches(observation), proposed.effect == .tool,
              nativeElement?.matches(observation, operation: operation, box: box) ?? true,
              Self.subjectValid(observation, anchorID: subjectAnchor, probability: subjectProbability),
              proposed.tool == expected.tool, proposed.elementText == expected.elementText,
              literal?.authorized(by: observation) ?? (![.typeText, .setValue].contains(operation)),
              let window = observation.task.window else { return false }
        var args = proposed.args
        for (key, value): (String, JSONValue) in [
            ("pid", .number(Double(window.pid))),
            ("window_id", .number(Double(window.windowID))),
            ("session", .string(binding.session)),
        ] {
            if let supplied = args.removeValue(forKey: key), supplied != value { return false }
        }
        return args == expected.args
    }
}
