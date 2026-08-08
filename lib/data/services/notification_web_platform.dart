/// Web 浏览器通知桥平台选择
/// - native：无浏览器通知，全部空实现
/// - web：基于浏览器 Notification API + 内存 Timer 调度
library;

export 'notification_web_io.dart'
    if (dart.library.js_interop) 'notification_web_web.dart';
