# Google sign-in setup and acceptance

## Current implementation

Native Google account selection on iOS/Android returns an ID token, exchanged
with the existing Supabase Auth project. No new account table/migration is
needed. Account cache isolation, secure Supabase session storage, manual sync,
RLS and the non-Apple deletion RPC are reused. No admin key belongs in the app.

The integration requests authentication only, not Gmail, Drive, Contacts or
Google API access/refresh tokens. A Google password never enters NAVIO.
The SDK may keep native credential state. Before interactive login we clear
its previous selection without revoking permission or signing the phone out
of Google services. Cancelling the picker produces no login error.

The raw random nonce remains in memory for the SDK/process lifetime; only its
SHA-256 hash is sent to Google. The raw nonce goes to Supabase over HTTPS for
validation. The plugin requires initialization exactly once per process, so
this is not a new nonce per attempt. Leave **Skip nonce checks OFF** in Supabase;
do not weaken the setting to work around an integration error.

The feature defaults OFF and does not enable web/macOS login. Android needs
its own package/certificate setup, build and device verification.

## 1. Google Cloud (owner)

1. Create/select one Google Cloud project. In **Google Auth Platform**, set up
   NAVIO branding, audience and data access. For external testing, add the
   owner's Google account as a test user. Request only `openid`, email and basic
   profile scopes. Prepare real privacy-policy/contact details before launch.
2. Create an OAuth **Web application** client for Supabase. Use the callback
   copied from Supabase's Google provider page as an authorized redirect URI.
   The current test project's URL is
   `https://wqoiddbvhlbqrdnuzlkw.supabase.co/auth/v1/callback`.
3. In the same project, create an OAuth **iOS** client for Bundle ID
   `com.williamli.motonav`. Do not change the existing Bundle ID.
4. Record the two public Client IDs. Enter the **Web Client Secret** directly
   in Supabase; never put it in Flutter, source control or chat.
5. For Android later, register the actual application ID and signing
   certificate SHA-1 with an Android OAuth client in the same Google project.
   Register release/Play App Signing certificates separately from debug.
   The Dart SDK uses the Web client ID as its server audience.

No Firebase database or account migration is required.

## 2. Supabase (owner)

Enable Google under Authentication → Sign-in/Providers in the SAME project as
email accounts. Enter the Web client ID and secret. Add the native iOS client
ID to allowed client IDs if the dashboard exposes additional IDs. The Google
token audience must match an allowed ID. Keep nonce validation enabled.

Supabase handles identity linking; Flutter never merges accounts by comparing
email strings. Verify same-email behavior with dedicated test accounts. Do not
assume Apple private-relay and Google accounts will share the same NAVIO user.

## 3. Local iOS build

Add the following **public** fields alongside existing Supabase settings in the
ignored `.navo/accounts.test.json`. Replace the sample IDs, not the existing
Supabase URL/key:

```json
{
  "NAVIO_GOOGLE_SIGN_IN": true,
  "NAVIO_GOOGLE_WEB_CLIENT_ID": "123-your-web-id.apps.googleusercontent.com",
  "NAVIO_GOOGLE_IOS_CLIENT_ID": "123-your-ios-id.apps.googleusercontent.com"
}
```

From `moto_nav_bridge`:

```sh
dart run tools/configure_google_sign_in.dart ../.navo/accounts.test.json
flutter build ios --release --dart-define-from-file=../.navo/accounts.test.json
```

The helper writes ignored `ios/Flutter/GoogleSignIn.local.xcconfig`, containing
only the reversed public iOS Client ID. Debug and Release/Profile include it.
Without it the bundle contains an inert placeholder callback scheme. NAVIO
checks the actual bundled scheme before entering Google's native SDK and
reports a safe configuration error if missing. The Google plugin handles its
own callback; generic Supabase auth deep-link detection remains disabled.

Rebuild when IDs change; hot reload does not update native schemes. CI needs
the same generation step. Do not commit the local config or any Client Secret.

## 4. Device acceptance still required

- Open account picker, complete consent, return with a verified Supabase
  session. Cancel quietly. Wrong audience/provider/nonce must be rejected.
- Sign out, choose another Google account, restart and restore the session.
  Verify per-user addresses/preferences and unchanged BLE binding.
- Test existing confirmed-email identity linking on the hosted project.
- Upload/restore and delete a dedicated Google account. The historical
  `navio_delete_email_account` RPC deletes non-Apple NAVIO accounts/data, not
  the user's Google account. Apple-linked accounts still require revocation.
- Complete the prepared Apple sign-in integration and assess App Review
  Guideline 4.8 before shipping third-party login on the App Store.

Fake SDK/HTTP tests do not verify native consent, Google token signatures,
hosted provider configuration or identity linking. Those require the owner's
configuration and real sign-in. Tests never inject identities into the cloud.

## Primary references

- https://supabase.com/docs/guides/auth/social-sign-in/auth-google
- https://pub.dev/packages/google_sign_in
- https://pub.dev/packages/google_sign_in_ios
- https://developers.google.com/identity/branding-guidelines
- https://developer.apple.com/app-store/review/guidelines/#login-services
