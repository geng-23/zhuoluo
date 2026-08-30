import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/services/pomodoro_native.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/theme/theme.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/shell/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  // runApp 前仅执行首屏必需且轻量的初始化：
  // 1. 通知初始化：时区数据 + 插件 + 渠道 + 冷启动深链捕获（HomeShell 同步消费）
  // 2. 番茄钟原生桥：注册原生→Dart 通道（冷启动即就绪，通知点击/动作可送达）
  // 3. 默认清单：首次查询触发 DB 惰性打开与迁移（任务页依赖默认清单存在）
  await container.read(notificationServiceProvider).init();
  container.read(pomodoroNativeProvider).init();
  await container.read(dbProvider).ensureDefaultList();
  // 轻量设置并行读取，runApp 前应用（主题/时区影响首帧渲染，音效/震动影响交互反馈）
  final settings = container.read(settingsProvider);
  final (savedTheme, appTimezone, soundEnabled, hapticsEnabled, savedColor) =
      await (
        container.read(dbProvider).getSetting('themeMode'),
        settings.getAppTimezone(),
        settings.getSoundEnabled(),
        settings.getHapticsEnabled(),
        container.read(dbProvider).getSetting('themeColor'),
      ).wait;
  if (savedTheme != null && savedTheme.isNotEmpty) {
    container.read(themeModeProvider.notifier).state = savedTheme;
  }
  if (savedColor != null && savedColor.isNotEmpty) {
    container.read(themeColorProvider.notifier).state = savedColor;
  }
  SoundService.soundsEnabled = soundEnabled;
  Haptics.hapticsEnabled = hapticsEnabled;
  // 时区数据已由 notificationService.init() 初始化；未设置 = 跟随系统。
  AppClock.setTimezone(appTimezone);
  runApp(
    UncontrolledProviderScope(container: container, child: const ZhuoluoApp()),
  );
  // runApp 之后异步执行（fire-and-forget），不阻塞首屏：
  // 存量锚点修复 → 通知权限请求 → 全量提醒重排，按依赖顺序串行；
  // 重排依赖权限结果（schedule 在权限未知时也会自动请求，顺序保证尽早弹窗）。
  // 任一步失败不阻塞后续与启动流程。
  unawaited(_runStartupBackground(container));
  // 每天首次打开自动备份（备份方案设计 3.2），不阻塞启动流程
  unawaited(container.read(backupServiceProvider).autoBackup());
  debugPrint('启动：已请求自动备份');
}

/// 启动后台任务链：锚点修复（数据正确性）→ 权限请求 → 全量重排（最重）。
/// 单步异常吞掉并记录，保证启动不崩溃、后续步骤继续。
Future<void> _runStartupBackground(ProviderContainer container) async {
  try {
    await container.read(dbProvider).fixOrphanRecurringAnchors();
  } catch (e) {
    debugPrint('启动后台：锚点修复失败 $e');
  }
  try {
    // 回收站超期条目自动清理（保留期来自偏好设置）
    final retention = await container
        .read(settingsProvider)
        .getTrashRetentionDays();
    await container.read(dbProvider).deleteTrashOlderThan(
      AppClock.now().subtract(Duration(days: retention)),
    );
  } catch (e) {
    debugPrint('启动后台：回收站清理失败 $e');
  }
  try {
    await container.read(notificationServiceProvider).requestPermission();
  } catch (e) {
    debugPrint('启动后台：通知权限请求失败 $e');
  }
  try {
    await container.read(reminderSchedulerProvider).rescheduleAll();
  } catch (e) {
    debugPrint('启动后台：全量提醒重排失败 $e');
  }
}

class ZhuoluoApp extends ConsumerWidget {
  const ZhuoluoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final themeColor = ThemePalette.fromHex(ref.watch(themeColorProvider));
    return MaterialApp(
      title: '着落',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(themeColor),
      darkTheme: AppTheme.dark(themeColor),
      // A7：主题切换过渡动画
      themeAnimationDuration: const Duration(milliseconds: 350),
      themeAnimationCurve: Curves.easeInOut,
      themeMode: switch (themeMode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      home: const HomeShell(),
    );
  }
}
