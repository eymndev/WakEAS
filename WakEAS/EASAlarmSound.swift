import AVFoundation
import Darwin
import Foundation

@MainActor
final class EASAlarmSound {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let narrator = AlarmNarrator()
    private let music = MusicAlarmPlayer()
    private var buffer: AVAudioPCMBuffer?
    private var intro: AVAudioPCMBuffer?
    private var japanBuffer: AVAudioPCMBuffer?
    private var installed = false
    private var sequence: Task<Void, Never>?
    #if os(iOS)
    private var sessionTransition: Task<Void, Never>?
    #endif

    func prepare() {
        installIfNeeded()
        if !engine.isRunning { engine.prepare() }
    }

    func start(configuration: AlarmConfiguration) {
        installIfNeeded()
        guard installed, sequence == nil else { return }
        player.volume = 1
        engine.mainMixerNode.outputVolume = 1
        #if os(iOS)
        let previousTransition = sessionTransition
        #endif
        sequence = Task { [weak self] in
            #if os(iOS)
            await previousTransition?.value
            #endif
            guard let self else { return }
            await self.runSequence(configuration: configuration)
        }
    }

    func stop() {
        let previousSequence = sequence
        previousSequence?.cancel()
        sequence = nil
        narrator.stop()
        player.stop()
        music.stop()
        engine.stop()
        #if os(iOS)
        let previousTransition = sessionTransition
        sessionTransition = Task { [weak self] in
            await previousTransition?.value
            await previousSequence?.value
            guard let self else { return }
            await self.deactivateSession()
        }
        #endif
    }

    private func runSequence(configuration: AlarmConfiguration) async {
        guard await activateSession(for: configuration.sound), !Task.isCancelled else { return }
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
        while !Task.isCancelled {
            await speak(configuration.intro)
            guard !Task.isCancelled else { break }
            await playSignal(configuration: configuration)
            guard !Task.isCancelled else { break }
            await speak(configuration.warning)
            guard !Task.isCancelled else { break }
            await speak(configuration.ending)
        }
    }

    private func speak(_ line: SpeechLine) async {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await narrator.say(text, language: line.language.rawValue)
    }

    private func playSignal(configuration: AlarmConfiguration) async {
        if configuration.sound == .appleMusic {
            if await music.start(songID: configuration.musicSongID) {
                try? await Task.sleep(for: .seconds(12))
                return
            }
            guard !Task.isCancelled else { return }
        }
        guard let duration = beginSignalPlayback(sound: configuration.sound) else { return }
        try? await Task.sleep(for: .seconds(duration))
        player.stop()
    }

    private func beginSignalPlayback(sound: AlertSound) -> Double? {
        player.stop()
        var duration = 8.0
        if sound == .japan {
            guard let japanBuffer else { return nil }
            player.scheduleBuffer(japanBuffer, at: nil, options: .loops, completionHandler: nil)
        } else {
            guard let buffer, let intro else { return nil }
            player.scheduleBuffer(intro, at: nil, options: [], completionHandler: nil)
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            duration += Double(intro.frameLength) / intro.format.sampleRate
        }
        try? player.playAudio()
        return duration
    }

    private func activateSession(for sound: AlertSound) async -> Bool {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback, mode: .default,
                options: sound == .appleMusic ? [.mixWithOthers] : [.duckOthers]
            )
        } catch {
            return false
        }
        return await withCheckedContinuation { continuation in
            session.activate(options: []) { activated, _ in
                continuation.resume(returning: activated)
            }
        }
        #else
        return true
        #endif
    }

    #if os(iOS)
    private func deactivateSession() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            AVAudioSession.sharedInstance().deactivate(options: .notifyOthersOnDeactivation) { _, _ in
                continuation.resume()
            }
        }
    }
    #endif

    private func installIfNeeded() {
        guard !installed else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
              let buffer = AlarmSynth.makeBuffer(format: format),
              let intro = AlarmSynth.makeIntro(format: format),
              let japanBuffer = AlarmSynth.makeJapanBuffer(format: format) else { return }
        self.buffer = buffer
        self.intro = intro
        self.japanBuffer = japanBuffer
        engine.attach(player)
        do {
            try engine.connectNode(player, to: engine.mainMixerNode, format: format)
        } catch {
            return
        }
        installed = true
    }

    #if os(iOS)
    var outputVolume: Float {
        AVAudioSession.sharedInstance().outputVolume
    }
    #endif
}

@MainActor
private final class AlarmNarrator: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var completion: CheckedContinuation<Void, Never>?
    private var current: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
        #if os(iOS)
        // A separate speech session mixes with and automatically ducks the MusicKit player.
        synthesizer.usesApplicationAudioSession = false
        #endif
    }

    func say(_ text: String, language: String) async {
        guard !Task.isCancelled else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.43
        utterance.pitchMultiplier = 0.8
        await withCheckedContinuation { continuation in
            current = utterance
            completion = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        finish(current.map(ObjectIdentifier.init))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finish(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finish(id) }
    }

    private func finish(_ id: ObjectIdentifier?) {
        guard let id, current.map(ObjectIdentifier.init) == id else { return }
        current = nil
        completion?.resume()
        completion = nil
    }
}

enum AlarmSynth {
    // SAME-style AFSK with no valid SAME preamble/header; an alarm must not address broadcast decoders.
    static func makeIntro(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let burst = 1.15
        let interval = 1.8
        let duration = interval * 3
        let count = Int(rate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        let bytes = Array("WAKEAS".utf8)
        var phase = 0.0
        for i in 0..<count {
            let time = Double(i) / rate
            let local = time.truncatingRemainder(dividingBy: interval)
            var sample = 0.0
            if local < burst {
                let bitIndex = Int(local * (3_125.0 / 6.0))
                let byte = bytes[(bitIndex / 8) % bytes.count]
                let mark = (byte >> (bitIndex % 8)) & 1 == 1
                phase += 2 * Double.pi * (mark ? 2_083.333333 : 1_562.5) / rate
                let edge = min(1, min(local, burst - local) / 0.005)
                sample = sin(phase) * 0.55 * edge
            }
            for channel in 0..<Int(format.channelCount) {
                channels[channel][i] = Float(sample)
            }
        }
        return buffer
    }

    static func makeBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let count = Int(sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        let low = 853.0 / sampleRate
        let high = 960.0 / sampleRate
        for i in 0..<count {
            let t = Double(i)
            let sample = Float(
                sin(t * low * 2 * Double.pi) * 0.36 +
                sin(t * high * 2 * Double.pi) * 0.36
            )
            for channel in 0..<Int(format.channelCount) {
                channels[channel][i] = sample
            }
        }
        return buffer
    }

    // A chime-inspired alternative, not a recording of an official J-Alert broadcast.
    static func makeJapanBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let notes = [784.0, 988.0, 740.0, 988.0]
        let noteLength = 0.4
        let count = Int(rate * noteLength * Double(notes.count))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        for i in 0..<count {
            let position = Double(i) / rate
            let noteIndex = min(Int(position / noteLength), notes.count - 1)
            let local = position - Double(noteIndex) * noteLength
            let edge = min(1, min(local, noteLength - local) / 0.015)
            let phase = position * notes[noteIndex] * 2 * Double.pi
            let sample = Float((sin(phase) * 0.34 + sin(phase * 2) * 0.08) * edge)
            for channel in 0..<Int(format.channelCount) {
                channels[channel][i] = sample
            }
        }
        return buffer
    }
}
