package com.zhuoluo.zhuoluo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * 番茄钟前台服务。
 *
 * 职责：番茄专注会话期间保持进程存活（返回桌面/切后台计时不中断），并托管
 * 常驻倒计时通知。倒计时读秒由系统 chronometer 按结束时刻渲染（SystemUI 原生
 * 走秒，与 App 进程是否被冻结无关）；通知动作（暂停/继续/结束）经
 * [PomodoroActionReceiver] 转发回 Dart 主隔离区。
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
        const val EXTRA_END_AT = "endAtMs"
        const val EXTRA_REMAINING = "remainingSec"
        const val EXTRA_RUNNING = "running"

        private const val CHANNEL_ID = "pomodoro_countdown_v1"

        /** 启动/更新前台通知（服务已运行时 startService 会再次回调 onStartCommand）。 */
        fun start(context: Context, id: Int, endAtMs: Long?, running: Boolean, remainingSec: Int) {
            val intent = Intent(context, PomodoroService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_ID, id)
                if (endAtMs != null) putExtra(EXTRA_END_AT, endAtMs)
                putExtra(EXTRA_REMAINING, remainingSec)
                putExtra(EXTRA_RUNNING, running)
            }
            context.startService(intent)
        }

        /** 更新通知内容（不改变前台状态）。 */
        fun update(context: Context, id: Int, endAtMs: Long?, running: Boolean, remainingSec: Int) {
            val intent = Intent(context, PomodoroService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_ID, id)
                if (endAtMs != null) putExtra(EXTRA_END_AT, endAtMs)
                putExtra(EXTRA_REMAINING, remainingSec)
                putExtra(EXTRA_RUNNING, running)
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
                val endAtMs = if (intent.hasExtra(EXTRA_END_AT)) intent.getLongExtra(EXTRA_END_AT, 0) else null
                val running = intent.getBooleanExtra(EXTRA_RUNNING, true)
                val remainingSec = intent.getIntExtra(EXTRA_REMAINING, 0)
                val notification = buildNotification(id, endAtMs, running, remainingSec)
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
        id: Int,
        endAtMs: Long?,
        running: Boolean,
        remainingSec: Int,
    ): Notification {
        ensureChannel()
        val title = "番茄专注"
        val body = if (running) {
            "专注中"
        } else {
            "已暂停 · 剩余 ${formatRemaining(remainingSec)}"
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setShowWhen(false)
            // 点通知主体回到 App（会话页面由用户自行导航）
            .setContentIntent(
                PendingIntent.getActivity(
                    this,
                    0,
                    Intent(this, MainActivity::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )

        if (running && endAtMs != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            // 系统 chronometer 倒计时：从结束时刻原生渲染读秒，进程冻结也精确
            builder.setUsesChronometer(true)
                .setChronometerCountDown(true)
                .setWhen(endAtMs)
        }

        // 动作按钮：cancelNotification=false —— 点击不撤下通知，仅就地更新
        val actionId = if (running) PomodoroActionReceiver.ACTION_PAUSE else PomodoroActionReceiver.ACTION_RESUME
        val actionLabel = if (running) "暂停" else "继续"
        builder.addAction(0, actionLabel, actionPendingIntent(actionId))
        builder.addAction(0, "结束", actionPendingIntent(PomodoroActionReceiver.ACTION_STOP))
        return builder.build()
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
