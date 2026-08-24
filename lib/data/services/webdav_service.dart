import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/services/backup_types.dart';

/// WebDAV 连接配置（凭据保存在本机 settings 表，不随备份文件导出）
class WebdavConfig {
  const WebdavConfig({
    required this.url,
    required this.username,
    required this.password,
    this.dir = WebdavService.defaultDir,
    this.enabled = true,
  });

  /// 服务器地址（含路径根），如 https://host/dav —— 允许带/不带末尾斜杠
  final String url;
  final String username;
  final String password;

  /// 远端备份目录（相对服务器路径根），支持多级如「备份/zhuoluo」
  final String dir;

  /// 是否参与每日自动上传（手动「立即上传」不受此开关限制）
  final bool enabled;

  /// 配置是否足以发起连接（enabled 不参与判断——手动上传只看前三项）
  bool get connectable =>
      url.trim().isNotEmpty &&
      username.trim().isNotEmpty &&
      password.isNotEmpty &&
      dir.trim().isNotEmpty;
}

/// 云端备份条目（名称/修改时间/大小）
class WebdavBackupInfo {
  const WebdavBackupInfo({
    required this.name,
    required this.modified,
    required this.size,
  });

  final String name;
  final DateTime modified;
  final int size;
}

/// 语义化异常：message 为可直接展示给用户的中文文案
class WebdavException implements Exception {
  const WebdavException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 极简 WebDAV 客户端：仅需 MKCOL/PUT/GET/PROPFIND/DELETE + Basic Auth，
/// 自行实现以免引入 dio 等重依赖；http.Client 可注入供测试替身。
///
/// 目录请求统一带末尾斜杠（部分服务器对集合路径要求严格）；
/// PROPFIND 应答按元素 local-name 解析，兼容 D:/d:/无前缀等命名空间写法。
class WebdavService {
  WebdavService({http.Client? client, this.quickTimeout, this.transferTimeout})
    : _client = client ?? http.Client();

  /// 远端默认目录名
  static const defaultDir = 'zhuoluo';

  /// 备份文件名前缀/后缀（与本地备份一致，云端与本地同格式互认）
  static const fileNamePrefix = 'zhuoluo_backup_';
  static const fileNameSuffix = '.json';

  final http.Client _client;

  /// 控制类请求（PROPFIND/MKCOL/DELETE）超时
  final Duration? quickTimeout;

  /// 传输类请求（PUT/GET）超时
  final Duration? transferTimeout;

  Duration get _quick => quickTimeout ?? const Duration(seconds: 20);
  Duration get _transfer => transferTimeout ?? const Duration(seconds: 60);

  /// 测试连接：对目标目录做 Depth:0 PROPFIND；
  /// 404 视为「地址正确但目录未建」——自动逐级建目录后复测一次。
  Future<void> testConnection(WebdavConfig c) async {
    final r = await _propfind(c, depth: '0');
    if (r.statusCode == 404) {
      await ensureRemoteDir(c);
      final retry = await _propfind(c, depth: '0');
      return _ensureOk(retry, '连接测试');
    }
    _ensureOk(r, '连接测试');
  }

  /// 上传一份备份（JSON 文本），返回生成的云端文件名。
  /// 先确保目录存在再 PUT，避免新目录首次上传因父目录缺失而 409。
  Future<String> upload(WebdavConfig c, String json) async {
    final name = backupFileName(AppClock.now());
    await ensureRemoteDir(c);
    final r = await _send(
      c,
      'PUT',
      buildUri(c, name),
      body: json,
      contentType: 'application/json;charset=utf-8',
      timeout: _transfer,
    );
    _ensureOk(r, '上传备份');
    return name;
  }

  /// 列出云端备份（按修改时间降序）。目录不存在视为空列表
  /// （首次使用尚未建目录是正常状态，不算错误）。
  Future<List<WebdavBackupInfo>> list(WebdavConfig c) async {
    final r = await _propfind(c, depth: '1');
    if (r.statusCode == 404) return const [];
    _ensureOk(r, '获取云端列表');
    return _parseMultistatus(r.body);
  }

  /// 下载一份云端备份内容（UTF-8 文本）
  Future<String> download(WebdavConfig c, String name) async {
    _validateFileName(name);
    final r = await _send(c, 'GET', buildUri(c, name), timeout: _transfer);
    _ensureOk(r, '下载备份');
    return utf8.decode(r.bodyBytes);
  }

  /// 删除若干云端备份；目标已不存在（404）视为删除成功
  Future<void> delete(WebdavConfig c, List<String> names) async {
    for (final name in names) {
      _validateFileName(name);
      final r = await _send(c, 'DELETE', buildUri(c, name), timeout: _quick);
      if (r.statusCode == 404) continue;
      _ensureOk(r, '删除云端备份');
    }
  }

  /// 逐级创建远端目录（含服务器路径中的子路径与用户目录多级段）；
  /// 405 Already Exists 视为成功。
  Future<void> ensureRemoteDir(WebdavConfig c) async {
    final base = _parseBase(c);
    final segments = [
      ...base.pathSegments.where((s) => s.isNotEmpty),
      ..._dirSegments(c),
    ];
    for (var i = 1; i <= segments.length; i++) {
      final uri = base
          .replace(pathSegments: [...segments.sublist(0, i), ''])
          ;
      final r = await _send(c, 'MKCOL', uri, timeout: _quick);
      final ok = r.statusCode >= 200 && r.statusCode < 300 ||
          r.statusCode == 405;
      if (!ok) _ensureOk(r, '创建云端目录');
    }
  }

  // ---------- 内部实现 ----------

  Uri _parseBase(WebdavConfig c) {
    final raw = c.url.trim();
    final base = Uri.tryParse(raw);
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      throw const WebdavException('服务器地址需以 http:// 或 https:// 开头');
    }
    if (base == null || !base.hasScheme || base.host.isEmpty) {
      throw const WebdavException('服务器地址格式不正确');
    }
    return base;
  }

  List<String> _dirSegments(WebdavConfig c) => [
    for (final s in c.dir.split('/'))
      if (s.trim().isNotEmpty) s.trim(),
  ];

  /// 拼接最终请求地址：服务器根路径 + 用户目录 + 可选文件名，
  /// 各段独立编码（目录/文件名可含中文与空格）
  Uri buildUri(WebdavConfig c, [String? fileName]) {
    final base = _parseBase(c);
    final segments = [
      ...base.pathSegments.where((s) => s.isNotEmpty),
      ..._dirSegments(c),
      // null-aware 元素：fileName 为 null 时跳过该段
      ?fileName,
    ];
    // 目录请求补末尾斜杠（空段），文件请求不带
    if (fileName == null) segments.add('');
    return base.replace(pathSegments: segments);
  }

  Future<http.Response> _propfind(WebdavConfig c, {required String depth}) =>
      _send(
        c,
        'PROPFIND',
        buildUri(c),
        body: '<?xml version="1.0" encoding="utf-8"?>'
            '<d:propfind xmlns:d="DAV:"><d:prop>'
            '<d:displayname/><d:getcontentlength/>'
            '<d:getlastmodified/><d:resourcetype/>'
            '</d:prop></d:propfind>',
        extraHeaders: {'Depth': depth},
        timeout: _quick,
      );

  Future<http.Response> _send(
    WebdavConfig c,
    String method,
    Uri uri, {
    String? body,
    String? contentType,
    Map<String, String>? extraHeaders,
    required Duration timeout,
  }) async {
    try {
      final token = base64Encode(utf8.encode('${c.username}:${c.password}'));
      final request = http.Request(method, uri)
        ..headers['Authorization'] = 'Basic $token'
        ..headers.addAll(extraHeaders ?? const {});
      if (body != null) {
        request.headers['Content-Type'] =
            contentType ?? 'application/xml;charset=utf-8';
        request.body = body;
      }
      final streamed = await _client.send(request).timeout(timeout);
      return await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw const WebdavException('连接超时，请检查网络后重试');
    } catch (e) {
      throw WebdavException('无法连接服务器，请检查网络与服务器地址（$e）');
    }
  }

  void _ensureOk(http.Response r, String action) {
    final code = r.statusCode;
    if (code >= 200 && code < 300) return;
    switch (code) {
      case 401:
        throw const WebdavException(
          '账号、密码或授权方式不正确'
          '（部分服务要求使用应用专用密码而非登录密码）',
        );
      case 403:
        throw const WebdavException('服务器拒绝访问：该账号可能没有此目录的读写权限');
      case 507:
        throw const WebdavException('云端存储空间不足');
    }
    if (code >= 500) {
      throw WebdavException('服务器错误（HTTP $code），请稍后重试');
    }
    throw WebdavException('$action失败（HTTP $code）');
  }

  void _validateFileName(String name) {
    final valid = name.startsWith(fileNamePrefix) &&
        name.endsWith(fileNameSuffix) &&
        !name.contains('/') &&
        !name.contains('\\') &&
        !name.contains('..');
    if (!valid) {
      throw const WebdavException('非法的云端备份文件名');
    }
  }

  /// 解析 PROPFIND multistatus 应答：取每个 response 的 href/长度/修改时间，
  /// 跳过目录（resourcetype 含 collection）与非本应用命名的条目。
  List<WebdavBackupInfo> _parseMultistatus(String body) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(body);
    } catch (_) {
      throw const WebdavException('云端返回了无法识别的数据格式');
    }
    final result = <WebdavBackupInfo>[];
    for (final resp in doc.findAllElements('response', namespaceUri: '*')) {
      if (resp.findAllElements('collection', namespaceUri: '*').isNotEmpty) continue;
      final hrefEl = resp.findAllElements('href', namespaceUri: '*').toList();
      if (hrefEl.isEmpty) continue;
      final href = hrefEl.first.innerText;
      final segments = Uri.tryParse(href)?.pathSegments ??
          href.split('/').where((s) => s.isNotEmpty);
      if (segments.isEmpty) continue;
      final name = Uri.decodeComponent(segments.last);
      if (!name.startsWith(fileNamePrefix) ||
          !name.endsWith(fileNameSuffix)) {
        continue;
      }
      result.add(
        WebdavBackupInfo(
          name: name,
          modified: _parseHttpDate(
            resp.findAllElements('getlastmodified', namespaceUri: '*').isEmpty
                ? ''
                : resp.findAllElements('getlastmodified', namespaceUri: '*').first.innerText,
          ),
          size: int.tryParse(
                resp.findAllElements('getcontentlength', namespaceUri: '*').isEmpty
                    ? ''
                    : resp.findAllElements('getcontentlength', namespaceUri: '*').first.innerText,
              ) ??
              0,
        ),
      );
    }
    result.sort((a, b) => b.modified.compareTo(a.modified));
    return result;
  }

  /// RFC1123 格式（Tue, 18 Aug 2026 02:25:15 GMT）；解析失败回退当前时刻，
  /// 仅影响列表排序展示，不阻断流程
  DateTime _parseHttpDate(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return AppClock.now();
    try {
      return HttpDate.parse(t);
    } catch (_) {
      return DateTime.tryParse(t) ?? AppClock.now();
    }
  }
}
