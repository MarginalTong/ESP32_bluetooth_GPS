import Foundation

func matchesNavigationWake(_ text: String) -> Bool {
  if text.contains("导航") { return true }
  // Whole words only: “Hey motorcycle” and “they moto” must not wake.
  let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted)
    .filter { !$0.isEmpty }
  return zip(words, words.dropFirst()).contains { $0 == "hey" && $1 == "moto" }
}

/// Energy-based endpoint, not a semantic VAD. Used only to end capture.
/// Never treats initial silence as a finished utterance.
struct SpeechEndpoint {
  private var voiced = 0.0
  private var quiet = 0.0
  private var elapsed = 0.0
  private(set) var ended = false

  mutating func observe(rms: Float, duration: Double) -> Bool {
    guard !ended, duration.isFinite, duration > 0, rms.isFinite else { return false }
    elapsed += duration
    if rms >= 0.008 {
      voiced += duration
      quiet = 0
    } else {
      quiet += duration
    }
    // Require 150 ms of above-threshold signal. Wind can delay completion;
    // a hard ten-second cap still applies. Silence alone never reaches inference.
    ended = (voiced >= 0.15 && quiet >= 1.0 - 1e-6) || elapsed >= 10 - 1e-6 ||
      (voiced < 0.15 && elapsed >= 5 - 1e-6)
    return ended
  }
}
