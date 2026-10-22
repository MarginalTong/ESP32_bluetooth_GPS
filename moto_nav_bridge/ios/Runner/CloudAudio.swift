import AVFoundation
import Flutter
import UIKit
import Security

enum VoiceCredentials {
  private static let key: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.williamli.motonav.voice",
    kSecAttrAccount as String: "gateway"]
  static func load() -> Any {
    var query = key
    query[kSecReturnData as String] = true
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return [:] as [String: String] }
    guard status == errSecSuccess, let data = item as? Data,
          let value = try? JSONSerialization.jsonObject(with: data) else {
      return FlutterError(code: "CREDENTIAL_READ_FAILED", message: nil, details: nil)
    }
    return value
  }
  static func save(_ value: [String: String]) -> Any? {
    guard let token = value["token"], token.count >= 32, token.count <= 512,
          let endpoint = value["endpoint"], let url = URL(string: endpoint),
          url.scheme == "https", url.host == "nav.williamligallery.uk",
          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
          url.port == nil || url.port == 443,
          let data = try? JSONSerialization.data(withJSONObject: value) else {
      return FlutterError(code: "INVALID_CREDENTIALS", message: nil, details: nil)
    }
    let update: [String: Any] = [kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
    var status = SecItemUpdate(key as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(key.merging(update) { _, new in new } as CFDictionary, nil)
    }
    return status == errSecSuccess ? nil :
      FlutterError(code: "CREDENTIAL_SAVE_FAILED", message: nil, details: nil)
  }
  static func clear() -> Any? {
    let status = SecItemDelete(key as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound ? nil :
      FlutterError(code: "CREDENTIAL_SAVE_FAILED", message: nil, details: nil)
  }
}

private final class CaptureCancellation {
  private let lock = NSLock()
  private var stopped = false
  var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
  func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

final class CloudAudioSession {
  private let cancellation = CaptureCancellation()
  private let audio = AVAudioEngine()
  private let samplesLock = NSLock()
  private var samples: [Float] = []
  private var tapped = false
  private var active = false
  private var timer: Timer?
  private var reply: ((Any?) -> Void)?
  private var captureEnded = false

  private func error(_ code: String, stage: String) -> FlutterError {
    FlutterError(code: code, message: nil, details: ["engine": "audio_capture", "stage": stage])
  }

  func listen(reply: @escaping (Any?) -> Void) {
    self.reply = reply
    guard UIApplication.shared.applicationState == .active else {
      complete(error("APP_NOT_ACTIVE", stage: "capture")); return
    }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .duckOthers])
      try session.setActive(true); active = true
      let input = audio.inputNode
      let source = input.outputFormat(forBus: 0)
      guard source.sampleRate > 0, source.channelCount > 0,
            let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: source, to: target) else {
        complete(error("MIC_UNAVAILABLE", stage: "audio_format")); return
      }
      var endpoint = SpeechEndpoint()
      input.installTap(onBus: 0, bufferSize: 1024, format: source) { [self] buffer, _ in
        guard !cancellation.cancelled else { return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / source.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
          if supplied { state.pointee = .noDataNow; return nil }
          supplied = true; state.pointee = .haveData; return buffer
        }
        guard status != .error, conversionError == nil, let floats = output.floatChannelData?[0] else {
          DispatchQueue.main.async {
            if !self.cancellation.cancelled {
              self.complete(self.error("AUDIO_ENGINE_ERROR", stage: "conversion"))
            }
          }
          return
        }
        samplesLock.lock()
        let count = min(Int(output.frameLength), 160_000 - samples.count)
        if count > 0 { samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: count)) }
        samplesLock.unlock()
        let frame = UnsafeBufferPointer(start: floats, count: Int(output.frameLength))
        let energy = frame.reduce(Float(0)) { $0 + $1 * $1 }
        if !frame.isEmpty, endpoint.observe(rms: sqrt(energy / Float(frame.count)), duration: Double(frame.count) / 16000) {
          DispatchQueue.main.async {
            guard !self.cancellation.cancelled else { return }
            self.finishCapture()
          }
        }
      }
      tapped = true
      audio.prepare(); try audio.start()
      timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
        self?.finishCapture()
      }
    } catch { complete(self.error("AUDIO_ENGINE_ERROR", stage: "audio_start")) }
  }

  private func stopAudio() {
    audio.stop()
    if tapped { audio.inputNode.removeTap(onBus: 0); tapped = false }
    if active {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      active = false
    }
  }

  private func finishCapture() {
    guard !captureEnded, !cancellation.cancelled else { return }
    captureEnded = true
    timer?.invalidate(); timer = nil
    stopAudio()
    samplesLock.lock(); let pcm = samples; samples.removeAll(); samplesLock.unlock()
    // Do not upload silent captures.
    guard pcm.count >= 1600, pcm.reduce(0, { $0 + $1 * $1 }) / Float(pcm.count) > 0.000001 else {
      complete(nil); return
    }
      // PCM16 mono WAV, in memory only. Maximum payload 320044 bytes.
      var wav = Data()
      func word<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
      }
      wav.append(contentsOf: "RIFF".utf8); word(UInt32(36 + pcm.count * 2))
      wav.append(contentsOf: "WAVEfmt ".utf8); word(UInt32(16))
      word(UInt16(1)); word(UInt16(1)); word(UInt32(16000))
      word(UInt32(32000)); word(UInt16(2)); word(UInt16(16))
      wav.append(contentsOf: "data".utf8); word(UInt32(pcm.count * 2))
      for sample in pcm { word(Int16(max(-1, min(1, sample.isFinite ? sample : 0)) * 32767)) }
      complete(FlutterStandardTypedData(bytes: wav))
  }

  private func complete(_ value: Any?) {
    let callback = reply
    cancel()
    callback?(value)
  }

  func cancel() {
    cancellation.cancel()
    reply = nil
    timer?.invalidate(); timer = nil
    stopAudio()
    samplesLock.lock(); samples.removeAll(); samplesLock.unlock()
  }
}
