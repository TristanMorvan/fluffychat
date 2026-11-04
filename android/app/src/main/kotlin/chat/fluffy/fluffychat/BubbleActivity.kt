package chat.fluffy.fluffychat

import android.os.Bundle
import android.content.Intent
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint
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
 * Chaque bulle possede son propre moteur et conserve la room de son Intent.
 */
class BubbleActivity : FlutterActivity() {

    // Le moteur de MainActivity partage entre deux FlutterViews plante le
    // raster thread dans la TaskView Android 15 (tombstone testphone).
    private var bubbleEngine: FlutterEngine? = null
    var roomId: String? = null
        private set
    var payload: String? = null
        private set

    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine =
        FlutterEngine(context.applicationContext).also { engine ->
            bubbleEngine = engine
            MainActivity.registerBubbleChannel(engine, context.applicationContext, this)
            engine.dartExecutor.executeDartEntrypoint(DartEntrypoint.createDefault())
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        roomId = intent?.getStringExtra(EXTRA_ROOM)?.takeIf { it.isNotEmpty() }
        payload = intent?.getStringExtra(BubbleTapReceiver.EXTRA_PAYLOAD)
        activeCount++
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        roomId = intent.getStringExtra(EXTRA_ROOM)?.takeIf { it.isNotEmpty() }
        payload = intent.getStringExtra(BubbleTapReceiver.EXTRA_PAYLOAD)
        sendRoomToFlutter()
    }

    override fun onResume() {
        super.onResume()
        sendRoomToFlutter()
        roomId?.let {
            BubbleNotificationHelper.onBubbleOpened(this, intent?.getStringExtra(EXTRA_SHORTCUT) ?: it)
        }
    }

    private fun sendRoomToFlutter() {
        // Si Dart n'ecoute pas encore, il lira cette instance via getPendingBubbleRoom.
        roomId?.let { room ->
            try {
                bubbleEngine?.let { eng ->
                    MethodChannel(
                        eng.dartExecutor.binaryMessenger,
                        MainActivity.BUBBLE_CHANNEL,
                    ).invokeMethod("onBubbleRoom", mapOf("roomId" to room, "payload" to payload))
                }
            } catch (e: Exception) {
                // Dart pas encore a l'ecoute : le pending sera demande au boot Dart.
            }
        }
    }

    override fun onDestroy() {
        activeCount--
        super.onDestroy()
        bubbleEngine?.destroy()
        bubbleEngine = null
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
        var activeCount = 0
            private set
        const val EXTRA_ROOM = "bubble_room"
        const val EXTRA_SHORTCUT = "bubble_shortcut"
    }
}
