import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/data/services/webdav_service.dart';

/// WebDAV 客户端单元测试：MockClient 模拟服务器，
/// 覆盖连接测试/上传/列表解析（含命名空间变体）/下载/删除/异常映射。
void main() {
  const config = WebdavConfig(
    url: 'https://dav.example.com/dav/',
    username: 'user',
    password: 'pass',
    dir: 'zhuoluo',
  );

  /// 带命名空间前缀的 PROPFIND 应答样例
  final prefixedMultistatus = '''
<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/zhuoluo/</D:href>
    <D:propstat><D:prop>
      <D:resourcetype><D:collection/></D:resourcetype>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/zhuoluo/zhuoluo_backup_20260824_101010_ab12.json</D:href>
    <D:propstat><D:prop>
      <D:getcontentlength>1234</D:getcontentlength>
      <D:getlastmodified>Tue, 18 Aug 2026 02:25:15 GMT</D:getlastmodified>
      <D:resourcetype/>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/zhuoluo/other_tool_file.txt</D:href>
    <D:propstat><D:prop><D:resourcetype/></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>
''';

  /// 无前缀（默认命名空间）的应答样例——同一语义的另一种服务器写法
  final plainMultistatus = prefixedMultistatus
      .replaceAll('D:', '')
      .replaceAll('<multistatus xmlns="DAV:">', '<multistatus>');

  http.Response xml(String body, [int status = 207]) => http.Response(
        body,
        status,
        headers: {'content-type': 'application/xml;charset=utf-8'},
      );

  group('testConnection', () {
    test('目录存在：Depth:0 PROPFIND 返回 207 即成功', () async {
      final methods = <String>[];
      final svc = WebdavService(
        client: MockClient((req) async {
          methods.add(req.method);
          expect(req.headers['Authorization'], startsWith('Basic '));
          return xml(prefixedMultistatus);
        }),
      );
      await svc.testConnection(config);
      expect(methods, ['PROPFIND']);
    });

    test('404 自动逐级建目录后复测成功', () async {
      final calls = <String>[];
      var propfindCount = 0;
      final svc = WebdavService(
        client: MockClient((req) async {
          calls.add('${req.method} ${req.url.path}');
          if (req.method == 'MKCOL') return http.Response('', 201);
          propfindCount++;
          // 首次目录不存在，建目录后复测返回成功
          return propfindCount == 1
              ? http.Response('', 404)
              : xml(prefixedMultistatus);
        }),
      );
      await svc.testConnection(config);
      expect(calls.first, startsWith('PROPFIND'));
      expect(calls.where((c) => c.startsWith('MKCOL')), isNotEmpty,
          reason: '404 后必须先创建目录');
      expect(calls.last, startsWith('PROPFIND'), reason: '建目录后应复测');
    });

    test('凭据错误：401 映射为应用专用密码提示', () async {
      final svc = WebdavService(
        client: MockClient((_) async => http.Response('', 401)),
      );
      await expectLater(
        svc.testConnection(config),
        throwsA(
          isA<WebdavException>().having(
            (e) => e.message,
            'message',
            contains('应用专用密码'),
          ),
        ),
      );
    });

    test('地址缺 scheme：直接给出格式提示，不发请求', () async {
      var requested = false;
      final svc = WebdavService(
        client: MockClient((_) async {
          requested = true;
          return http.Response('', 207);
        }),
      );
      await expectLater(
        svc.testConnection(
          const WebdavConfig(
              url: 'dav.example.com/dav', username: 'u', password: 'p'),
        ),
        throwsA(isA<WebdavException>()),
      );
      expect(requested, isFalse);
    });
  });

  group('upload', () {
    test('先 MKCOL 确保目录再 PUT；文件名符合本地备份命名', () async {
      final calls = <String>[];
      String? putBody;
      final svc = WebdavService(
        client: MockClient((req) async {
          calls.add(req.method);
          if (req.method == 'PUT') {
            putBody = utf8.decode(req.bodyBytes);
            return http.Response('', 201);
          }
          return http.Response('', 201); // MKCOL
        }),
      );
      final name = await svc.upload(config, '{"hello":"world"}');
      expect(
        RegExp(r'^zhuoluo_backup_\d{8}_\d{6}_[a-z0-9]{4}\.json$').hasMatch(name),
        isTrue,
      );
      expect(putBody, '{"hello":"world"}');
      expect(calls.indexOf('MKCOL'), lessThan(calls.indexOf('PUT')),
          reason: '必须先确保目录存在再 PUT（防新目录首次上传 409）');
    });

    test('中文目录与无末尾斜杠地址正确编码拼接', () async {
      Uri? captured;
      final svc = WebdavService(
        client: MockClient((req) async {
          if (req.method == 'PUT') captured = req.url;
          return http.Response('', 201);
        }),
      );
      await svc.upload(
        const WebdavConfig(
          url: 'https://host.cn/dav',
          username: 'u',
          password: 'p',
          dir: '着落/备份',
        ),
        '{}',
      );
      expect(captured!.pathSegments.take(3), ['dav', '着落', '备份'],
          reason: '路径段解码后应等于原始目录名');
      expect(captured!.path.endsWith('/'), isFalse,
          reason: '文件请求不应带末尾斜杠');
    });

    test('目录请求带末尾斜杠', () {
      final svc = WebdavService(
          client: MockClient((_) async => http.Response('', 207)));
      final uri = svc.buildUri(config);
      expect(uri.path, endsWith('/'));
    });

    test('云端空间不足：507 语义化提示', () async {
      final svc = WebdavService(
        client: MockClient((req) async => req.method == 'MKCOL'
            ? http.Response('', 201)
            : http.Response('', 507)),
      );
      await expectLater(
        svc.upload(config, '{}'),
        throwsA(isA<WebdavException>()
            .having((e) => e.message, 'message', contains('存储空间不足'))),
      );
    });
  });

  group('list', () {
    test('解析 D: 前缀应答：过滤目录与外部文件，按时间降序', () async {
      final svc = WebdavService(
        client: MockClient((req) async {
          expect(req.method, 'PROPFIND');
          expect(req.headers['Depth'], '1');
          return xml(prefixedMultistatus);
        }),
      );
      final items = await svc.list(config);
      expect(items, hasLength(1));
      expect(items.single.name, 'zhuoluo_backup_20260824_101010_ab12.json');
      expect(items.single.size, 1234);
      expect(items.single.modified.year, 2026);
      expect(items.single.modified.month, 8);
    });

    test('解析无前缀（默认命名空间）应答', () async {
      final svc = WebdavService(
        client: MockClient((_) async => xml(plainMultistatus)),
      );
      final items = await svc.list(config);
      expect(items, hasLength(1));
      expect(items.single.name, 'zhuoluo_backup_20260824_101010_ab12.json');
    });

    test('目录不存在（404）：视为空列表而非错误', () async {
      final svc = WebdavService(
        client: MockClient((_) async => http.Response('', 404)),
      );
      expect(await svc.list(config), isEmpty);
    });

    test('非 XML 应答：给出可读错误', () async {
      final svc = WebdavService(
        client: MockClient((_) async => http.Response('<internal error', 207)),
      );
      await expectLater(
        svc.list(config),
        throwsA(isA<WebdavException>()
            .having((e) => e.message, 'message', contains('无法识别'))),
      );
    });
  });

  group('download / delete', () {
    test('下载返回 UTF-8 文本', () async {
      final svc = WebdavService(
        client: MockClient((req) async {
          expect(req.method, 'GET');
          expect(req.url.pathSegments.last, 'zhuoluo_backup_a.json');
          return http.Response.bytes(utf8.encode('{"version":1}'), 200);
        }),
      );
      expect(
          await svc.download(config, 'zhuoluo_backup_a.json'), '{"version":1}');
    });

    test('删除 204 成功、404 视为已删', () async {
      final deleted = <String>[];
      final svc = WebdavService(
        client: MockClient((req) async {
          deleted.add(req.url.pathSegments.last);
          return deleted.length == 1
              ? http.Response('', 204)
              : http.Response('', 404);
        }),
      );
      await svc.delete(config, [
        'zhuoluo_backup_a.json',
        'zhuoluo_backup_b.json',
      ]);
      expect(deleted, hasLength(2));
    });

    test('拒绝越权路径的文件名', () async {
      final svc = WebdavService(
          client: MockClient((_) async => http.Response('', 204)));
      for (final bad in [
        '../evil.json',
        'other/file.json',
        r'..\evil.json',
        'random.txt',
        '',
      ]) {
        await expectLater(
          svc.delete(config, [bad]),
          throwsA(isA<WebdavException>()),
          reason: '文件名 $bad 应被白名单校验拦截',
        );
      }
    });
  });

  group('异常映射', () {
    test('网络不可达', () async {
      final svc = WebdavService(
        client: MockClient(
          (_) async => throw http.ClientException('connection closed'),
        ),
      );
      await expectLater(
        svc.testConnection(config),
        throwsA(isA<WebdavException>()
            .having((e) => e.message, 'message', contains('无法连接服务器'))),
      );
    });

    test('超时给出明确提示', () async {
      final svc = WebdavService(
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return http.Response('', 207);
        }),
        quickTimeout: const Duration(milliseconds: 30),
      );
      await expectLater(
        svc.testConnection(config),
        throwsA(isA<WebdavException>()
            .having((e) => e.message, 'message', contains('超时'))),
      );
    });

    test('服务器错误（5xx）', () async {
      final svc = WebdavService(
        client: MockClient((_) async => http.Response('', 502)),
      );
      await expectLater(
        svc.testConnection(config),
        throwsA(isA<WebdavException>()
            .having((e) => e.message, 'message', contains('502'))),
      );
    });
  });
}
