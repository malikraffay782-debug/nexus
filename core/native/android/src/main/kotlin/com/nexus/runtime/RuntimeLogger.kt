package com.nexus.runtime

import android.util.Log

/**
 * Simple centralized logger so we can later redirect logs to Flutter easily.
 */
object RuntimeLogger {
    private const val TAG = "NexusRuntime"

    var enabled: Boolean = true

    fun d(message: String) {
        if (enabled) Log.d(TAG, message)
    }

    fun i(message: String) {
        if (enabled) Log.i(TAG, message)
    }

    fun w(message: String) {
        if (enabled) Log.w(TAG, message)
    }

    fun e(message: String, throwable: Throwable? = null) {
        if (enabled) {
            if (throwable != null) Log.e(TAG, message, throwable)
            else Log.e(TAG, message)
        }
    }
}