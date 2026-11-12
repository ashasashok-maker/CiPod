package com.adeeteya.classipod

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** audio_service's activity (it shares the Flutter engine with the playback service), plus the remote-media bridge. */
class MainActivity : AudioServiceActivity() {
    private var remote: RemoteMediaBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val bridge = RemoteMediaBridge(applicationContext)
        remote = bridge
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "classipod/remote_media")
            .setMethodCallHandler(bridge)
    }
}
