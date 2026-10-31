package chat.fluffy.fluffychat

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
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

    // Fork M6 : historique leger par piece (sender, texte) pour reconstruire
    // un fil dans la notif de bulle (getActiveNotificationMessagingStyle est
    // vide quand la notif est bullee). Purge quand la bulle s'ouvre.
    private val history =
        java.util.concurrent.ConcurrentHashMap<String, MutableList<Pair<String?, String>>>()

    // Fork M6 : la bulle s'ouvre (tap cercle / autoExpand) -> la notif a fait
    // son travail ; on la retire et on purge l'historique.
    fun onBubbleOpened(context: Context, roomId: String) {
        history.remove(roomId)
    }

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
        val downloadedAvatar =
            avatarBytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
        // Never replace a person's icon with the app launcher. An absent,
        // timed-out or undecodable MXC gets a stable initials avatar instead;
        // the next push replaces the dynamic shortcut with the real bitmap.
        val avatarBitmap = downloadedAvatar ?: initialsAvatar(sender ?: title, shortcutId)
        Log.i("BubbleHelper", "avatar shortcut=$shortcutId source=${if (downloadedAvatar != null) "mxc" else "initials"} bytes=${avatarBytes?.size ?: 0}")
        // Fork M6 : contenu de la bulle = BubbleActivity (allowEmbedded +
        // documentLaunchMode=always, voir manifest) ; MainActivity ne peut
        // pas servir de contenu de bulle.
        val contentIntent = PendingIntent.getActivity(
            context,
            id,
            Intent(context, BubbleActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK
                putExtra(BubbleActivity.EXTRA_ROOM, shortcutId)
                putExtra(BubbleTapReceiver.EXTRA_PAYLOAD, payload)
                putExtra(BubbleTapReceiver.EXTRA_NOTIFICATION_ID, id)
            },
            // Android 12+ refuses a bubble notification when its content
            // PendingIntent is immutable (NotificationService: Not posted).
            // Explicit BubbleActivity intent keeps the mutable PI targeted.
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                    PendingIntent.FLAG_MUTABLE else 0,
        )

        // Fork: le shortcut de conversation DOIT être publié (pushDynamicShortcut)
        // avant le posting, sinon le système ignore le BubbleMetadata et
        // aucun cercle de bulle n'apparaît sur la notification.
        ensureBubbleShortcut(context, shortcutId, title, avatarBitmap)

        val senderPerson = Person.Builder().setName(sender ?: title).apply {
            setIcon(IconCompat.createWithBitmap(avatarBitmap))
        }.build()

        // Fork M6 : fil cumule dans la notif de bulle (historique par piece)
        val style = NotificationCompat.MessagingStyle(
            Person.Builder().setName("Vous").build(),
        )
        val hist = history.getOrPut(shortcutId) { mutableListOf() }
        synchronized(hist) {
            hist.add(Pair(sender, text))
            while (hist.size > 30) hist.removeAt(0)
            for ((hSender, hText) in hist) {
                val person =
                    if (hSender == null) senderPerson else
                        Person.Builder().setName(hSender).apply {
                            setIcon(IconCompat.createWithBitmap(avatarBitmap))
                        }.build()
                style.addMessage(hText, System.currentTimeMillis(), person)
            }
        }

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
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            // bulle = contenu de conversation : visible sur écran verrouillé
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setShortcutId(shortcutId)
            .apply { groupKey?.let { setGroup(it) } }

        builder.setBubbleMetadata(
            NotificationCompat.BubbleMetadata.Builder(
                contentIntent,
                IconCompat.createWithBitmap(avatarBitmap),
            )
                .setDesiredHeight(maxBubbleHeight(context))
                .setAutoExpandBubble(autoExpand)
                .setSuppressNotification(false)
                .build(),
        )

        NotificationManagerCompat.from(context).notify(id, builder.build())
    }

    /**
     * Fork: hauteur de bulle demandee = ecran reel moins barre d'etat,
     * plancher 85 % (l'ancien 420 px code en dur faisait remonter le
     * BubbleController a son minimum = demi-ecran). Android clampera de
     * toute facon au plafond systeme si la valeur depasse.
     */
    internal fun maxBubbleHeight(context: Context): Int {
        val full = context.resources.displayMetrics.heightPixels
        val statusBarRes =
            context.resources.getIdentifier("status_bar_height", "dimen", "android")
        val statusBar = if (statusBarRes > 0) {
            context.resources.getDimensionPixelSize(statusBarRes)
        } else {
            0
        }
        return maxOf(full - statusBar, (full * 0.85f).toInt())
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
        avatarBitmap: Bitmap,
    ) {
        if (shortcutId.isEmpty()) return
        try {
            // Intent du shortcut : ouvre l'app (package cible explicite)
            val intent = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(BubbleActivity.EXTRA_ROOM, shortcutId)
            }
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
                val icon = android.graphics.drawable.Icon.createWithBitmap(avatarBitmap)
                val shortcut = ShortcutInfo.Builder(context, shortcutId)
                    .setShortLabel(title)
                    .setIntent(intent)
                    .setIcon(icon)
                    .setPerson(
                        android.app.Person.Builder()
                            .setName(title)
                            .setKey(shortcutId)
                            .setIcon(icon)
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
                        IconCompat.createWithBitmap(avatarBitmap),
                    )
                    .setPerson(
                        Person.Builder().setName(title).setKey(shortcutId)
                            .setIcon(IconCompat.createWithBitmap(avatarBitmap))
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

    private fun initialsAvatar(name: String, key: String): Bitmap {
        val size = 128
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val colors = intArrayOf(0xff465a83.toInt(), 0xff75548a.toInt(),
            0xff327d7a.toInt(), 0xffa05b4b.toInt(), 0xff586f3b.toInt())
        paint.color = colors[(key.hashCode().toLong().and(0x7fffffffL) % colors.size).toInt()]
        canvas.drawCircle(64f, 64f, 64f, paint)
        val initials = name.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
            .take(2).joinToString("") { it.take(1).uppercase() }.ifEmpty { "?" }
        paint.color = Color.WHITE
        paint.textAlign = Paint.Align.CENTER
        paint.textSize = if (initials.length > 1) 53f else 69f
        paint.typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.BOLD)
        val baseline = 64f - (paint.ascent() + paint.descent()) / 2
        canvas.drawText(initials, 64f, baseline, paint)
        return bitmap
    }

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Bulles de discussion",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) setAllowBubbles(true)
            lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }
}
