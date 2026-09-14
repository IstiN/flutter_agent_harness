// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.
package dev.fa1.app

import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

/// JVM-side logic test of the `fah/keychain` codec (issue #329 AC2): the
/// real AES-GCM round trip the Android handler performs, minus the
/// AndroidKeyStore/SharedPreferences wiring (device-only).
class KeychainCodecTest {
    private fun key(): SecretKey =
        KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

    @Test
    fun valueRoundTripsThroughEncryptAndDecrypt() {
        val k = key()
        val blob = KeychainCodec.encrypt(k, "sk-zai-secret".toByteArray())
        assertArrayEquals(
            "sk-zai-secret".toByteArray(),
            KeychainCodec.decrypt(k, blob),
        )
    }

    @Test
    fun everyEncryptionUsesAFreshIv() {
        val k = key()
        val first = KeychainCodec.encrypt(k, "same".toByteArray())
        val second = KeychainCodec.encrypt(k, "same".toByteArray())
        assertNotEquals(first.toList(), second.toList())
    }

    @Test
    fun aWrongKeyReadsAsNullNotACrash() {
        val blob = KeychainCodec.encrypt(key(), "sk-zai".toByteArray())
        assertNull(KeychainCodec.decrypt(key(), blob))
    }

    @Test
    fun corruptOrTruncatedBlobsReadAsNull() {
        val k = key()
        assertNull(KeychainCodec.decrypt(k, byteArrayOf(1, 2, 3)))
        val blob = KeychainCodec.encrypt(k, "sk-zai".toByteArray())
        blob[blob.size - 1] = (blob[blob.size - 1].toInt() xor 0x55).toByte()
        assertNull(KeychainCodec.decrypt(k, blob))
    }
}
