import SwiftUI
#if os(iOS)
import CoreHaptics
import UIKit
#endif

enum EASColor {
    static let red = Color(red: 0.86, green: 0.02, blue: 0.07)
    static let yellow = Color(red: 1.0, green: 0.84, blue: 0.0)
    static let ink = Color(red: 0.02, green: 0.02, blue: 0.02)
}

struct EASAlarmView: View {
    var theme: AlertTheme = .yellow
    var onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Color.black
                alarm(date: context.date)
                    .padding(12)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(theme.accent.opacity(borderOpacity(t)), lineWidth: 8)
                    .padding(5)
                    .allowsHitTesting(false)
            }
            #if os(iOS)
            .overlay(alignment: .topTrailing) {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(theme.labelColor)
                        .frame(width: 52, height: 52)
                        .background(theme.accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop alarm")
                .padding(.top, 18)
                .padding(.trailing, 20)
            }
            #endif
        }
        .background(Color.black.ignoresSafeArea())
        .task { await pulseHaptics() }
    }

    private var cornerRadius: CGFloat {
        #if os(iOS)
        40
        #else
        0
        #endif
    }

    private func borderOpacity(_ t: TimeInterval) -> Double {
        if reduceMotion { return 1 }
        return 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 2 * .pi * 0.8))
    }

    private func alarm(date: Date) -> some View {
        GeometryReader { geo in
            #if os(macOS)
            let scale = min(max(min(geo.size.width / 800, geo.size.height / 480), 0.72), 1.35)
            #else
            let scale = min(max(min(geo.size.width / 390, geo.size.height / 700), 0.72), 1.35)
            #endif
            VStack(spacing: 0) {
                header(date: date, scale: scale)
                Spacer(minLength: 12)
                VStack(spacing: 8 * scale) {
                    Text("WAKE UP")
                        .font(.system(size: 76 * scale, weight: .black))
                        .minimumScaleFactor(0.35)
                        .lineLimit(1)
                    Text("OPEN YOUR EYES")
                        .font(.system(size: 28 * scale, weight: .heavy))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text("EYES CLOSED")
                        .font(.system(size: 16 * scale, weight: .bold))
                        .tracking(1.4)
                        .padding(.top, 6 * scale)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                #if os(macOS)
                .frame(maxWidth: 720)
                #endif
                Spacer(minLength: 12)
                ticker(scale: scale)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Color.black)
        }
    }

    private func header(date: Date, scale: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("EMERGENCY ALERT")
                    .font(.system(size: 22 * scale, weight: .black))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(date.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 13 * scale, weight: .bold, design: .monospaced))
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            #if os(macOS)
            Text("WAKEAS")
                .font(.system(size: 14 * scale, weight: .black))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(EASColor.ink)
                .foregroundStyle(theme.accent)
            #endif
            #if os(macOS)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 18 * scale, weight: .heavy))
                    .frame(width: 44, height: 44)
                    .background(EASColor.ink, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(theme.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop alarm")
            .layoutPriority(1)
            #endif
        }
        .foregroundStyle(theme.labelColor)
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 10 * scale)
        .frame(maxWidth: .infinity)
        .background(theme.accent)
    }

    private func ticker(scale: CGFloat) -> some View {
        #if os(macOS)
        let text = "WAKEAS ALERT  ·  EYES CLOSED  ·  PRESS × TO STOP  ·  THIS IS A WAKE ALARM"
        #else
        let text = "EYES CLOSED  ·  PRESS × TO STOP"
        #endif
        return Text(text)
            .font(.system(size: 16 * scale, weight: .bold))
            .foregroundStyle(theme.labelColor)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity)
            .frame(height: 32 * scale)
            .background(theme.accent)
    }

    private func pulseHaptics() async {
        #if os(iOS)
        let haptics = AlarmHaptics()
        haptics.start()
        defer { haptics.stop() }
        while !Task.isCancelled {
            haptics.pulse()
            do {
                try await Task.sleep(for: .milliseconds(1_200))
            } catch {
                break
            }
        }
        #endif
    }
}

#if os(iOS)
@MainActor
private final class AlarmHaptics {
    private var engine: CHHapticEngine?
    private let fallback = UIImpactFeedbackGenerator(style: .heavy)

    func start() {
        fallback.prepare()
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.isAutoShutdownEnabled = false
        try? engine?.start()
    }

    func pulse() {
        guard let engine else {
            fallback.impactOccurred(intensity: 1)
            fallback.prepare()
            return
        }
        let events = [
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
            ], relativeTime: 0, duration: 0.45),
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)
            ], relativeTime: 0.55)
        ]
        guard let pattern = try? CHHapticPattern(events: events, parameters: []),
              let player = try? engine.makePlayer(with: pattern) else {
            fallback.impactOccurred(intensity: 1)
            return
        }
        do {
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            fallback.impactOccurred(intensity: 1)
        }
    }

    func stop() {
        engine?.stop(completionHandler: nil)
    }
}
#endif

#Preview("Alarm") {
    EASAlarmView(onDismiss: {})
}
