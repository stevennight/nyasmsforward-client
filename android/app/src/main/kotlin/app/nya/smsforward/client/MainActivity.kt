package app.nya.smsforward.client

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "app.nya.smsforward.client/updater"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            if (call.method != "installApk") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            if (path.isNullOrBlank()) {
                result.error("bad_path", "APK 路径为空", null)
                return@setMethodCallHandler
            }
            installApk(path, result)
        }
    }

    private fun installApk(path: String, result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName"),
                    ),
                )
                result.error("permission_required", "请允许本应用安装未知来源应用", null)
                return
            }
            val file = File(path).canonicalFile
            val cache = cacheDir.canonicalFile
            require(file.path.startsWith(cache.path + File.separator)) { "APK 不在应用缓存目录中" }
            require(file.isFile && file.length() > 0) { "APK 文件不存在或为空" }
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            startActivity(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                },
            )
            result.success(null)
        } catch (e: Exception) {
            result.error("install_failed", e.message ?: "无法打开系统安装器", null)
        }
    }
}
