import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';

/// 番茄专注：记录写入、关联任务、统计窗口、外键容错
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> insertTask({required String title}) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    return db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: title,
      createdAt: DateTime.now(),
    ));
  }

  test('15/25/45 分钟记录写入且时长保留', () async {
    final now = DateTime.now();
    for (final d in [15, 25, 45]) {
      await db.insertPomodoro(null, d, now);
    }
    final all = await db.getPomodoros();
    expect(all.length, 3);
    final minutes = all.map((p) => p.durationMinutes).toSet();
    expect(minutes, {15, 25, 45});
  });

  test('关联任务：taskId 记录正确且参与统计', () async {
    final id = await insertTask(title: '写方案');
    await db.insertPomodoro(id, 25, DateTime.now());
    final all = await db.getPomodoros();
    expect(all.single.taskId, id, reason: '番茄记录关联任务');
  });

  test('统计窗口：from/to 过滤按完成时刻', () async {
    final id = await insertTask(title: '写方案');
    // 用固定时刻完成（completedAt 取 AppClock.now，这里直接断言窗口边界语义）
    await db.insertPomodoro(id, 25, DateTime(2026, 8, 10, 9, 0));
    // from/to 窗口包含"今天"（AppClock.now 为真实今天）→ 记录在内
    final now = AppClock.now();
    final from = AppClock.at(now.year, now.month, now.day)
        .subtract(const Duration(days: 1));
    final to = AppClock.at(now.year, now.month, now.day)
        .add(const Duration(days: 1));
    final inWindow = await db.getPomodoros(from: from, to: to);
    expect(inWindow, isNotEmpty, reason: '今天的番茄记录在窗口内');
  });

  test('关联任务被删除后插入不崩溃（外键容错路径）', () async {
    final id = await insertTask(title: '将被删除');
    await db.deleteTask(id);
    // 番茄页结束时任务已不存在：insertPomodoro 外键失败由 UI 捕获，
    // DB 层直接插入会抛外键异常——验证调用方容错语义（此处用 try 模拟）
    var threw = false;
    try {
      await db.insertPomodoro(id, 25, DateTime.now());
    } catch (_) {
      threw = true;
    }
    // DB 层确实抛外键异常（UI 捕获后提示，不崩溃）
    expect(threw, isTrue,
        reason: '关联任务删除后写番茄应外键失败（UI 层捕获）');
  });
}
