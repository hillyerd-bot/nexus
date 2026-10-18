%% Thin AES-256-GCM binding over OTP crypto for provider API keys at rest
%% (docs/plans/multi-provider.md §6). Envelope layout, key-length checks,
%% and error mapping live on the Gleam side (src/nexus/crypto.gleam) —
%% this file only moves bytes and never inspects them.
-module(nexus_crypto_ffi).

-export([strong_rand_bytes/1, aead_encrypt/4, aead_decrypt/5]).

%% N fresh random bytes for the per-encryption nonce. Always from the
%% strong source, never derived from the key, and never a weaker fallback:
%% {error, nil} (→ Gleam EncryptFailed) beats continuing with bad entropy.
strong_rand_bytes(N) ->
    try
        {ok, crypto:strong_rand_bytes(N)}
    catch
        _:_ -> {error, nil}
    end.

%% Returns {ok, {CipherText, Tag}}. Key/IV lengths are validated in
%% Gleam first; the catch is a backstop so a backend error can never
%% escape as an exception.
aead_encrypt(Key, Iv, Aad, PlainText) ->
    try
        {CipherText, Tag} = crypto:crypto_one_time_aead(
            aes_256_gcm, Key, Iv, PlainText, Aad, 16, true
        ),
        {ok, {CipherText, Tag}}
    catch
        _:_ -> {error, nil}
    end.

%% AES-256-GCM decrypt. Authentication failure surfaces differently across
%% OTP releases: 28 returns the bare atom `error`, older releases raise
%% `error:decrypt_failed`. Both map to {error, nil}, which the Gleam side
%% reports as a fixed AuthenticationFailed (wrong key, wrong AAD, or
%% tampered envelope — never the key material or the reason term).
aead_decrypt(Key, Iv, Aad, CipherText, Tag) ->
    try
        case crypto:crypto_one_time_aead(
            aes_256_gcm, Key, Iv, CipherText, Aad, Tag, false
        ) of
            PlainText when is_binary(PlainText) -> {ok, PlainText};
            _ -> {error, nil}
        end
    catch
        _:_ -> {error, nil}
    end.
