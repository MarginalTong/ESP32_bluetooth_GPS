import 'dart:convert';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

class ProfileAvatar {
  ProfileAvatar(this.id, Uint8List jpeg) : jpeg = Uint8List.fromList(jpeg) {
    validateJpeg(this.jpeg);
    if (!validId(id)) throw const FormatException('Invalid avatar version');
  }
  final String id;
  final Uint8List jpeg;
  static const maxBytes = 32768;
  static bool validId(String id) => RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  ).hasMatch(id);
  static void validateJpeg(Uint8List bytes) {
    if (bytes.length < 4 ||
        bytes.length > maxBytes ||
        bytes[0] != 0xff ||
        bytes[1] != 0xd8 ||
        bytes[bytes.length - 2] != 0xff ||
        bytes.last != 0xd9) {
      throw const FormatException('Invalid thumbnail');
    }
    final info = img.JpegDecoder().startDecode(bytes);
    if (info == null ||
        info.width < 1 ||
        info.height < 1 ||
        info.width > 256 ||
        info.height > 256) {
      throw const FormatException('Invalid thumbnail dimensions');
    }
  }

  factory ProfileAvatar.fromJson(Map<String, dynamic> json) => ProfileAvatar(
    json['id'] as String,
    decodeJpeg(json['jpeg_base64'] as String),
  );
  static Uint8List decodeJpeg(String value) {
    if (value.length > 43692) throw const FormatException('Oversized avatar');
    final bytes = base64Decode(value);
    validateJpeg(bytes);
    return bytes;
  }
}
