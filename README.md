# 着落

一款让事事有着落的本地待办应用：任务、日历、四象限，数据全部保存在设备上，无需账号。

## 功能

- **任务**：快速添加（支持中文时间解析，如"明天下3点交报告"）、智能清单（全部/今天/最近7天/已完成）、清单分组、拖拽排序、完成/撤销、删除可撤销
- **子任务**：父任务下添加子任务（仅在任务详情页展示），子任务全部完成后父任务自动完成
- **日历**：月/周/日视图、时间轴任务块（重叠自动分栏）、跨天/全天任务置顶、"今天"一键定位、红线标记当前时间
- **四象限**：重要紧急/重要不紧急/紧急不重要/一般，支持拖动归类
- **提醒**：任务到点本地通知（自定义内置提示音）
- **其他**：番茄专注、习惯打卡、统计、主题（亮/暗/跟随系统）、备份导出/恢复（JSON 文件）

## 技术栈

- Flutter（Material 3）
- Riverpod（状态管理）
- Drift（SQLite，本地数据库）
- flutter_local_notifications（本地通知）
- audioplayers（动作音效）

## 开发

```bash
# 安装依赖
flutter pub get

# 运行
flutter run

# 测试
flutter test

# 静态检查
flutter analyze

# 构建 release APK
flutter build apk --release
```

## 联系

confusion_geng@protonmail.com
