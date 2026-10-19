# 着落（zhuoluo）

着落是一款本地优先的 Android 待办应用。任务数据保存在设备上，无需账号；需要异地备份时，可自行配置 WebDAV。

## 主要功能

- **任务与日历**：清单、子任务、四象限，以及月、周、日视图。
- **快速添加**：用中文输入日期、时间和重复规则，例如“明天下午三点交报告”“每周五开会”。
- **重复与提醒**：按规则管理每次任务，并使用 Android 系统提醒。
- **专注与习惯**：番茄钟、习惯打卡和统计。
- **备份**：本地自动备份、手动导入导出，以及可选的 WebDAV 备份。

项目使用 Flutter、Riverpod、Drift 和 SQLite，当前以 Android 为主平台。

## 数据与换机

在“我的 → 备份管理”中可以导出和导入数据。应用会保留最近 10 份本地自动备份；Android 系统云备份和设备间自动迁移已关闭。备份文件是**明文 JSON**，请妥善保存。

WebDAV 仅接受 **HTTPS** 地址。WebDAV 账号密码只保存在本机，不会写入备份；换机恢复后需重新填写。

此前 GitHub 发布的 APK 使用另一把签名密钥，不能直接覆盖安装当前版本。更换前请先从旧版导出备份，再卸载旧版、安装新版并导入数据。

## 开发与构建

需要 Flutter 3.44+、Dart 3.12+ 和 Android SDK。常用命令：

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64
```

## 许可

[MIT](LICENSE) · [项目主页](https://github.com/geng-23/zhuoluo) · 联系：confusion_geng@protonmail.com
