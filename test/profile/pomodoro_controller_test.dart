import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/features/profile/pomodoro_controller.dart';

import '../support/fake_notification_scheduler.dart';

/// 番茄专注：进程级控制器状态机 + 通知同步 + 通知动作分发 + 记录写入
///
/// 时间推进方式：AppClock.setNow 注入 + debugTick 同步 tick，
/// 规避真实 Timer 的不确定性；通知走记录型替身断言真实调用。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late FakeNotificationScheduler fake;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.ensureDefaultList();
    fake = FakeNotificationScheduler();
    NotificationService.instance.debugOverrideScheduler = fake;
    // 重置权限缓存：前序测试可能置 false（stub 模式下视为已授权）
    NotificationService.instance.debugOverridePermission = true;
    await NotificationService.instance.refreshPermissionCache();
    NotificationService.instance.debugOverridePermission = null;
    SoundService.enabled = false;
    container = ProviderContainer(overrides: [dbProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);
  });

  tearDown(() async {
    NotificationService.instance.debugOverrideScheduler = null;
    NotificationService.instance.debugOverridePermission = null;
    AppClock.setNow(null);
    await db.close();
  });

  /// 泵微任务直到条件成立（unawaited 异步链收敛；真实事件循环下有限轮询）
  Future<void> pumpUntil(bool Function() predicate,
      [int maxTurns = 50]) async {
    for (var i = 0; i < maxTurns; i++) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    fail('pumpUntil 超时：条件未在 $maxTurns 轮内成立');
  }

  Future<int> insertTask({required String title}) async {
    final list = await db.getDefaultList();
    return db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: title,
      createdAt: DateTime.now(),
    ));
  }

  test('开始：running + 满剩余 + 通知栏发出倒计时', () async {
    final c = container.read(pomodoroControllerProvider.notifier);
    c.start();
    expect(c.state.state, PomodoroState.running);
    expect(c.state.remainingSeconds, 25 * 60);
    expect(fake.countdownShows, isNotEmpty, reason: '开始即显示倒计时通知');
    expect(fake.countdownShows.last.running, isTrue);
    expect(fake.countdownShows.last.remainingSeconds, 25 * 60);
  });

  test('墙钟推进：tick 后剩余按真实经过时间减少（挂起纠偏）', () async {
    final t0 = DateTime(2026, 8, 20, 10, 0, 0);
    AppClock.setNow(t0);
    final c = container.read(pomodoroControllerProvider.notifier);
    c.start();
    AppClock.setNow(t0.add(const Duration(seconds: 90)));
    c.debugTick();
    expect(c.state.remainingSeconds, 25 * 60 - 90);
    // 挂起恢复后一次 tick 直接补上全部经过时间（不依赖每秒累积）
    AppClock.setNow(t0.add(const Duration(minutes: 3)));
    c.debugTick();
    expect(c.state.remainingSeconds, 25 * 60 - 3 * 60);
  });

  test('暂停：冻结剩余、通知变已暂停、tick 不再推进', () async {
    final t0 = DateTime(2026, 8, 20, 10, 0, 0);
    AppClock.setNow(t0);
    final c = container.read(pomodoroControllerProvider.notifier);
    c.start();
    AppClock.setNow(t0.add(const Duration(seconds: 30)));
    c.debugTick();
    final frozen = c.state.remainingSeconds;
    c.pause();
    expect(c.state.state, PomodoroState.paused);
    expect(c.state.remainingSeconds, frozen);
    expect(fake.countdownShows.last.running, isFalse,
        reason: '暂停态通知显示继续按钮');
    // 暂停后 tick 不推进剩余
    AppClock.setNow(t0.add(const Duration(seconds: 120)));
    c.debugTick();
    expect(c.state.remainingSeconds, frozen);
  });

  test('继续：从冻结值恢复计时', () async {
    final t0 = DateTime(2026, 8, 20, 10, 0, 0);
    AppClock.setNow(t0);
    final c = container.read(pomodoroControllerProvider.notifier);
    c.start();
    AppClock.setNow(t0.add(const Duration(seconds: 60)));
    c.debugTick();
    c.pause();
    final frozen = c.state.remainingSeconds;
    AppClock.setNow(t0.add(const Duration(seconds: 120)));
    c.resume();
    expect(c.state.state, PomodoroState.running);
    expect(c.state.remainingSeconds, frozen, reason: '继续从暂停冻结值起步');
    AppClock.setNow(t0.add(const Duration(seconds: 150)));
    c.debugTick();
    expect(c.state.remainingSeconds, frozen - 30);
  });

  test('重新开始：放弃进度从头计时', () async {
    final t0 = DateTime(2026, 8, 20, 10, 0, 0);
    AppClock.setNow(t0);
    final c = container.read(pomodoroControllerProvider.notifier);
    c.start();
    AppClock.setNow(t0.add(const Duration(minutes: 10)));
    c.debugTick();
    c.restart();
    expect(c.state.state, PomodoroState.running);
    expect(c.state.remainingSeconds, 25 * 60);
  });

  test('空闲态切换时长同步剩余；运行中不可改', () async {
    final c = container.read(pomodoroControllerProvider.notifier);
    c.setMinutes(45);
    expect(c.state.minutes, 45);
    expect(c.state.remainingSeconds, 45 * 60);
    c.start();
    c.setMinutes(15);
    expect(c.state.minutes, 45, reason: '运行中不可改时长');
  });

  test('关联任务设置：空闲态生效，运行中锁定', () async {
    final taskId = await insertTask(title: '写方案');
    final c = container.read(pomodoroControllerProvider.notifier);
    c.setTaskId(taskId);
    expect(c.state.taskId, taskId);
    c.start();
    c.setTaskId(null);
    expect(c.state.taskId, taskId, reason: '运行中不可改关联任务');
  });

  test('提前结束：记录实际时长、回空闲、清倒计时通知、发完成事件', () async {
    final t0 = DateTime(2026, 8, 20, 10, 0, 0);
    AppClock.setNow(t0);
    final c = container.read(pomodoroControllerProvider.notifier);
    PomodoroFinishResult? result;
    c.finished.listen((r) => result = r);
    c.start();
    AppClock.setNow(t0.add(const Duration(minutes: 5)));
    c.debugTick();
    await c.finish();
    await Future<void>.delayed(Duration.zero); // broadcast 流投递需一轮事件循环
    expect(c.state.state, PomodoroState.idle);
    expect(c.state.remainingSeconds, 25 * 60, reason: '空闲态恢复待开始显示');
    expect(result?.isSuccess, isTrue);
    expect(result?.minutes, 5);
    expect(fake.cancelled, contains(NotificationIds.forPomodoro),
        reason: '结束清理倒计时通知');
    final rows = await db.getPomodoros();
    expect(rows.single.durationMinutes, 5);
    expect(rows.single.taskId, isNull);
  });

  test('立即结束：记录 0 分钟（不把完整时长记进统计）', () async {
    AppClock.setNow(DateTime(2026, 8, 20, 10, 0, 0));
    final c = container.read(pomodoroControllerProvider.notifier);
    PomodoroFinishResult? result;
    c.finished.listen((r) => result = r);
    c.start();
    await c.finish();
    await Future<void>.delayed(Duration.zero); // broadcast 流投递需一轮事件循环
    expect(result?.minutes, 0);
    final rows = await db.getPomodoros();
    expect(rows.single.durationMinutes, 0);
  });

  test('计时归零自动结束：写满时长、清通知、后台弹完成通知', () async {
    final t0 = DateTime(2026, 8, 20, 10, 0, 0);
    AppClock.setNow(t0);
    final c = container.read(pomodoroControllerProvider.notifier);
    PomodoroFinishResult? result;
    c.finished.listen((r) => result = r);
    c.start();
    AppClock.setNow(t0.add(const Duration(minutes: 25)));
    c.debugTick(); // 触发 unawaited finish
    await pumpUntil(() => c.state.state == PomodoroState.idle);
    await pumpUntil(() => result != null);
    expect(result?.minutes, 25);
    expect(fake.cancelled, contains(NotificationIds.forPomodoro));
    // 测试环境无 resumed 生命周期 → 视为后台结束 → 弹完成通知
    expect(fake.finishedShows, contains(25));
    final rows = await db.getPomodoros();
    expect(rows.single.durationMinutes, 25);
  });

  test('关联任务被删除后结束：外键失败被捕获，不崩溃', () async {
    final taskId = await insertTask(title: '将被删除');
    await db.deleteTask(taskId);
    final c = container.read(pomodoroControllerProvider.notifier);
    c.setTaskId(taskId);
    c.start();
    PomodoroFinishResult? result;
    c.finished.listen((r) => result = r);
    await c.finish();
    await Future<void>.delayed(Duration.zero); // broadcast 流投递需一轮事件循环
    expect(result?.isSuccess, isFalse);
    expect(result?.error, isNotNull);
    expect(c.state.state, PomodoroState.idle);
  });

  test('通知动作分发：暂停/继续/结束', () async {
    final t0 = DateTime(2026, 8, 20, 10, 0, 0);
    AppClock.setNow(t0);
    final c = container.read(pomodoroControllerProvider.notifier);
    c.start();
    NotificationService.instance.debugSimulateAction(
      PomodoroController.actionPause,
    );
    await pumpUntil(() => c.state.state == PomodoroState.paused);
    expect(c.state.state, PomodoroState.paused, reason: '通知栏暂停生效');
    NotificationService.instance.debugSimulateAction(
      PomodoroController.actionResume,
    );
    await pumpUntil(() => c.state.state == PomodoroState.running);
    expect(c.state.state, PomodoroState.running, reason: '通知栏继续生效');
    AppClock.setNow(t0.add(const Duration(minutes: 3)));
    c.debugTick();
    NotificationService.instance.debugSimulateAction(
      PomodoroController.actionStop,
    );
    await pumpUntil(() => c.state.state == PomodoroState.idle);
    expect(c.state.state, PomodoroState.idle, reason: '通知栏结束生效');
    final rows = await db.getPomodoros();
    expect(rows.single.durationMinutes, 3);
  });

  test('通知权限被拒：计时照常运行，通知全部跳过', () async {
    NotificationService.instance.debugOverridePermission = false;
    await NotificationService.instance.refreshPermissionCache();
    final c = container.read(pomodoroControllerProvider.notifier);
    c.start();
    expect(c.state.state, PomodoroState.running, reason: '权限被拒不阻止计时');
    expect(fake.countdownShows, isEmpty, reason: '权限被拒不弹倒计时');
    await c.finish();
    expect(fake.finishedShows, isEmpty, reason: '权限被拒不弹完成通知');
    expect(c.state.state, PomodoroState.idle);
  });
}
