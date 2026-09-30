import MusicKit
import SwiftUI

enum AlertSound: String, CaseIterable, Identifiable {
    case usa
    case japan
    case appleMusic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usa: "USA EAS"
        case .japan: "Japan-style alert"
        case .appleMusic: "Apple Music"
        }
    }
}

enum AlertTheme: String, CaseIterable, Identifiable {
    case yellow
    case black
    case red

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var accent: Color {
        switch self {
        case .yellow: EASColor.yellow
        case .black: .white
        case .red: EASColor.red
        }
    }

    var labelColor: Color { self == .red ? .white : EASColor.ink }
}

enum SpeechLanguage: String, CaseIterable, Identifiable {
    case english = "en-US"
    case turkish = "tr-TR"
    case japanese = "ja-JP"
    case german = "de-DE"
    case spanish = "es-ES"
    case french = "fr-FR"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: "English"
        case .turkish: "Türkçe"
        case .japanese: "日本語"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .french: "Français"
        }
    }
}

enum AlarmDefaults {
    static let intro = "PRESIDENTIAL WARNING!"
    static let warning = "THIS IS NOT A DRILL! THIS IS NOT A DRILL! IT HAS BEEN DETECTED THAT YOUR EYELID IS CLOSED!"
    static let ending = "UYAN YEĞEN! ALARM ÇALIYOR!"
}

struct SpeechLine {
    let text: String
    let language: SpeechLanguage
}

struct AlarmConfiguration {
    let sound: AlertSound
    let theme: AlertTheme
    let musicSongID: String
    let intro: SpeechLine
    let warning: SpeechLine
    let ending: SpeechLine
}

struct AlarmSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var companion = CompanionLink.shared
    @AppStorage("alertSound") private var sound: AlertSound = .usa
    @AppStorage("alertTheme") private var theme: AlertTheme = .yellow
    @AppStorage("musicSongID") private var musicSongID = ""
    @AppStorage("musicSongTitle") private var musicSongTitle = ""
    @AppStorage("musicSongArtist") private var musicSongArtist = ""
    @AppStorage("introSpeech") private var introSpeech = AlarmDefaults.intro
    @AppStorage("introLanguage") private var introLanguage: SpeechLanguage = .english
    @AppStorage("warningSpeech") private var warningSpeech = AlarmDefaults.warning
    @AppStorage("warningLanguage") private var warningLanguage: SpeechLanguage = .english
    @AppStorage("endingSpeech") private var endingSpeech = AlarmDefaults.ending
    @AppStorage("endingLanguage") private var endingLanguage: SpeechLanguage = .turkish
    @State private var showingMusicPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Alert") {
                    Picker("Sound", selection: $sound) {
                        ForEach(AlertSound.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    Picker("Colors", selection: $theme) {
                        ForEach(AlertTheme.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    if sound == .appleMusic {
                        Button("Choose a song") { showingMusicPicker = true }
                        Text(musicSongID.isEmpty ? "No song selected" : "\(musicSongTitle) — \(musicSongArtist)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Mac–iPhone Connection") {
                    Toggle(companionToggleTitle, isOn: Binding(
                        get: { companion.enabled },
                        set: { companion.setEnabled($0) }
                    ))
                    if let connectedName = companion.connectedName {
                        Label("Connected: \(connectedName)", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    }
                    #if os(macOS)
                    ForEach(companion.nearbyPhones) { phone in
                        Button("Connect to \(phone.name)") { companion.connect(to: phone) }
                    }
                    #else
                    Text("Keep both apps open to receive Mac alerts on this iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    #endif
                }
                speechSection("Opening", text: $introSpeech, language: $introLanguage)
                speechSection("Warning", text: $warningSpeech, language: $warningLanguage)
                speechSection("Closing", text: $endingSpeech, language: $endingLanguage)
                Section {
                    Button("Reset Speech to Defaults", role: .destructive, action: resetSpeech)
                        .disabled(speechIsDefault)
                }
            }
            .navigationTitle("Alarm Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingMusicPicker) {
                MusicSongPicker()
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 580)
        #endif
    }

    private var companionToggleTitle: String {
        #if os(macOS)
        "Find nearby iPhones"
        #else
        "Allow nearby Macs"
        #endif
    }

    private var speechIsDefault: Bool {
        introSpeech == AlarmDefaults.intro && introLanguage == .english
            && warningSpeech == AlarmDefaults.warning && warningLanguage == .english
            && endingSpeech == AlarmDefaults.ending && endingLanguage == .turkish
    }

    private func resetSpeech() {
        introSpeech = AlarmDefaults.intro
        introLanguage = .english
        warningSpeech = AlarmDefaults.warning
        warningLanguage = .english
        endingSpeech = AlarmDefaults.ending
        endingLanguage = .turkish
    }

    private func speechSection(_ title: String, text: Binding<String>, language: Binding<SpeechLanguage>) -> some View {
        Section(title) {
            Picker("Language", selection: language) {
                ForEach(SpeechLanguage.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            TextEditor(text: text)
                .frame(minHeight: 72)
                .accessibilityLabel("\(title) speech text")
        }
    }
}

private struct MusicSongPicker: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("musicSongID") private var musicSongID = ""
    @AppStorage("musicSongTitle") private var musicSongTitle = ""
    @AppStorage("musicSongArtist") private var musicSongArtist = ""
    @State private var search = ""
    @State private var songs: [Song] = []
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                if let message { Text(message).foregroundStyle(.secondary) }
                ForEach(songs, id: \.id) { song in
                    Button {
                        musicSongID = song.id.rawValue
                        musicSongTitle = song.title
                        musicSongArtist = song.artistName
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title)
                            Text(song.artistName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search your Apple Music library")
            .navigationTitle("Choose a Song")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: search) { await loadSongs() }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 480)
        #endif
    }

    private func loadSongs() async {
        if !search.isEmpty {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
        }
        let status = MusicAuthorization.currentStatus == .authorized
            ? MusicAuthorization.currentStatus : await MusicAuthorization.request()
        guard status == .authorized else {
            message = "Allow Music access in Settings to choose a song."
            songs = []
            return
        }
        do {
            let results: [Song]
            if search.isEmpty {
                var request = MusicLibraryRequest<Song>()
                request.limit = 100
                results = Array(try await request.response().items)
            } else {
                var request = MusicLibrarySearchRequest(term: search, types: [Song.self])
                request.limit = 100
                results = Array(try await request.response().songs)
            }
            guard !Task.isCancelled else { return }
            songs = results
            message = results.isEmpty ? "No songs found in your library." : nil
        } catch {
            message = "Couldn't load your music library. Check MusicKit access and try again."
            songs = []
        }
    }
}
