import AppKit
import Combine
import JevVoiceCore
import SwiftUI

@MainActor
final class VoiceController: ObservableObject {
    enum Status: Equatable {
        case idle, listening, thinking, awaitingConfirm, executing, done
        case error(String)
    }

    @Published var status: Status = .idle
    @Published var transcript = ""
    @Published var decisions: [Decision] = []
    @Published var latencyMs: Double = 0
    @Published var model = ""
    @Published var history: [Decision] = []
    @Published var showSettings = false
    @Published var missingPermissions: [Permission] = Permission.missing
    @Published var hotKeyRegistered = true

    var isListening: Bool { status == .listening }

    let config = Config.shared
    let recognizer = SpeechRecognizer()

    var onListeningChanged: ((Bool) -> Void)?
    var onDone: (() -> Void)?
    var onWillExecute: (() -> Void)?

    private var apps: [String] = []
    private var cancellables: Set<AnyCancellable> = []
    private var lastExternalApp = NSWorkspace.shared.frontmostApplication?.localizedName
    private var commandFrontmostApp: String?

    init() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastExternalApp = $0.localizedName }
            .store(in: &cancellables)
        recognizer.onFinalTranscript = { [weak self] text in
            Task { @MainActor in await self?.interpretAndExecute(text) }
        }
        recognizer.onEndedWithoutSpeech = { [weak self] error in
            guard let self, self.status == .listening else { return }
            if let error {
                self.status = .error("Speech recognition failed: \(error.localizedDescription)")
                self.onDone?()
            } else {
                self.status = .idle
            }
            self.onListeningChanged?(false)
        }
        recognizer.$transcript
            .filter { !$0.isEmpty }
            .sink { [weak self] in self?.transcript = $0 }
            .store(in: &cancellables)
    }

    func refreshPermissions() {
        missingPermissions = Permission.missing
    }

    /// Shows the system prompt for every permission the app still lacks and can
    /// still ask for; already-denied ones are left to the in-popover banner.
    func requestMissingPermissions() async {
        for permission in Permission.missing where permission.canPrompt {
            await permission.request()
        }
        refreshPermissions()
    }

    func toggle() {
        switch status {
        case .listening:
            recognizer.stop()
        case .idle, .done, .error:
            startListening()
        default:
            break
        }
    }

    private var startTask: Task<Void, Never>?

    func startListening() {
        guard startTask == nil else { return }
        commandFrontmostApp = lastExternalApp
        startTask = Task {
            defer { startTask = nil }
            let granted = await SpeechRecognizer.requestAuthorization()
            refreshPermissions()
            guard granted else {
                status = .error("Microphone or Speech Recognition permission denied")
                onDone?()
                return
            }
            do {
                decisions = []
                transcript = ""
                try recognizer.start()
                status = .listening
                onListeningChanged?(true)
            } catch {
                status = .error(error.localizedDescription)
                onDone?()
            }
        }
    }

    private func interpretAndExecute(_ text: String) async {
        status = .thinking
        onListeningChanged?(false)
        transcript = text

        if apps.isEmpty { apps = InstalledApps.all() }
        let client = JevClient(apiKey: config.apiKey)
        let interpreter = CommandInterpreter(client: client, installedApps: apps)
        let frontmost = commandFrontmostApp

        do {
            var result = try await interpreter.interpret(transcript: text, frontmostApp: frontmost)
            latencyMs = result.map(\.latencyMs).max() ?? 0
            model = result.first?.model ?? ""
            for i in result.indices { result[i].latencyMs = latencyMs }
            decisions = result
            history = (result + history).prefix(10).map { $0 }
        } catch {
            status = .error(error.localizedDescription)
            onDone?()
            return
        }

        if config.autoExecute && decisions.allSatisfy({ $0.confidence >= config.confidenceThreshold || $0.action == .none }) {
            await executeAll()
        } else {
            status = .awaitingConfirm
            onDone?()
        }
    }

    func confirmAndExecute() async {
        await executeAll()
    }

    func dismiss() {
        guard status == .awaitingConfirm else { return }
        decisions = []
        status = .idle
    }

    private func executeAll() async {
        let actionable = decisions.filter { $0.action != .none }
        guard !actionable.isEmpty else {
            status = .done
            onDone?()
            return
        }
        status = .executing
        onWillExecute?()
        for decision in actionable {
            do {
                _ = try await Executor.execute(decision)
            } catch {
                status = .error(error.localizedDescription)
                onDone?()
                return
            }
        }
        status = .done
        onDone?()
    }
}
