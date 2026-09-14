// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.
package dev.fa1.app

import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/// AES-256-GCM codec for the `fah/keychain` channel (issue #329): a value
/// encrypts to `IV || ciphertext` — a fresh random IV per encryption, the
/// 128-bit auth tag appended by the cipher. Deliberately free of Android
/// classes so the JVM unit suite exercises the real crypto; the
/// AndroidKeyStore master key and the SharedPreferences persistence live
/// in MainActivity.
internal object KeychainCodec {
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128

    fun encrypt(key: SecretKey, value: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        return cipher.iv + cipher.doFinal(value)
    }

    /// Null on any corruption or auth failure: a broken entry is skipped,
    /// never fatal — the store degrades like the iOS Keychain channel does.
    fun decrypt(key: SecretKey, blob: ByteArray): ByteArray? = try {
        require(blob.size > IV_BYTES)
        val spec = GCMParameterSpec(TAG_BITS, blob, 0, IV_BYTES)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, spec)
        cipher.doFinal(blob, IV_BYTES, blob.size - IV_BYTES)
    } catch (e: Exception) {
        null
    }
}
