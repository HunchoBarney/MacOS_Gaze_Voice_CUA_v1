import CryptoKit
import Darwin
import Foundation
import JevVoiceCore

@MainActor
enum VoiceRemoteTrial {
    nonisolated static func main() -> Never {
        Task { @MainActor in
            do { exit(try await run()) }
            catch {
                FileHandle.standardError.write(Data("Remote trial preflight failed. No acceptance recorded.\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private static func uuids(_ url: URL) throws -> [String] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dwarfdump")
        process.arguments = ["--uuid", url.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let ids = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: " ")
            guard fields.count >= 3, fields[0] == "UUID:" else { return nil }
            return String(fields[1]) + " " + String(fields[2])
        }.sorted()
        guard process.terminationStatus == 0, !ids.isEmpty else { throw VoiceError("remote_uuid_missing") }
        return ids
    }

    private static func run() async throws -> Int32 {
        let args = CommandLine.arguments
        func argument(_ name: String) throws -> String {
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
                throw VoiceError("remote_argument_missing")
            }
            return args[index + 1]
        }
        guard ProcessInfo.processInfo.environment["JARVIS_P3_REMOTE_LIVE"] == "approved-4" else {
            throw VoiceError("remote_live_not_enabled")
        }
        let evidence = root.appendingPathComponent(".agent/results/P3/remote-evidence")
        let auth = URL(fileURLWithPath: try argument("--authorization")).standardizedFileURL
        guard auth == evidence.appendingPathComponent("authorization.json") else {
            throw VoiceError("remote_authorization_path")
        }
        let id = try argument("--authorization-id")
        let budget = try VoiceRemoteResponseBudget(url: auth, authorizationID: id)
        let out = URL(fileURLWithPath: try argument("--out")).standardizedFileURL.resolvingSymlinksInPath()
        guard out.deletingLastPathComponent().deletingLastPathComponent() == evidence.resolvingSymlinksInPath(),
              out.lastPathComponent == "result.json",
              !FileManager.default.fileExists(atPath: out.path) else {
            throw VoiceError("remote_output_path")
        }
        let buildURL = root.appendingPathComponent(".agent/results/P3/build.json")
        let build = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: buildURL))
        let source = root.appendingPathComponent(".build/release/JevVoice")
        let executed = URL(fileURLWithPath: args[0]).standardizedFileURL
        let sourceIDs = try uuids(source), executedIDs = try uuids(executed)
        guard sourceIDs == executedIDs, build["artifact_sha256"]?.string == (try digest(source)),
              let hashes = build["source_hashes"]?.object else { throw VoiceError("remote_build_stale") }
        for (path, hash) in hashes {
            guard hash.string == (try digest(root.appendingPathComponent(path))) else {
                throw VoiceError("remote_source_stale")
            }
        }
        var report: [String: JSONValue] = [
            "schema_version": .number(1), "source": .string("server-live"),
            "verification_kind": .string("production-realtime-server"), "remote_live_authorized": .bool(true),
            "authorization_id": .string(id), "artifact_sha256": build["artifact_sha256"] ?? .null,
            "source_hashes": .object(hashes), "executed_executable": .string(executed.path),
            "executed_artifact_sha256": .string(try digest(executed)),
            "executed_build_uuids": .array(executedIDs.map(JSONValue.string)),
            "profile": .string("production-lane-real-websocket-text-only"),
            "phase_accepted": .bool(false), "rows": .array([])
        ]
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: false)
        func save() throws {
            try JSONEncoder().encode(JSONValue.object(report)).write(to: out, options: .atomic)
        }
        report["status"] = .string("preflight")
        try save()
        let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            ?? (try? KeychainAPIKeyStore(account: "openAIAPIKey", allowUserInteraction: false).read()) ?? ""
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            report["status"] = .string("blocked")
            report["reason"] = .string("credential_unavailable_without_interaction")
            try save()
            return 2
        }
        let driver = Driver(apiKey: key, budget: budget)
        do {
            _ = try await withVoiceDeadline(until: ProcessInfo.processInfo.systemUptime + 180) {
                try await driver.perform()
                return true
            }
            report["status"] = .string("passed")
        } catch {
            report["status"] = .string("failed")
            report["reason"] = .string("live_exchange_or_verification_failed")
        }
        await driver.close()
        if await driver.control.hasOverflow() {
            report["status"] = .string("failed")
            report["reason"] = .string("transport_metadata_overflow")
        }
        report["rows"] = .array(driver.rows)
        report["ingress"] = driver.metadata.snapshot
        report["outbound"] = .array(await driver.control.frames())
        report["desktop_executor_attempts"] = .number(Double(driver.state.forbidden))
        try save()
        print("Remote diagnostic attempt saved; phase acceptance remains false.")
        return report["status"]?.string == "passed" ? 0 : 1
    }

    @MainActor
    private final class State {
        var wires: [VoiceRemoteLiveWire] = []
        var replies: [UUID: [String]] = [:]
        var ended: Set<UUID> = []
        var forbidden = 0
        var failed = false
    }

    @MainActor
    private final class Driver {
        let control = VoiceRemoteLiveControl()
        let metadata = VoiceRemoteMetadata(frameLimit: 1024, byteLimit: 256 * 1024)
        let state = State()
        let client: RealtimeVoiceClient
        let lane: RealtimeVoiceLane
        var rows: [JSONValue] = []

        init(apiKey: String, budget: VoiceRemoteResponseBudget) {
            let state = self.state, control = self.control, metadata = self.metadata
            let client = RealtimeVoiceClient(wireFactory: { request in
                let wire = VoiceRemoteLiveWire(request: request, budget: budget, control: control)
                state.wires.append(wire)
                return wire
            })
            self.client = client
            let lane = RealtimeVoiceLane(apiKey: { apiKey }, client: client)
            self.lane = lane
            let original = client.onWireEvent
            client.onWireEvent = { envelope in metadata.record(envelope); original?(envelope) }
            lane.commandHandler = { _, _, _, _, _, _ in
                state.forbidden += 1
                return VoiceToolCatalog.result(status: "refused", summary: "Diagnostic desktop tripwire.")
            }
            lane.exactTaskResponseHandler = { _, _, _, _ in
                state.forbidden += 1
                return VoiceToolCatalog.result(status: "refused", summary: "Diagnostic task tripwire.")
            }
            lane.delegationHandler = { _, _, _, _, _ in
                state.forbidden += 1
                return VoiceToolCatalog.result(status: "refused", summary: "Diagnostic delegation tripwire.")
            }
            lane.onEvent = { id, event in
                switch event {
                case .toolSay(let text): state.replies[id, default: []].append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                case .turnEnded: state.ended.insert(id)
                case .failure: state.failed = true
                default: break
                }
            }
        }

        var frames: [JSONValue] { metadata.snapshot["frames"]?.array ?? [] }

        func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                guard !state.failed, state.forbidden == 0, metadata.snapshot["overflow"]?.bool == false else {
                    throw VoiceError("remote_trial_guard_failed")
                }
                if await condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw VoiceError("remote_case_deadline")
        }

        func created(after index: Int, generation: UUID) -> JSONValue? {
            frames.dropFirst(index).first {
                $0["kind"]?.string == "response.created"
                    && $0["connection_generation"]?.string == generation.uuidString
            }
        }

        func row(_ caseID: String, stage: String, turn: UUID, start: Int, generation: UUID) async throws -> [String: JSONValue] {
            let sent = await control.frames().filter {
                $0["kind"]?.string == "response.create" && $0["case_id"]?.string == caseID && $0["stage"]?.string == stage
            }
            let outputs = await control.frames().filter {
                $0["kind"]?.string == "conversation.item.create"
                    && $0["function_output_call_id"]?.string != nil
                    && $0["case_id"]?.string == caseID && $0["stage"]?.string == stage
            }
            let expected = caseID == "safe-miss" || (caseID == "stale-response" && stage == "new") ? 1 : 0
            guard sent.count == 1, let request = sent.first?["request_id"]?.string,
                  let response = created(after: start, generation: generation)?["response_id"]?.string,
                  outputs.count == expected, state.forbidden == 0 else {
                throw VoiceError("remote_case_evidence_missing")
            }
            return ["case_id": .string(caseID), "request_id": .string(request),
                    "server_response_id": .string(response), "turn_id": .string(turn.uuidString),
                    "connection_generation": .string(generation.uuidString),
                    "verification_passed": .bool(true), "wrong_critical_actions": .number(Double(state.forbidden)),
                    "dispatch_count": .number(Double(outputs.count)),
                    "duplicate_dispatches": .number(Double(max(0, outputs.count - expected)))]
        }

        func perform() async throws {
            let safe = UUID(), safeStart = frames.count
            try await lane.submitTyped(VoiceRemoteLivePolicy.safeQuestion, sessionID: safe)
            let safeGeneration = client.connectionID
            try await wait { self.state.ended.contains(safe) && !self.lane.responseInFlight }
            guard state.replies[safe] == ["4"] else { throw VoiceError("remote_safe_reply_mismatch") }
            rows.append(.object(try await row("safe-miss", stage: "safe", turn: safe, start: safeStart, generation: safeGeneration)))

            let outcomeStart = frames.count
            await control.configure(.init(caseID: "outcome-only", stage: "outcome"))
            lane.pushTaskEvent(VoiceRemoteLivePolicy.outcome, speak: true)
            try await wait {
                guard let response = self.created(after: outcomeStart, generation: safeGeneration)?["response_id"]?.string else { return false }
                return !self.lane.responseInFlight && self.frames.dropFirst(outcomeStart).contains {
                    $0["kind"]?.string == "response.done" && $0["response_id"]?.string == response
                }
            }
            let outcomeSent = await control.frames().filter {
                $0["kind"]?.string == "response.create" && $0["case_id"]?.string == "outcome-only"
            }
            guard outcomeSent.count == 1, outcomeSent[0]["tools_disabled"]?.bool == true,
                  frames.dropFirst(outcomeStart).allSatisfy({ ($0["call_ids"]?.array ?? []).isEmpty }) else {
                throw VoiceError("remote_outcome_authority_failed")
            }
            var outcome = try await row("outcome-only", stage: "outcome", turn: safe, start: outcomeStart, generation: safeGeneration)
            outcome["owning_turn_id"] = .null
            outcome["source_turn_id"] = .string(safe.uuidString)
            outcome["tools_disabled"] = .bool(true)
            rows.append(.object(outcome))

            await control.configure(.init(caseID: "cancel", stage: "cancel", holdCalls: true))
            let cancel = UUID(), cancelStart = frames.count
            try await lane.submitTyped(VoiceRemoteLivePolicy.cancelQuestion, sessionID: cancel)
            let cancelGeneration = client.connectionID
            try await wait { self.created(after: cancelStart, generation: cancelGeneration) != nil }
            guard lane.responseInFlight, let cancelWire = state.wires.last else {
                throw VoiceError("remote_cancel_not_pending")
            }
            lane.cancel()
            try await wait {
                let closed = await cancelWire.isClosed()
                return self.client.connectionID != cancelGeneration && closed
            }
            guard state.replies[cancel, default: []].isEmpty else { throw VoiceError("remote_cancel_reply_escaped") }
            var cancellation = try await row("cancel", stage: "cancel", turn: cancel, start: cancelStart, generation: cancelGeneration)
            cancellation["cancellation_kind"] = .string("owning_connection_closed")
            rows.append(.object(cancellation))

            await control.configure(.init(caseID: "stale-response", stage: "old", holdCalls: true, forceAnswer: true))
            let old = UUID(), oldStart = frames.count
            try await lane.submitTyped(VoiceRemoteLivePolicy.oldQuestion, sessionID: old)
            let oldGeneration = client.connectionID
            guard let oldWire = state.wires.last else { throw VoiceError("remote_old_wire_missing") }
            try await wait { await oldWire.heldPayload != nil }
            guard let raw = await oldWire.heldPayload else { throw VoiceError("remote_live_frame_missing") }
            lane.cancel()
            try await wait { await oldWire.isClosed() }

            await control.configure(.init(caseID: "stale-response", stage: "new", holdCalls: true, forceAnswer: true))
            let new = UUID(), newStart = frames.count
            try await lane.submitTyped(VoiceRemoteLivePolicy.newQuestion, sessionID: new)
            let newGeneration = client.connectionID
            guard newGeneration != oldGeneration, let newWire = state.wires.last else {
                throw VoiceError("remote_reconnect_missing")
            }
            try await wait {
                let held = await newWire.heldPayload != nil
                return self.created(after: newStart, generation: newGeneration) != nil && held
            }
            guard let envelope = RealtimeVoiceClient.decodeWire(raw, connectionID: oldGeneration),
                  let oldResponse = envelope.responseID,
                  let oldCall = envelope.events.compactMap({ event -> String? in
                      if case .functionCall(let id, let name, _) = event, name == "answer" { return id }
                      return nil
                  }).first else { throw VoiceError("remote_live_frame_missing") }
            for _ in 0..<2 {
                guard let replay = RealtimeVoiceClient.decodeWire(raw, connectionID: oldGeneration) else {
                    throw VoiceError("remote_replay_decode_failed")
                }
                client.onWireEvent?(replay)
            }
            let deliveries = frames.filter {
                $0["kind"]?.string == "response.function_call_arguments.done"
                    && $0["connection_generation"]?.string == oldGeneration.uuidString
                    && $0["response_id"]?.string == oldResponse
                    && $0["call_ids"]?.array?.contains(.string(oldCall)) == true
            }
            guard deliveries.count == 2 else { throw VoiceError("remote_replay_ingress_missing") }
            await newWire.releaseHeld()
            try await wait { self.state.ended.contains(new) && !self.lane.responseInFlight }
            guard state.replies[new] == ["9"], state.replies[old, default: []].isEmpty else {
                throw VoiceError("remote_stale_frame_escaped")
            }
            var stale = try await row("stale-response", stage: "new", turn: new, start: newStart, generation: newGeneration)
            let oldRow = try await row("stale-response", stage: "old", turn: old, start: oldStart, generation: oldGeneration)
            stale["old_request_id"] = oldRow["request_id"]
            stale["old_dispatch_count"] = oldRow["dispatch_count"]
            stale["old_connection_generation"] = .string(oldGeneration.uuidString)
            stale["old_server_response_id"] = .string(oldResponse)
            stale["old_call_id"] = .string(oldCall)
            stale["replayed_frame_sha256"] = .string(SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined())
            stale["local_replay_count"] = .number(2)
            stale["network_replay"] = .bool(false)
            rows.append(.object(stale))
            let overflow = await control.hasOverflow()
            guard rows.count == 4, state.forbidden == 0, !overflow, metadata.snapshot["overflow"]?.bool == false else {
                throw VoiceError("remote_final_guard_failed")
            }
        }

        func close() async {
            lane.cancel()
            client.teardown()
            for wire in state.wires { await wire.close() }
        }
    }
}
