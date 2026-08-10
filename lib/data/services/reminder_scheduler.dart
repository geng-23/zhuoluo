import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/data/services/rrule_expander.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';

/// 提醒调度引擎
///
/// 设计文档 §8：增量重排（任务变更时）+ 全量重排（开机/备份恢复）
class ReminderScheduler {
  ReminderScheduler(this._db);

  final AppDatabase _db;

  /// 上次全量重排时间（内存态，进程内有效）。
  /// 用于"窗口滚动"门控：resumed 时距上次重排 >24h 才再排一次，
  /// 避免每次回前台都 cancelAll+全量重排（93 天窗口随日期前进）。
  DateTime? _lastFullReschedule;

  /// 计算任务在 [instanceDate] 实例的提醒绝对时间列表
  List<DateTime> computeReminderTimes(
    Task task,
    DateTime instanceDate,
    List<Reminder> reminders,
  ) {
    return reminders.map((r) {
      final t = _reminderBase(task, instanceDate, r)
          .subtract(Duration(minutes: r.remindMinutesBefore));
      return t;
    }).toList();
  }

  /// 任务在实例日期的"提醒基准时间"：
  /// - 全天任务：当天 [Reminder.remindAtMinutes] 时刻（null = 默认 09:00）
  /// - 定时任务：实例时间（例外改期带时分时用实例时分），否则 planStart 的时分
  DateTime _reminderBase(Task task, DateTime instanceDate, Reminder r) {
    final d = AppClock.at(
      instanceDate.year,
      instanceDate.month,
      instanceDate.day,
    );
    final ps = task.planStart;
    if (task.isAllDay || ps == null) {
      final remindAt = r.remindAtMinutes ?? 540; // 默认 09:00
      return d.add(Duration(minutes: remindAt));
    }
    // 例外改期到带时分的目标（如改期本次选了具体时间）
    if (instanceDate.hour != 0 || instanceDate.minute != 0) {
      return AppClock.at(
        d.year,
        d.month,
        d.day,
        instanceDate.hour,
        instanceDate.minute,
      );
    }
    // ps 为 DB 读回值（系统时区字段），先按应用时区解释再取时分
    final a = AppClock.asApp(ps);
    return AppClock.at(d.year, d.month, d.day, a.hour, a.minute);
  }

  /// 调度单个任务的提醒（增量重排：先取消旧通知再排新）。
  /// 返回 false 表示有提醒未成功排入系统（通知权限被拒/精确闹钟缺失等），
  /// 供 UI 向用户提示；通知平台调用失败不影响业务，吞掉异常避免
  /// 破坏调用方（如任务详情页刷新）的数据流程。
  Future<bool> scheduleTask(Task task) async {
    try {
      return await _scheduleTaskInner(task);
    } catch (e) {
      debugPrint('提醒调度失败 taskId=${task.id}: $e');
      return false;
    }
  }

  Future<bool> _scheduleTaskInner(Task task) async {
    // 取消该任务的全部旧通知
    await cancelTask(task.id);
    if (task.completedAt != null) return true;
    final reminders = await _db.getReminders(task.id);
    if (reminders.isEmpty) return true;

    var ok = true;
    if (task.rrule.isEmpty) {
      final ps = task.planStart;
      if (ps == null) {
        // 仅截止时间的任务（备份兼容路径）——按截止日当天 +
        // 提醒时刻排期（_reminderBase 对 ps==null 已按全天式 remindAtMinutes
        // 处理，默认 09:00）。此前调度器直接跳过，提醒静默失效。
        final due = task.dueTime;
        if (due == null) return true;
        final a = AppClock.asApp(due);
        final day = AppClock.at(a.year, a.month, a.day);
        ok = await _scheduleDay(task, day, reminders) && ok;
      } else {
        final a = AppClock.asApp(ps);
        final day = AppClock.at(a.year, a.month, a.day);
        ok = await _scheduleDay(task, day, reminders) && ok;
      }
    } else {
      // 重复任务：调度未来 3 个月内的实例
      final today = AppClock.now();
      final start = task.planStart ?? today;
      final windowStart = today.subtract(const Duration(days: 1));
      final windowEnd = today.add(const Duration(days: 93));
      // 批量预取例外/完成记录/跳过日期——此前逐实例查库（每实例 2 次查询，
      // 93 天窗口单任务约 186 次），无限期任务实例多时调度慢
      final exceptions = await _db.getExceptions(task.id);
      final doneSet = await _db.getCompletedSetForTasks(
        [task.id],
        windowStart,
        windowEnd,
      );
      final skippedDays = _db.decodeSkippedDays(task);
      // 从 start 展开并截取未来窗口（老任务不再因前 100 个实例全在过去而漏排）
      final instances = RruleService.instance.expand(
        start,
        task.rrule,
        from: windowStart,
        to: windowEnd,
        limit: 500,
      );
      for (final inst in instances) {
        // 实例日期归一化到当天 00:00，与完成记录存储基准一致，
        // 避免 RRULE 展开保留的时分（如 09:00）与完成记录（00:00）互相不识别
        final day = DateUtilsEx.normalizeInstanceDate(inst);
        // 内存判断跳过/例外移走（此前 _isSkipped 每实例查库）
        if (!_db.hasInstanceOnDaySync(task, day, exceptions, skippedDays)) {
          continue;
        }
        if (doneSet.contains(_db.completionKey(task.id, day))) continue;
        ok = await _scheduleDay(task, day, reminders) && ok;
      }
      // 例外改期：原日期已被 hasInstanceOnDaySync 判为移走，改期到的新日期
      // 不在规则展开里，需单独在窗口内排提醒
      for (final ex in exceptions) {
        final od = ex.overrideScheduledDate;
        if (ex.action != 'edit' || od == null) continue;
        final a = AppClock.asApp(od);
        final day = AppClock.at(a.year, a.month, a.day);
        if (day.isBefore(windowStart) || day.isAfter(windowEnd)) continue;
        if (doneSet.contains(_db.completionKey(task.id, day))) continue;
        ok = await _scheduleDay(task, day, reminders) && ok;
      }
    }
    return ok;
  }

  Future<bool> _scheduleDay(
    Task task,
    DateTime day,
    List<Reminder> reminders,
  ) async {
    var ok = true;
    for (final r in reminders) {
      final when = _reminderBase(
        task,
        day,
        r,
      ).subtract(Duration(minutes: r.remindMinutesBefore));
      if (when.isBefore(AppClock.now())) continue; // 已过时间：不算失败
      // ID 含实例日期：同一 (task, reminder) 的不同实例通知互不覆盖
      final id = NotificationIds.forReminder(r.id, day);
      final scheduled = await NotificationService.instance.schedule(
        id,
        title: task.title,
        body: _bodyText(task, day, r),
        when: when,
        payload: 't${task.id}',
      );
      if (!scheduled) ok = false;
    }
    if (!task.hasReminder) {
      await _db.updateTaskHasReminder(task.id, true);
    }
    return ok;
  }

  String _bodyText(Task task, DateTime day, Reminder r) {
    final t = _reminderBase(task, day, r);
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '${task.title} · $hh:$mm';
  }

  /// 任务在"排期窗口"内的全部提醒日期（规则实例 + 例外改期日期）。
  /// 取消用超集：多取消不存在的 ID 无副作用，保证排过的都能被取消。
  Future<List<DateTime>> _cancelDatesFor(Task t) async {
    if (t.rrule.isEmpty) {
      final ps = t.planStart;
      if (ps == null) {
        // 仅截止时间的任务：与排期对称，按截止日当天取消
        final due = t.dueTime;
        if (due == null) return const [];
        final a = AppClock.asApp(due);
        return [AppClock.at(a.year, a.month, a.day)];
      }
      final a = AppClock.asApp(ps);
      return [AppClock.at(a.year, a.month, a.day)];
    }
    final today = AppClock.now();
    final start = t.planStart ?? today;
    final instances = RruleService.instance.expand(
      start,
      t.rrule,
      from: today.subtract(const Duration(days: 1)),
      to: today.add(const Duration(days: 93)),
      limit: 500,
    );
    final dates = instances
        .map((d) => AppClock.at(d.year, d.month, d.day))
        .toList();
    final exceptions = await _db.getExceptions(t.id);
    for (final ex in exceptions) {
      final od = ex.overrideScheduledDate;
      if (ex.action == 'edit' && od != null) {
        final a = AppClock.asApp(od);
        dates.add(AppClock.at(a.year, a.month, a.day));
      }
    }
    return dates;
  }

  /// 取消任务全部通知
  /// 通知平台失败不影响业务（如插件异常/权限问题），吞掉异常保证
  /// 删除/改期等流程不因通知问题中断（小米等厂商机插件稳定性差异）
  Future<void> cancelTask(int taskId) async {
    try {
      final t = await _db.getTask(taskId);
      if (t == null) return;
      final reminders = await _db.getReminders(taskId);
      final dates = await _cancelDatesFor(t);
      for (final d in dates) {
        for (final r in reminders) {
          try {
            await NotificationService.instance.cancel(
              NotificationIds.forReminder(r.id, d),
            );
          } catch (e) {
            debugPrint('通知取消失败 taskId=$taskId reminderId=${r.id}: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('取消任务通知失败 taskId=$taskId: $e');
    }
  }

  /// 取消单条提醒的全部通知（删除某条提醒时调用；ID 含实例维度需按日期枚举）
  Future<void> cancelReminder(int taskId, int reminderId) async {
    try {
      final t = await _db.getTask(taskId);
      if (t == null) return;
      final dates = await _cancelDatesFor(t);
      for (final d in dates) {
        await NotificationService.instance.cancel(
          NotificationIds.forReminder(reminderId, d),
        );
      }
    } catch (e) {
      debugPrint('取消提醒通知失败 taskId=$taskId reminderId=$reminderId: $e');
    }
  }

  /// 全量重排（开机恢复 / 备份恢复后 / 时区变化）
  /// 单条失败不影响整体（通知平台异常被吞掉，保证启动不崩溃）
  Future<void> rescheduleAll() async {
    try {
      // B：权限未授予时不得先 cancelAll——否则会把已排提醒清掉且排不回来
      //（schedule 在权限被拒时短路，取消后只剩空）。先刷新缓存确认，
      // 仍未授予则整体跳过（排了也会被 schedule 短路）
      if (!await NotificationService.instance.ensureNotificationsGranted()) {
        debugPrint('全量重排跳过：通知权限未授予');
        return;
      }
      await NotificationService.instance.cancelAll();
      final allTasks = await _db.getAllUncompleted();
      for (final t in allTasks) {
        final ps = t.planStart;
        // 仅截止时间（dueTime）的任务同样纳入全量重排
        if (ps == null && t.rrule.isEmpty && t.dueTime == null) continue;
        await scheduleTask(t);
      }
      // 习惯提醒：每日固定时刻重复
      final habits = await _db.getHabits();
      for (final h in habits) {
        await scheduleHabitReminder(h);
      }
      _lastFullReschedule = AppClock.now();
    } catch (e) {
      debugPrint('全量重排失败: $e');
    }
  }

  /// 93 天排期窗口滚动——进程常驻期间窗口不会自动前进，
  /// 距上次全量重排超过 24h 时补排一次（resumed 生命周期回调调用；
  /// 用户每天回到前台即完成滚动，避免长期不重启设备重复任务
  /// 提醒在窗口外静默消失）。
  Future<void> rescheduleIfStale() async {
    final last = _lastFullReschedule;
    if (last == null) return;
    final stale =
        AppClock.now().difference(last) > const Duration(hours: 24);
    if (stale) {
      await rescheduleAll();
    }
  }

  // ---------- 习惯提醒 ----------

  /// 调度习惯每日提醒（无 reminderTime 则取消）。
  /// 逐日排期（93 天窗口，一次性通知，ID 含日期维度）——
  /// 已打卡的日期跳过（此前 scheduleDaily 循环通知无法按天跳过，
  /// 当天已打卡后仍弹"该打卡了"）；打卡/撤销打卡后调用本方法重排。
  /// 返回 false 表示有提醒未成功排入系统（权限被拒等）。
  Future<bool> scheduleHabitReminder(Habit habit) async {
    try {
      final time = habit.reminderTime;
      // 无论是否取消提醒，先取消窗口内全部旧通知再重排——
      // 打卡后重排时已排的"今天"通知必须取消，否则已打卡仍到点弹
      await cancelHabitReminder(habit.id);
      if (time == null) return true;
      var ok = true;
      final now = AppClock.now();
      final start = AppClock.at(now.year, now.month, now.day);
      for (var i = 0; i < 93; i++) {
        final day = start.add(Duration(days: i));
        // 已打卡的日期不排提醒（无效打扰）
        if (await _db.isHabitDone(habit.id, day)) continue;
        // reminderTime 为 DB 读回值（系统时区字段），先按应用时区解释
        final a = AppClock.asApp(time);
        final when = AppClock.at(
          day.year,
          day.month,
          day.day,
          a.hour,
          a.minute,
        );
        // 已过去的提醒时刻（今天）跳过，从明天开始
        if (when.isBefore(now)) continue;
        ok = await NotificationService.instance.schedule(
              NotificationIds.forHabit(habit.id, day),
              title: '习惯提醒',
              body: '该打卡「${habit.name}」了',
              when: when,
              payload: 'h${habit.id}',
              // 习惯提醒走独立渠道（声音/开关可与任务提醒分开控制）
              channel: 'habit_reminder_v3',
            ) &&
            ok;
      }
      return ok;
    } catch (e) {
      debugPrint('习惯提醒调度失败 habitId=${habit.id}: $e');
      return false;
    }
  }

  /// 取消习惯提醒（未来 93 天窗口逐日取消，ID 含日期维度）
  Future<void> cancelHabitReminder(int habitId) async {
    final now = AppClock.now();
    final start = AppClock.at(now.year, now.month, now.day);
    for (var i = 0; i < 93; i++) {
      await NotificationService.instance.cancel(
        NotificationIds.forHabit(habitId, start.add(Duration(days: i))),
      );
    }
  }

  // ---------- 跳过实例（任务页/日历页共用，统一收口） ----------

  /// 跳过实例时被删除的完成记录暂存（撤销跳过时恢复原完成时间）。
  /// 缓存最近 50 条防内存增长；暂存仅内存级，App 重启后失效。
  final Map<String, DateTime> _skippedCompletionCache = {};
  static const int _skippedCompletionCacheLimit = 50;

  static String _skipCompletionKey(int taskId, DateTime day) =>
      '$taskId:${day.toIso8601String()}';

  /// 跳过实例：写入 skippedDates、清理当天完成记录（暂存原完成时间）、重排提醒。
  /// 返回 false 表示任务不存在（调用方据此跳过反馈）。
  /// 与撤销跳过成对使用，任务页与日历页统一走本方法（此前日历侧不暂存
  /// 完成记录，撤销后统计/已完成视图数据漂移）。
  Future<bool> skipInstance(int taskId, DateTime instanceDate) async {
    final t = await _db.getTask(taskId);
    if (t == null) return false;
    // 跳过日期归一化到当天 00:00（与规则展开/例外基准一致）
    final day = DateUtilsEx.normalizeInstanceDate(instanceDate);
    final skipped = DateUtilsEx.parseSkippedDates(t.skippedDates);
    if (!skipped.contains(day.toIso8601String())) {
      skipped.add(day.toIso8601String());
    }
    // C1-1/清理当天完成记录前暂存完成时间——否则"删除本次"后
    // 列表/已完成视图/统计仍认为今天已完成；撤销跳过时恢复原记录
    if (await _db.isInstanceCompleted(taskId, day)) {
      final comp = await _db.getInstanceCompletion(taskId, day);
      if (comp != null) {
        _skippedCompletionCache[_skipCompletionKey(taskId, day)] =
            comp.completedAt;
        while (_skippedCompletionCache.length >
            _skippedCompletionCacheLimit) {
          _skippedCompletionCache.remove(_skippedCompletionCache.keys.first);
        }
      }
    }
    await _db.uncompleteInstance(taskId, day);
    await _db.updateTask(
      taskId,
      TasksCompanion(skippedDates: Value(jsonEncode(skipped))),
    );
    // 重新取任务：旧快照的 skippedDates 不含本次跳过，会让重排重新排上该实例
    final fresh = await _db.getTask(taskId);
    if (fresh != null) {
      await scheduleTask(fresh);
    }
    return true;
  }

  /// 撤销跳过：从 skippedDates 移除指定日期，并恢复被删除的完成记录
  ///（保留原完成时间，统计不漂移）。返回 false 表示任务不存在。
  Future<bool> unskipInstance(int taskId, DateTime instanceDate) async {
    final t = await _db.getTask(taskId);
    if (t == null) return false;
    final day = DateUtilsEx.normalizeInstanceDate(instanceDate);
    final skipped = DateUtilsEx.parseSkippedDates(t.skippedDates);
    skipped.remove(day.toIso8601String());
    // 撤销跳过恢复被删除的完成记录（保留原完成时间，统计不漂移）
    final cachedAt = _skippedCompletionCache.remove(
      _skipCompletionKey(taskId, day),
    );
    if (cachedAt != null) {
      await _db.restoreInstanceCompletion(taskId, day, cachedAt);
    }
    await _db.updateTask(
      taskId,
      TasksCompanion(skippedDates: Value(jsonEncode(skipped))),
    );
    // 重新取任务：旧快照仍含被移除的跳过日期，会让重排漏排该实例
    final fresh = await _db.getTask(taskId);
    if (fresh != null) {
      await scheduleTask(fresh);
    }
    return true;
  }
}

/// 计算某条提醒在"目标实例日"的触发时间：
/// - 全天任务：实例日 00:00 + [remindAtMinutes]（null = 默认 09:00）− 提前量
/// - 定时任务：实例日 + planStart 时分 − 提前量
/// - 仅截止时间任务：截止日 + [remindAtMinutes]（与调度器口径一致）
/// 实例日：重复任务 = 今天；非重复 = planStart 当天。
/// 返回 null 表示任务没有计划/截止时间（无法判断）。
DateTime? reminderTriggerAt(
  Task task,
  int remindMinutesBefore, {
  int? remindAtMinutes,
}) {
  final ps = task.planStart;
  final now = AppClock.now();
  final today = AppClock.at(now.year, now.month, now.day);
  if (ps == null) {
    // 仅截止时间的任务（备份兼容路径）：按截止日当天 + 提醒时刻 − 提前量，
    // 与 _reminderBase 的全天式口径一致（默认 09:00）
    final due = task.dueTime;
    if (due == null) return null;
    final a = AppClock.asApp(due);
    final min = remindAtMinutes ?? 540; // 默认 09:00
    return AppClock.at(a.year, a.month, a.day)
        .add(Duration(minutes: min))
        .subtract(Duration(minutes: remindMinutesBefore));
  }
  final pa = AppClock.asApp(ps);
  final day = task.rrule.isNotEmpty
      ? today
      : AppClock.at(pa.year, pa.month, pa.day);
  if (task.isAllDay) {
    final min = remindAtMinutes ?? 540; // 默认 09:00
    return day
        .add(Duration(minutes: min))
        .subtract(Duration(minutes: remindMinutesBefore));
  }
  return AppClock.at(
    day.year,
    day.month,
    day.day,
    pa.hour,
    pa.minute,
  ).subtract(Duration(minutes: remindMinutesBefore));
}
