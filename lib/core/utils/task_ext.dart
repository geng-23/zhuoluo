import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';

/// Task 新时间模型辅助扩展（v0.2）
extension TaskEx on Task {
  /// 计划时长（分钟），未设置时为 60
  int get durationMinutes {
    final ps = planStart;
    final pe = planEnd;
    if (ps == null || pe == null) return 60;
    final d = pe.difference(ps).inMinutes;
    return d > 0 ? d : 60;
  }

  /// 是否过期（计划结束时间或截止时间已过；纳入 dueTime）
  bool get isOverdueNow {
    if (completedAt != null) return false;
    final now = AppClock.now();
    final pe = planEnd;
    if (pe != null && pe.isBefore(now)) return true;
    final dt = dueTime;
    if (dt != null && dt.isBefore(now)) return true;
    return false;
  }
}
