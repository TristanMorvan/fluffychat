package chat.fluffy.fluffychat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.IsolateNameServer
import org.json.JSONObject

/**
 * Fork: tap sur une bulle. Si l'isolate principale est vivante, on lui envoie
 * un NotificationResponse au format du plugin flutter_local_notifications
 * (même chemin que notificationTapBackground) ; sinon on ouvre l'app.
 */
class BubbleTapReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val payload = intent.getStringExtra(EXTRA_PAYLOAD) ?: return
        val id = intent.getIntExtra(EXTRA_NOTIFICATION_ID, 0)
        val engine = MainActivity.engine
        val dartExecutor = engine?.dartExecutor
        val port = dartExecutor?.let {
            IsolateNameServer.lookupPortByName(it, MAIN_ISOLATE_PORT)
        }
        if (port != null) {
            val json = JSONObject()
                .put("type", "selectNotification")
                .put("id", id)
                .put("payload", payload)
                .put("data", JSONObject())
                .toString()
            port.send(json)
            return
        }
        context.startActivity(
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(EXTRA_PAYLOAD, payload)
                putExtra(EXTRA_NOTIFICATION_ID, id)
            },
        )
    }

    companion object {
        const val ACTION = "chat.fluffy.fluffychat.BUBBLE_TAP"
        const val EXTRA_PAYLOAD = "chat.fluffy.fluffychat.PAYLOAD"
        const val EXTRA_NOTIFICATION_ID = "chat.fluffy.fluffychat.NOTIFICATION_ID"
        // AppConfig.mainIsolatePortName
        const val MAIN_ISOLATE_PORT = "main_isolate"
    }
}
