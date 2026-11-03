import Flutter
import Security

/// The paired display's binding JSON, including the key that signs every
/// navigation write. Stored as one opaque string; Dart validates its content.
enum DisplayBindingKeychain {
  private static let item: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.williamli.motonav.display",
    kSecAttrAccount as String: "binding"]

  /// The stored JSON, nil when nothing is saved, or a FlutterError.
  static func load() -> Any? {
    var query = item
    query[kSecReturnData as String] = true
    var found: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &found)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = found as? Data,
          let text = String(data: data, encoding: .utf8) else {
      return FlutterError(code: "BINDING_READ_FAILED", message: nil, details: nil)
    }
    return text
  }

  static func save(_ text: String?) -> Any? {
    guard let text = text, !text.isEmpty, text.utf8.count <= 1024,
          let data = text.data(using: .utf8) else {
      return FlutterError(code: "INVALID_BINDING", message: nil, details: nil)
    }
    // Reconnects run in the background with the phone locked in a pocket, so
    // the key must stay readable after the first unlock. ThisDeviceOnly keeps
    // it out of backups and off other devices.
    let update: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    var status = SecItemUpdate(item as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(item.merging(update) { _, new in new } as CFDictionary, nil)
    }
    return status == errSecSuccess ? nil :
      FlutterError(code: "BINDING_SAVE_FAILED", message: nil, details: nil)
  }

  static func clear() -> Any? {
    let status = SecItemDelete(item as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound ? nil :
      FlutterError(code: "BINDING_SAVE_FAILED", message: nil, details: nil)
  }
}
