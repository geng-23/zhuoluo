import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// 本地通知服务（flutter_local_notifications v22 封装）
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();

  final _tapController = StreamController<String?>.broadcast();

  bool _initialized = false;

  /// P1-C：通知权限结果缓存（启动/设置页请求一次；
  /// 调度时不再重复请求，被拒后不再弹窗轰炸）
  bool? _permissionGranted;

  /// P0-10：冷启动深链——进程被杀后点击通知启动 App 时，
  /// payload 不经过 onDidReceiveNotificationResponse 回调（此时无人订阅），
  /// 需在 init 时通过 getNotificationAppLaunchDetails 主动捕获，供订阅前消费。
  String? _launchPayload;

  /// 系统级能力通道（MainActivity 原生实现）：
  /// 通知设置跳转 / 电池优化豁免查询与请求
  static const _systemChannel = MethodChannel('zhuoluo/notifications');

  /// 通知是否已开启（Android 13+ 通知权限）
  Future<bool> areNotificationsEnabled() async {
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      return await android?.areNotificationsEnabled() ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 打开系统"应用通知设置"页（Android）
  Future<void> openNotificationSettings() async {
    try {
      await _systemChannel
          .invokeMethod<void>('openNotificationSettings')
          // 测试环境无原生通道，Future 永不完成——超时兜底避免挂起
          .timeout(const Duration(seconds: 2), onTimeout: () {});
    } catch (_) {}
  }

  /// 是否已豁免电池优化（系统日历级准时提醒的前置条件）
  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final r = await _systemChannel
          .invokeMethod<bool>('isIgnoringBatteryOptimizations')
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 请求豁免电池优化（跳系统设置页）
  Future<void> requestBatteryOptimizationExemption() async {
    try {
      await _systemChannel
          .invokeMethod<void>('requestBatteryOptimizationExemption')
          .timeout(const Duration(seconds: 2), onTimeout: () {});
    } catch (_) {}
  }

  /// 发送测试通知（1 秒后弹出，验证通知链路是否正常）。
  /// 返回 false 表示未成功排入系统（权限被拒等）。
  Future<bool> sendTestNotification() async {
    return schedule(
      NotificationIds.forTest,
      title: '通知测试',
      body: '通知正常工作：即使应用未运行，也会按时提醒',
      when: DateTime.now().add(const Duration(seconds: 1)),
      payload: null,
    );
  }

  /// 初始化（含显式创建通知 channel，避免首次调度时才创建的不确定性）
  Future<void> init() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    // P1-C：使用设备本地时区（此前硬编码 Asia/Shanghai，非中国时区用户
    // 通知时刻全部偏移；"回退本地时区"分支实为不可达死代码）
    tz.setLocalLocation(tz.local);
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );
    await _plugin.initialize(
      settings: settings,
      // 点击通知 → 打开 App 定位任务
      onDidReceiveNotificationResponse: (response) {
        _tapController.add(response.payload);
      },
    );
    // 显式创建 channel（幂等；importance/声音在首次创建时生效）
    // N1-C：渠道显式指定系统默认通知音 URI（content://settings/system/notification_sound）。
    // 小米 MIUI 对未显式指定声音的渠道按"无声音"处理（通知不响铃），
    // 原生 Android 则回退默认音——因此必须显式设置。
    // 渠道 ID 升级 v4/v3 强制新渠道（旧渠道声音已固化，无法修改）
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    // 清理旧的无声音渠道（上一版创建的），避免残留
    try {
      await android?.deleteNotificationChannel(channelId: 'task_reminder_v3');
      await android?.deleteNotificationChannel(channelId: 'habit_reminder_v2');
    } catch (_) {}
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'task_reminder_v4',
        '任务提醒',
        description: '任务到点提醒',
        importance: Importance.high,
        sound: UriAndroidNotificationSound(
          'content://settings/system/notification_sound',
        ),
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'habit_reminder_v3',
        '习惯提醒',
        description: '习惯打卡每日提醒',
        importance: Importance.high,
        sound: UriAndroidNotificationSound(
          'content://settings/system/notification_sound',
        ),
      ),
    );
    // N1-C：小米 MIUI 渠道默认"锁屏不显示通知"（渠道 lockscreenVisibility 未设置时
    // UI 显示为不显示，锁屏既不弹也不响）。flutter_local_notifications 渠道 API
    // 不支持设置锁屏可见性，通过原生通道将渠道 lockscreenVisibility 更新为 PUBLIC。
    try {
      await _systemChannel
          .invokeMethod<void>('setLockscreenVisibility', {
            'channels': ['task_reminder_v4', 'habit_reminder_v3'],
          })
          .timeout(const Duration(seconds: 2), onTimeout: () {});
    } catch (_) {}
    // P0-10：捕获冷启动通知 payload（进程被杀后点通知启动 App 的深链）。
    // 测试环境无原生宿主时默认返回 didNotificationLaunchApp=false，安全。
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp == true) {
        _launchPayload = details?.notificationResponse?.payload;
        debugPrint('通知：捕获启动深链 payload=$_launchPayload');
      }
    } catch (e) {
      debugPrint('通知：读取启动详情失败 $e');
    }
    _initialized = true;
  }

  /// 取出并清空冷启动深链 payload（HomeShell 订阅前调用一次）。
  /// 返回 null 表示非通知启动或无 payload。
  String? consumeLaunchPayload() {
    final p = _launchPayload;
    _launchPayload = null;
    return p;
  }

  Stream<String?> get tapStream => _tapController.stream;

  /// 请求通知权限（Android 13+；Web = 浏览器通知权限）。
  /// 结果缓存（P1-C）：后续 schedule() 直接读缓存，不再重复请求。
  Future<bool> requestPermission() async {
    final granted = await _fetchPermission();
    _permissionGranted = granted;
    return granted;
  }

  /// N-P1-1：权限缓存失效通道——用户在系统设置授予/拒绝通知权限后调用，
  /// 否则调度器会一直按旧的 `_permissionGranted` 短路（提醒全部静默跳过）。
  Future<bool> refreshPermissionCache() async {
    try {
      final granted = await _fetchPermission();
      _permissionGranted = granted;
      return granted;
    } catch (e) {
      // 策略性吞掉（与 areNotificationsEnabled 一致）：平台不可用
      // （测试环境无宿主）时保持原缓存，不破坏权限中心流程
      debugPrint('通知：权限缓存刷新失败 $e');
      return _permissionGranted ?? true;
    }
  }

  Future<bool> _fetchPermission() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final granted = await android?.requestNotificationsPermission();
    return granted ?? true;
  }

  /// 精确闹钟权限（Android 12+/小米等厂商默认拒绝；未授予时精确调度会失败）
  Future<bool> canScheduleExactAlarms() async {
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      return await android?.canScheduleExactNotifications() ?? true;
    } catch (_) {
      // 平台不可用（测试环境/桌面）视为可调度
      return true;
    }
  }

  /// 跳转系统"闹钟与提醒"权限设置页
  Future<void> requestExactAlarmPermission() async {
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.requestExactAlarmsPermission();
    } catch (_) {
      // 平台不可用时静默
    }
  }

  /// 调度通知。返回 false 表示未调度（时间已过/无权限），供调用方提示用户
  /// [payload] 深链载荷：'t{taskId}' 定位任务 / 'h{habitId}' 打开习惯页
  Future<bool> schedule(
    int id, {
    required String title,
    required String body,
    required DateTime when,
    // 可空：测试通知不带深链
    String? payload,
  }) async {
    if (!_initialized) await init();
    // Android 13+：确保通知权限已授予；未授予则不调度
    // P1-C：只在状态未知时请求一次（被拒后不再重复弹窗）
    if (_permissionGranted == false) {
      debugPrint('通知：权限被拒，跳过 $id');
      return false;
    }
    if (_permissionGranted == null) {
      final granted = await requestPermission();
      if (!granted) {
        debugPrint('通知：权限未授予，跳过 $id');
        return false;
      }
    }
    if (when.isBefore(DateTime.now())) {
      debugPrint('通知：时间已过（$when），跳过 $id');
      return false;
    }
    final tzWhen = tz.TZDateTime.from(when, tz.local);
    // 精确闹钟失败（如厂商默认拒绝 SCHEDULE_EXACT_ALARM）时降级为 inexact，
    // 保证通知仍能触发（时间可能延迟）
    try {
      await _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: tzWhen,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'task_reminder_v4',
            '任务提醒',
            channelDescription: '任务到点提醒',
            visibility: NotificationVisibility.public,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: payload,
      );
      debugPrint('通知：已调度 $id @ $tzWhen');
    } catch (e) {
      debugPrint('通知：精确调度失败 $id（$e），降级 inexact');
      try {
        await _plugin.zonedSchedule(
          id: id,
          title: title,
          body: body,
          scheduledDate: tzWhen,
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'task_reminder_v4',
              '任务提醒',
              channelDescription: '任务到点提醒',
              visibility: NotificationVisibility.public,
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          payload: payload,
        );
        debugPrint('通知：已降级调度 $id @ $tzWhen');
      } catch (e2) {
        debugPrint('通知：降级调度也失败 $id: $e2');
        return false;
      }
    }
    return true;
  }

  /// 调度每日固定时刻重复通知（习惯提醒用）
  Future<bool> scheduleDaily(
    int id, {
    required String title,
    required String body,
    required DateTime time,
    required String payload,
  }) async {
    if (!_initialized) await init();
    // P1-C：权限状态未知时请求一次（与 schedule 一致，不重复弹窗）
    if (_permissionGranted == false) {
      debugPrint('通知：权限被拒，跳过习惯提醒 $id');
      return false;
    }
    if (_permissionGranted == null) {
      final granted = await requestPermission();
      if (!granted) {
        debugPrint('通知：权限未授予，跳过习惯提醒 $id');
        return false;
      }
    }
    // 若时间已过，顺延到明天，保证下一次立刻生效
    var next = time;
    if (next.isBefore(DateTime.now())) {
      next = next.add(const Duration(days: 1));
    }
    final tzWhen = tz.TZDateTime.from(next, tz.local);
    try {
      await _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: tzWhen,
        matchDateTimeComponents: DateTimeComponents.time,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'habit_reminder_v3',
            '习惯提醒',
            channelDescription: '习惯打卡每日提醒',
            visibility: NotificationVisibility.public,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: payload,
      );
      debugPrint('通知：已调度习惯提醒 $id @ $tzWhen');
    } catch (e) {
      debugPrint('通知：习惯提醒精确调度失败（$e），降级 inexact');
      try {
        await _plugin.zonedSchedule(
          id: id,
          title: title,
          body: body,
          scheduledDate: tzWhen,
          matchDateTimeComponents: DateTimeComponents.time,
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'habit_reminder_v3',
              '习惯提醒',
              channelDescription: '习惯打卡每日提醒',
              visibility: NotificationVisibility.public,
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          payload: payload,
        );
        debugPrint('通知：习惯提醒已降级调度 $id @ $tzWhen');
      } catch (e2) {
        debugPrint('通知：习惯提醒降级调度也失败 $id: $e2');
        return false;
      }
    }
    return true;
  }

  /// 取消通知（失败静默：业务不依赖）
  Future<void> cancel(int id) async {
    try {
      await _plugin.cancel(id: id);
    } catch (e) {
      debugPrint('通知取消失败 $id: $e');
    }
  }

  /// 取消全部（失败静默）
  Future<void> cancelAll() async {
    try {
      await _plugin.cancelAll();
    } catch (e) {
      debugPrint('通知全部取消失败: $e');
    }
  }
}

/// 通知 ID 分配
/// 提醒 ID 含实例日期维度：同一 (task, reminder) 在不同实例上的通知互不覆盖，
/// 否则重复任务 93 天内的各实例会因同 ID 互相替换（只剩最后一个）。
///
/// P0-6：旧公式 taskId*1e6 + dayIndex*100 + reminderId 在两条提醒
/// reminderId 相差 100 时跨实例碰撞（N*100+r1 == (N-1)*100+(r1+100)），
/// reminderId≥100 时直接跨入次日槽位。新公式改为：
///   taskId*200000（任务段）+ dayIndex*64（实例日槽）+ reminderId（提醒序号）
/// 同任务提醒数 < 64 时，同任务跨实例、同实例多条提醒均互不冲突；
/// taskId ≤ 10000 时任务段互不侵入，且最高值 ≈2.0015e9 远低于习惯段
/// 2.1e9（P2-11 隔离带天然成立）。
class NotificationIds {
  static final DateTime _epoch = DateTime(2024, 1, 1);

  /// 每任务最多同时存在的提醒条数（每实例槽位宽）。实际每任务 0-5 条。
  static const int _reminderSlots = 64;

  /// 任务段宽：dayIndex*64 最大贡献 200000 内（约 3125 天，2032 年前安全）
  /// 即 taskId 段互不侵入；排期窗口实际仅 93 天，远期改期仍远小于该值。
  static const int _taskSegmentWidth = 200000;

  /// 提醒通知 ID：taskId*200000 + 实例日距 2024-01-01 天数*64 + reminderId
  /// 实例日必须传入当天 00:00（与排期/取消使用同一天数基准）。
  /// 约束：reminderId ∈ [0, 63]；taskId ≤ 10000（超出段位则可能跨段侵入）。
  static int forReminder(int taskId, int reminderId, DateTime instanceDate) {
    assert(
      reminderId < _reminderSlots,
      '提醒 ID 段位溢出：reminderId=$reminderId ≥ $_reminderSlots，'
      '同一任务提醒过多将导致通知 ID 碰撞',
    );
    final dayIndex = instanceDate.difference(_epoch).inDays;
    return taskId * _taskSegmentWidth + dayIndex * _reminderSlots + reminderId;
  }

  /// 习惯提醒 ID（独立区段，置于任务 ID 空间之上，互不干扰）
  static int forHabit(int habitId) => 2100000000 - habitId;

  /// 通知测试 ID（独立区段，int32 上限附近，不与任务/习惯冲突；
  /// 旧值 2099999990 恰与第 10 个习惯提醒 ID 相同——P0-7）
  static int get forTest => 2147483646;
}
