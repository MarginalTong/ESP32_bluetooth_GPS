import 'dart:async';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:moto_nav_bridge/models/profile_avatar.dart';
import 'package:moto_nav_bridge/services/avatar_backend.dart';
import 'package:moto_nav_bridge/services/avatar_photo_source.dart';

Uint8List avatarJpeg() => img.encodeJpg(img.Image(width: 32, height: 32));
ProfileAvatar sampleAvatar([
  String id = '10000000-0000-4000-8000-000000000001',
]) => ProfileAvatar(id, avatarJpeg());

class FakeAvatarBackend implements AvatarBackend {
  ProfileAvatar? photo;
  Completer<ProfileAvatar?>? fetchGate;
  bool fail = false;
  int uploads = 0, removals = 0;
  String? lastActor;
  @override
  Future<ProfileAvatar?> fetchOwn() async =>
      fetchGate != null ? fetchGate!.future : photo;
  @override
  Future<ProfileAvatar> upload(String expectedUser, Uint8List jpeg) async {
    if (fail) throw StateError('offline');
    uploads++;
    lastActor = expectedUser;
    return photo = ProfileAvatar('10000000-0000-4000-8000-000000000002', jpeg);
  }

  @override
  Future<void> remove(String expectedUser) async {
    if (fail) throw StateError('offline');
    removals++;
    lastActor = expectedUser;
    photo = null;
  }
}

class FakeAvatarSource implements AvatarPhotoSource {
  Uint8List? result = avatarJpeg();
  Completer<Uint8List?>? gate;
  @override
  Future<Uint8List?> choose() async => gate != null ? gate!.future : result;
}
