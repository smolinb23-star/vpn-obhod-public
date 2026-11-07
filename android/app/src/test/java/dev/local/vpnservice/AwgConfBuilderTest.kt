package dev.local.vpnservice

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Проверяет, что параметры обфускации Amnezia корректно транслируются
 * из Dart-payload в канонический AWG .conf, который парсит нативный движок.
 */
class AwgConfBuilderTest {

    private val basePayload = mapOf(
        "name" to "warp",
        "privateKey" to "aFnb7EZii3t5lSVfJ3x0u3IPZ0yLY5XBw9pF9dJ1hkg=",
        "publicKey" to "h19Uv5I3wQ2r7KxM4nZ8pL6tY0sB3dF7gH2jK9mN4pQ=",
        "endpoint" to "45.76.12.34:443",
        "addresses" to listOf("10.66.66.2/32"),
    )

    @Test
    fun `минимальный конфиг собирается`() {
        val conf = AwgConfBuilder.build(basePayload)!!
        assertTrue(conf.startsWith("[Interface]"))
        assertTrue(conf.contains("PrivateKey = aFnb7EZii3t5lSVfJ3x0u3IPZ0yLY5XBw9pF9dJ1hkg="))
        assertTrue(conf.contains("Address = 10.66.66.2/32"))
        assertTrue(conf.contains("[Peer]"))
        assertTrue(conf.contains("Endpoint = 45.76.12.34:443"))
        // дефолты
        assertTrue(conf.contains("AllowedIPs = 0.0.0.0/0, ::/0"))
        assertTrue(conf.contains("PersistentKeepalive = 25"))
    }

    @Test
    fun `amnezia-расширения получают канонические имена`() {
        val payload = basePayload + mapOf(
            "amnezia" to mapOf(
                "jc" to "6", "jmin" to "40", "jmax" to "1200",
                "s1" to "1194", "s2" to "1188",
                "h1" to "1104220836", "h2" to "2600550896",
                "h3" to "3367297924", "h4" to "1316139190",
            ),
        )
        val conf = AwgConfBuilder.build(payload)!!
        for ((canon, value) in listOf(
            "Jc" to "6", "Jmin" to "40", "Jmax" to "1200",
            "S1" to "1194", "S2" to "1188",
            "H1" to "1104220836", "H2" to "2600550896",
            "H3" to "3367297924", "H4" to "1316139190",
        )) {
            assertTrue("нет $canon = $value в:\n$conf", conf.contains("$canon = $value"))
        }
    }

    @Test
    fun `регистр ключей amnezia не важен`() {
        val payload = basePayload + mapOf("amnezia" to mapOf("JC" to "5", "H1" to "42"))
        val conf = AwgConfBuilder.build(payload)!!
        assertTrue(conf.contains("Jc = 5"))
        assertTrue(conf.contains("H1 = 42"))
    }

    @Test
    fun `неизвестные ключи отбрасываются`() {
        val payload = basePayload + mapOf("amnezia" to mapOf("bogus" to "1", "jc" to "2"))
        val conf = AwgConfBuilder.build(payload)!!
        assertFalse(conf.contains("bogus"))
        assertTrue(conf.contains("Jc = 2"))
    }

    @Test
    fun `dns mtu preshared и allowedIps проходят насквозь`() {
        val payload = basePayload + mapOf(
            "dns" to listOf("8.8.8.8", "8.8.4.4"),
            "mtu" to 1420,
            "presharedKey" to "kQ2r7KxM4nZ8pL6tY0sB3dF7gH2jK9mN4pQaFnb7EZi=",
            "allowedIps" to listOf("0.0.0.0/0", "10.66.66.0/24"),
            "keepalive" to 30,
        )
        val conf = AwgConfBuilder.build(payload)!!
        assertTrue(conf.contains("DNS = 8.8.8.8, 8.8.4.4"))
        assertTrue(conf.contains("MTU = 1420"))
        assertTrue(conf.contains("PresharedKey = kQ2r7KxM4nZ8pL6tY0sB3dF7gH2jK9mN4pQaFnb7EZi="))
        assertTrue(conf.contains("AllowedIPs = 0.0.0.0/0, 10.66.66.0/24"))
        assertTrue(conf.contains("PersistentKeepalive = 30"))
    }

    @Test
    fun `отсутствующие обязательные поля — null`() {
        assertNull(AwgConfBuilder.build(null))
        assertNull(AwgConfBuilder.build(basePayload - "privateKey"))
        assertNull(AwgConfBuilder.build(basePayload - "publicKey"))
        assertNull(AwgConfBuilder.build(basePayload - "endpoint"))
        assertNull(AwgConfBuilder.build(basePayload - "addresses"))
        assertNull(AwgConfBuilder.build(basePayload + mapOf("addresses" to emptyList<String>())))
    }

    @Test
    fun `amnezia-строки идут до секции Peer`() {
        val payload = basePayload + mapOf("amnezia" to mapOf("jc" to "6", "h1" to "1"))
        val conf = AwgConfBuilder.build(payload)!!
        val jcPos = conf.indexOf("Jc = 6")
        val peerPos = conf.indexOf("[Peer]")
        assertTrue("Jc должен быть в [Interface]", jcPos in 0 until peerPos)
    }

    @Test
    fun `equivalence: конфиг содержит обе секции ровно по одному разу`() {
        val conf = AwgConfBuilder.build(basePayload)!!
        assertEquals(1, Regex("\\[Interface]").findAll(conf).count())
        assertEquals(1, Regex("\\[Peer]").findAll(conf).count())
    }
}
