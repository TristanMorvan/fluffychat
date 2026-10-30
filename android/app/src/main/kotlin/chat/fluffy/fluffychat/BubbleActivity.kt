package chat.fluffy.fluffychat

import android.os.Bundle
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Fork M6 : activite affichee DANS la bulle flottante Android (chat head).
 *
 * Pourquoi une activite dediee : le systeme ne met un contenu en bulle
 * flottante que si celui-ci est une activite declaree allowEmbedded +
 * documentLaunchMode=always + resizeableActivity (voir manifest). MainActivity
 * (singleTask, plein ecran) ne peut pas servir de contenu de bulle - sans
 * cette activite, aucune bulle flottante n'est possible, quel que soit le
 * reglage systeme.
 *
 * Limite MVP assumee : le moteur Flutter est partage avec MainActivity, donc
 * une seule bulle vivante a la fois. La vue bullee (conversation pleine,
 * sans shell de navigation) est pilotee cote Dart via le canal
 * chat.fluffy/bubbles.
 */
class BubbleActivity : FlutterActivity() {

    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine =
        MainActivity.provideRunningEngine(context)

    override fun onCreate(savedInstanceState: Bundle?) {
        intent?.getStringExtra(EXTRA_ROOM)?.takeIf { it.isNotEmpty() }?.let {
            MainActivity.pendingBubbleRoomId = it
        }
        super.onCreate(savedInstanceState)
    }

    override fun onResume() {
        super.onResume()
        // La bulle prend la main sur le moteur partage : cote Dart, bascule
        // sur la page conversation. Si le handler Dart n'est pas encore pret
        // (app morte + ouverture par la bulle), Dart reclamera le pending via
        // getPendingBubbleRoom a son demarrage.
        MainActivity.pendingBubbleRoomId?.let { room ->
            try {
                MainActivity.engine?.let { eng ->
                    MethodChannel(
                        eng.dartExecutor.binaryMessenger,
                        MainActivity.BUBBLE_CHANNEL,
                    ).invokeMethod("onBubbleRoom", room)
                }
            } catch (e: Exception) {
                // Dart pas encore a l'ecoute : le pending sera demande au boot Dart
            }
        }
        // La conversation est affichee en bulle : sa notif a fait son travail.
        MainActivity.pendingBubbleRoomId?.let {
            BubbleNotificationHelper.onBubbleOpened(this, it)
        }
    }

    override fun onDestroy() {
        MainActivity.pendingBubbleRoomId = null
        super.onDestroy()
    }

    // Retour arriere = replier la bulle (finish), pas fermer l'app.
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean =
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            finish()
            true
        } else {
            super.onKeyDown(keyCode, event)
        }

    companion object {
        const val EXTRA_ROOM = "bubble_room"
    }
}
