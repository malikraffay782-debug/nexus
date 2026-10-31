package com.nexus.studio

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.nexus.runtime.RuntimePlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Register the Embedded Runtime plugin
        flutterEngine.plugins.add(RuntimePlugin())
    }
}
