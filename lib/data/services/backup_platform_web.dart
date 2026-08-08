import 'dart:convert';
import 'dart:js_interop';

import 'package:file_selector/file_selector.dart';
import 'package:web/web.dart' as web;

import 'backup_types.dart';

/// 方案 A（Web）：导出=浏览器下载 JSON（无本地文件系统）。
/// 返回下载文件名；无需用户选择位置。
Future<String?> exportToUserLocationImpl(String json) async {
  final name = backupFileName(DateTime.now());
  final blob = web.Blob(
    [json.toJS].toJS,
    web.BlobPropertyBag(type: 'application/json'),
  );
  final url = web.URL.createObjectURL(blob);
  try {
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = name
      ..style.display = 'none';
    web.document.body!.append(anchor);
    anchor.click();
    anchor.remove();
  } finally {
    web.URL.revokeObjectURL(url);
  }
  return name; // 虚拟路径：仅作下载文件名展示
}

/// 方案 A（Web）：从打开对话框选择备份 JSON（上传）。
/// 返回文件内容；用户取消返回 null。
Future<String?> pickBackupFileImpl() async {
  const typeGroup = XTypeGroup(
    label: '着落备份',
    extensions: ['json'],
    mimeTypes: ['application/json'],
  );
  final file = await openFile(acceptedTypeGroups: const [typeGroup]);
  if (file == null) return null;
  // 与 io 端一致：readAsBytes + utf8.decode（readAsString 对
  // 部分实现会按 code unit 解读字节导致中文乱码）
  return utf8.decode(await file.readAsBytes());
}

/// Web 端导出：触发浏览器下载 JSON 文件（无本地文件系统）
Future<String> exportToFileImpl(
  String json, {
  required bool toDownloads,
}) async {
  final name = backupFileName(DateTime.now());
  final blob = web.Blob(
    [json.toJS].toJS,
    web.BlobPropertyBag(type: 'application/json'),
  );
  final url = web.URL.createObjectURL(blob);
  try {
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = name
      ..style.display = 'none';
    web.document.body!.append(anchor);
    anchor.click();
    anchor.remove();
  } finally {
    web.URL.revokeObjectURL(url);
  }
  return name; // 虚拟路径：仅作下载文件名展示
}

/// Web 端：浏览器无本地备份文件列表
Future<List<String>> listBackupFilesImpl() async => const [];

/// Web 端：无法读取本地文件
Future<String> readFileImpl(String path) async =>
    throw UnsupportedError('浏览器环境无法读取本地备份文件');

/// Web 端：无需删除（下载导出不落盘）
Future<void> deleteBackupFilesImpl(List<String> paths) async {}

/// Web 端：浏览器无本地备份文件列表
Future<List<BackupFileInfo>> listBackupInfosImpl() async => const [];

/// 自动备份不可用（浏览器无本地文件系统，不触发无意义的下载）
bool autoBackupSupportedImpl() => false;
