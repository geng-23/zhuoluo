import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'backup_types.dart';

/// 备份文件名（时间戳 + 随机后缀，防同秒覆盖，设计文档 3.1）
String _backupFileName() => backupFileName(DateTime.now());

/// 安卓备份通道（MainActivity 原生实现：MediaStore 写公共下载目录）
const _androidBackupChannel = MethodChannel('zhuoluo/notifications');

/// 方案 A：导出备份。
/// - Android：写公共下载目录（卸载不删，可恢复；file_selector 的
///   getSaveLocation 在 Android 无实现，此前导出必失败）
/// - iOS/桌面：系统保存对话框（用户选定位置）
/// 返回保存位置；用户取消（非 Android）返回 null。
Future<String?> exportToUserLocationImpl(String json) async {
  if (Platform.isAndroid) {
    try {
      final path = await _androidBackupChannel.invokeMethod<String>(
        'saveBackupToDownloads',
        {'json': json, 'name': _backupFileName()},
      );
      return path;
    } catch (e) {
      throw StateError('备份保存到下载目录失败：$e');
    }
  }
  const typeGroup = XTypeGroup(
    label: '着落备份',
    extensions: ['json'],
    mimeTypes: ['application/json'],
  );
  final location = await getSaveLocation(
    suggestedName: _backupFileName(),
    acceptedTypeGroups: const [typeGroup],
  );
  if (location == null) return null;
  await File(location.path).writeAsString(json);
  return location.path;
}

/// 方案 A：从系统打开对话框选择备份 JSON。
/// 返回文件内容；用户取消返回 null。
/// 注意：必须用 readAsBytes + utf8.decode，不能用 readAsString——
/// file_selector_android 返回 XFile.fromData(bytes)，而 cross_file 的
/// readAsString 对带 bytes 的 XFile 用 String.fromCharCodes（忽略编码），
/// 中文会变成乱码（实测：导入后"收件箱"变 æ\x94¶…）。
Future<String?> pickBackupFileImpl() async {
  const typeGroup = XTypeGroup(
    label: '着落备份',
    extensions: ['json'],
    mimeTypes: ['application/json'],
  );
  final file = await openFile(acceptedTypeGroups: const [typeGroup]);
  if (file == null) return null;
  return utf8.decode(await file.readAsBytes());
}

/// 获取导出目录：
/// - 下载目录（Android 10+ 的 MediaStore 映射 / iOS / 桌面）
/// - 不可用时回退应用文档目录
/// P1-C：此前硬编码 /storage/emulated/0/Download——Android 9 及以下
/// 无 WRITE_EXTERNAL_STORAGE 权限必失败，iOS/桌面会建在错误位置。
Future<Directory> _exportBase() async {
  final downloads = await getDownloadsDirectory();
  if (downloads != null) return downloads;
  return getApplicationDocumentsDirectory();
}

/// 导出备份 JSON 到文件（下载目录或应用文档目录），返回文件路径
Future<String> exportToFileImpl(
  String json, {
  required bool toDownloads,
}) async {
  final base = toDownloads
      ? await _exportBase()
      : await getApplicationDocumentsDirectory();
  await base.create(recursive: true);
  final name = backupFileName(DateTime.now());
  final file = File('${base.path}/$name');
  await file.writeAsString(json);
  return file.path;
}

/// 列出可恢复的备份文件（下载目录 + 应用文档目录，仅 zhuoluo_backup_ 前缀）
Future<List<String>> listBackupFilesImpl() async {
  final files = <String>[];
  for (final dir in await _backupDirs()) {
    try {
      if (!await dir.exists()) continue;
      await for (final f in dir.list()) {
        if (f is File &&
            f.path.endsWith('.json') &&
            f.path.split('/').last.startsWith('zhuoluo_backup_')) {
          files.add(f.path);
        }
      }
    } catch (_) {}
  }
  files.sort((a, b) => b.compareTo(a)); // 最新的在前
  return files;
}

/// 读取备份文件内容
Future<String> readFileImpl(String path) => File(path).readAsString();

/// 删除备份文件
Future<void> deleteBackupFilesImpl(List<String> paths) async {
  for (final p in paths) {
    try {
      final f = File(p);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
  }
}

/// 备份文件详情（路径 + 文件名 + 修改时间，仅 zhuoluo_backup_ 前缀）
Future<List<BackupFileInfo>> listBackupInfosImpl() async {
  final files = <BackupFileInfo>[];
  for (final dir in await _backupDirs()) {
    try {
      if (!await dir.exists()) continue;
      await for (final f in dir.list()) {
        if (f is File &&
            f.path.endsWith('.json') &&
            f.path.split('/').last.startsWith('zhuoluo_backup_')) {
          final stat = await f.stat();
          files.add(
            BackupFileInfo(
              path: f.path,
              name: f.path.split('/').last,
              modified: stat.modified,
              size: stat.size,
            ),
          );
        }
      }
    } catch (_) {}
  }
  files.sort((a, b) => b.modified.compareTo(a.modified));
  return files;
}

/// 自动备份是否可用（native：可写应用私有目录）
bool autoBackupSupportedImpl() => true;

/// 备份搜索目录（下载目录 + 应用文档目录 + Android 公共下载位置，失败静默跳过）
Future<List<Directory>> _backupDirs() async {
  final dirs = <Directory>[];
  if (Platform.isAndroid) {
    // 方案 A：MediaStore 导出位置（API29+ 为 Download/着落，
    // API≤28 为 Download 根目录）；自己导出的备份文件可直接读取
    dirs.add(Directory('/storage/emulated/0/Download/着落'));
    dirs.add(Directory('/storage/emulated/0/Download'));
  }
  final downloads = await getDownloadsDirectory();
  if (downloads != null && !dirs.contains(downloads)) dirs.add(downloads);
  dirs.add(await getApplicationDocumentsDirectory());
  return dirs;
}
