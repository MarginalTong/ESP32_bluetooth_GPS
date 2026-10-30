# Profile avatars

## Scope and privacy

- Signed-in users choose a gallery photo in NAVIO Account, preview the circular
  center crop, confirm upload, replace or remove it. No camera permission.
- Images are resized/cropped to 256×256 JPEG, at most 32 KiB. A fresh pixel
  buffer is encoded in a background isolate so source EXIF/GPS/ICC metadata,
  filename and original image are not uploaded. Native gallery selection asks
  for reduced size and does not request full photo metadata.
- Avatar changes sync immediately, independently of manual place/preferences
  upload/restore. They do not reset settings, routes or BLE pairing.
- Account photos are private by default. Signed-in viewers can request one only
  when its owner has an active, published, unexpired rider-sharing session.
  The location-sharing consent explains that the profile photo is visible too.
- Turning sharing off, expiry, session rotation, photo replacement/removal and
  account deletion revoke further old-avatar fetches. Already viewed/captured
  photos cannot be made secret again; do not promise screenshot prevention.
- The public avatar version changes with the rotating rider ID; no account ID,
  email or stable profile object URL is added to the map response.

## Deployment

The owner must execute `supabase/migrations/202610310001_profile_avatars.sql`
after the account and rider-presence migrations. This creates a private RLS
table and authenticated RPCs, and extends `navio_list_riders()` with optional
avatar metadata. Old app versions ignore that metadata. It does not delete
existing data or change the original sharing session/sequence/expiry guards.

This pilot deliberately stores only a tiny JPEG in an account-owned database
row, not original photos, public Storage buckets or permanent signed URLs. It
avoids extra Storage policies/functions and lets account deletion cascade
atomically. Database backups follow the project's retention policy; deletion
of the active row is not erasure of past backups. At broader scale assess
Storage/image delivery, abuse controls and cost before raising limits.

RPCs:

- `navio_get_profile_avatar()` reads only the caller's thumbnail.
- `navio_set_profile_avatar(expected_user, jpeg_base64)` bounds/validates JPEG
  payloads and rotates its version. Expected-user checking prevents late picker
  results being saved into a different account after a session change.
- `navio_remove_profile_avatar(expected_user)` removes only the caller's photo.
- `navio_get_rider_avatar(public_id, avatar_id)` requires authentication and the
  matching active public presence/version. No direct client table access.

App-side JPEG byte/pixel limits are checked before Flutter/native display, even
for remote uploads. Database checks bound the payload and structural JPEG
markers; they are not a full image decoder or content moderation service.

## Performance and cache

Rider metadata/positions appear immediately, with a default avatar while the
photo loads independently. At most two photo requests run concurrently, and
only the newest 64 visible marker versions have photos cached. Downloads time
out and retry failures after 30 s without hiding valid markers. Closing the
viewer, logging out or expiring markers removes those cached references and
late completions cannot resurrect them. Native map updates send JPEG bytes
only when the photo version first loads/changes; movement sends metadata only.
Avatar updates never refit the camera, replace routes or reset gestures.

Own avatars live in memory and load from the account service. After an offline
restart a default icon is used until the cloud photo can be loaded. A failed
replacement/removal preserves the last known photo instead of claiming success.

## Validation

Local tests cover account separation, picker cancellation/confirmation, late
results, failure preservation, image metadata/size limits, bounded rider cache,
and marker-only incremental transport. PostgreSQL tests cover anonymous/direct
access denial, expected-user guards, sharing/expiry/version revocation and
account cascade deletion. No test publishes a real person's photo to the cloud.

Still verify on device: actual iOS gallery permissions (including denial), HEIC
orientation, crop preview, replace/remove, cloud reload on another client, and
avatars on the live map with two opted-in riders. A passing build is not proof
of those device/cloud workflows.
