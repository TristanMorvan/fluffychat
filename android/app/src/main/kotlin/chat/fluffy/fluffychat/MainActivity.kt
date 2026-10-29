package chat.fluffy.fluffychat

import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint
import io.flutter.plugin.common.MethodChannel

import android.content.Context
import android.content.Intent
import android.os.Bundle

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
    }
}
