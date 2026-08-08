/// 备份文件系统操作平台实现选择
/// - native（Android/iOS/桌面）：真实文件系统
/// - web：浏览器下载导出（无本地文件系统，列表/读取/删除不可用）
library;

export 'backup_platform_io.dart'
    if (dart.library.js_interop) 'backup_platform_web.dart';
