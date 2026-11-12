package com.adeeteya.classipod

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.SystemClock
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.view.KeyEvent
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * Lets the click wheel drive another app's player (Spotify, Pandora, …) through its media
 * session. Android only shares sessions with apps that have notification access, which is
 * what [RemoteMediaListener] is for.
 */
class RemoteMediaBridge(private val context: Context) : MethodChannel.MethodCallHandler {
    private val sessions = context.getSystemService(MediaSessionManager::class.java)
    private val listener = ComponentName(context, RemoteMediaListener::class.java)
    private var artKey: String? = null
    private var artBytes: ByteArray? = null

    private val hasAccess: Boolean
        get() = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
            ?.split(':')?.any { it.startsWith(context.packageName + "/") } == true

    /** The session for [pkg], or with no package the newest one that isn't ours. */
    private fun controller(pkg: String?): MediaController? {
        if (!hasAccess) return null
        val active = try {
            sessions.getActiveSessions(listener)
        } catch (_: SecurityException) {
            return null
        }
        return if (pkg != null) active.firstOrNull { it.packageName == pkg }
        else active.firstOrNull { it.packageName != context.packageName }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val pkg = call.argument<String>("package")
        when (call.method) {
            "state" -> result.success(state(pkg))
            "command" -> {
                command(pkg, call.argument<String>("action").orEmpty())
                result.success(null)
            }
            "openAccess" -> {
                runCatching {
                    context.startActivity(
                        Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                }
                result.success(null)
            }
            "openApp" -> {
                openApp(pkg)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun state(pkg: String?): Map<String, Any?> {
        val installed = pkg == null || context.packageManager.getLaunchIntentForPackage(pkg) != null
        val c = controller(pkg)
            ?: return mapOf("access" to hasAccess, "installed" to installed, "active" to false)
        val meta = c.metadata
        val pb = c.playbackState
        val title = meta?.getString(MediaMetadata.METADATA_KEY_TITLE)
        val artist = meta?.getString(MediaMetadata.METADATA_KEY_ARTIST)
        val album = meta?.getString(MediaMetadata.METADATA_KEY_ALBUM)
        val key = "${c.packageName}|$title|$artist|$album"
        if (key != artKey) {
            artKey = key
            val bitmap = meta?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
                ?: meta?.getBitmap(MediaMetadata.METADATA_KEY_ART)
                ?: meta?.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)
            artBytes = bitmap?.let { bmp ->
                ByteArrayOutputStream().use { out ->
                    val scaled = if (bmp.width > 600) Bitmap.createScaledBitmap(bmp, 600, 600 * bmp.height / bmp.width, true) else bmp
                    scaled.compress(Bitmap.CompressFormat.JPEG, 85, out)
                    out.toByteArray()
                }
            }
        }
        var position = pb?.position ?: 0L
        if (pb != null && pb.state == PlaybackState.STATE_PLAYING && position >= 0) {
            position += ((SystemClock.elapsedRealtime() - pb.lastPositionUpdateTime) * pb.playbackSpeed).toLong()
        }
        return mapOf(
            "access" to true,
            "installed" to true,
            "active" to true,
            "package" to c.packageName,
            "appName" to appName(c.packageName),
            "title" to title,
            "artist" to artist,
            "album" to album,
            "playing" to (pb?.state == PlaybackState.STATE_PLAYING || pb?.state == PlaybackState.STATE_BUFFERING),
            "positionMs" to position.coerceAtLeast(0),
            "durationMs" to (meta?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L).coerceAtLeast(0),
            "artKey" to artKey,
            "art" to artBytes,
        )
    }

    private fun command(pkg: String?, action: String) {
        val c = controller(pkg)
        if (c == null) {
            // Nothing playing yet: ask the app to resume its last queue.
            if (pkg != null && (action == "play" || action == "toggle")) sendMediaButton(pkg, KeyEvent.KEYCODE_MEDIA_PLAY)
            return
        }
        val t = c.transportControls
        when (action) {
            "play" -> t.play()
            "pause" -> t.pause()
            "toggle" -> if (c.playbackState?.state == PlaybackState.STATE_PLAYING) t.pause() else t.play()
            "next" -> t.skipToNext()
            "previous" -> t.skipToPrevious()
        }
    }

    private fun openApp(pkg: String?) {
        if (pkg == null) {
            runCatching { controller(null)?.sessionActivity?.send() }
            return
        }
        val launch = context.packageManager.getLaunchIntentForPackage(pkg) ?: return
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(launch) }
    }

    private fun sendMediaButton(pkg: String, code: Int) {
        for (action in listOf(KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP)) {
            val intent = Intent(Intent.ACTION_MEDIA_BUTTON).setPackage(pkg).putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(action, code))
            runCatching { context.sendBroadcast(intent) }
        }
    }

    private fun appName(packageName: String): String = runCatching {
        val pm = context.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
    }.getOrDefault(packageName)
}

/** Registered only so Android will share other apps' media sessions with Classipod. */
class RemoteMediaListener : NotificationListenerService()
