package com.silentsave.silentsave

import android.content.Context
import androidx.work.Worker
import androidx.work.WorkerParameters
import android.content.Intent

class CleanupWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    
    override fun doWork(): Result {
        return try {
            // Trigger Flutter cleanup via broadcast
            val intent = Intent("com.silentsave.CLEANUP_EVENT")
            applicationContext.sendBroadcast(intent)
            
            // Also store a flag in shared preferences that Flutter can check
            val prefs = applicationContext.getSharedPreferences("notification_data", Context.MODE_PRIVATE)
            val editor = prefs.edit()
            editor.putBoolean("cleanup_requested", true)
            editor.putLong("cleanup_timestamp", System.currentTimeMillis())
            editor.apply()
            
            Result.success()
        } catch (e: Exception) {
            e.printStackTrace()
            Result.retry()
        }
    }
}
