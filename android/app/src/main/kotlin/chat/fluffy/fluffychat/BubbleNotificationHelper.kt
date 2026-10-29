package chat.fluffy.fluffychat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.StandardMessageCodec

/**
 * Fork: bulles Android (chat heads) pour les discussions directes.
 * flutter_local_notifications n'expose pas allowBubbles/BubbleMetadata,
 * d'où ce canal et ce posting 100 % natifs.
 */
object BubbleNotificationHelper {
    const val CHANNEL_ID = "fluffychat_bubble"

    // Fork: canal de tap partagé avec Dart (BasicMessageChannel, l'ancien
    // IsolateNameServer n'existe plus dans l'embedding Flutter actuel)
    const val TAP_CHANNEL = "chat.fluffy/bubble_tap"

    fun sendTapToFlutter(engine: FlutterEngine?, payload: String, id: Int): Boolean {
        val messenger = engine?.dartExecutor?.binaryMessenger ?: return false
        BasicMessageChannel(
            messenger,
            TAP_CHANNEL,
            StandardMessageCodec.INSTANCE,
        ).send(mapOf("id" to id, "payload" to payload))
        return true
    }

    fun showBubble(
        context: Context,
        id: Int,
        title: String,
        text: String,
        sender: String?,
        shortcutId: String,
        groupKey: String?,
        payload: String,
        avatarBytes: ByteArray?,
    ) {
        ensureChannel(context)
        val pm = context.packageManager
        val contentIntent = PendingIntent.getActivity(
            context,
            id,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(BubbleTapReceiver.EXTRA_PAYLOAD, payload)
                putExtra(BubbleTapReceiver.EXTRA_NOTIFICATION_ID, id)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val senderPerson = Person.Builder().setName(sender ?: title).apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                avatarBytes?.let { bytes ->
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.let {
                        setIcon(android.graphics.drawable.Icon.createWithBitmap(it))
                    }
                }
            }
        }.build()

        val style = NotificationCompat.MessagingStyle(
            Person.Builder().setName("Vous").build(),
        )
        style.addMessage(text, System.currentTimeMillis(), senderPerson)

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(style)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setShortcutId(shortcutId)
            .apply { groupKey?.let { setGroup(it) } }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setBubbleMetadata(
                Notification.BubbleMetadata.Builder(shortcutId)
                    .setIntent(contentIntent)
                    .setDesiredHeight(600)
                    .setAutoExpandBubble(false)
                    .setSuppressNotification(false)
                    .build(),
            )
        }

        NotificationManagerCompat.from(context).notify(id, builder.build())
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Bulles de discussion",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            setAllowBubbles(true)
        }
        manager.createNotificationChannel(channel)
    }
}
