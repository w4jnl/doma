// make voice: the apps' Listener (app/shared/Voice) on the Mac, which has the speech models the
// simulator lacks. macOS speaks a sentence in English, Dutch and Slovak with say, and each is
// played to the Listener as the microphone would be; the words must come back. A model the Mac
// does not have yet is downloaded by macOS, once, as the phone's is by iOS.
import Foundation
import Speech

@main
struct VoiceCheck {
    @MainActor
    static func main() async {
        let dir = URL(filePath: CommandLine.arguments[1])
        let cases: [(Language, [String])] = [
            (.english, ["milk", "bread"]),
            (.dutch, ["melk", "brood"]),
            (.slovak, ["mlieka", "chlieb"]),
        ]
        var failed = false
        for (language, expected) in cases {
            guard let module = await Listener.module(language) else {
                print("voice: \(language.name): no model")
                failed = true
                continue
            }
            let listener = Listener()
            var words: [String] = []
            listener.words = { words.append($0) }
            await listener.play(dir.appending(path: "\(language.rawValue).aiff"), language)
            let text = words.joined(separator: " ")
            let missing = expected.filter { !text.lowercased().contains($0) }
            if case .failed(let why) = listener.state {
                print("voice: \(language.name): \(why)")
                failed = true
            } else if !missing.isEmpty {
                print("voice: \(language.name) (\(type(of: module))): \"\(text)\" has no \(missing.joined(separator: ", "))")
                failed = true
            } else {
                print("voice: \(language.name) (\(type(of: module))): \"\(text)\"")
            }
        }
        exit(failed ? 1 : 0)
    }
}
