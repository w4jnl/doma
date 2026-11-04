// Listener turns speech into words on the device (docs/design.md, "iPhone and Mac apps", Voice),
// as nt's does: Apple's SpeechAnalyzer, with SpeechTranscriber where it has the language and
// DictationTranscriber, the keyboard's model, where it does not (Dutch and Slovak). Only the
// words are kept: the sound goes from the microphone to the model and nowhere else, and the app
// makes no network call for it; the system fetches a language's model once, as it does for the
// keyboard. Mic is the microphone; Heard keeps the words as they come and says where a pause
// ends what was said. This file stands alone (Foundation, AVFoundation, Speech), so make voice
// can compile it with scripts/voice.swift outside the app.
import AVFoundation
import Foundation
import Observation
import Speech

/// Language is what the person speaks, chosen under the mic, since speech is not told its
/// language by itself. The last one is remembered on the device.
enum Language: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case dutch = "nl"
    case slovak = "sk"

    var id: String { rawValue }

    /// name is the language in itself, so each person finds their own.
    var name: String {
        switch self {
        case .english: "English"
        case .dutch: "Nederlands"
        case .slovak: "Slovenčina"
        }
    }

    var short: String { rawValue.uppercased() }

    /// locales are the ones to ask a model for, best first: the device's own for the language
    /// (en-GB on a British iPhone), then the usual one. Only a locale a model has exactly counts:
    /// the nearest to en-NL a model offers is en-IN.
    var locales: [Locale] {
        let mine = Locale.preferredLanguages.map { Locale(identifier: $0) }
            .filter { $0.language.languageCode?.identifier == rawValue && $0.region != nil }
        let usual = switch self {
        case .english: "en-US"
        case .dutch: "nl-NL"
        case .slovak: "sk-SK"
        }
        return mine + [Locale(identifier: usual)]
    }

    /// key is where the language last chosen is kept, in the app's defaults.
    static let key = "voice.language"

    /// remembered is the language last chosen, the device's own until one is.
    static var remembered: Language {
        get {
            if let l = UserDefaults.standard.string(forKey: key).flatMap(Language.init) { return l }
            let first = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "" }
            return Language(rawValue: first ?? "") ?? .english
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

@MainActor
@Observable
final class Listener {
    enum State: Equatable {
        case idle
        case preparing(String) // what it waits for, when it says
        case listening
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var heard = Heard()
    private(set) var levels = [Float](repeating: 0, count: 21) // the loudness of the last moments, 0 to 1
    private(set) var started: Date?
    /// lines: the words come as lines, each when the speaker pauses; else each piece as soon as
    /// the model has settled it, and paused is told when the speaker then pauses.
    @ObservationIgnored var lines = false
    /// words takes the words: a line, or a piece.
    @ObservationIgnored var words: ((String) -> Void)?
    /// changed is told the words the model may still change, as they change.
    @ObservationIgnored var changed: ((String) -> Void)?
    /// paused is told, with lines off, that the speaker has paused with every piece given: in a
    /// list, what was said is one item.
    @ObservationIgnored var paused: (() -> Void)?

    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var feed: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var mic: Mic?
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var watching: Task<Void, Never>?
    @ObservationIgnored private var finalizing = false
    @ObservationIgnored private var run = 0 // which start the results belong to

    /// pause is how long a silence ends what was said.
    nonisolated static let pause: TimeInterval = 1.5

    var busy: Bool {
        switch state {
        case .preparing, .listening: true
        default: false
        }
    }

    /// start listens through the microphone in language.
    func start(_ language: Language) async {
        guard !busy else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .failed(String(localized: "doma may not use the microphone: allow it in Settings"))
            return
        }
        await begin(language) { [weak self] format, feed in
            try Mic(to: format, feed: feed) { level in
                Task { @MainActor in self?.level(level) }
            }
        }
    }

    /// play feeds the sound in file to the model as if it were spoken, then stops, for the tests.
    func play(_ file: URL, _ language: Language) async {
        await begin(language) { format, feed in
            try Mic(playing: file, to: format, feed: feed)
        }
        await mic?.played()
        await stop()
    }

    private func begin(_ language: Language, source: (AVAudioFormat, AsyncStream<AnalyzerInput>.Continuation) throws -> Mic) async {
        run += 1
        let me = run
        state = .preparing("")
        heard = Heard()
        do {
            guard let module = await Self.module(language) else {
                throw Problem(String(localized: "\(language.name) speech is not available on this device"))
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                state = .preparing(String(localized: "Getting the \(language.name) speech model, once"))
                try await request.downloadAndInstall()
            }
            guard me == run else { return }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                throw Problem(String(localized: "The \(language.name) speech model takes no sound from this device"))
            }
            let (stream, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let analyzer = SpeechAnalyzer(modules: [module])
            try await analyzer.prepareToAnalyze(in: format)
            reading = Task { [weak self] in await self?.read(module, me) }
            try await analyzer.start(inputSequence: stream)
            guard me == run else {
                feed.finish()
                await analyzer.cancelAndFinishNow()
                return
            }
            self.analyzer = analyzer
            self.feed = feed
            mic = try source(format, feed)
            started = .now
            state = .listening
            watching = Task { [weak self] in await self?.watch(me) }
        } catch {
            await end()
            state = .failed((error as? Problem)?.message ?? error.localizedDescription)
        }
    }

    /// stop stops listening and gives the words heard so far, the last line or piece.
    func stop() async {
        guard busy else { return }
        guard state == .listening else { return await cancel() }
        watching?.cancel()
        mic?.stop()
        mic = nil
        feed?.finish()
        feed = nil
        // the words still coming belong to this run until the model has settled them all
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await reading?.value
        run += 1
        let rest = heard.rest()
        heard = Heard()
        changed?("")
        if !rest.isEmpty { words?(rest) }
        await end()
        state = .idle
    }

    /// cancel stops listening and drops the words not given yet.
    func cancel() async {
        run += 1
        heard = Heard()
        changed?("")
        await end()
        state = .idle
    }

    private func end() async {
        mic?.stop()
        mic = nil
        feed?.finish()
        feed = nil
        watching?.cancel()
        watching = nil
        reading?.cancel()
        reading = nil
        if let analyzer {
            self.analyzer = nil
            await analyzer.cancelAndFinishNow()
        }
        started = nil
        levels = levels.map { _ in 0 }
    }

    /// module is the model for language: SpeechTranscriber where it has the language, else the
    /// keyboard's DictationTranscriber.
    static func module(_ language: Language) async -> (any SpeechModule)? {
        if SpeechTranscriber.isAvailable, let l = pick(language.locales, from: await SpeechTranscriber.supportedLocales) {
            return SpeechTranscriber(locale: l, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        }
        if let l = pick(language.locales, from: await DictationTranscriber.supportedLocales) {
            return DictationTranscriber(locale: l, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
        }
        return nil
    }

    private static func pick(_ wanted: [Locale], from have: [Locale]) -> Locale? {
        let ids = Set(have.map { $0.identifier(.bcp47) })
        return wanted.first { ids.contains($0.identifier(.bcp47)) }
    }

    private func read(_ module: any SpeechModule, _ me: Int) async {
        do {
            if let t = module as? SpeechTranscriber {
                for try await r in t.results { got(String(r.text.characters), final: r.isFinal, me) }
            } else if let t = module as? DictationTranscriber {
                for try await r in t.results { got(String(r.text.characters), final: r.isFinal, me) }
            }
        } catch {
            guard me == run, !Task.isCancelled else { return }
            await end()
            state = .failed(error.localizedDescription)
        }
    }

    private func got(_ text: String, final: Bool, _ me: Int) {
        guard me == run else { return }
        heard.got(text, final: final, at: .now)
        if !lines, final, case let piece = heard.take(), !piece.isEmpty {
            words?(piece)
        }
        changed?(heard.volatile)
    }

    /// watch ends a line at each pause, and has the model settle words that a pause left
    /// unsettled, so that they come; with lines off it says when the speaker paused instead.
    private func watch(_ me: Int) async {
        while !Task.isCancelled, me == run {
            try? await Task.sleep(for: .milliseconds(200))
            guard me == run else { return }
            if lines, let line = heard.line(at: .now, pause: Self.pause) {
                words?(line)
            } else if heard.unsettled(at: .now, pause: Self.pause), !finalizing, let analyzer {
                finalizing = true
                try? await analyzer.finalize(through: nil)
                finalizing = false
            } else if !lines, heard.pauseDue(at: .now, pause: Self.pause) {
                paused?()
            }
        }
    }

    private func level(_ l: Float) {
        guard state == .listening else { return }
        levels = Array(levels.dropFirst()) + [l]
    }

    struct Problem: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}

/// Heard is the words as the model gives them: settled (final) ones not taken yet, and the ones
/// it may still change (volatile), which each result replaces. A line is the settled words once
/// the speaker has paused with nothing unsettled.
struct Heard: Equatable, Sendable {
    private(set) var settled = ""
    private(set) var volatile = ""
    private(set) var last = Date.distantPast // when the words last changed
    private(set) var spoke = false // words came since the last pause

    mutating func got(_ text: String, final: Bool, at now: Date) {
        if final {
            settled = Self.join(settled, text)
            volatile = ""
            last = now
            spoke = true
        } else if text != volatile {
            volatile = text.trimmingCharacters(in: .whitespacesAndNewlines)
            last = now
            spoke = true
        }
    }

    /// line takes the settled words as a line when the speaker paused for pause seconds.
    mutating func line(at now: Date, pause: TimeInterval) -> String? {
        guard volatile.isEmpty, !settled.isEmpty, now.timeIntervalSince(last) >= pause else { return nil }
        return take()
    }

    /// unsettled: words the model may still change have waited a pause.
    func unsettled(at now: Date, pause: TimeInterval) -> Bool {
        !volatile.isEmpty && now.timeIntervalSince(last) >= pause
    }

    /// pauseDue is true once per utterance: words came, every piece was taken, and the speaker
    /// has been quiet for pause seconds.
    mutating func pauseDue(at now: Date, pause: TimeInterval) -> Bool {
        guard spoke, volatile.isEmpty, settled.isEmpty, now.timeIntervalSince(last) >= pause else { return false }
        spoke = false
        return true
    }

    /// take takes the settled words.
    mutating func take() -> String {
        defer { settled = "" }
        return settled
    }

    /// rest takes everything heard, settled or not, as when listening stops.
    mutating func rest() -> String {
        defer { self = Heard() }
        return Self.join(settled, volatile)
    }

    /// join puts words after words with one space between, and none before punctuation.
    static func join(_ a: String, _ b: String) -> String {
        let b = b.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if a.isEmpty || b.isEmpty { return a.isEmpty ? b : a }
        if let c = b.first, ".,;:!?)".contains(c) { return a + b }
        return a + " " + b
    }

    /// item is spoken words as a list line: no full stop at the end, which the model puts after
    /// a sentence and nobody writes after milk.
    static func item(_ words: String) -> String {
        var s = Substring(words.trimmingCharacters(in: .whitespacesAndNewlines))
        while let c = s.last, ".!?".contains(c) { s = s.dropLast() }
        return String(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Mic is the sound for the model: the microphone's, or a file's for the tests, converted to the
/// format the model takes. The microphone's tap runs on the audio thread, so nothing here belongs
/// to the main actor.
final class Mic: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var playing: Task<Void, Never>?

    init(to format: AVAudioFormat, feed: AsyncStream<AnalyzerInput>.Continuation, level: @escaping @Sendable (Float) -> Void) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        #endif
        let input = engine.inputNode
        let natural = input.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, let convert = Converter(from: natural, to: format) else {
            throw Listener.Problem(String(localized: "There is no microphone to listen with"))
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: natural) { buffer, _ in
            level(Self.loudness(buffer))
            if let b = convert(buffer) { feed.yield(AnalyzerInput(buffer: b)) }
        }
        engine.prepare()
        try engine.start()
    }

    init(playing url: URL, to format: AVAudioFormat, feed: AsyncStream<AnalyzerInput>.Continuation) throws {
        let file = try AVAudioFile(forReading: url)
        guard let convert = Converter(from: file.processingFormat, to: format) else {
            throw Listener.Problem("\(url.lastPathComponent) cannot be read as speech")
        }
        playing = Task.detached {
            while let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
                  (try? file.read(into: b)) != nil, b.frameLength > 0 {
                if let c = convert(b) { feed.yield(AnalyzerInput(buffer: c)) }
            }
        }
    }

    /// played is when the file has all gone to the model.
    func played() async {
        await playing?.value
    }

    func stop() {
        if let playing {
            playing.cancel()
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// loudness is the buffer's level from silence (0) to full (1), over 50 dB.
    static func loudness(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[0][i] * data[0][i] }
        let db = 10 * log10(max(sum / Float(n), 1e-10))
        return min(max((db + 50) / 50, 0), 1)
    }
}

/// Converter turns the sound's format into the model's, a buffer at a time.
final class Converter: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let to: AVAudioFormat

    init?(from: AVAudioFormat, to: AVAudioFormat) {
        self.to = to
        if from == to {
            converter = nil
            return
        }
        guard let c = AVAudioConverter(from: from, to: to) else { return nil }
        c.primeMethod = .none // a stream: no silence before the first buffer
        converter = c
    }

    func callAsFunction(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let frames = AVAudioFrameCount((Double(buffer.frameLength) * to.sampleRate / buffer.format.sampleRate).rounded(.up)) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: frames) else { return nil }
        nonisolated(unsafe) var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}
