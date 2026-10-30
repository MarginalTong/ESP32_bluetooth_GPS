import '../models/lat_lng.dart';
import '../models/rider_presence.dart';

abstract interface class RiderPresenceBackend {
  String? get userId;
  bool get available;
  Stream<String?> get userChanges;
  Future<String> begin();
  Future<void> stop(String session);
  Future<bool> publish(String session, int sequence, NavigationFix fix);
  Future<RiderSnapshot> fetch();
}
