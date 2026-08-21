import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/data/services/notification_service.dart';

import '../support/fake_notification_scheduler.dart';

/// 提醒通知渠道默认设置与状态查询：
/// - 任务/习惯提醒渠道 ID 常量稳定（渠道属性在系统侧创建后固化，
///   变更属性须换新渠道 ID，因此常量既是契约也是回归护栏）
/// - schedule 渠道路由（任务默认渠道 / 习惯独立渠道）
/// - 原生渠道状态查询的解码与优雅降级（无原生宿主不抛异常）
/// - 渠道默认再断言（applyReminderChannelDefaults）的通道调用
void main() {
  // mock 原生通道需要 TestDefaultBinaryMessengerBinding
  TestWidgetsFlutterBinding.ensureInitialized();

  group('提醒通知渠道默认设置', () {
    test('任务/习惯提醒渠道 ID 常量稳定（v4/v3）', () {
      expect(NotificationService.reminderChannelId, 'task_reminder_v4');
      expect(NotificationService.habitReminderChannelId, 'habit_reminder_v3');
    });

    test('schedule 默认走任务提醒渠道；习惯提醒显式走独立渠道', () async {
      final fake = FakeNotificationScheduler();
      NotificationService.instance.debugOverrideScheduler = fake;
      addTearDown(() {
        NotificationService.instance.debugOverrideScheduler = null;
      });
      final when = DateTime(2026, 8, 20, 12);
      await NotificationService.instance.schedule(
        1,
        title: 't',
        body: 'b',
        when: when,
      );
      await NotificationService.instance.schedule(
        2,
        title: 'h',
        body: 'b',
        when: when,
        channel: NotificationService.habitReminderChannelId,
      );
      expect(fake.scheduled, hasLength(2));
      expect(fake.scheduled[0].channel, NotificationService.reminderChannelId);
      expect(
        fake.scheduled[1].channel,
        NotificationService.habitReminderChannelId,
      );
    });

    test('ReminderChannelStatus.allOn 语义：三项全开且渠道存在才算全开', () {
      const allOn = ReminderChannelStatus(
        exists: true,
        soundEnabled: true,
        vibrationEnabled: true,
        floatingEnabled: true,
      );
      expect(allOn.allOn, isTrue);
      const noSound = ReminderChannelStatus(
        exists: true,
        soundEnabled: false,
        vibrationEnabled: true,
        floatingEnabled: true,
      );
      expect(noSound.allOn, isFalse);
      const noChannel = ReminderChannelStatus(
        exists: false,
        soundEnabled: true,
        vibrationEnabled: true,
        floatingEnabled: true,
      );
      expect(noChannel.allOn, isFalse);
    });
  });

  group('渠道状态查询（原生通道）', () {
    const channel = MethodChannel('zhuoluo/notifications');

    void mockNative(Future<Object?> Function(MethodCall) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
    }

    test('解码原生返回：声音/悬浮/振动全开 → allOn', () async {
      mockNative((call) async {
        if (call.method == 'getReminderChannelSettings') {
          return <String, Object?>{
            'exists': true,
            'soundEnabled': true,
            'vibrationEnabled': true,
            'importance': 4,
          };
        }
        return null;
      });
      final status = await NotificationService.instance.getReminderChannelStatus(
        NotificationService.reminderChannelId,
      );
      expect(status, isNotNull);
      expect(status!.exists, isTrue);
      expect(status.soundEnabled, isTrue);
      expect(status.vibrationEnabled, isTrue);
      expect(status.floatingEnabled, isTrue);
      expect(status.allOn, isTrue);
    });

    test('解码原生返回：部分未开启（无声/低重要性 → 悬浮不可用）', () async {
      mockNative((call) async {
        if (call.method == 'getReminderChannelSettings') {
          return <String, Object?>{
            'exists': true,
            'soundEnabled': false,
            'vibrationEnabled': true,
            'importance': 2, // < IMPORTANCE_HIGH(4) → 悬浮不可用
          };
        }
        return null;
      });
      final status = await NotificationService.instance.getReminderChannelStatus(
        NotificationService.reminderChannelId,
      );
      expect(status, isNotNull);
      expect(status!.soundEnabled, isFalse);
      expect(status.floatingEnabled, isFalse);
      expect(status.allOn, isFalse);
    });

    test('渠道不存在 → exists=false（Android 8.0 以下无渠道机制）', () async {
      mockNative((call) async {
        if (call.method == 'getReminderChannelSettings') {
          return <String, Object?>{'exists': false};
        }
        return null;
      });
      final status = await NotificationService.instance.getReminderChannelStatus(
        NotificationService.reminderChannelId,
      );
      expect(status, isNotNull);
      expect(status!.exists, isFalse);
      expect(status.allOn, isFalse);
    });

    test('无原生宿主（未 mock）时优雅降级返回 null，不抛异常', () async {
      final status = await NotificationService.instance.getReminderChannelStatus(
        NotificationService.reminderChannelId,
      );
      expect(status, isNull);
    });

    test('applyReminderChannelDefaults 走原生通道（任务/习惯两渠道）', () async {
      final calls = <MethodCall>[];
      mockNative((call) async {
        calls.add(call);
        return null;
      });
      await NotificationService.instance.applyReminderChannelDefaults();
      expect(calls.map((c) => c.method), contains('applyReminderChannelDefaults'));
      final channels = calls
          .firstWhere((c) => c.method == 'applyReminderChannelDefaults')
          .arguments as Map;
      expect(
        channels['channels'],
        [NotificationService.reminderChannelId, NotificationService.habitReminderChannelId],
      );
    });

    test('无原生宿主时 applyReminderChannelDefaults 不抛异常', () async {
      // 未 mock 原生通道：MissingPluginException 被服务内捕获
      await NotificationService.instance.applyReminderChannelDefaults();
      expect(true, isTrue, reason: '调用未抛异常即通过');
    });
  });
}
