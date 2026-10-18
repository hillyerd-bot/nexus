import gleam/bit_array
import gleam/int
import gleeunit/should
import nexus/crypto

/// Fixed 32-byte test key. Public test material — the real master key only
/// ever exists in `NEXUS_ENCRYPTION_KEY`.
const test_key = "0123456789abcdef0123456789abcdef"

fn key() -> BitArray {
  bit_array.from_string(test_key)
}

fn other_key() -> BitArray {
  bit_array.from_string("fedcba9876543210fedcba9876543210")
}

/// Envelope with one byte XOR-flipped at `offset` — a surgical tamper that
/// keeps the length intact.
fn flipped_at(bits: BitArray, offset: Int) -> BitArray {
  let assert Ok(head) = bit_array.slice(bits, 0, offset)
  let assert Ok(target) = bit_array.slice(bits, offset, 1)
  let assert Ok(tail) =
    bit_array.slice(bits, offset + 1, bit_array.byte_size(bits) - offset - 1)
  let assert <<byte>> = target
  bit_array.append(head, <<int.bitwise_exclusive_or(byte, 1)>>)
  |> bit_array.append(tail)
}

pub fn round_trip_test() {
  let assert Ok(envelope) = crypto.encrypt(key(), "provider-1", "sk-secret-1")
  crypto.decrypt(key(), "provider-1", envelope)
  |> should.equal(Ok("sk-secret-1"))
}

pub fn round_trip_empty_plaintext_test() {
  // Keyless providers store NULL, but the format must not special-case an
  // empty string: zero-length ciphertext is a legal segment.
  let assert Ok(envelope) = crypto.encrypt(key(), "provider-1", "")
  crypto.decrypt(key(), "provider-1", envelope) |> should.equal(Ok(""))
}

pub fn round_trip_unicode_test() {
  let secret = "ключ-🔑-pa$$w0rd"
  let assert Ok(envelope) = crypto.encrypt(key(), "provider-1", secret)
  crypto.decrypt(key(), "provider-1", envelope)
  |> should.equal(Ok(secret))
}

pub fn envelope_layout_test() {
  // 0x01 || nonce(12) || tag(16) || ciphertext — 12 plaintext bytes
  // must produce exactly 29 + 12 envelope bytes, version byte first.
  // P1 stores this blob as bytea; a format change is a migration.
  let assert Ok(envelope) = crypto.encrypt(key(), "provider-1", "sk-test-1234")
  should.equal(bit_array.byte_size(envelope), 41)
  let assert <<1, rest:bits>> = envelope
  should.equal(bit_array.byte_size(rest), 40)
}

pub fn nonce_is_fresh_per_encryption_test() {
  let assert Ok(a) = crypto.encrypt(key(), "provider-1", "same-secret")
  let assert Ok(b) = crypto.encrypt(key(), "provider-1", "same-secret")
  should.be_true(a != b)
  crypto.decrypt(key(), "provider-1", a) |> should.equal(Ok("same-secret"))
  crypto.decrypt(key(), "provider-1", b) |> should.equal(Ok("same-secret"))
}

pub fn wrong_aad_fails_test() {
  // AAD is the provider id — an envelope swapped or copied to another row
  // must not authenticate there.
  let assert Ok(envelope) = crypto.encrypt(key(), "provider-1", "sk-secret-1")
  crypto.decrypt(key(), "provider-2", envelope)
  |> should.equal(Error(crypto.AuthenticationFailed))
}

pub fn wrong_key_fails_test() {
  let assert Ok(envelope) = crypto.encrypt(key(), "provider-1", "sk-secret-1")
  crypto.decrypt(other_key(), "provider-1", envelope)
  |> should.equal(Error(crypto.AuthenticationFailed))
}

pub fn tampered_ciphertext_fails_test() {
  // First ciphertext byte sits at offset 29 (version + nonce + tag).
  let assert Ok(envelope) = crypto.encrypt(key(), "provider-1", "sk-secret-1")
  crypto.decrypt(key(), "provider-1", flipped_at(envelope, 29))
  |> should.equal(Error(crypto.AuthenticationFailed))
}

pub fn tampered_tag_fails_test() {
  // The 16-byte tag starts at offset 13.
  let assert Ok(envelope) = crypto.encrypt(key(), "provider-1", "sk-secret-1")
  crypto.decrypt(key(), "provider-1", flipped_at(envelope, 13))
  |> should.equal(Error(crypto.AuthenticationFailed))
}

pub fn tampered_nonce_fails_test() {
  let assert Ok(envelope) = crypto.encrypt(key(), "provider-1", "sk-secret-1")
  crypto.decrypt(key(), "provider-1", flipped_at(envelope, 1))
  |> should.equal(Error(crypto.AuthenticationFailed))
}

pub fn unknown_version_rejected_test() {
  // 1 XOR 1 = 0: flipping byte 0 rewrites the version, not the payload.
  let assert Ok(envelope) = crypto.encrypt(key(), "provider-1", "sk-secret-1")
  crypto.decrypt(key(), "provider-1", flipped_at(envelope, 0))
  |> should.equal(Error(crypto.InvalidEnvelope))
}

pub fn truncated_envelope_rejected_test() {
  crypto.decrypt(key(), "provider-1", <<1, 0, 0, 0>>)
  |> should.equal(Error(crypto.InvalidEnvelope))
}

pub fn short_key_encrypt_rejected_test() {
  let assert Ok(short) = bit_array.slice(key(), 0, 31)
  crypto.encrypt(short, "provider-1", "sk")
  |> should.equal(Error(crypto.InvalidKey))
}

pub fn long_key_encrypt_rejected_test() {
  let long = bit_array.append(key(), <<0>>)
  crypto.encrypt(long, "provider-1", "sk")
  |> should.equal(Error(crypto.InvalidKey))
}

pub fn short_key_decrypt_rejected_test() {
  let assert Ok(envelope) = crypto.encrypt(key(), "provider-1", "sk-secret-1")
  crypto.decrypt(<<0:size(128)>>, "provider-1", envelope)
  |> should.equal(Error(crypto.InvalidKey))
}

pub fn decode_key_accepts_wellformed_test() {
  let encoded = bit_array.base64_encode(key(), True)
  let assert Ok(decoded) = crypto.decode_key(encoded)
  should.equal(decoded, key())
}

pub fn decode_key_rejects_garbage_test() {
  crypto.decode_key("not~~base64!!") |> should.equal(Error(crypto.InvalidKey))
}

pub fn decode_key_rejects_wrong_length_test() {
  // Valid base64, but 31 bytes — the `openssl rand -base64 32` shape is
  // mandatory.
  let assert Ok(short) = bit_array.slice(key(), 0, 31)
  crypto.decode_key(bit_array.base64_encode(short, True))
  |> should.equal(Error(crypto.InvalidKey))
}

pub fn describe_is_fixed_text_test() {
  // No error string can name a key, a provider, or a backend term.
  should.equal(
    crypto.describe(crypto.InvalidKey),
    "invalid encryption key: expected base64 of exactly 32 bytes",
  )
  should.equal(
    crypto.describe(crypto.InvalidEnvelope),
    "invalid encrypted envelope",
  )
  should.equal(
    crypto.describe(crypto.AuthenticationFailed),
    "decryption failed: wrong key, provider, or tampered data",
  )
}
