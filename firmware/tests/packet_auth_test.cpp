// Host test for the sketch's PACKET AUTH block (prepended by the runner).
// Vectors come from Python's hmac module and are shared with the App's
// test/packet_signer_test.dart, so both sides are checked against one truth.
#include <CommonCrypto/CommonHMAC.h>
#include <stdio.h>
#include <string.h>

bool navHmacSha256(const uint8_t* key, size_t keyLength, const uint8_t* a,
                   size_t aLength, const uint8_t* b, size_t bLength,
                   uint8_t out[32]) {
  CCHmacContext context;
  CCHmacInit(&context, kCCHmacAlgSHA256, key, keyLength);
  CCHmacUpdate(&context, a, aLength);
  CCHmacUpdate(&context, b, bLength);
  CCHmacFinal(&context, out);
  return true;
}

static int failures = 0;

static void check(const char* name, bool ok) {
  if (!ok) {
    printf("FAIL %s\n", name);
    failures++;
  }
}

// Builds "<json>|<16 hex>" exactly as the App's PacketSigner does.
static void sign(const uint8_t* key, const uint8_t* nonce, const char* json,
                 char* out, size_t outSize) {
  uint8_t mac[32];
  navHmacSha256(key, AUTH_KEY_BYTES, nonce, AUTH_NONCE_BYTES,
                reinterpret_cast<const uint8_t*>(json), strlen(json), mac);
  int written = snprintf(out, outSize, "%s|", json);
  for (size_t i = 0; i < AUTH_TAG_BYTES; ++i)
    written += snprintf(out + written, outSize - written, "%02x", mac[i]);
}

static AuthKeyMatch use(KeyRing& ring, const uint8_t* signingKey,
                        const uint8_t* nonce, bool pairingConnection,
                        bool* changed = nullptr) {
  char packet[128];
  sign(signingKey, nonce, "{\"dir\":\"UP\",\"dist\":50,\"n\":1}", packet,
       sizeof(packet));
  int jsonLength = 0;
  const AuthKeyMatch which =
      ring.match(nonce, packet, strlen(packet), &jsonLength);
  const bool persisted =
      which != AuthKeyMatch::None && ring.noteUsed(which, pairingConnection);
  if (changed != nullptr) *changed = persisted;
  return which;
}

static void keyRingScenarios(const uint8_t* nonce) {
  uint8_t k0[AUTH_KEY_BYTES], k1[AUTH_KEY_BYTES], k2[AUTH_KEY_BYTES],
      stranger[AUTH_KEY_BYTES];
  for (size_t i = 0; i < AUTH_KEY_BYTES; ++i) {
    k0[i] = 0x10 + i;
    k1[i] = 0x20 + i;
    k2[i] = 0x30 + i;
    stranger[i] = 0x40 + i;
  }

  // Phone A paired with k0 and has used it since.
  KeyRing ring;
  ring.rotate(k0);
  bool changed = false;
  check("first key proven on a normal connection",
        use(ring, k0, nonce, false, &changed) == AuthKeyMatch::Current &&
            changed && ring.currentProven);

  // BOOT pairing issues k1, then the link drops before the phone stores it.
  ring.rotate(k1);
  check("link drop: phone still holding k0 keeps working",
        use(ring, k0, nonce, false) == AuthKeyMatch::Previous);
  check("link drop: k0 is not retired by its own use", ring.hasPrevious);
  check("a stranger's key is rejected",
        use(ring, stranger, nonce, false) == AuthKeyMatch::None);

  // Using k1 on the pairing connection itself must not retire k0: the phone
  // could still drop before it saves the key.
  check("pairing connection accepts k1",
        use(ring, k1, nonce, true, &changed) == AuthKeyMatch::Current &&
            !changed);
  check("pairing connection does not retire k0", ring.hasPrevious);

  // A second pairing before k1 was ever proven keeps k0, the proven key.
  ring.rotate(k2);
  check("repeat pairing keeps the proven key",
        use(ring, k0, nonce, false) == AuthKeyMatch::Previous);
  check("repeat pairing drops the unproven key",
        use(ring, k1, nonce, false) == AuthKeyMatch::None);

  // The phone reconnects with k2: proven, and k0 is finally retired.
  check("new key proven on a later connection",
        use(ring, k2, nonce, false, &changed) == AuthKeyMatch::Current &&
            changed && ring.currentProven && !ring.hasPrevious);
  check("old key rejected once the new key is proven",
        use(ring, k0, nonce, false) == AuthKeyMatch::None);

  KeyRing fresh;
  check("an unpaired display accepts nothing",
        use(fresh, k0, nonce, false) == AuthKeyMatch::None);
}

static void expectLength(const char* name, const uint8_t* key,
                         const uint8_t* nonce, const char* packet,
                         int expected) {
  const int actual = verifyPacketTag(key, nonce, packet, strlen(packet));
  if (actual != expected) {
    printf("FAIL %s: expected %d, got %d\n", name, expected, actual);
    failures++;
  }
}

int main() {
  uint8_t key[AUTH_KEY_BYTES];
  uint8_t nonce[AUTH_NONCE_BYTES];
  uint8_t otherNonce[AUTH_NONCE_BYTES];
  for (size_t i = 0; i < AUTH_KEY_BYTES; ++i) key[i] = i;
  for (size_t i = 0; i < AUTH_NONCE_BYTES; ++i) nonce[i] = 0xa0 + i;
  for (size_t i = 0; i < AUTH_NONCE_BYTES; ++i) otherNonce[i] = 0xb0 + i;

  const char* nav = "{\"dir\":\"LEFT\",\"dist\":200,\"n\":1}|acdb15653d20ac00";
  const int navJson = strlen("{\"dir\":\"LEFT\",\"dist\":200,\"n\":1}");
  expectLength("App navigation vector", key, nonce, nav, navJson);
  expectLength("App clock vector", key, nonce,
               "{\"clock\":1761200000,\"n\":1}|2c663afa65eb024b",
               strlen("{\"clock\":1761200000,\"n\":1}"));
  expectLength("uppercase tag hex", key, nonce,
               "{\"dir\":\"LEFT\",\"dist\":200,\"n\":1}|ACDB15653D20AC00",
               navJson);

  expectLength("tampered body", key, nonce,
               "{\"dir\":\"RIGHT\",\"dist\":200,\"n\":1}|acdb15653d20ac00", -1);
  expectLength("tampered counter", key, nonce,
               "{\"dir\":\"LEFT\",\"dist\":200,\"n\":2}|acdb15653d20ac00", -1);
  expectLength("tampered tag", key, nonce,
               "{\"dir\":\"LEFT\",\"dist\":200,\"n\":1}|acdb15653d20ac01", -1);
  expectLength("previous session nonce", key, otherNonce, nav, -1);
  uint8_t otherKey[AUTH_KEY_BYTES];
  memcpy(otherKey, key, sizeof(otherKey));
  otherKey[0] ^= 1;
  expectLength("another display's key", otherKey, nonce, nav, -1);

  expectLength("unsigned legacy packet", key, nonce,
               "{\"dir\":\"LEFT\",\"dist\":200}", -1);
  expectLength("missing separator", key, nonce,
               "{\"dir\":\"LEFT\",\"dist\":200,\"n\":1}xacdb15653d20ac00", -1);
  expectLength("non-hex tag", key, nonce,
               "{\"dir\":\"LEFT\",\"dist\":200,\"n\":1}|acdb15653d20acZZ", -1);
  expectLength("tag only", key, nonce, "|acdb15653d20ac00", -1);
  expectLength("empty", key, nonce, "", -1);

  keyRingScenarios(nonce);

  if (failures == 0) printf("packet auth: all checks passed\n");
  return failures == 0 ? 0 : 1;
}
