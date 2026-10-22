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

  if (failures == 0) printf("packet auth: all checks passed\n");
  return failures == 0 ? 0 : 1;
}
