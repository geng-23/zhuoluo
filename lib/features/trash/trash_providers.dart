import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/data/database/database.dart';

/// 回收站条目列表（删除时间倒序），随 dataVersion 自动刷新。
/// 回收站操作（恢复/彻底删除/清空/超期清理）在 TasksController 内完成后
/// bump dataVersion，本 provider 随之重建。
final trashItemsProvider = FutureProvider<List<TrashItem>>((ref) async {
  ref.watch(dataVersionProvider);
  return ref.read(dbProvider).getTrashItems();
});

/// 回收站保留天数（偏好设置可调，默认 30）
final trashRetentionDaysProvider = FutureProvider<int>((ref) async {
  return ref.read(settingsProvider).getTrashRetentionDays();
});
