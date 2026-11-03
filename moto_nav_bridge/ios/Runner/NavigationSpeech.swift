import AVFoundation
import Flutter

/// Spoken navigation guidance for the `moto_nav_bridge/voice` channel. Dart
/// decides what to say; this speaks it and reports when it starts and ends.
final class NavigationSpeech: NSObject, AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private var utterance: AVSpeechUtterance?
  /// Tells Dart when a navigation announcement starts and ends, so it can
  /// defer non-urgent guidance instead of cutting the current one off.
  private var speechEvent: ((String) -> Void)?

  func attach(to messenger: FlutterBinaryMessenger) {
    synthesizer.usesApplicationAudioSession = false
    synthesizer.delegate = self
    let channel = FlutterMethodChannel(name: "moto_nav_bridge/voice", binaryMessenger: messenger)
    speechEvent = { state in channel.invokeMethod("speechState", arguments: state) }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      if call.method == "stop" {
        self.stop()
        result(nil)
      } else if call.method == "speak",
                let args = call.arguments as? [String: String],
                let text = args["text"], let language = args["language"],
                let voice = AVSpeechSynthesisVoice(language: language) {
        self.speak(text, voice: voice)
        result(nil)
      } else {
        result(FlutterError(code: "VOICE_UNAVAILABLE", message: nil, details: nil))
      }
    }
  }

  private func speak(_ text: String, voice: AVSpeechSynthesisVoice) {
    // A newer announcement always replaces the one playing.
    stop()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    self.utterance = utterance
    synthesizer.speak(utterance)
  }

  private func stop() {
    endUtterance()
    synthesizer.stopSpeaking(at: .immediate)
  }

  private func endUtterance() {
    guard utterance != nil else { return }
    utterance = nil
    speechEvent?("navigationSpeechEnded")
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    if utterance === self.utterance { speechEvent?("navigationSpeechStarted") }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    if utterance === self.utterance { endUtterance() }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    if utterance === self.utterance { endUtterance() }
  }
}
