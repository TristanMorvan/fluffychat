package chat.fluffy.fluffychat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Fork: tap sur une bulle. Si le moteur Flutter est vivant (app en mémoire),
 * on envoie le tap à l'isolate principale via le BasicMessageChannel partagé ;
 * sinon on ouvre l'app (le tap est alors perdu si Dart n'est pas encore prêt,
 * acceptable — la conversation reste visible dans la liste).
 */
class BubbleTapReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val payload = intent.getStringExtra(EXTRA_PAYLOAD) ?: return
        val id = intent.getIntExtra(EXTRA_NOTIFICATION_ID, 0)
        if (BubbleNotificationHelper.sendTapToFlutter(MainActivity.engine, payload, id)) {
            // amener la fenêtre au premier plan aussi
            context.startActivity(
                Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                },
            )
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
    }
}
