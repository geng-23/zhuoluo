import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/chinese_date_parser.dart';
import 'package:zhuoluo/features/task/providers.dart';

/// 偏好设置组（2026-08-08）：默认清单 / 默认提醒 / 全天提醒时刻 / 应用时区
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // AppClock.setTimezone 需要时区数据库（main 启动链亦会初始化）
  tzdata.initializeTimeZones();

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    // 每个用例后复位应用时区，避免跨用例污染
    AppClock.setTimezone(null);
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> settle(ProviderContainer container) async {
    final state = container.read(tasksControllerProvider);
    var guard = 0;
    while (state.loading && guard < 200) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      guard++;
    }
    // 等 addTask 尾部 _bump 触发的异步 _reloadTasks 跑完，
    // 避免容器 dispose 后监听器访问已释放的 StateNotifier
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  group('偏好设置默认值', () {
    test('未设置时全部回落默认', () async {
      final settings = SettingsController(db);
      expect(await settings.getDefaultListId(), isNull);
      expect(await settings.getDefaultRemindMinutes(), isNull);
      expect(await settings.getDefaultAllDayRemindAt(), 540,
          reason: '全天任务默认提醒时刻 = 09:00');
      expect(await settings.getAppTimezone(), isNull);
    });

    test('非法值回落默认', () async {
      final settings = SettingsController(db);
      await settings.set(SettingsController.keyDefaultAllDayRemindAt, '9999');
      expect(await settings.getDefaultAllDayRemindAt(), 540);
      await settings.set(SettingsController.keyDefaultRemindMinutes, 'abc');
      expect(await settings.getDefaultRemindMinutes(), isNull);
      await settings.set(SettingsController.keyDefaultListId, '-5');
      expect(await settings.getDefaultListId(), isNull);
    });
  });

  group('默认清单', () {
    test('设置后快建落入指定清单；清除后回落收件箱', () async {
      await db.ensureDefaultList();
      final settings = SettingsController(db);
      final def = await db.getDefaultList();
      final work = await db.insertList('工作', '#FF0000', 1);
      await settings.set(SettingsController.keyDefaultListId, '$work');
      expect(await settings.getDefaultListId(), work);

      final container = makeContainer();
      final notifier = container.read(tasksControllerProvider.notifier);
      final parsed = ChineseDateParser.instance.parse('明天下3点交报告');
      await notifier.addTaskFromParsed('交报告', parsed);
      await settle(container);

      final inWork = await db.getTasksByList(work);
      expect(inWork.map((t) => t.title), contains('交报告'),
          reason: '默认清单设置生效：任务落入指定清单');
      final inDef = await db.getTasksByList(def.id);
      expect(inDef.map((t) => t.title), isNot(contains('交报告')));

      // 清除设置 → 回落收件箱（默认清单）
      await settings.set(SettingsController.keyDefaultListId, '');
      expect(await settings.getDefaultListId(), isNull);
      final parsed2 = ChineseDateParser.instance.parse('明天晨跑');
      await notifier.addTaskFromParsed('晨跑', parsed2);
      await settle(container);
      final defTasks = await db.getTasksByList(def.id);
      expect(defTasks.map((t) => t.title), contains('晨跑'),
          reason: '清除默认清单设置后回落收件箱');
    });

    test('清单已删除时 getDefaultListId 回落 null', () async {
      await db.ensureDefaultList();
      final settings = SettingsController(db);
      final tmp = await db.insertList('临时', '#FF0000', 1);
      await settings.set(SettingsController.keyDefaultListId, '$tmp');
      await db.deleteList(tmp);
      expect(await settings.getDefaultListId(), isNull,
          reason: '清单删除后设置失效自动回落，不残留失效 id');
    });
  });

  group('默认提醒', () {
    test('设置/清除提前量', () async {
      final settings = SettingsController(db);
      await settings.set(SettingsController.keyDefaultRemindMinutes, '30');
      expect(await settings.getDefaultRemindMinutes(), 30);
      await settings.set(SettingsController.keyDefaultRemindMinutes, '');
      expect(await settings.getDefaultRemindMinutes(), isNull);
    });

    test('全天任务默认提醒时刻', () async {
      final settings = SettingsController(db);
      await settings.set(SettingsController.keyDefaultAllDayRemindAt, '600');
      expect(await settings.getDefaultAllDayRemindAt(), 600);
      await settings.set(SettingsController.keyDefaultAllDayRemindAt, '');
      expect(await settings.getDefaultAllDayRemindAt(), 540,
          reason: '空值回落 09:00');
    });
  });

  group('自动默认提醒（新建任务）', () {
    test('设置提前量后新建定时任务自动带默认提醒', () async {
      await db.ensureDefaultList();
      final settings = SettingsController(db);
      await settings.set(SettingsController.keyDefaultRemindMinutes, '30');

      final container = makeContainer();
      final notifier = container.read(tasksControllerProvider.notifier);
      final parsed = ChineseDateParser.instance.parse('明天3点开会');
      final id = (await notifier.addTaskFromParsed('开会', parsed))!;
      await settle(container);

      final reminders = await db.getReminders(id);
      expect(reminders, hasLength(1),
          reason: '设置默认提醒提前量后新建任务自动带一条提醒');
      expect(reminders.single.remindMinutesBefore, 30);
      final task = (await db.getTask(id))!;
      expect(task.hasReminder, isTrue);
    });

    test('全天任务自动带默认提醒时刻（可配置，无提前量）', () async {
      await db.ensureDefaultList();
      final settings = SettingsController(db);
      await settings.set(SettingsController.keyDefaultRemindMinutes, '10');
      await settings.set(SettingsController.keyDefaultAllDayRemindAt, '600');

      final container = makeContainer();
      final notifier = container.read(tasksControllerProvider.notifier);
      final parsed = ChineseDateParser.instance.parse('明天晨跑');
      final id = (await notifier.addTaskFromParsed('晨跑', parsed))!;
      await settle(container);

      final reminders = await db.getReminders(id);
      expect(reminders, hasLength(1));
      expect(reminders.single.remindMinutesBefore, 0,
          reason: '全天任务无"提前量"概念，remindMinutesBefore 恒为 0');
      expect(reminders.single.remindAtMinutes ?? -1, 600,
          reason: '全天任务自动提醒用偏好设置的全天提醒时刻');
    });

    test('未设置默认提醒时全天任务不自动添加', () async {
      await db.ensureDefaultList();
      // 未设置默认提醒提前量：即使全天时刻有默认值也不自动添加
      final container = makeContainer();
      final notifier = container.read(tasksControllerProvider.notifier);
      final parsed = ChineseDateParser.instance.parse('明天晨跑');
      final id = (await notifier.addTaskFromParsed('晨跑', parsed))!;
      await settle(container);

      expect(await db.getReminders(id), isEmpty,
          reason: '未开启默认提醒时全天任务不自动添加提醒');
    });

    test('未设置默认提醒时不自动添加', () async {
      await db.ensureDefaultList();
      final container = makeContainer();
      final notifier = container.read(tasksControllerProvider.notifier);
      final parsed = ChineseDateParser.instance.parse('明天3点开会');
      final id = (await notifier.addTaskFromParsed('开会', parsed))!;
      await settle(container);

      expect(await db.getReminders(id), isEmpty,
          reason: '未设置默认提醒提前量时行为不变（不自动添加）');
    });

    test('纯标题任务（无计划时间）不自动添加提醒', () async {
      await db.ensureDefaultList();
      final settings = SettingsController(db);
      await settings.set(SettingsController.keyDefaultRemindMinutes, '30');

      final container = makeContainer();
      final notifier = container.read(tasksControllerProvider.notifier);
      final parsed = ChineseDateParser.instance.parse('随便记一笔');
      final id = (await notifier.addTaskFromParsed('随便记一笔', parsed))!;
      await settle(container);

      expect(await db.getReminders(id), isEmpty,
          reason: '无计划时间的任务无法排提醒，不自动添加');
    });
  });

  group('AppClock 应用时区', () {
    test('未设置 = 跟随系统时区', () {
      expect(AppClock.timezoneName, isNull);
      final a = AppClock.now();
      final b = DateTime.now();
      expect(
        a.millisecondsSinceEpoch,
        closeTo(b.millisecondsSinceEpoch, 2000),
        reason: '绝对时刻与真实当前时刻一致',
      );
    });

    test('设置 Asia/Shanghai 后字段按北京时间解释', () {
      AppClock.setTimezone('Asia/Shanghai');
      expect(AppClock.timezoneName, 'Asia/Shanghai');
      final cn = AppClock.now();
      final shanghai = DateTime.now().toUtc().add(const Duration(hours: 8));
      expect(cn.year, shanghai.year);
      expect(cn.month, shanghai.month);
      expect(cn.day, shanghai.day);
      expect(cn.hour, shanghai.hour);
      expect(cn.minute, closeTo(shanghai.minute, 1));
      expect(
        cn.millisecondsSinceEpoch,
        closeTo(DateTime.now().millisecondsSinceEpoch, 2000),
        reason: '字段按时区解释，绝对时刻仍正确',
      );
    });

    test('非法时区名回落跟随系统', () {
      AppClock.setTimezone('Not/AZone');
      expect(AppClock.timezoneName, isNull);
      expect(
        AppClock.now().millisecondsSinceEpoch,
        closeTo(DateTime.now().millisecondsSinceEpoch, 2000),
      );
    });

    test('清除时区回落跟随系统', () {
      AppClock.setTimezone('Asia/Tokyo');
      expect(AppClock.timezoneName, 'Asia/Tokyo');
      AppClock.setTimezone(null);
      expect(AppClock.timezoneName, isNull);
      expect(
        AppClock.now().millisecondsSinceEpoch,
        closeTo(DateTime.now().millisecondsSinceEpoch, 2000),
      );
    });
  });
}
