import Foundation

@main struct SpeechEndpointChecks {
  static func main() {
    precondition(matchesNavigationWake("Hey Moto"))
    precondition(matchesNavigationWake("HEY, Moto!"))
    precondition(matchesNavigationWake("Well hey moto please"))
    precondition(!matchesNavigationWake("Hey motorcycle"))
    precondition(!matchesNavigationWake("they moto"))
    precondition(matchesNavigationWake("导航"))
    var speech = SpeechEndpoint()
    precondition(!speech.observe(rms: 0, duration: 1))
    precondition(!speech.observe(rms: 0.03, duration: 0.3))
    precondition(!speech.observe(rms: 0, duration: 0.9))
    precondition(speech.observe(rms: 0, duration: 0.1))
    precondition(!speech.observe(rms: 0, duration: 1)) // Only one completion.
    var pause = SpeechEndpoint()
    precondition(!pause.observe(rms: 0.03, duration: 0.3))
    precondition(!pause.observe(rms: 0, duration: 0.8))
    precondition(!pause.observe(rms: 0.03, duration: 0.2))
    precondition(!pause.observe(rms: 0, duration: 0.8))
    precondition(pause.observe(rms: 0, duration: 0.2))
    var silent = SpeechEndpoint()
    precondition(!silent.observe(rms: 0, duration: 4.9))
    precondition(silent.observe(rms: 0, duration: 0.1))
    var noisy = SpeechEndpoint()
    precondition(!noisy.observe(rms: 0.1, duration: 9.9))
    precondition(noisy.observe(rms: 0.1, duration: 0.1))
    print("Speech endpoint checks passed")
  }
}
