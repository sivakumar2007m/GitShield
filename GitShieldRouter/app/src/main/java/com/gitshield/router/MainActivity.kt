package com.gitshield.router

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val url = intent?.data?.toString()

        if (url == null) {
            finish()
            return
        }

        if (isGitHubLink(url)) {
            openGitShield(url)
        } else {
            openChrome(url)
        }

        finish()
    }

    private fun isGitHubLink(url: String): Boolean {
        return try {
            val lower = url.lowercase().trim()
            // Must explicitly contain github.com as a domain
            lower.contains("github.com/") &&
                    !lower.contains("github.com/login") &&
                    !lower.contains("github.com/logout")
        } catch (e: Exception) {
            false
        }
    }

    private fun openGitShield(url: String) {
        val launchIntent = packageManager
            .getLaunchIntentForPackage("com.example.gitshield")
        if (launchIntent != null) {
            launchIntent.action = Intent.ACTION_VIEW
            launchIntent.data = Uri.parse(url)
            launchIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
            startActivity(launchIntent)
        } else {
            openChrome(url)
        }
    }

    private fun openChrome(url: String) {
        try {
            // Try Chrome first
            val chromeIntent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            chromeIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            chromeIntent.setPackage("com.android.chrome")
            startActivity(chromeIntent)
        } catch (e: Exception) {
            try {
                // Try Samsung browser
                val samsungIntent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                samsungIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                samsungIntent.setPackage("com.sec.android.app.sbrowser")
                startActivity(samsungIntent)
            } catch (e2: Exception) {
                try {
                    // Fallback — open with any available browser
                    // IMPORTANT: exclude GitShield Router itself
                    val fallbackIntent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    fallbackIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    fallbackIntent.addCategory(Intent.CATEGORY_BROWSABLE)
                    // This prevents routing back to ourselves
                    fallbackIntent.setPackage(null)
                    val resolveInfos = packageManager.queryIntentActivities(
                        fallbackIntent, 0
                    )
                    val targetPackage = resolveInfos.firstOrNull {
                        it.activityInfo.packageName != packageName &&
                                it.activityInfo.packageName != "com.example.gitshield"
                    }
                    if (targetPackage != null) {
                        fallbackIntent.setPackage(targetPackage.activityInfo.packageName)
                        startActivity(fallbackIntent)
                    }
                } catch (e3: Exception) {
                    // Nothing worked
                }
            }
        }
    }
}