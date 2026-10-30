package chat.fluffy.fluffychat

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.BitmapFactory
import android.os.Build
import android.os.PersistableBundle
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.StandardMessageCodec

/**
 * Fork: bulles Android (chat heads) pour les discussions directes.
 * flutter_local_notifications n'expose pas allowBubbles/BubbleMetadata,
 * d'où ce canal et ce posting 100 % natifs.
 *
 * IMPORTANT (review Tristan) — pourquoi la bulle ronde peut ne pas apparaître
 * immédiatement : depuis Android 11, la PREMIÈRE bulle d'une conversation ne
 * peut jamais s'ouvrir toute seule. La notification arrive dans la barre avec
 * un petit cercle à sa droite ; il faut le toucher UNE fois (« Bulle » ou
 * glisser le cercle) pour que la conversation bulle ensuite automatiquement.
 * C'est une restriction système non contournable (anti-abus). Le réglage
 * système « Toujours bulles pour cette conversation » (appui long sur la notif
 * → Bulles) a le même effet. Il faut aussi que l'app ait l'autorisation
 * Bulles accordée (Réglages → Applications → TitucleChat → Notifications →
 * Bulles).
 *
 * Côté code, tout le nécessaire est là : canal allowBubbles + IMPORTANCE_HIGH,
 * BubbleMetadata (autoExpand=false), shortcut de conversation long-lived
 * publié via pushDynamicShortcut (sans quoi le système ignore le
 * BubbleMetadata — c'était la cause du « notification sans cercle »), et
 * shortcutId sur la notification.
 */
object BubbleNotificationHelper {
    const val CHANNEL_ID = "fluffychat_bubble"

    // Fork: canal de tap partagé avec Dart (BasicMessageChannel, l'ancien
    // IsolateNameServer n'existe plus dans l'embedding Flutter actuel)
    const val TAP_CHANNEL = "chat.fluffy/bubble_tap"

    // Fork: extras long-lived du shortcut de conversation (motifs de la lib
    // Jetpack conversation-shortcuts ; inoffensifs si le système les ignore,
    // ils alimentent le réglage « toujours bulles pour cette conversation »
    // là où ils sont lus)
    private const val EXTRA_SHORTCUT_STRATEGY = "android.intent.extra.shortcut.STRATEGY"
    private const val CHOOSE_CONVERSATION_STRATEGY =
        "android.app.shortcut.strategy.CHOOSE_CONVERSATION"
    private const val EXTRA_BUBBLE_SHORTCUT = "bubbles.shortcut"

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
        // Fork: autoExpand=true pour l'ouverture manuelle (« Ouvrir la
        // bulle ») ; le système n'auto-ouvre que si les bulles sont
        // autorisées et la conversation déjà bubblée une fois (restriction
        // Android 11+ : la première bulle exige un tap sur le cercle).
        autoExpand: Boolean = false,
    ) {
        ensureChannel(context)
        val avatarBitmap =
            avatarBytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
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

        // Fork: le shortcut de conversation DOIT être publié (pushDynamicShortcut)
        // avant le posting, sinon le système ignore le BubbleMetadata et
        // aucun cercle de bulle n'apparaît sur la notification.
        ensureBubbleShortcut(context, shortcutId, title, avatarBitmap)

        val senderPerson = Person.Builder().setName(sender ?: title).apply {
            avatarBitmap?.let { setIcon(IconCompat.createWithBitmap(it)) }
        }.build()

        val style = NotificationCompat.MessagingStyle(
            Person.Builder().setName("Vous").build(),
        )
        style.addMessage(text, System.currentTimeMillis(), senderPerson)

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            // Fork: pastille = icône propre au fork (overlay titucle = T
            // jaune ; source set main = silhouette). Un mipmap donnerait une
            // pastille blanche pleine sur beaucoup de ROMs.
            .setSmallIcon(R.drawable.ic_stat_titucle)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(style)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            // bulle = contenu de conversation : visible sur écran verrouillé
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setShortcutId(shortcutId)
            .apply { groupKey?.let { setGroup(it) } }

        builder.setBubbleMetadata(
            NotificationCompat.BubbleMetadata.Builder(
                contentIntent,
                avatarBitmap?.let { IconCompat.createWithBitmap(it) }
                    ?: IconCompat.createWithResource(context, R.mipmap.ic_launcher),
            )
                .setDesiredHeight(600)
                .setAutoExpandBubble(autoExpand)
                .setSuppressNotification(false)
                .build(),
        )

        NotificationManagerCompat.from(context).notify(id, builder.build())
    }

    /**
     * Fork: shortcut de conversation long-lived, id stable = room id.
     * - pushDynamicShortcut : remplace/évince proprement au-delà du quota
     *   (addDynamicShortcuts échoue silencieusement au-delà de ~5 par app).
     * - longLived : survit au restart, condition pour bulle-ifier.
     * - catégorie conversation + Person : classement « Conversations ».
     * - extras STRATEGY / BUBBLE_SHORTCUT : motif conversation-shortcuts.
     * - package cible explicite sur l'intent.
     */
    internal fun ensureBubbleShortcut(
        context: Context,
        shortcutId: String,
        title: String,
        avatarBitmap: android.graphics.Bitmap?,
    ) {
        if (shortcutId.isEmpty()) return
        try {
            // Intent du shortcut : ouvre l'app (package cible explicite)
            val intent = Intent(Intent.ACTION_VIEW).setPackage(context.packageName)
            // Extras de conversation (motif conversation-shortcuts). Note de
            // review : le vrai canal système (ShortcutInfo.Builder#
            // addLongLivedExtra) est réservé aux apps système (systemapi) —
            // en tierce, ces extras sont informatifs ; ce qui fait fonctionner
            // la bulle est longLived + pushDynamicShortcut + shortcutId +
            // catégorie conversation, tous présents ici.
            val strategy = PersistableBundle().apply {
                putString(EXTRA_SHORTCUT_STRATEGY, CHOOSE_CONVERSATION_STRATEGY)
                putBoolean(EXTRA_BUBBLE_SHORTCUT, true)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val icon = avatarBitmap?.let {
                    android.graphics.drawable.Icon.createWithBitmap(it)
                } ?: android.graphics.drawable.Icon.createWithResource(
                    context,
                    R.mipmap.ic_launcher,
                )
                val shortcut = ShortcutInfo.Builder(context, shortcutId)
                    .setShortLabel(title)
                    .setIntent(intent)
                    .setIcon(icon)
                    .setPerson(
                        android.app.Person.Builder()
                            .setName(title)
                            .setKey(shortcutId)
                            .setImportant(true)
                            .build(),
                    )
                    .setCategories(setOf(ShortcutInfo.SHORTCUT_CATEGORY_CONVERSATION))
                    .setLongLived(true)
                    .setExtras(strategy)
                    .build()
                context.getSystemService(ShortcutManager::class.java)
                    ?.pushDynamicShortcut(shortcut)
            } else {
                val shortcut = ShortcutInfoCompat.Builder(context, shortcutId)
                    .setShortLabel(title)
                    .setIntent(intent)
                    .setIcon(
                        avatarBitmap?.let { IconCompat.createWithBitmap(it) }
                            ?: IconCompat.createWithResource(context, R.mipmap.ic_launcher),
                    )
                    .setPerson(
                        Person.Builder().setName(title).setKey(shortcutId)
                            .setImportant(true).build(),
                    )
                    // même valeur que ShortcutInfo.SHORTCUT_CATEGORY_CONVERSATION
                    // (le compat ne expose pas la constante selon les versions)
                    .setCategories(setOf("android.shortcut.conversation"))
                    .setLongLived(true)
                    .setExtras(strategy)
                    .build()
                ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
            }
        } catch (e: Exception) {
            // quota de shortcuts dépassé / ROM capricieuse : la notif
            // classique reste émise, on ne casse pas le flux de notification
            Log.w("BubbleHelper", "ensureBubbleShortcut($shortcutId) failed", e)
        }
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
            lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }
}
