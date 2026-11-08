package dev.local.vpnservice

/**
 * Payload Dart -> канонический AWG .conf (чистая функция, без Android-зависимостей).
 *
 * Обязательные поля приходят из валидированного Dart-парсером WireGuardConfig;
 * Amnezia-расширения мапятся на канонические имена (jc -> Jc и т.д.),
 * неизвестные ключи отбрасываются — org.amnezia.awg Config.parse их отверг бы.
 */
object AwgConfBuilder {

    /** Канонические имена Amnezia-атрибутов. */
    private val AWG_KEYS = mapOf(
        "jc" to "Jc", "jmin" to "Jmin", "jmax" to "Jmax",
        "s1" to "S1", "s2" to "S2",
        "h1" to "H1", "h2" to "H2", "h3" to "H3", "h4" to "H4",
    )

    fun build(payload: Map<*, *>?): String? {
        if (payload == null) return null
        val privateKey = payload["privateKey"] as? String ?: return null
        val publicKey = payload["publicKey"] as? String ?: return null
        val endpoint = payload["endpoint"] as? String ?: return null
        val addresses =
            (payload["addresses"] as? List<*>)?.filterIsInstance<String>() ?: return null
        if (addresses.isEmpty()) return null

        val sb = StringBuilder()
        sb.append("[Interface]\n")
        sb.append("PrivateKey = ").append(privateKey).append('\n')
        sb.append("Address = ").append(addresses.joinToString(", ")).append('\n')
        (payload["dns"] as? List<*>)?.filterIsInstance<String>()?.takeIf { it.isNotEmpty() }
            ?.let { sb.append("DNS = ").append(it.joinToString(", ")).append('\n') }
        (payload["mtu"] as? Number)?.takeIf { it.toInt() > 0 }
            ?.let { sb.append("MTU = ").append(it.toInt()).append('\n') }
        (payload["amnezia"] as? Map<*, *>)?.forEach { (k, v) ->
            val canon = AWG_KEYS[k.toString().lowercase()] ?: return@forEach
            sb.append(canon).append(" = ").append(v).append('\n')
        }
        sb.append("[Peer]\n")
        sb.append("PublicKey = ").append(publicKey).append('\n')
        (payload["presharedKey"] as? String)?.takeIf { it.isNotEmpty() }
            ?.let { sb.append("PresharedKey = ").append(it).append('\n') }
        val allowed = (payload["allowedIps"] as? List<*>)?.filterIsInstance<String>()
            ?.takeIf { it.isNotEmpty() } ?: listOf("0.0.0.0/0", "::/0")
        sb.append("AllowedIPs = ").append(allowed.joinToString(", ")).append('\n')
        sb.append("Endpoint = ").append(endpoint).append('\n')
        val keepalive = (payload["keepalive"] as? Number)?.toInt() ?: 25
        sb.append("PersistentKeepalive = ").append(keepalive).append('\n')
        return sb.toString()
    }
}
