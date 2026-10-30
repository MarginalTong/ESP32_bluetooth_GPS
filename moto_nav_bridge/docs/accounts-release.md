# NAVIO accounts: deployment and acceptance

## Current scope

- Supabase email/password, email-code confirmation and password recovery.
- Native Apple sign-in uses a raw nonce and its SHA-256 hash. It stays disabled
  unless `NAVIO_APPLE_SIGN_IN=true` and all server/developer requirements below
  are met. An optional entitlements file is supplied, but deliberately not
  attached to the current free-team build.
- My devices → NAVIO Account, manual upload/restore, explicit guest import,
  logout, and confirmed account deletion.
- Only saved places and route/map preferences sync. No GPS track, search
  history, live route, BLE binding or signing key is uploaded.
- Each account has its own local cache. Guest data is preserved separately.
  Navigating/routing/paused/arrival states block profile-changing actions;
  session loss during a trip defers local activation until navigation ends.
- Uploads use an optimistic cloud revision. A conflict keeps both copies and
  requires an explicit restore; no silent last-writer-wins overwrite.

## 1. Project and database

Use the owner's test project. Confirm its Region in Project Settings; this
code does not move an existing project's data or assume its region is Sydney.
The public URL and publishable key are in the ignored `.navo/accounts.test.json`
for this workstation. Never put a database password, secret/service_role key,
Apple private key or refresh token in Flutter, dart-defines, source control or
chat. Public keys are not substitutes for authenticated user tokens/RLS.

Run `supabase/migrations/202610300001_accounts.sql` in the test project's SQL
Editor. This creates four tables and RPCs; it must not be blindly rerun against
an already-migrated project. Future changes need a new migration.

- `profiles`, `user_preferences`, `saved_places`: authenticated own-row reads.
  Only the authenticated atomic sync RPC writes user data.
- `account_apple_grants`: no client access. Only the server service role can
  read/write encrypted provider grants.
- `navio_get_account_data()`: consistent snapshot.
- `navio_save_account_data(payload, expected_revision)`: verified caller UID,
  validated bounded data, atomic replacement and conflict detection.
- `navio_delete_email_account('DELETE')`: transactional cascade of the caller's
  account only. Apple-linked accounts cannot bypass provider revocation.

Anonymous requests to the tables/RPCs must be rejected. Do NOT switch off RLS
or grant anonymous access to make a test pass.

## 2. Email delivery

In Authentication settings enable email/password signup, email confirmations,
and a password minimum of 6 characters, matching the app's registration and
reset forms. Keep confirmation enabled. This Auth service setting is independent
of the SQL migrations and must be changed in the project dashboard; shipping the
app alone does not change the hosted policy. Longer unique passwords are still
recommended; do not impose a new minimum on existing users when signing in.

Copy `supabase/templates/confirmation.html` and `recovery.html` into the matching
Email Templates. They use `{{ .Token }}` because the app verifies codes instead
of accepting arbitrary auth deep links. `supabase/config.toml` describes local
CLI settings; committing it does NOT change a hosted project's settings.

Configure a real SMTP provider and verified sending domain before testing
public signup/reset with external users. Supabase's default mailer is heavily
restricted and not a production mail service. Do not disable confirmation as
a workaround. For initial login-only device testing, the owner may create a
dedicated confirmed test user under Authentication → Users; the owner enters
the password privately. That does not validate signup/email delivery.

## 3. Apple sign-in (requires paid Apple Developer membership)

1. Enable Sign in with Apple on the existing App ID/Bundle ID. Do not change
   the Bundle ID just for branding; that would change installed-app identity.
2. Add the capability in Xcode and use `Runner/NAVIO-Apple.entitlements` for
   Debug/Profile/Release only after the team's provisioning supports it.
3. Enable the Apple provider in Supabase for the native Bundle ID. Configure
   the private email relay/SPF/DKIM if sending mail to Apple relay addresses.
4. Create the Apple server key. The owner retains the `.p8` file privately.
   Set the values listed in `supabase/.env.example` as Edge Function secrets.
   Generate the token-encryption key securely and back it up; replacing it
   without migrating stored grants breaks provider revocation.
5. Deploy `supabase/functions/account-actions` to the SAME project. With an
   authenticated Supabase CLI, run `supabase functions deploy account-actions
   --project-ref YOUR_PROJECT_REF`. Do not paste management tokens into chat.
6. The function validates every Bearer JWT using Supabase Auth before any
   admin operation; an API key alone is not accepted. The function's explicit
   validation also supports projects using new JWT signing keys.
7. Native login sends the one-time Apple authorization code to that function.
   The server exchanges it, validates Apple's signature/issuer/audience and
   subject against the verified Supabase identity, then AES-GCM-encrypts the
   refresh token. The encryption key stays in function secrets, not SQL.
8. Deletion revokes Apple's provider token BEFORE deleting the Supabase user.
   Provider failure must retain the account. If the stored grant is missing,
   reauthorize Apple in the account page and retry. Email-only deletion does
   not need privileged server credentials in the app.
9. After configuring and validating the function, set the test build's
   `NAVIO_APPLE_SIGN_IN` to the JSON boolean `true`, then rebuild. Do not turn
   it on just to expose an unconfigured/nonfunctional login button.

## 4. Local verification

```sh
npm --prefix supabase/tests ci --ignore-scripts
npm --prefix supabase/tests test
npx --yes deno@2.9.6 check --frozen --lock=supabase/functions/deno.lock supabase/functions/account-actions/index.ts
cd moto_nav_bridge
flutter analyze
flutter test
flutter build ios --release --dart-define-from-file=../.navo/accounts.test.json
```

Database tests run PostgreSQL/WASM locally with a minimal Auth-schema fixture;
they are not a substitute for verifying the hosted Supabase configuration.
Function tests mock Apple network calls; a successful type check does not
prove real Apple credentials or revocation work.

## 5. iPhone acceptance

Use a dedicated disposable test account; never upload a real home/work address
just for testing. Keep the damaged/hot display unplugged. This round's phone
testing cannot certify BLE or hardware operation.

- Fresh install/unconfigured build: maps and local Bluetooth functions still
  open; no cloud setup must be required for guest navigation.
- Sign up, receive and verify a code, restart, and sign in again. Test wrong
  password, expired code, offline state, reset code and new password.
- Apple: first and repeat sign-in, hidden-email relay, cancellation, failed
  grant registration, revoked Apple authorization and reauthentication.
- Verify session persistence on relaunch/lock and that credentials are in
  device-only secure storage, not SharedPreferences/logs/backups.
- Add synthetic Home/Work/School addresses and preferences; upload and restore
  on a second session/device. Verify conflicts do not silently overwrite data.
- Switch A → B → guest: never see/upload the previous account's data.
- Navigate, expire/sign out the session, then end navigation: no mid-trip
  settings/engine reset; pending account isolation takes effect afterward.
- Cancel deletion: no data changes. Confirm deletion using DELETE: user and
  associated cloud rows disappear, cached account data is removed, guest data
  and the local BLE binding remain. Test Apple revocation failure/retry too.

## 6. TestFlight and review

TestFlight requires the owner's active paid Apple Developer membership,
App Store Connect app record, agreements and appropriate distribution signing.
A free development certificate can install a device build, not publish it to
TestFlight. Do not auto-purchase membership or upload on the owner's behalf.

After all real-provider/device checks: use a separate production project or
explicitly promote a reviewed environment, confirm region/SMTP/backups/rate
limits, configure the privacy/support URLs, update App Privacy disclosures,
provide a stable review account and hardware demonstration, then archive and
upload with an incremented build number. A draft or partially configured
account system must not be presented as ready for App Review.

References: [Supabase Flutter](https://supabase.com/docs/guides/getting-started/quickstarts/flutter),
[SMTP](https://supabase.com/docs/guides/auth/auth-smtp),
[Apple provider](https://supabase.com/docs/guides/auth/social-sign-in/auth-apple),
[Apple account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/).
