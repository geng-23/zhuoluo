import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhuoluo/data/services/webdav_service.dart';

/// WebDAV 服务替身：拦截上传/列表/删除，记录调用供断言。
/// 客户端注入 MockClient（任何意外真实请求直接失败），生产代码零触碰网络。
class FakeWebdavService extends WebdavService {
  FakeWebdavService() : super(client: _neverClient());

  static http.Client _neverClient() => MockClient(
        (_) async => throw StateError('替身不应发出真实请求'),
      );

  int uploadCalls = 0;
  final List<String> uploadedJson = [];

  /// upload 抛出的异常（null = 成功）
  Object? uploadError;

  /// testConnection 抛出的异常（null = 成功）
  Object? testConnectionError;

  int testConnectionCalls = 0;

  /// 最近一次连接测试收到的配置（断言表单值直传）
  WebdavConfig? lastTestedConfig;

  /// list 返回的远端内容（测试预置）
  List<WebdavBackupInfo> remoteSeed = [];

  int listCalls = 0;
  int deleteCalls = 0;

  /// delete 收到的文件名（按调用顺序累计）
  final List<String> deletedNames = [];

  @override
  Future<void> testConnection(WebdavConfig c) async {
    testConnectionCalls++;
    lastTestedConfig = c;
    if (testConnectionError != null) {
      throw testConnectionError!;
    }
  }

  @override
  Future<String> upload(WebdavConfig c, String json) async {
    uploadCalls++;
    uploadedJson.add(json);
    if (uploadError != null) {
      throw uploadError!;
    }
    return 'zhuoluo_backup_fake.json';
  }

  @override
  Future<List<WebdavBackupInfo>> list(WebdavConfig c) async {
    listCalls++;
    return List.of(remoteSeed);
  }

  @override
  Future<void> delete(WebdavConfig c, List<String> names) async {
    deleteCalls++;
    deletedNames.addAll(names);
  }
}
