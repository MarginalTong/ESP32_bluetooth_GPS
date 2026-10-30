import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import '../models/profile_avatar.dart';

abstract interface class AvatarPhotoSource {
  Future<Uint8List?> choose();
}

class GalleryAvatarPhotoSource implements AvatarPhotoSource {
  @override
  Future<Uint8List?> choose() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 90,
      requestFullMetadata: false,
    );
    if (file == null) return null;
    if (await file.length() > 15 * 1024 * 1024) {
      throw const FormatException('Photo too large');
    }
    return compute(prepareAvatarPhoto, await file.readAsBytes());
  }
}

/// Center-crop, rotate and re-encode in an isolate. No EXIF/GPS/filename survives.
Uint8List prepareAvatarPhoto(Uint8List bytes) {
  if (bytes.length > 15 * 1024 * 1024) {
    throw const FormatException('Photo too large');
  }
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null ||
      info.width < 1 ||
      info.height < 1 ||
      info.width > 4096 ||
      info.height > 4096 ||
      info.width * info.height > 16000000) {
    throw const FormatException('Unsupported photo');
  }
  final original = decoder!.decodeFrame(0);
  if (original == null) throw const FormatException('Unsupported photo');
  final square = img.copyResizeCropSquare(
    img.bakeOrientation(original),
    size: 256,
  );
  // Construct fresh RGB pixels rather than carrying source EXIF/ICC metadata.
  final clean = img.Image.fromBytes(
    width: 256,
    height: 256,
    bytes: square.getBytes(order: img.ChannelOrder.rgb).buffer,
    numChannels: 3,
  );
  for (final quality in [82, 70, 55, 40]) {
    final encoded = img.encodeJpg(clean, quality: quality);
    if (encoded.length <= ProfileAvatar.maxBytes) return encoded;
  }
  throw const FormatException('Photo cannot fit thumbnail limit');
}
