import Foundation
import JevVoiceCore

/// DOM-element actuation for browser-originated candidates.
///
/// Two driver surfaces address a page element, and they do not overlap:
///
/// - A `p<snapshot>:<index>` ref minted by `get_browser_state` resolves
///   only on the typed `browser_*` surface — the ref store is
///   driver-internal. `browser_click` must pin `input_route: "dom_event"`
///   explicitly: the default `trusted` CDP Input route activates its
///   standalone browser window on macOS, so the driver refuses it with
///   `browser_input_trust_unavailable` and names `dom_event` as the
///   background-safe alternative. `browser_type` already takes the same
///   ref. Both are `browser_bound_input` operations — the driver's
///   standard-mode grantable tier — so they stay on the loop's ordinary
///   consent path.
/// - A CSS selector resolves on the legacy `page` surface —
///   `click_element`, `insert_text`, `type_keystrokes`. Selector
///   addressing is what the gaze lane's `.dom` candidates carry (a
///   probe-stamped attribute), so this surface exists for them. The
///   mutations are doubly gated driver-side: the `browser_unbounded_
///   script` adapter refuses every permission mode but `unrestricted`,
///   and the `page` tool itself refuses unless the daemon launched with
///   `CUA_DRIVER_ENABLE_LEGACY_PAGE_MUTATIONS=1`. Both refusals are
///   detected and reported verbatim — an actuation the driver refused is
///   a refusal here, never a synthesized success.
enum BrowserActuation {
    typealias Call = (String, [String: JSONValue]) async throws -> JSONValue

    /// One driver call — a caller's consent gate sees `tool`+`args`
    /// verbatim before anything dispatches.
    struct Request: Sendable, Equatable {
        var tool: String
        var args: [String: JSONValue]
    }

    /// What an actuation produced. `dispatched` means the driver accepted
    /// and ran the call; `confirmed` only when the driver's own `effect`
    /// says so — `dom_event` clicks and `page` mutations report
    /// `unverifiable` (a synthetic event cannot prove activation), so a
    /// completed call is dispatched-but-unconfirmed, never upgraded.
    /// `result` carries the last call's raw structured body so a caller
    /// that minted evidence (the stamp step's element rect) can read it.
    struct Outcome: Sendable, Equatable {
        var dispatched: Bool
        var confirmed: Bool
        var effect: String
        var escalation: String?
        var detail: String?
        var result: JSONValue?

        static func refused(_ detail: String) -> Outcome {
            Outcome(dispatched: false, confirmed: false, effect: "refused",
                    escalation: nil, detail: detail, result: nil)
        }
        static func unreachable(_ detail: String) -> Outcome {
            Outcome(dispatched: false, confirmed: false, effect: "unreachable",
                    escalation: nil, detail: detail, result: nil)
        }
    }

    /// The daemon-launch knob for the legacy `page` mutations. It is read
    /// at daemon startup only — flipping the host environment does nothing
    /// until the daemon restarts, and the embedded daemon intentionally
    /// does not inherit ambient `CUA_DRIVER_*` variables.
    static let legacyMutationsEnv = "CUA_DRIVER_ENABLE_LEGACY_PAGE_MUTATIONS"
    /// Both launch-time gates a `page` mutation needs: the env flag above
    /// plus the driver adapter's unrestricted-mode requirement.
    static let mutationGateHint =
        "--permission-mode unrestricted plus \(legacyMutationsEnv)=1 at daemon startup"

    // MARK: - Ref-addressed requests (typed browser_* surface)

    /// Click a `get_browser_state` ref — `browser_click` pinned to the
    /// `dom_event` input route, the only route the driver serves into a
    /// standalone macOS browser window in background.
    static func clickRequest(ref: String, binding: BrowserSupport.Binding,
                             session: String) -> Request {
        var args = BrowserSupport.clickArgs(binding, ref: ref, session: session)
        args["input_route"] = .string("dom_event")
        return Request(tool: "browser_click", args: args)
    }

    /// Type into a `get_browser_state` ref — `browser_type` delivers
    /// `Input.insertText` (or per-key events with mode=keystrokes) into the
    /// exactly-bound element.
    static func typeRequest(ref: String, text: String,
                            binding: BrowserSupport.Binding,
                            session: String) -> Request {
        Request(tool: "browser_type",
                args: BrowserSupport.typeArgs(binding, ref: ref, text: text,
                                              session: session))
    }

    // MARK: - Selector-addressed requests (legacy page surface)

    /// `page click_element` — CSS selector addressing scoped to
    /// pid+window; the driver animates the agent cursor to the element's
    /// screen center before dispatching, so the user sees what was hit.
    static func clickRequest(selector: String, pid: Int, windowID: Int,
                             session: String) -> Request {
        Request(tool: "page", args: pageArgs(action: "click_element",
                                             pid: pid, windowID: windowID,
                                             session: session,
                                             extra: ["selector": .string(selector)]))
    }

    /// `insert_text`/`type_keystrokes` type into whatever holds DOM focus,
    /// so a selector-addressed type is a sequence: `click_element` focuses
    /// the element (and gives the cursor feedback) first.
    static func typeRequests(selector: String, text: String, pid: Int,
                             windowID: Int, session: String,
                             keystrokes: Bool = false) -> [Request] {
        [clickRequest(selector: selector, pid: pid, windowID: windowID,
                      session: session),
         Request(tool: "page", args: pageArgs(
            action: keystrokes ? "type_keystrokes" : "insert_text",
            pid: pid, windowID: windowID, session: session,
            extra: ["text": .string(text)]))]
    }

    /// The page-surface calls of a selector-addressed actuation, in
    /// dispatch order.
    static func pageRequests(action: Action, selector: String, pid: Int,
                             windowID: Int, session: String) -> [Request] {
        switch action {
        case .click:
            return [clickRequest(selector: selector, pid: pid,
                                 windowID: windowID, session: session)]
        case .insertText(let text):
            return typeRequests(selector: selector, text: text, pid: pid,
                                windowID: windowID, session: session)
        case .typeKeystrokes(let text):
            return typeRequests(selector: selector, text: text, pid: pid,
                                windowID: windowID, session: session,
                                keystrokes: true)
        }
    }

    enum Action: Sendable, Equatable {
        case click
        /// Bulk `Input.insertText` — one operation at the caret.
        case insertText(String)
        /// Per-character synthesized keys — slower but durable on editors
        /// that discard a bulk insert.
        case typeKeystrokes(String)
    }

    // MARK: - Dispatch

    /// Run requests in order through `call`, stopping at the first
    /// failure. The driver's own `effect` word survives verbatim; a `page`
    /// result carries no `effect`, so a returned call is `dispatched`
    /// (`effect == "unverifiable"`) but not `confirmed`. Refusals map to
    /// `Outcome.refused` — the legacy-page gates name their unlock knobs —
    /// and transport failures to `.unreachable`. Nothing here synthesizes
    /// a success the driver did not report.
    static func actuate(_ requests: [Request], via call: Call) async -> Outcome {
        var last = Outcome(dispatched: false, confirmed: false,
                           effect: "unverifiable", escalation: nil,
                           detail: nil, result: nil)
        for request in requests {
            do {
                let result = try await call(request.tool, request.args)
                let effect = result["effect"]?.string ?? "unverifiable"
                last = Outcome(dispatched: true, confirmed: effect == "confirmed",
                               effect: effect,
                               escalation: result["escalation"]?["recommended"]?.string,
                               detail: nil, result: result)
            } catch let error as DriverConnectionError {
                return refusalOutcome(for: request, error)
            } catch {
                return .unreachable("The driver connection failed mid-actuation: \(error.localizedDescription)")
            }
        }
        return last
    }

    // MARK: - Gaze `.dom` candidates

    /// The querySelectorAll selector the DOM probe enumerates — mirrors
    /// `GazeCandidateFeed.domProbeJS`; the actuation re-runs the same
    /// enumeration so a candidate's index resolves to the same element.
    /// (The probe literal lives in the gaze lane; keep the two in sync.)
    static let domInteractiveSelector =
        #"a[href],button,[role="button"],[role="link"],input,select,textarea,[role="menuitem"],[role="tab"],[role="checkbox"],[role="radio"],summary,[onclick]"#

    /// The attribute `page` selectors bind — stamped on the resolved
    /// element at actuation time so `click_element` hits exactly the node
    /// the probe enumerated.
    static let stampAttribute = "data-jev-act"

    /// Gaze parity entry point. A `.dom` candidate's id is
    /// `dom:<pid>:<wid>:<index>` — the probe's filtered enumeration order —
    /// so the element is re-resolved by the same enumeration, stamped with
    /// a unique attribute, and clicked through `page` `click_element` for
    /// cursor-animated delivery. The probe itself is an
    /// `execute_javascript` call, so a `.dom` candidate existing at all
    /// implies the legacy-mutation gates were open when it was minted; a
    /// refusal here is still reported honestly (stale element, moved rect,
    /// or a gate that closed since).
    static func actuate(candidate: IntentCandidate, session: String = "voice",
                        via call: Call) async -> Outcome {
        guard candidate.kind == .dom else {
            return .refused("BrowserActuation serves .dom candidates — \(candidate.kind.rawValue) has its own lane.")
        }
        let parts = candidate.id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "dom",
              let parsedPID = Int(parts[1]), let parsedWID = Int(parts[2]),
              let index = Int(parts[3]), index >= 0
        else { return .refused("The .dom candidate carries no resolvable element.") }
        let pid = candidate.pid.map(Int.init) ?? parsedPID
        let windowID = candidate.windowID ?? parsedWID
        let token = "jev\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"

        // Step 1: re-run the probe's enumeration, stamp element `index`,
        // and read back its rect in the same screen-point space the
        // candidate was minted in.
        let stamp = await actuate([Request(tool: "page", args: pageArgs(
            action: "execute_javascript",
            pid: pid, windowID: windowID, session: session,
            extra: ["javascript": .string(Self.stampJS(index: index, token: token))]))],
            via: call)
        guard stamp.dispatched, let result = stamp.result else { return stamp }

        // Step 2: the page may have reflowed between probe and commit —
        // clicking a stale index would land on a neighbor. The stamped
        // element's center must sit near the candidate's frame.
        guard let rect = stampedRect(result) else {
            return .refused("The element is no longer on the page — nothing was clicked.")
        }
        let dx = rect.midX - candidate.frame.midX
        let dy = rect.midY - candidate.frame.midY
        if (dx * dx + dy * dy).squareRoot() > 32 {
            return .refused("The element moved since it was seen — nothing was clicked.")
        }

        // Step 3: cursor-animated click on the stamp.
        return await actuate([clickRequest(
            selector: "[\(stampAttribute)=\"\(token)\"]",
            pid: pid, windowID: windowID, session: session)], via: call)
    }

    /// Re-runs the probe's filtered enumeration and stamps element
    /// `index` with `data-jev-act=<token>`, returning its rect in screen
    /// DIPs (the probe's `sx/sy + css-px*scale` convention). Stale stamps
    /// are swept first so a retried actuation binds exactly one element.
    static func stampJS(index: Int, token: String) -> String {
        """
        (() => {
          const sel = \(jsString(domInteractiveSelector));
          const want = \(index);
          const mark = \(jsString(token));
          document.querySelectorAll('[\(stampAttribute)]')
            .forEach(el => el.removeAttribute('\(stampAttribute)'));
          const s = window.visualViewport ? window.visualViewport.scale : 1;
          const sx = window.screenX + (window.outerWidth - window.innerWidth) / 2;
          const sy = window.screenY + (window.outerHeight - window.innerHeight);
          let n = 0;
          for (const el of document.querySelectorAll(sel)) {
            const r = el.getBoundingClientRect();
            if (r.width < 2 || r.height < 2) continue;
            const cs = getComputedStyle(el);
            if (cs.visibility === 'hidden' || cs.display === 'none') continue;
            if (n >= 60) break;
            if (n++ === want) {
              el.setAttribute('\(stampAttribute)', mark);
              return JSON.stringify({x: sx + r.left * s, y: sy + r.top * s,
                                     w: r.width * s, h: r.height * s});
            }
          }
          return JSON.stringify({error: 'element_gone'});
        })()
        """
    }

    // MARK: - Internals

    private static func pageArgs(action: String, pid: Int, windowID: Int,
                                 session: String,
                                 extra: [String: JSONValue]) -> [String: JSONValue] {
        var args: [String: JSONValue] = [
            "action": .string(action),
            "pid": .number(Double(pid)),
            "window_id": .number(Double(windowID)),
            "session": .string(session)]
        for (key, value) in extra { args[key] = value }
        return args
    }

    /// A JS string literal — `JSONEncoder` emits the quoted, escaped form
    /// so a selector carrying `"` survives embedding.
    static func jsString(_ string: String) -> String {
        (try? JSONEncoder().encode(string)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "\"\""
    }

    /// Map a thrown driver error to an honest outcome. `page` refusals
    /// arrive two ways: the `browser_unbounded_script` adapter throws
    /// `unbounded_operation_requires_unrestricted`, while PageTool's own
    /// flag check is a bare `ToolResult::error` whose text does not cross
    /// the `call` boundary — so the gate's unlock knobs are named here
    /// instead of repeating a generic transport string.
    private static func refusalOutcome(for request: Request,
                                       _ error: DriverConnectionError) -> Outcome {
        let isPageMutation = request.tool == "page"
            && (request.args["action"]?.string).map {
                ["execute_javascript", "click_element", "insert_text",
                 "type_keystrokes", "enable_javascript_apple_events"].contains($0)
            } == true
        switch error {
        case .toolRefused(_, let code, let detail):
            if isPageMutation, code == "unbounded_operation_requires_unrestricted"
                || detail.contains(legacyMutationsEnv)
                || detail.contains("legacy page mutation") {
                return .refused(
                    "The driver refused \(request.tool): legacy page mutations "
                    + "require \(mutationGateHint) — both are daemon-launch "
                    + "operator decisions.")
            }
            return .refused(detail.isEmpty
                            ? "The driver refused \(request.tool) (\(code))."
                            : detail)
        case .remote(let text):
            if isPageMutation {
                // A bare ToolResult::error loses its text crossing `call` —
                // for a mutating action the likeliest refusal is the gate,
                // with a missing element as the other possibility.
                return .refused(
                    "The driver refused the page action — legacy page mutations "
                    + "require \(mutationGateHint), or the element was gone.")
            }
            return .refused(text)
        case .refused(let text):
            if isPageMutation, text.contains("legacy page mutation")
                || text.contains(legacyMutationsEnv) {
                return .refused(
                    "The driver refused \(request.tool): legacy page mutations "
                    + "require \(mutationGateHint).")
            }
            return .refused(text)
        case .unavailable, .closed, .malformed, .timedOut:
            return .unreachable("The driver could not be reached: \(error.localizedDescription)")
        }
    }

    /// `execute_javascript` returns its JSON text in one of these slots —
    /// mirrored from `GazeCandidateFeed.domCandidates(from:)` so the stamp
    /// result decodes the same way.
    private static func resultText(_ result: JSONValue) -> String? {
        result["structuredContent"]?["result"]?.string
            ?? result["structuredContent"]?["output"]?.string
            ?? result["result"]?.string
            ?? result["content"]?.array?.compactMap { $0["text"]?.string }.first
            ?? result["text"]?.string
    }

    /// The stamp step's rect — the JS returns the element's screen-DIP
    /// rect, or `{error: "element_gone"}` when the index no longer
    /// resolves.
    private static func stampedRect(_ result: JSONValue) -> CGRect? {
        guard let text = resultText(result),
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = (obj["x"] as? NSNumber)?.doubleValue,
              let y = (obj["y"] as? NSNumber)?.doubleValue,
              let w = (obj["w"] as? NSNumber)?.doubleValue,
              let h = (obj["h"] as? NSNumber)?.doubleValue
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
