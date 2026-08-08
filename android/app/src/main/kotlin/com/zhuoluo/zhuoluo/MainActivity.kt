package com.zhuoluo.zhuoluo

import android.app.Notification
import android.app.NotificationManager
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 通知权限统一由 Dart 侧（main.dart 启动时）请求，
        // 此处不再重复请求（P1-C：双入口弹窗时机冲突）
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "zhuoluo/notifications",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // 打开应用通知设置页（Android 13+ 权限被拒后可手动开启）
                "openNotificationSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                        startActivity(intent)
                    } else {
                        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                            .setData(Uri.parse("package:$packageName"))
                        startActivity(intent)
                    }
                    result.success(null)
                }
                // 是否已豁免电池优化
                "isIgnoringBatteryOptimizations" -> {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }
                // 请求豁免电池优化（系统设置页）
                "requestBatteryOptimizationExemption" -> {
                    val intent = Intent(
                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Uri.parse("package:$packageName"),
                    )
                    startActivity(intent)
                    result.success(null)
                }
                // 将指定通知渠道的锁屏可见性更新为 PUBLIC。
                // N1-C：flutter_local_notifications 的渠道 API 不支持设置
                // lockscreenVisibility；小米 MIUI 默认按"未设置"处理为锁屏不显示，
                // 锁屏既不弹通知也不响铃，这里统一改为锁屏显示全部内容。
                "setLockscreenVisibility" -> {
                    val ids = call.argument<List<String>>("channels") ?: emptyList()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
                        for (id in ids) {
                            val channel = nm.getNotificationChannel(id) ?: continue
                            channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                            nm.createNotificationChannel(channel)
                        }
                    }
                    result.success(null)
                }
                // 备份导出：写入公共下载目录（卸载 App 不丢失，重装可恢复）。
                // Android 10+ 用 MediaStore（免权限）；9 及以下用外部存储写权限直写。
                // 返回保存路径；失败抛异常由 Dart 侧捕获提示。
                "saveBackupToDownloads" -> {
                    val json = call.argument<String>("json")
                    val name = call.argument<String>("name")
                    if (json == null || name == null) {
                        result.error("bad_args", "参数缺失", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val path = saveBackup(json, name)
                        result.success(path)
                    } catch (e: Exception) {
                        result.error("save_failed", e.message ?: "保存失败", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 写入公共下载目录，返回展示路径。 */
    private fun saveBackup(json: String, name: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/json")
                put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/着落")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("无法创建下载文件")
            resolver.openOutputStream(uri)?.use { out ->
                out.write(json.toByteArray(Charsets.UTF_8))
            } ?: throw IllegalStateException("无法写入下载文件")
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            // 返回展示路径（备份管理据此扫描）
            return "Download/着落/$name"
        }
        // Android 9 及以下：直接写公共下载目录（需 WRITE_EXTERNAL_STORAGE，已在 Manifest 声明）
        val dir = File("/storage/emulated/0/Download")
        if (!dir.exists()) {
            dir.mkdirs()
        }
        val file = File(dir, name)
        FileOutputStream(file).use { out ->
            out.write(json.toByteArray(Charsets.UTF_8))
        }
        return file.absolutePath
    }
}
