//// AES-256-GCM envelope encryption for provider API keys at rest
//// (`docs/plans/multi-provider.md` §6).
////
//// The envelope is one blob, `0x01 || nonce(12) || tag(16) || ciphertext`,
//// stored in `provider.api_key_encrypted`. The leading version byte lets
//// the envelope format change independently of a row's `key_version`.
//// AAD is the provider id, so an envelope swapped or copied between rows
//// fails authentication instead of decrypting somewhere else.
////
//// Byte-moving lives in `nexus_crypto_ffi.erl`; policy — key length,
//// envelope layout, error mapping — lives here. This module has no
//// provider logic. Keys never reach errors or logs: `CryptoError` is a
//// closed type and `describe` emits fixed strings only.

import gleam/bit_array
import gleam/result

/// AES-256 key length in bytes. `NEXUS_ENCRYPTION_KEY` is the base64 of
/// exactly this many random bytes (`openssl rand -base64 32`).
pub const key_bytes = 32

/// Envelope overhead in bytes: version byte + nonce + GCM tag.
pub const envelope_overhead = 29

/// Closed error type — no variant can carry key material or backend terms.
pub type CryptoError {
  /// Key is not exactly `key_bytes` bytes (or not decodable base64 when
  /// read from the environment).
  InvalidKey
  /// Envelope shorter than `envelope_overhead`, or an unknown version byte.
  InvalidEnvelope
  /// GCM authentication failed: wrong key, wrong AAD, or tampered bytes.
  AuthenticationFailed
  /// Backend refused to encrypt. Unreachable once the key-length pre-check
  /// passes; a typed home for the FFI's backstop catch.
  EncryptFailed
  /// Authenticated plaintext was not valid UTF-8. Impossible via `encrypt`
  /// (it takes a `String`); defense in depth on `decrypt`.
  InvalidPlaintext
}

@external(erlang, "nexus_crypto_ffi", "strong_rand_bytes")
fn strong_rand_bytes(n: Int) -> BitArray

/// FFI encrypt → `Ok(#(ciphertext, tag))`; the Erlang catch maps any
/// backend failure to `nil`.
@external(erlang, "nexus_crypto_ffi", "aead_encrypt")
fn aead_encrypt(
  key: BitArray,
  iv: BitArray,
  aad: String,
  plaintext: String,
) -> Result(#(BitArray, BitArray), Nil)

/// FFI decrypt → `Ok(plaintext_bits)`; a GCM tag mismatch raises inside
/// OTP crypto and arrives here as `Error(Nil)`.
@external(erlang, "nexus_crypto_ffi", "aead_decrypt")
fn aead_decrypt(
  key: BitArray,
  iv: BitArray,
  aad: String,
  ciphertext: BitArray,
  tag: BitArray,
) -> Result(BitArray, Nil)

/// Fixed human-readable error text — the only strings this module emits.
pub fn describe(error: CryptoError) -> String {
  case error {
    InvalidKey -> "invalid encryption key: expected base64 of exactly 32 bytes"
    InvalidEnvelope -> "invalid encrypted envelope"
    AuthenticationFailed ->
      "decryption failed: wrong key, provider, or tampered data"
    EncryptFailed -> "encryption backend error"
    InvalidPlaintext -> "decrypted value is not valid UTF-8"
  }
}

/// Decode `NEXUS_ENCRYPTION_KEY`: standard padded base64 of exactly
/// `key_bytes` bytes. Boot fails loudly on anything else; there is no
/// default and no derived key.
pub fn decode_key(encoded: String) -> Result(BitArray, CryptoError) {
  use raw <- result.try(
    bit_array.base64_decode(encoded) |> result.replace_error(InvalidKey),
  )
  case bit_array.byte_size(raw) == key_bytes {
    True -> Ok(raw)
    False -> Error(InvalidKey)
  }
}

/// Encrypt `plaintext` under `key`, bound to `aad` (the provider id).
/// Every call draws a fresh 12-byte nonce, so encrypting the same value
/// twice yields different envelopes that both decrypt to it.
pub fn encrypt(
  key: BitArray,
  aad: String,
  plaintext: String,
) -> Result(BitArray, CryptoError) {
  case bit_array.byte_size(key) == key_bytes {
    False -> Error(InvalidKey)
    True -> {
      let nonce = strong_rand_bytes(12)
      case aead_encrypt(key, nonce, aad, plaintext) {
        Ok(#(ciphertext, tag)) ->
          // 0x01 || nonce(12) || tag(16) || ciphertext
          Ok(<<1, nonce:bits, tag:bits, ciphertext:bits>>)
        Error(Nil) -> Error(EncryptFailed)
      }
    }
  }
}

/// Decrypt an envelope produced by `encrypt` under the same `key` and
/// `aad`. Any mismatch — key, AAD, or bytes — is `AuthenticationFailed`;
/// GCM never yields a partial plaintext.
pub fn decrypt(
  key: BitArray,
  aad: String,
  envelope: BitArray,
) -> Result(String, CryptoError) {
  case bit_array.byte_size(key) == key_bytes {
    False -> Error(InvalidKey)
    True ->
      case envelope {
        // Anything shorter, or a version byte other than 1, falls through
        // to InvalidEnvelope below.
        <<1, nonce:bytes-size(12), tag:bytes-size(16), ciphertext:bits>> ->
          case aead_decrypt(key, nonce, aad, ciphertext, tag) {
            Ok(plain) ->
              case bit_array.to_string(plain) {
                Ok(text) -> Ok(text)
                Error(Nil) -> Error(InvalidPlaintext)
              }
            Error(Nil) -> Error(AuthenticationFailed)
          }
        _ -> Error(InvalidEnvelope)
      }
  }
}
