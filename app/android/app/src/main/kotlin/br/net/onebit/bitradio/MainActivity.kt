package br.net.onebit.bitradio

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity

/**
 * Activity do BitRádio.
 *
 * ESTENDE AudioServiceActivity, NÃO FlutterActivity. É ela que mantém a ponte
 * viva com o serviço de mídia quando o app vai para segundo plano; com
 * FlutterActivity o áudio corta ao trocar de aplicativo.
 *
 * Pede POST_NOTIFICATIONS porque, a partir do Android 13, declarar a permissão
 * no manifesto não basta — sem o consentimento em tempo de execução o sistema
 * não exibe a notificação do player, e é nela que ficam os controles de play,
 * pause e o que está no ar. Pedimos aqui, em Kotlin, em vez de trazer um
 * pacote de permissões só para isto.
 */
class MainActivity : AudioServiceActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pedirPermissaoDeNotificacao()
    }

    private fun pedirPermissaoDeNotificacao() {
        // TIRAMISU = Android 13. Abaixo disso a permissão é concedida na
        // instalação, e pedir em runtime não tem efeito.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return

        val concedida = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!concedida) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PEDIDO_NOTIFICACAO)
        }
    }

    private companion object {
        const val PEDIDO_NOTIFICACAO = 1001
    }
}
