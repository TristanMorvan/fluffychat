package chat.fluffy.fluffychat

import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint
import io.flutter.plugin.common.MethodChannel

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.app.NotificationManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings

class MainActivity : FlutterFragmentActivity() {

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
    }


    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return provideEngine(getApplicationContext())
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        registerBubbleChannel(flutterEngine, applicationContext)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        forwardBubblePayload(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        forwardBubblePayload(intent)
    }

    // Fork: tap sur une bulle quand l'app était morte — on relaye vers
    // l'isolate principale si elle est prête, sinon l'app s'ouvre simplement.
    private fun forwardBubblePayload(intent: Intent?) {
        val payload = intent?.getStringExtra(BubbleTapReceiver.EXTRA_PAYLOAD) ?: return
        intent.removeExtra(BubbleTapReceiver.EXTRA_PAYLOAD)
        val id = intent.getIntExtra(BubbleTapReceiver.EXTRA_NOTIFICATION_ID, 0)
        BubbleNotificationHelper.sendTapToFlutter(engine, payload, id)
    }

    // Prevent Flutter engine gets destroyed on back button close.
    override fun createFlutterFragment(): FlutterFragment =
        super.createFlutterFragment().apply {
            arguments?.putBoolean("destroy_engine_with_fragment", false)
        }

    companion object {
        const val BUBBLE_CHANNEL = "chat.fluffy/bubbles"
        var engine: FlutterEngine? = null

        // Fork M6 : piece a buller en attente (cas app morte -> ouverture
        // par la bulle : Dart la reclamera via getPendingBubbleRoom)
        var pendingBubbleRoomId: String? = null

        // Fork: le moteur étant créé à la main (provideEngine), configureFlutterEngine
        // n'est pas toujours appelé — on enregistre le canal natif dès la création.
        fun registerBubbleChannel(flutterEngine: FlutterEngine, context: Context) {
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                BUBBLE_CHANNEL,
            ).setMethodCallHandler { call, result ->
                if (call.method == "showBubble") {
                    try {
                        BubbleNotificationHelper.showBubble(
                            context,
                            call.argument<Int>("id") ?: 0,
                            call.argument<String>("title") ?: "",
                            call.argument<String>("text") ?: "",
                            call.argument<String>("sender"),
                            call.argument<String>("shortcutId") ?: "",
                            call.argument<String>("groupKey"),
                            call.argument<String>("payload") ?: "",
                            call.argument<ByteArray>("avatar"),
                        )
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("bubble", e.message, null)
                    }
                } else if (call.method == "clearNonBubbleNotifications") {
                    // A receipt clears the unread count on opening a bubble.
                    // cancelAll would also remove the notification anchoring
                    // the live bubble, immediately closing its TaskView.
                    val manager = context.getSystemService(NotificationManager::class.java)
                    for (item in manager.activeNotifications) {
                        if (item.notification.flags and android.app.Notification.FLAG_BUBBLE == 0) {
                            manager.cancel(item.tag, item.id)
                        }
                    }
                    result.success(null)
                } else if (call.method == "cancelNotificationUnlessBubble") {
                    val id = call.argument<Int>("id") ?: 0
                    val manager = context.getSystemService(NotificationManager::class.java)
                    val item = manager.activeNotifications.firstOrNull { it.id == id }
                    if (item != null && item.notification.flags and android.app.Notification.FLAG_BUBBLE == 0) {
                        manager.cancel(item.tag, id)
                    }
                    result.success(null)
                } else if (call.method == "ensureBubbleChannel") {
                    try {
                        BubbleNotificationHelper.ensureChannel(context)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("bubble_channel", e.message, null)
                    }
                } else if (call.method == "openBubble") {
                    try {
                        openBubble(
                            context,
                            call.argument<String>("roomId") ?: "",
                            call.argument<String>("title") ?: "",
                            call.argument<String>("payload") ?: "",
                            result,
                        )
                    } catch (e: Exception) {
                        result.error("bubble", e.message, null)
                    }
                } else if (call.method == "getPendingBubbleRoom") {
                    // Fork M6 : Dart demande la piece en attente au demarrage
                    result.success(pendingBubbleRoomId)
                } else if (call.method == "openNotificationSettings") {
                    try {
                        openNotificationSettings(context)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("settings", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
        }

        fun provideEngine(context: Context): FlutterEngine {
            val eng = engine ?: FlutterEngine(context, emptyArray(), true, false).also {
                engine = it
                registerBubbleChannel(it, context)
            }
            return eng
        }

        // Make push services run in the same engine.
        // https://codeberg.org/UnifiedPush/flutter-connector/src/branch/main/unifiedpush_android/android/src/main/kotlin/org/unifiedpush/flutter/connector/UnifiedPushService.kt#L17-L32
        fun provideRunningEngine(context: Context): FlutterEngine {
            var eng = engine
            if (eng == null) {
                eng = provideEngine(context)
                eng.getLocalizationPlugin().sendLocalesToFlutter(
                    context.getResources().getConfiguration())
                eng.getDartExecutor().executeDartEntrypoint(
                    DartEntrypoint.createDefault())
            }
            return eng
        }

    // Fork: ouverture d'une bulle à la demande (item « Ouvrir la bulle »
    // de la page détails). La voie publique setLaunchIntoBubbles +
    // android:allowBubbles est @hide (vérifié android.jar 37.2) : on poste
    // donc une notification de bulle avec autoExpand=true (mécanisme de
    // Messenger). Le raccourci de conversation est publié d'abord pour que
    // la bulle soit rattachée à la bonne pièce. Repli honnête : si les
    // bulles ne sont pas autorisées, on ouvre la conversation normalement
    // et on remonte « bubbles_not_allowed » pour que Dart affiche le
    // message. Succès ne garantit pas l'auto-ouverture : restriction
    // Android 11+, la toute première bulle d'une conversation exige un tap
    // sur le cercle de la notification — Dart affiche un conseil.
    private fun openBubble(
        context: Context,
        roomId: String,
        title: String,
        payload: String,
        result: MethodChannel.Result,
    ) {
        if (roomId.isEmpty()) {
            result.error("bad_args", "roomId is required", null)
            return
        }
        val bubblesAllowed = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            context.getSystemService(NotificationManager::class.java)
                .areBubblesAllowed()
        if (!bubblesAllowed) {
            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(BubbleTapReceiver.EXTRA_PAYLOAD, payload)
            }
            context.startActivity(intent)
            result.error(
                "bubbles_not_allowed",
                "Bubbles are not allowed for this app in system settings",
                null,
            )
            return
        }
        BubbleNotificationHelper.showBubble(
            context,
            // id stable par pièce : l'ouverture manuelle remplace sa propre
            // notif au lieu d'empiler
            (roomId.hashCode() and 0x7FFF0000) or 0x42,
            title,
            title,
            null,
            roomId,
            null,
            payload,
            null,
            autoExpand = true,
        )
        result.success(null)
    }

    // Fork M5 : deep link vers la page systeme des notifications de
    // l'app (la ou Android/Samsung autorise les bulles).
    // ACTION_APP_NOTIFICATION_SETTINGS (API 26+) ; si la ROM n'a pas
    // cette page (ActivityNotFoundException) ou si SDK < 26, repli sur
    // la fiche « Details de l'application ».
    private fun openNotificationSettings(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                context.startActivity(
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                        putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    },
                )
                return
            } catch (e: ActivityNotFoundException) {
                // ROM sans cette page : on tombe sur le repli ci-dessous
            }
        }
        context.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:" + context.packageName)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            },
        )
    }
    }
}
