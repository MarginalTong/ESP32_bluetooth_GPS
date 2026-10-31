/// Nicknames are labels, not unique account identifiers or authentication data.
class AccountProfile {
  const AccountProfile(this.displayName, this.revision);
  final String displayName;
  final int revision;
  static const maxNameLength = 32;
  static final _forbidden = RegExp(
    r'[\x00-\x1f\x7f-\x9f\u200e\u200f\u202a-\u202e\u2066-\u2069]',
  );

  static bool validName(String value) =>
      value.isNotEmpty &&
      value.trim() == value &&
      value.runes.length <= maxNameLength &&
      !_forbidden.hasMatch(value);

  factory AccountProfile.fromJson(Map<String, dynamic> data) {
    final name = data['display_name'], revision = data['name_revision'];
    // Legacy manually chosen names could be up to 80 characters.
    if (name is! String ||
        name.trim().isEmpty ||
        name.runes.length > 80 ||
        _forbidden.hasMatch(name) ||
        revision is! int ||
        revision < 0) {
      throw const FormatException('Invalid profile');
    }
    return AccountProfile(name, revision);
  }
  Map<String, Object> toJson() => {
    'display_name': displayName,
    'name_revision': revision,
  };
}
