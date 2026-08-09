import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/theme/theme.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/shell/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  await container.read(notificationServiceProvider).init();
  await container.read(dbProvider).ensureDefaultList();
  // 存量数据修复：重复任务锚点不匹配规则时自动吸附（旧版本创建的数据）
  await container.read(dbProvider).fixOrphanRecurringAnchors();
  // 启动时请求通知权限（Android 13+ 必须授予才显示通知）
  await container.read(notificationServiceProvider).requestPermission();
  // 全量重排提醒：App 重装/系统清理后已排的通知会丢失，启动时恢复
  await container.read(reminderSchedulerProvider).rescheduleAll();
  // 恢复主题设置（I1：#31 主题持久化）
  final savedTheme = await container.read(dbProvider).getSetting('themeMode');
  if (savedTheme != null && savedTheme.isNotEmpty) {
    container.read(themeModeProvider.notifier).state = savedTheme;
  }
  // 恢复音效/震动开关
  final settings = container.read(settingsProvider);
  SoundService.soundsEnabled = await settings.getSoundEnabled();
  Haptics.hapticsEnabled = await settings.getHapticsEnabled();
  // 恢复应用时区（偏好设置组：出差/旅行保持家乡时间）。
  // 时区数据已由 notificationService.init() 初始化；未设置 = 跟随系统。
  AppClock.setTimezone(await settings.getAppTimezone());
  runApp(
    UncontrolledProviderScope(container: container, child: const ZhuoluoApp()),
  );
  // 每天首次打开自动备份（备份方案设计 3.2）：
  // runApp 之后异步执行（fire-and-forget），不阻塞启动流程
  unawaited(container.read(backupServiceProvider).autoBackup());
}

class ZhuoluoApp extends ConsumerWidget {
  const ZhuoluoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: '着落',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
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
