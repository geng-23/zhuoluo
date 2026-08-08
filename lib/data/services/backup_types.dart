import 'dart:math';

/// 备份文件信息（跨平台共享类型）
class BackupFileInfo {
  final String path;
  final String name;
  final DateTime modified;
  final int size;

  BackupFileInfo({
    required this.path,
    required this.name,
    required this.modified,
    required this.size,
  });
}
/// 备份内容统计（导入确认框与完成报告用）
class BackupStats {
  final int lists;
  final int tasks;
  final int reminders;
  final int completions;
  final int exceptions;
  final int habits;
  final int pomodoros;

  BackupStats({
    required this.lists,
    required this.tasks,
    required this.reminders,
    required this.completions,
    required this.exceptions,
    required this.habits,
    required this.pomodoros,
  });
}

/// 备份文件名时间戳（精确到秒）
String backupStamp(DateTime now) =>
    '${now.year}${now.month.toString().padLeft(2, '0')}'
    '${now.day.toString().padLeft(2, '0')}_'
    '${now.hour.toString().padLeft(2, '0')}'
    '${now.minute.toString().padLeft(2, '0')}'
    '${now.second.toString().padLeft(2, '0')}';

/// 备份文件名：时间戳 + 4 位随机小写字母数字（防同秒覆盖，设计文档 3.1）
String backupFileName(DateTime now) {
  final rand = Random();
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final suffix =
      List.generate(4, (_) => chars[rand.nextInt(chars.length)]).join();
  return 'zhuoluo_backup_${backupStamp(now)}_$suffix.json';
}
