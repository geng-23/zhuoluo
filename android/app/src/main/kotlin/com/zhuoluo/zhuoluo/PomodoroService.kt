package com.zhuoluo.zhuoluo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * 番茄钟前台服务。
 *
 * 职责：番茄专注会话期间保持进程存活（返回桌面/切后台计时不中断），并托管
 * 常驻倒计时通知。倒计时由 Dart 每秒推送剩余秒数，正文实时显示"剩余 MM:SS"
 *（chronometer 在部分 ROM 不渲染，故采用文本每秒更新，全设备一致）；
 * 通知动作（暂停/继续/结束）经 [PomodoroActionReceiver] 转发回 Dart 主隔离区。
 *
 * 生命周期：会话开始（start）→ 状态变更（update）→ 结束（stop）。
 * 停止时移除通知；进程/服务被杀时系统自动移除通知（无残留冻结倒计时）。
 * 服务本身不持有计时状态——Dart 侧 [PomodoroController] 是唯一事实源，
 * 此处仅负责展示与保活。
 */
class PomodoroService : Service() {

    companion object {
        const val ACTION_START = "com.zhuoluo.zhuoluo.PomodoroService.START"
        const val ACTION_UPDATE = "com.zhuoluo.zhuoluo.PomodoroService.UPDATE"
        const val ACTION_STOP = "com.zhuoluo.zhuoluo.PomodoroService.STOP"
        const val EXTRA_ID = "notificationId"
        const val EXTRA_REMAINING = "remainingSec"
        const val EXTRA_TOTAL = "totalSec"
        const val EXTRA_RUNNING = "running"
        const val EXTRA_TITLE = "title"

        private const val CHANNEL_ID = "pomodoro_countdown_v1"

        /** 番茄主题主色（与 App 主题 seedColor 0xFF4F8EF7 一致） */
        private const val ACCENT_COLOR = 0xFF4F8EF7.toInt()

        /** 启动/更新前台通知（服务已运行时 startService 会再次回调 onStartCommand）。 */
        fun start(
            context: Context,
            id: Int,
            running: Boolean,
            remainingSec: Int,
            totalSec: Int,
            title: String?,
        ) {
            val intent = Intent(context, PomodoroService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_ID, id)
                putExtra(EXTRA_REMAINING, remainingSec)
                putExtra(EXTRA_TOTAL, totalSec)
                putExtra(EXTRA_RUNNING, running)
                putExtra(EXTRA_TITLE, title)
            }
            context.startService(intent)
        }

        /** 更新通知内容（不改变前台状态）。 */
        fun update(
            context: Context,
            id: Int,
            running: Boolean,
            remainingSec: Int,
            totalSec: Int,
            title: String?,
        ) {
            val intent = Intent(context, PomodoroService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_ID, id)
                putExtra(EXTRA_REMAINING, remainingSec)
                putExtra(EXTRA_TOTAL, totalSec)
                putExtra(EXTRA_RUNNING, running)
                putExtra(EXTRA_TITLE, title)
            }
            context.startService(intent)
        }

        /** 停止服务并移除通知。 */
        fun stop(context: Context, id: Int) {
            val intent = Intent(context, PomodoroService::class.java).apply {
                action = ACTION_STOP
                putExtra(EXTRA_ID, id)
            }
            context.startService(intent)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            ACTION_START, ACTION_UPDATE -> {
                val id = intent.getIntExtra(EXTRA_ID, 0)
                val running = intent.getBooleanExtra(EXTRA_RUNNING, true)
                val remainingSec = intent.getIntExtra(EXTRA_REMAINING, 0)
                val totalSec = intent.getIntExtra(EXTRA_TOTAL, 0)
                val title = intent.getStringExtra(EXTRA_TITLE)
                val notification = buildNotification(running, remainingSec, totalSec, title)
                if (ACTION_START == intent.action) {
                    // Android 14+ 需显式传入前台服务类型（manifest 已声明 specialUse）；
                    // 更早版本不识别该位，传 0 由系统按 manifest 兜底
                    val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                    } else {
                        0
                    }
                    ServiceCompat.startForeground(this, id, notification, type)
                } else {
                    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    nm.notify(id, notification)
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun buildNotification(
        running: Boolean,
        remainingSec: Int,
        totalSec: Int,
        title: String?,
    ): Notification {
        ensureChannel()
        val elapsedSec = (totalSec - remainingSec).coerceAtLeast(0)
        // 正文实时倒计时（Dart 每秒推送剩余秒数；chronometer 部分 ROM 不渲染，
        // 故用文本每秒更新，全设备一致）
        val body = if (running) {
            "剩余 ${formatRemaining(remainingSec)}"
        } else {
            "已暂停 · 剩余 ${formatRemaining(remainingSec)}"
        }
        // 标题带任务上下文：番茄专注 / 番茄专注 · 写方案
        val contentTitle = if (title.isNullOrBlank()) "番茄专注" else "番茄专注 · $title"
        // 展开态大文本：进度 + 任务上下文
        val bigText = if (running) {
            val taskLine = if (title.isNullOrBlank()) "" else "\n任务：$title"
            "正在专注 ${totalSec / 60} 分钟 · 已专注 ${formatRemaining(elapsedSec)}$taskLine"
        } else {
            "已暂停 · 已专注 ${formatRemaining(elapsedSec)}"
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_pomodoro)
            .setLargeIcon(drawableToBitmap(R.drawable.ic_tomato_large, 128))
            .setColor(ACCENT_COLOR)
            .setContentTitle(contentTitle)
            .setContentText(body)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setShowWhen(false)
            // 会话进度条（已专注秒数 / 总秒数）
            .setProgress(if (totalSec > 0) totalSec else 1, elapsedSec, false)
            // 展开态大文本
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .setBigContentTitle(contentTitle)
                    .bigText(bigText),
            )
            // 点通知主体 → 打开 App 并直达番茄专注页
            .setContentIntent(
                PendingIntent.getActivity(
                    this,
                    0,
                    Intent(this, MainActivity::class.java)
                        .putExtra(MainActivity.EXTRA_OPEN_POMODORO, true)
                        .addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP,
                        ),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )

        // 动作按钮（带图标）：cancelNotification=false —— 点击不撤下通知，仅就地更新
        val actionId = if (running) PomodoroActionReceiver.ACTION_PAUSE else PomodoroActionReceiver.ACTION_RESUME
        val actionLabel = if (running) "暂停" else "继续"
        val actionIcon =
            if (running) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        builder.addAction(actionIcon, actionLabel, actionPendingIntent(actionId))
        builder.addAction(
            R.drawable.ic_action_stop,
            "结束",
            actionPendingIntent(PomodoroActionReceiver.ACTION_STOP),
        )
        return builder.build()
    }

    /** VectorDrawable → ARGB 位图（大图标用；API 21+ 支持 VectorDrawable 绘制） */
    private fun drawableToBitmap(resId: Int, size: Int): Bitmap {
        val drawable = androidx.core.content.ContextCompat.getDrawable(this, resId)!!
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        return bitmap
    }

    private fun actionPendingIntent(actionId: String): PendingIntent =
        PendingIntent.getBroadcast(
            this,
            actionId.hashCode(),
            Intent(this, PomodoroActionReceiver::class.java).setAction(actionId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        // 防御性创建（正常由插件 init 创建；渠道属性以插件创建为准）
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "番茄钟倒计时",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { lockscreenVisibility = Notification.VISIBILITY_PUBLIC },
        )
    }

    private fun formatRemaining(sec: Int): String {
        val s = if (sec < 0) 0 else sec
        val mm = (s / 60).toString().padStart(2, '0')
        val ss = (s % 60).toString().padStart(2, '0')
        return "$mm:$ss"
    }
}
