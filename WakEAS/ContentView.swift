import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 980, height: 640)
        #endif
    }
}

struct ContentView: View {
    @State private var monitor = EyeMonitor()
    @State private var alarm = EASAlarmSound()
    @State private var companion = CompanionLink.shared
    @AppStorage("closedSeconds") private var threshold = 3.0
    @AppStorage("alertSound") private var alertSound: AlertSound = .usa
    @AppStorage("alertTheme") private var alertTheme: AlertTheme = .yellow
    @AppStorage("musicSongID") private var musicSongID = ""
    @AppStorage("introSpeech") private var introSpeech = AlarmDefaults.intro
    @AppStorage("introLanguage") private var introLanguage: SpeechLanguage = .english
    @AppStorage("warningSpeech") private var warningSpeech = AlarmDefaults.warning
    @AppStorage("warningLanguage") private var warningLanguage: SpeechLanguage = .english
    @AppStorage("endingSpeech") private var endingSpeech = AlarmDefaults.ending
    @AppStorage("endingLanguage") private var endingLanguage: SpeechLanguage = .turkish
    @State private var closedFor = 0.0
    @State private var alarming = false
    @State private var activeTheme: AlertTheme = .yellow
    @State private var showingSettings = false
    #if os(iOS)
    @State private var savedBrightness: CGFloat?
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            monitorScreen
                .opacity(alarming ? 0 : 1)
                .allowsHitTesting(!alarming && !hasRemoteAlert)
                .accessibilityHidden(alarming || hasRemoteAlert)
            if alarming {
                EASAlarmView(theme: activeTheme, onDismiss: endAlarm)
                    .transition(.opacity)
            }
            #if os(iOS)
            if !alarming && companion.incomingAlert {
                EASAlarmView(theme: .yellow, onDismiss: { companion.incomingAlert = false })
                    .transition(.opacity)
            }
            #endif
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden(alarming)
        .persistentSystemOverlays(alarming ? .hidden : .automatic)
        #endif
        .animation(.easeInOut(duration: 0.12), value: alarming)
        .sheet(isPresented: $showingSettings) { AlarmSettingsView() }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 480)
        #endif
        .task { alarm.prepare() }
        .task { await monitor.start() }
        .task { companion.restoreIfEnabled() }
        .task { await runClock() }
        .onAppear(perform: holdAwake)
        .onDisappear {
            alarm.stop()
            monitor.stop()
            releaseAwake()
            if alarming { restoreBrightness() }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            closedFor = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            monitor.resume()
            if alarming { alarm.start(configuration: alarmConfiguration) }
        }
        #endif
    }

    private var monitorScreen: some View {
        #if os(macOS)
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 20) {
                cameraFrame
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls
                    .frame(width: min(320, max(240, geo.size.width * 0.32)))
            }
            .padding(20)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        #else
        ScrollView {
            VStack(spacing: 18) {
                titleBlock
                    .padding(.top, 12)
                cameraFrame
                    .frame(maxWidth: 520)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .padding(.horizontal, 22)
                controls
            }
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    private var titleBlock: some View {
        VStack(spacing: 4) {
            HStack {
                Text("WAKEAS")
                    .font(.system(size: 13, weight: .black))
                    .tracking(3)
                    .foregroundStyle(EASColor.red)
                Spacer(minLength: 8)
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .frame(width: 38, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel("Alarm settings")
            }
            .padding(.horizontal, 24)
            Text("Alarm when your eyes close")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
    }

    private var cameraFrame: some View {
        preview
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(monitor.eyesClosed ? EASColor.red : Color.white.opacity(0.14), lineWidth: monitor.eyesClosed ? 4 : 1)
            }
            .overlay { countdownOverlay }
    }

    private var controls: some View {
        VStack(spacing: 18) {
            #if os(macOS)
            titleBlock
            #endif
            statusBlock
            thresholdControl
            demoButton
        }
    }

    @ViewBuilder
    private var preview: some View {
        #if os(iOS) || os(macOS)
        if monitor.permission == .granted, monitor.failure == nil {
            MonitorPreview(monitor: monitor)
        } else {
            placeholder
        }
        #else
        placeholder
        #endif
    }

    private var placeholder: some View {
        ZStack {
            Color(white: 0.08)
            VStack(spacing: 10) {
                Image(systemName: "eye")
                    .font(.system(size: 36, weight: .light))
                Text(placeholderText)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 24)
                if monitor.permission == .denied {
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(.borderedProminent)
                        .tint(EASColor.red)
                } else if monitor.permission == .unknown || monitor.permission == .unavailable {
                    Button("Enable Camera") {
                        Task { await monitor.start() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(EASColor.red)
                }
            }
            .foregroundStyle(.white)
        }
    }

    private var placeholderText: String {
        if let failure = monitor.failure { return failure }
        switch monitor.permission {
        case .denied: return "Camera access is off. Allow it so the alarm can run."
        case .unavailable: return "No front camera on this device. You can still preview the alarm."
        case .unknown: return "The front camera watches your eyes. If they stay closed, the alarm starts."
        case .granted: return "Starting camera"
        }
    }

    private var countdownOverlay: some View {
        Group {
            if monitor.faceVisible && closedFor > 0.12 && !alarming {
                Text(remainingText)
                    .font(.system(size: 84, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.65), radius: 8, y: 2)
                    .monospacedDigit()
            }
        }
    }

    private var remainingText: String {
        let left = max(0, threshold - closedFor)
        return String(format: "%.1f", left)
    }

    private var statusBlock: some View {
        VStack(spacing: 8) {
            Text(statusTitle)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
            Text(instruction)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
            progress
                .frame(height: 6)
                .padding(.horizontal, 36)
                .padding(.top, 4)
            #if os(iOS)
            if alarm.outputVolume < 0.2 {
                Text("Volume is low. Turn it up for the alarm.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(EASColor.yellow)
            }
            #endif
        }
    }

    private var instruction: String {
        #if os(macOS)
        "Sit facing the camera."
        #else
        "Point the camera at your face."
        #endif
    }

    private var statusTitle: String {
        if monitor.permission != .granted { return "Waiting for camera" }
        if !monitor.faceVisible { return "No face detected" }
        if monitor.eyesClosed { return "Eyes closed" }
        return "Eyes open"
    }

    private var progress: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(monitor.eyesClosed ? EASColor.red : EASColor.yellow)
                    .frame(width: geo.size.width * progressFraction)
            }
        }
    }

    private var progressFraction: CGFloat {
        guard threshold > 0 else { return 0 }
        return min(1, CGFloat(closedFor / threshold))
    }

    private var thresholdControl: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Eyes closed for")
                Spacer()
                Text(String(format: "%.1f s", threshold))
                    .monospacedDigit()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.8))
            Slider(value: $threshold, in: 1.5...8, step: 0.5)
                .tint(EASColor.red)
        }
        .padding(.horizontal, 28)
    }

    private var demoButton: some View {
        Button("Preview alarm") { beginAlarm() }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(EASColor.red)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 22)
    }

    private func runClock() async {
        var last = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            let now = Date()
            let dt = min(0.2, now.timeIntervalSince(last))
            last = now
            tick(dt)
        }
    }

    private func tick(_ dt: Double) {
        guard !alarming else { return }
        guard !hasRemoteAlert else {
            closedFor = 0
            return
        }
        guard !showingSettings else {
            closedFor = 0
            return
        }
        // A paused camera must never keep the last "eyes closed" reading alive.
        #if os(macOS)
        let maxReadingAge = 0.8
        #else
        let maxReadingAge = 0.35
        #endif
        guard Date().timeIntervalSince(monitor.lastReadingAt) < maxReadingAge else {
            closedFor = 0
            return
        }
        if monitor.faceVisible && monitor.eyesClosed {
            closedFor += dt
            if closedFor >= threshold { beginAlarm() }
        } else {
            closedFor = 0
        }
    }

    private func beginAlarm() {
        guard !alarming else { return }
        activeTheme = alertTheme
        alarming = true
        boostBrightness()
        alarm.start(configuration: alarmConfiguration)
        #if os(macOS)
        companion.sendAlarm()
        #endif
    }

    private var hasRemoteAlert: Bool {
        #if os(iOS)
        companion.incomingAlert
        #else
        false
        #endif
    }

    private var alarmConfiguration: AlarmConfiguration {
        AlarmConfiguration(
            sound: alertSound,
            theme: alertTheme,
            musicSongID: musicSongID,
            intro: SpeechLine(text: introSpeech, language: introLanguage),
            warning: SpeechLine(text: warningSpeech, language: warningLanguage),
            ending: SpeechLine(text: endingSpeech, language: endingLanguage)
        )
    }

    private func endAlarm() {
        guard alarming else { return }
        alarming = false
        closedFor = 0
        alarm.stop()
        restoreBrightness()
    }

    private func holdAwake() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #elseif os(macOS)
        SleepActivity.shared.begin()
        #endif
    }

    private func releaseAwake() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #elseif os(macOS)
        SleepActivity.shared.end()
        #endif
    }

    private func boostBrightness() {
        #if os(iOS)
        guard let screen = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.screen else { return }
        savedBrightness = screen.brightness
        screen.brightness = 1
        #endif
    }

    private func restoreBrightness() {
        #if os(iOS)
        guard let savedBrightness,
              let screen = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first?.screen else { return }
        screen.brightness = savedBrightness
        self.savedBrightness = nil
        #endif
    }

    private func openSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #elseif os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
        #endif
    }
}

#if os(macOS)
@MainActor
final class SleepActivity {
    static let shared = SleepActivity()
    private var token: NSObjectProtocol?

    func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "WakEAS"
        )
    }

    func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}
#endif

#Preview {
    ContentView()
}
