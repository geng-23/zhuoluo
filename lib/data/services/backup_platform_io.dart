import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'backup_types.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';

/// 备份文件名（时间戳 + 随机后缀，防同秒覆盖，设计文档 3.1）
String _backupFileName() => backupFileName(AppClock.now());

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

/// 获取非 Android 平台的导出目录：
/// - 下载目录（iOS / 桌面）
/// - 不可用时回退应用文档目录
/// 此前硬编码 /storage/emulated/0/Download——Android 9 及以下
/// 无 WRITE_EXTERNAL_STORAGE 权限必失败，iOS/桌面会建在错误位置。
Future<Directory> _exportBase() async {
  final downloads = await getDownloadsDirectory();
  if (downloads != null) return downloads;
  return getApplicationDocumentsDirectory();
}

/// 导出备份 JSON 到文件，Android 下载目录通过 MediaStore 写入。
Future<String> exportToFileImpl(
  String json, {
  required bool toDownloads,
}) async {
  if (Platform.isAndroid && toDownloads) {
    return (await exportToUserLocationImpl(json))!;
  }
  final base = toDownloads
      ? await _exportBase()
      : await getApplicationDocumentsDirectory();
  await base.create(recursive: true);
  final name = backupFileName(AppClock.now());
  final file = File('${base.path}/$name');
  await file.writeAsString(json);
  return file.path;
}

/// 自动备份写入公共下载目录的独立子目录，避免卸载应用时一起删除。
Future<String> writeAutoBackupFileImpl(String json) async {
  if (!Platform.isAndroid) {
    return exportToFileImpl(json, toDownloads: false);
  }
  final path = await _androidBackupChannel.invokeMethod<String>(
    'saveAutoBackupToDownloads',
    {'json': json, 'name': _backupFileName()},
  );
  if (path == null) throw StateError('无法保存自动备份到下载目录');
  return path;
}

/// 旧版自动备份位于应用私有目录。启动时迁移，避免升级后卸载仍丢失旧文件。
Future<void> migrateLegacyAutoBackupsImpl() async {
  if (!Platform.isAndroid) return;
  final files = await _scanBackupDir(await getApplicationDocumentsDirectory());
  for (final info in files) {
    final json = await File(info.path).readAsString();
    final saved = await _androidBackupChannel.invokeMethod<String>(
      'saveAutoBackupToDownloads',
      {'json': json, 'name': info.name},
    );
    if (saved == null) throw StateError('旧备份迁移失败：${info.name}');
    await File(info.path).delete();
  }
}

/// 读取备份文件内容
Future<String> readFileImpl(String path) async {
  if (Platform.isAndroid && path.startsWith('content://')) {
    final json = await _androidBackupChannel.invokeMethod<String>(
      'readBackupUri',
      {'uri': path},
    );
    if (json == null) throw StateError('无法读取备份文件');
    return json;
  }
  return File(path).readAsString();
}

/// 删除备份文件
Future<void> deleteBackupFilesImpl(List<String> paths) async {
  for (final p in paths) {
    try {
      if (Platform.isAndroid && p.startsWith('content://')) {
        await _androidBackupChannel.invokeMethod<bool>('deleteBackupUri', {
          'uri': p,
        });
        continue;
      }
      final f = File(p);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
  }
}

/// 备份文件详情（路径/内容 URI + 文件名 + 修改时间）。
/// Android 下载目录通过 MediaStore 查询，同时包含旧版应用私有备份。
Future<List<BackupFileInfo>> listBackupInfosImpl() async {
  final files = <BackupFileInfo>[];
  if (Platform.isAndroid) {
    files.addAll(await _listAndroidBackups('listDownloadBackups'));
    files.addAll(
      await _scanBackupDir(await getApplicationDocumentsDirectory()),
    );
    files.sort((a, b) => b.modified.compareTo(a.modified));
    return files;
  }
  for (final dir in await _backupDirs()) {
    files.addAll(await _scanBackupDir(dir));
  }
  files.sort((a, b) => b.modified.compareTo(a.modified));
  return files;
}

/// 自动备份文件列表：只查询 Downloads/着落/自动备份。
///
/// 自动备份"保留最近 N 份"的清理必须以本列表为基准——若用全量视图
/// [listBackupInfosImpl] 计数，用户手动导出到下载目录的备份会被一并
/// 计入"第 N+1 份及更旧"而遭误删。
Future<List<BackupFileInfo>> listAutoBackupInfosImpl() async {
  final files = Platform.isAndroid
      ? await _listAndroidBackups('listAutoBackups')
      : await _scanBackupDir(await getApplicationDocumentsDirectory());
  files.sort((a, b) => b.modified.compareTo(a.modified));
  return files;
}

Future<List<BackupFileInfo>> _listAndroidBackups(String method) async {
  final rows = await _androidBackupChannel.invokeListMethod<Map>(method);
  return (rows ?? const <Map>[]).map((row) {
    return BackupFileInfo(
      path: row['path'] as String,
      name: row['name'] as String,
      modified: DateTime.fromMillisecondsSinceEpoch(row['modified'] as int),
      size: row['size'] as int,
    );
  }).toList();
}

/// 扫描单个目录下的备份文件（zhuoluo_backup_ 前缀 + .json），目录不存在
/// 或无权限时返回空列表（静默跳过，不中断其余目录的扫描）
Future<List<BackupFileInfo>> _scanBackupDir(Directory dir) async {
  final files = <BackupFileInfo>[];
  try {
    if (!await dir.exists()) return files;
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
  return files;
}

/// 自动备份是否可用（native）
bool autoBackupSupportedImpl() => true;

/// 非 Android 平台的备份搜索目录。
Future<List<Directory>> _backupDirs() async {
  final dirs = <Directory>[];
  final downloads = await getDownloadsDirectory();
  if (downloads != null && !dirs.contains(downloads)) dirs.add(downloads);
  dirs.add(await getApplicationDocumentsDirectory());
  return dirs;
}
