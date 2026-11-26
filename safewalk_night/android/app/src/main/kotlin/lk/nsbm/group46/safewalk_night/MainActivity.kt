package lk.nsbm.group46.safewalk_night

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SmsManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Sends the emergency SMS directly, without the user having to press
        // "send" - this is what makes the alert automatic.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "safewalk_night/sms")
            .setMethodCallHandler { call, result ->
                if (call.method != "sendSms") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val phone = call.argument<String>("phone")
                val message = call.argument<String>("message")
                if (phone.isNullOrBlank() || message.isNullOrBlank()) {
                    result.error("bad_args", "Phone number and message are required", null)
                    return@setMethodCallHandler
                }
                val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS) ==
                    PackageManager.PERMISSION_GRANTED
                if (!granted) {
                    result.error("no_permission", "SMS permission not granted", null)
                    return@setMethodCallHandler
                }
                try {
                    @Suppress("DEPRECATION")
                    val sms: SmsManager =
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) getSystemService(SmsManager::class.java)
                        else SmsManager.getDefault()
                    sms.sendMultipartTextMessage(phone, null, sms.divideMessage(message), null, null)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("send_failed", e.message ?: "Could not send SMS", null)
                }
            }
    }
}
