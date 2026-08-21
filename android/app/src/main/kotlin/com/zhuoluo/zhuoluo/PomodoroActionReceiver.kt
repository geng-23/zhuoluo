package com.zhuoluo.zhuoluo

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 番茄钟通知动作接收器（暂停/继续/结束）。
 *
 * flutter_local_notifications v22 的动作回调只投递到后台隔离区且无法桥接回
 * 主隔离区（后台引擎不注册插件），因此通知动作由本接收器原生处理：
 * - 进程存活：经 MainActivity 静态持有的 MethodChannel 直达 Dart 主隔离区，
 *   PomodoroController 即时响应（App 不跳前台，纯后台控制）。
 * - 进程已死：冷启动 MainActivity（会话已随进程终止，动作无意义，仅回前台）。
 */
class PomodoroActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_PAUSE = "com.zhuoluo.zhuoluo.pomodoro.pause"
        const val ACTION_RESUME = "com.zhuoluo.zhuoluo.pomodoro.resume"
        const val ACTION_STOP = "com.zhuoluo.zhuoluo.pomodoro.stop"
        private const val TAG = "PomodoroActionReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val actionId = intent.action ?: return
        // 通知动作 ID 口径与 Dart 侧一致：pause/resume/stop
        val dartAction = when (actionId) {
            ACTION_PAUSE -> "pause"
            ACTION_RESUME -> "resume"
            ACTION_STOP -> "stop"
            else -> return
        }
        val channel = MainActivity.pomodoroChannel
        if (channel != null) {
            // 进程存活：直达主隔离区
            try {
                channel.invokeMethod("action", dartAction, null)
            } catch (e: Exception) {
                Log.w(TAG, "转发番茄钟动作失败: $dartAction", e)
            }
        } else {
            // 进程已死：冷启动 App（会话已失）
            val launch = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(launch)
        }
    }
}
