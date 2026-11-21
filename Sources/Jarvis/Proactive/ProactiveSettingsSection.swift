import SwiftUI

/// The alert settings shown in Settings while `voice.live` is on: the
/// more/less level, calendar access, important people and the opt-in
/// notification banner source (D4).
struct ProactiveSettingsSection: View {
    @ObservedObject var settings: ProactiveSettings
    @State private var people = ""
    @State private var calendarAllowed = EventKitSource.allowed

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Speak up", selection: $settings.level) {
                ForEach(ProactiveLevel.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(levelNote).font(.callout).foregroundStyle(.secondary)
            if !calendarAllowed {
                Button("Allow Calendar and Reminders") {
                    Task {
                        await EventKitSource.requestAccess()
                        calendarAllowed = EventKitSource.allowed
                    }
                }
            }
            TextField("Important people, separated by commas", text: $people)
                .onSubmit(savePeople)
                .onDisappear(perform: savePeople)
            Toggle("Read other apps' notifications", isOn: $settings.readNotificationBanners)
            Text("Jarvis reads notification banners on this Mac to find urgent messages from important people. Their text never leaves your Mac.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { people = settings.importantPeople.joined(separator: ", ") }
    }

    private var levelNote: String {
        switch settings.level {
        case .quiet: "Jarvis speaks only for safety warnings and reminders you set."
        case .normal: "Jarvis speaks for meetings, urgent messages and replies you're waiting for, up to 3 times an hour."
        case .chatty: "Jarvis also speaks smaller updates, up to 6 times an hour."
        }
    }

    private func savePeople() {
        settings.importantPeople = people.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
