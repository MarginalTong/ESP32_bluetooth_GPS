import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:moto_nav_bridge/models/profile_avatar.dart';
import 'package:moto_nav_bridge/services/avatar_photo_source.dart';

void main() {
  test('photo becomes a square bounded JPEG with fresh metadata', () {
    final original = img.Image(width: 640, height: 400);
    original.exif.imageIfd.imageDescription = 'private-photo-metadata';
    final result = prepareAvatarPhoto(img.encodeJpg(original));
    ProfileAvatar.validateJpeg(result);
    final decoded = img.decodeJpg(result)!;
    expect(decoded.width, 256);
    expect(decoded.height, 256);
    expect(result.length, lessThanOrEqualTo(32768));
    expect(latin1.decode(result), isNot(contains('private-photo-metadata')));
  });
  test(
    'large and invalid public images are rejected before native drawing',
    () {
      expect(
        () => ProfileAvatar.decodeJpeg('A' * 44000),
        throwsFormatException,
      );
      expect(
        () => ProfileAvatar.validateJpeg(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
      final oversized = img.encodeJpg(img.Image(width: 512, height: 512));
      expect(
        () => ProfileAvatar.validateJpeg(oversized),
        throwsFormatException,
      );
      expect(
        () => prepareAvatarPhoto(Uint8List(15 * 1024 * 1024 + 1)),
        throwsFormatException,
      );
      expect(
        () => prepareAvatarPhoto(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
    },
  );
}
