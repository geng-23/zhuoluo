import 'package:zhuoluo/data/services/notification_service.dart';

/// 记录型通知调度替身：记录每次 schedule/cancel/cancelAll 调用，
/// 供测试断言真实调度结果（ID/时间/数量/取消），而非依赖平台插件
/// 不可用时的异常吞掉行为。
///
/// 用法：
/// ```dart
/// final fake = FakeNotificationScheduler();
/// NotificationService.instance.debugOverrideScheduler = fake;
/// addTearDown(() => NotificationService.instance.debugOverrideScheduler = null);
/// ```
class FakeNotificationScheduler implements NotificationScheduler {
  /// 成功调度记录（title/body/when/payload/channel 全量）
  final List<({int id, String title, String body, DateTime when, String? payload, String channel})> scheduled = [];

  /// 取消记录（按调用顺序）
  final List<int> cancelled = [];

  /// 取消全部次数
  int cancelAllCount = 0;

  /// 番茄钟完成提醒记录（专注分钟数）
  final List<int> finishedShows = [];

  /// 调度是否失败（默认 false；测试可置 true 模拟权限拒绝/平台错误）
  bool failSchedules = false;

  /// 最后一条成功调度的通知（无则 null）
  ({int id, String title, String body, DateTime when, String? payload, String channel})?
      get lastScheduled => scheduled.isEmpty ? null : scheduled.last;

  @override
  Future<bool> schedule(
    int id, {
    required String title,
    required String body,
    required DateTime when,
    String? payload,
    String channel = 'task_reminder_v4',
  }) async {
    if (failSchedules) return false;
    scheduled.add((
      id: id,
      title: title,
      body: body,
      when: when,
      payload: payload,
      channel: channel,
    ));
    return true;
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCount++;
  }

  @override
  Future<void> showPomodoroFinished({required int minutes}) async {
    finishedShows.add(minutes);
  }

  /// 按通知 ID 筛选的调度记录
  List<({int id, String title, String body, DateTime when, String? payload, String channel})>
      byId(int id) => scheduled.where((s) => s.id == id).toList();

  void clear() {
    scheduled.clear();
    cancelled.clear();
    cancelAllCount = 0;
    finishedShows.clear();
  }
}
