import AVFoundation
import Flutter

/// How guidance claims audio while it speaks. `.playback` keeps it audible
/// with the ring/silent switch on and in the background (with the `audio`
/// background mode), and routes to Bluetooth A2DP headsets such as helmet
/// intercoms. `.voicePrompt` marks it as navigation: other audio is ducked
/// and spoken audio (podcasts) paused, then resumed when guidance ends.
enum SpeechAudioPolicy {
  static let category = AVAudioSession.Category.playback
  static let mode = AVAudioSession.Mode.voicePrompt
  static let options: AVAudioSession.CategoryOptions = [
    .duckOthers, .interruptSpokenAudioAndMixWithOthers,
  ]
}

/// Spoken navigation guidance for the `moto_nav_bridge/voice` channel. Dart
/// decides what to say; this speaks it and reports when it starts and ends.
final class NavigationSpeech: NSObject, AVSpeechSynthesizerDelegate {
  private let session = AVAudioSession.sharedInstance()
  private let synthesizer = AVSpeechSynthesizer()
  private var utterance: AVSpeechUtterance?
  /// Tells Dart when a navigation announcement starts and ends, so it can
  /// defer non-urgent guidance instead of cutting the current one off.
  private var speechEvent: ((String) -> Void)?

  func attach(to messenger: FlutterBinaryMessenger) {
    // Speak in this app's session so SpeechAudioPolicy applies; the
    // synthesizer's own session follows the silent switch and stops in the
    // background.
    synthesizer.usesApplicationAudioSession = true
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
    activateSession()
    synthesizer.speak(utterance)
  }

  private func activateSession() {
    do {
      try session.setCategory(
        SpeechAudioPolicy.category, mode: SpeechAudioPolicy.mode,
        options: SpeechAudioPolicy.options)
      try session.setActive(true)
    } catch {
      // Speaking still works with the default route; nothing else to do.
    }
  }

  /// Gives audio back to other apps (music returns to full volume) once
  /// nothing is queued. Deferred so the synthesizer has released the route.
  private func releaseSession() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.utterance == nil, !self.synthesizer.isSpeaking else { return }
      try? self.session.setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  private func stop() {
    endUtterance()
    synthesizer.stopSpeaking(at: .immediate)
  }

  private func endUtterance() {
    guard utterance != nil else { return }
    utterance = nil
    speechEvent?("navigationSpeechEnded")
    releaseSession()
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
