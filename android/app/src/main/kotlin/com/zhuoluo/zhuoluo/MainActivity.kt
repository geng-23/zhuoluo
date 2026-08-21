package com.zhuoluo.zhuoluo

import android.app.Notification
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {

    companion object {
        /** 番茄钟桥通道（进程存活时非空；供 [PomodoroActionReceiver] 转发动作到 Dart 主隔离区） */
        @JvmStatic
        var pomodoroChannel: MethodChannel? = null

        /** 通知点击"打开番茄页"意图 extra（PomodoroService contentIntent 携带） */
        const val EXTRA_OPEN_POMODORO = "com.zhuoluo.zhuoluo.pomodoro.open"

        /** 进程级引擎缓存 ID */
        private const val ENGINE_ID = "zhuoluo_engine"
    }

    /** 待转发的"打开番茄页"标志（onCreate/onNewIntent 置位，onResume 转发后清除） */
    private var pendingOpenPomodoro = false

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent?.getBooleanExtra(EXTRA_OPEN_POMODORO, false) == true) {
            pendingOpenPomodoro = true
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra(EXTRA_OPEN_POMODORO, false)) {
            pendingOpenPomodoro = true
        }
    }

    override fun onResume() {
        super.onResume()
        // Dart 主隔离区在首帧前已就绪（main 提前 init 桥），此处转发可达
        if (pendingOpenPomodoro) {
            pendingOpenPomodoro = false
            try {
                pomodoroChannel?.invokeMethod("openPomodoro", null, null)
            } catch (_: Exception) {
                // 通道不可用时静默（App 已打开，用户可自行导航）
            }
        }
    }

    /**
     * 进程级引擎（懒创建 + 缓存）：Activity 销毁（连续返回退出）后引擎与
     * Dart 隔离区继续存活——番茄钟会话与通知栏动作（暂停/继续/结束）不中断。
     * 首次挂载创建并缓存；后续挂载复用同一引擎（Activity 不销毁它）。
     */
    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine? {
        val cache = FlutterEngineCache.getInstance()
        return cache.get(ENGINE_ID) ?: run {
            val engine = FlutterEngine(context)
            // 手动创建引擎需自行启动 Dart 入口（isExecutingDart 防与
            // FlutterActivity 委托重复执行）；插件也需自行注册
            if (!engine.dartExecutor.isExecutingDart()) {
                engine.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint.createDefault(),
                )
            }
            GeneratedPluginRegistrant.registerWith(engine)
            cache.put(ENGINE_ID, engine)
            engine
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 番茄钟前台服务桥：Dart→原生 start/update/stop；原生→Dart action 事件。
        // 静态持有供通知动作接收器在进程存活时直达主隔离区。
        pomodoroChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "zhuoluo/pomodoro",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForeground" -> {
                        PomodoroService.start(
                            this,
                            call.argument<Int>("id") ?: 0,
                            call.argument<Boolean>("running") ?: true,
                            call.argument<Int>("remainingSec") ?: 0,
                            call.argument<Int>("totalSec") ?: 0,
                            call.argument<String>("title"),
                        )
                        result.success(null)
                    }
                    "updateForeground" -> {
                        PomodoroService.update(
                            this,
                            call.argument<Int>("id") ?: 0,
                            call.argument<Boolean>("running") ?: true,
                            call.argument<Int>("remainingSec") ?: 0,
                            call.argument<Int>("totalSec") ?: 0,
                            call.argument<String>("title"),
                        )
                        result.success(null)
                    }
                    "stopForeground" -> {
                        PomodoroService.stop(this, call.argument<Int>("id") ?: 0)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        // 通知权限统一由 Dart 侧（main.dart 启动时）请求，
        // 此处不再重复请求（双入口弹窗时机冲突）
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
                // 打开小米/HyperOS 自启动管理页（进程被清理后系统才会恢复
                // 闹钟触发的通知）；组件不存在时回退应用详情页。
                "openAutoStartSettings" -> {
                    var opened = false
                    if (Build.MANUFACTURER.equals("xiaomi", true)) {
                        try {
                            val intent = Intent("miui.intent.action.OP_AUTO_START")
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                .setPackage("com.miui.securitycenter")
                            startActivity(intent)
                            opened = true
                        } catch (_: ActivityNotFoundException) {
                            // 尝试显式组件，再回退应用详情页
                        }
                    }
                    if (!opened) {
                        try {
                            val intent = Intent()
                                .setClassName(
                                    "com.miui.securitycenter",
                                    "com.miui.permcenter.autostart.AutoStartManagementActivity",
                                )
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            opened = true
                        } catch (_: ActivityNotFoundException) {
                            // 回退应用详情页
                        }
                    }
                    if (!opened) {
                        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                            .setData(Uri.parse("package:$packageName"))
                        startActivity(intent)
                    }
                    result.success(null)
                }
                // 统一断言提醒渠道默认设置（每次启动渠道创建后调用，幂等）：
                // 系统默认通知音 + 振动开启 + 高重要性（悬浮通知/heads-up）。
                // 锁屏显示按系统默认，不在此强制。
                // 在同一次 fetch+mutate+recreate 中同时断言——部分 ROM 在
                // 渠道 re-create 时会把声音/振动复位为关闭。
                // AOSP 语义：用户已手动修改过的字段（user-locked）由系统保留，
                // 不覆盖用户选择；用户未改过的渠道保证三项默认全开。
                "applyReminderChannelDefaults" -> {
                    val ids = call.argument<List<String>>("channels") ?: emptyList()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
                        val soundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                        val audioAttributes = AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                            .build()
                        for (id in ids) {
                            val channel = nm.getNotificationChannel(id) ?: continue
                            channel.setSound(soundUri, audioAttributes)
                            channel.enableVibration(true)
                            channel.setImportance(NotificationManager.IMPORTANCE_HIGH)
                            nm.createNotificationChannel(channel)
                        }
                    }
                    result.success(null)
                }
                // 查询单个通知渠道的设置状态（我的 → 通知权限中心展示与引导）。
                // 悬浮通知以渠道重要性 >= IMPORTANCE_HIGH 为代理判断。
                "getReminderChannelSettings" -> {
                    val channelId = call.argument<String>("channelId")
                    if (channelId == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                        result.success(mapOf("exists" to false))
                        return@setMethodCallHandler
                    }
                    val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
                    val channel = nm.getNotificationChannel(channelId)
                    if (channel == null) {
                        result.success(mapOf("exists" to false))
                        return@setMethodCallHandler
                    }
                    result.success(
                        mapOf(
                            "exists" to true,
                            "soundEnabled" to (channel.getSound() != null),
                            "vibrationEnabled" to channel.shouldVibrate(),
                            "importance" to channel.getImportance(),
                        ),
                    )
                }
                // 跳转系统"指定通知渠道"设置页（通知声音/悬浮通知/振动/锁屏显示
                // 等选项集中在该页，供权限中心一键引导开启）
                "openChannelNotificationSettings" -> {
                    val channelId = call.argument<String>("channelId")
                    if (channelId != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val intent = Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            .putExtra(Settings.EXTRA_CHANNEL_ID, channelId)
                        startActivity(intent)
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
                // 返回当前系统时区 IANA ID（如 Asia/Shanghai、America/Los_Angeles）。
                // 用于"跟随系统时区"模式下运行中检测时区变化：Flutter 引擎的
                // 本地时区在进程启动时缓存，改系统时区后 Dart 侧读不到新值，
                // 必须由原生侧实时返回，App 回前台据此重读并全量重排提醒。
                "getSystemTimezoneId" -> {
                    result.success(java.util.TimeZone.getDefault().id)
                }
                else -> result.notImplemented()
            }
        }
        // 键盘避让桥：Dart→原生查询当前软键盘可见高度（物理像素）。
        // 小米/HyperOS 等 ROM 不把 IME insets 派发给应用窗口（Flutter 侧
        // MediaQuery.viewInsets 恒为 0），弹层无法据此抬升内容；这里在
        // 原生侧直接取键盘高度，不依赖窗口是否 resize。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "zhuoluo/ime",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "imeHeight" -> {
                    result.success(queryImeHeight())
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 当前软键盘可见高度（物理像素）；无键盘返回 0。 */
    private fun queryImeHeight(): Int {
        // API 30+：标准窗口 insets 的 IME 高度（多数 ROM 派发；此 ROM 不派发则为 0）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val ime = window.decorView.rootWindowInsets
                ?.getInsets(android.view.WindowInsets.Type.ime())
                ?.bottom
            if (ime != null && ime > 0) return ime
        }
        // 兜底：getInputMethodWindowVisibleHeight（公开 API，较新 SDK stub 已移除，
        // 用反射调用——返回输入法窗口真实可见高度，不依赖 insets 派发）
        return try {
            val imm = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
            val m = InputMethodManager::class.java.getMethod("getInputMethodWindowVisibleHeight")
            m.invoke(imm) as Int
        } catch (_: Exception) {
            0
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
