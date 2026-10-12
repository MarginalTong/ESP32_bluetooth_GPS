/// Physical selection identity, not a cryptographic credential.
class DisplayBinding {
  const DisplayBinding(this.remote, this.identity);
  final String remote;
  final String identity;

  factory DisplayBinding.fromJson(Map<String, dynamic> data) {
    final remote = data['remote'];
    final identity = data['identity'];
    if (remote is! String ||
        remote.isEmpty ||
        identity is! String ||
        !RegExp(r'^[0-9A-F]{12}$').hasMatch(identity)) {
      throw const FormatException('Invalid saved display binding');
    }
    return DisplayBinding(remote, identity);
  }

  bool matches(String remoteId, String screenId) =>
      remote == remoteId && identity == screenId;
}
