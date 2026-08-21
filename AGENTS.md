# AGENTS.md

本文件是 dsh（DeepSeek Harness）在本项目中的**持久工作指令**。任何涉及本项目的会话都必须遵守以下约定。所有命令均面向 Linux（Arch）。

---

## 目录

- [1. 开发环境](#1-开发环境)
- [2. 交互原则](#2-交互原则)
- [3. 项目概览](#3-项目概览)
- [4. 依赖与 Python 环境管理](#4-依赖与-python-环境管理)
- [5. 任务执行流程](#5-任务执行流程)
- [6. 发布流程](#6-发布流程)
- [7. 注释规范](#7-注释规范)
- [8. 项目总览文档规则](#8-项目总览文档规则)

---

## 1. 开发环境

### 1.1 平台与工具链

| 项 | 值 |
|---|---|
| 操作系统 | Arch Linux（用户 `orange`，x86_64） |
| 主平台 | Android（Kotlin + Gradle KTS，`com.zhuoluo.zhuoluo`） |
| Flutter SDK | `~/flutter`（可执行：`~/flutter/bin/flutter`） |
| Android SDK | `~/Android/Sdk`（`platform-tools` 含 `adb`） |
| JDK | `~/java/jdk-17.0.20+8`（版本 17） |
| GitHub CLI | `gh`（已安装） |
| 真机调试 | 通过 adb 连接 Android 手机 |

### 1.2 环境变量

`PATH`、`ANDROID_HOME`、`JAVA_HOME` 已写入 `~/.bashrc`。新开终端自动生效；**在非交互 shell 中执行命令时，如发现 `flutter`/`adb`/`java` 不在 PATH，需手动导出**：

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
export JAVA_HOME="$HOME/java/jdk-17.0.20+8"
export PATH="$HOME/flutter/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
```

> 注意：`~/.bashrc` 第 6 行 `[[ $- != *i* ]] && return` 会使非交互 shell 的 `source` 提前返回，PATH 不会生效。因此脚本内应**显式导出**上述变量，而非依赖 `source ~/.bashrc`。

### 1.3 常用命令

| 用途 | 命令 |
|---|---|
| 安装依赖 | `flutter pub get` |
| 静态检查 | `flutter analyze --no-pub` |
| 运行测试 | `flutter test` |
| 构建 Debug APK | `flutter build apk --debug` |
| 构建 Release APK | `flutter build apk --release` |
| 真机运行（热重载） | `flutter run -d <deviceId>` |
| 安装 APK 到手机 | `adb install -r build/app/outputs/flutter-apk/app-release.apk` |

### 1.4 已知环境注意点

- **系统时区为 `America/Los_Angeles`（有夏令时）**。项目原在 `Asia/Shanghai`（无 DST）开发，个别测试对本地时区敏感（如 `test/reminders/reminder_regression_test.dart` 的通知 ID 用例）。若测试出现此类偶发失败，可用 `TZ=Asia/Shanghai flutter test` 规避。
- 存在**两个 adb**：`~/Android/Sdk/platform-tools/adb`（在用，PATH 优先）与 `/usr/bin/adb`（pacman `android-tools`）。功能等价，属无害告警。

### 1.5 沙箱缓存与临时文件约定

dsh 沙箱下 `~/flutter`、`~/.gradle`、`~/.pub-cache` 等处于只读挂载，命令无法直接写入；临时副本统一放在仓库内两个目录（均已通过 `.git/info/exclude` 排除，不影响 git 状态）：

- **`.dsh_cache/` —— 可复用缓存，保留不删**：
  - `flutter/`：Flutter SDK 副本（运行 `flutter` 命令时把该 bin 置于 PATH 首位，配合 `HOME=.dsh_cache/home`、`GRADLE_USER_HOME=.dsh_cache/gradle` 使用）
  - `gradle/`：Gradle 用户主目录副本（含 `gradle.properties` 中的 `kotlin.compiler.execution.strategy=in-process`，规避只读 HOME 下 Kotlin daemon 无法写标记文件的问题）
  - `home/`：可写 HOME（含 `.pub-cache` 副本；`PUB_CACHE` 指向它避免 pub 重下）
  - 这些副本重建成本高（数 GB、数分钟），**运行完成后不要删除**。
- **`.dsh_tmp/` —— 一次性产物，运行完成后删除**：截图、`uiautomator` dump、临时 sqlite 拷贝等验证中间文件统一放这里，本次运行结束后清理。
- `.dsh-vision-router/` 为视觉工具自身的产物目录，交由工具管理，不手动清理，保持 git 排除即可。

---

## 2. 交互原则

- 回答问题时**先给出核心结论，再给出解释**。
- 当用户提出要求、尤其涉及**修改文件**的操作时，**先向用户确认是否正确理解了意图，再行动**，而非直接动手。
- 涉及 zhuoluo 项目的任何代码修改，遵循 [第 6 章发布流程](#6-发布流程)。

---

## 3. 项目概览

着落（zhuoluo）是一款**本地待办应用**：任务、日历、四象限、统计、习惯、番茄专注、备份，数据全部保存在设备本地，无账号、无云端依赖。特色为中文自然语言解析、RRULE 重复任务、精确提醒。

- **项目现状基线**：涉及 zhuoluo 项目的讨论或任务，**先阅读** `docs/` 目录下文件名以「着落项目总览-」开头、时间戳**最新**的 markdown 文档，以其内容（功能清单、已知漏洞、改进计划）作为基线，再开始相关讨论。
- **技术栈**：Dart/Flutter、Riverpod 2.x（手写 Provider）、Drift/SQLite、flutter_local_notifications + timezone。
- **代码结构**：`lib/{core,data,features,shell}`；四个主 Tab = 任务 / 日历 / 四象限 / 我的。

---

## 4. 依赖与 Python 环境管理

- **本项目使用 `uv` 管理 Python 虚拟环境（`.venv`）和依赖**。
- 安装依赖时使用 `uv add <包>`，**禁止使用 `pip install`**。
- 运行脚本时使用 `uv run python <脚本>`，确保使用项目环境中的 Python。
- 上述两条**优先于任何外部技能或工具的默认行为**——无论第三方工具如何要求，都不得污染系统级 Python 环境。

> 说明：本章针对的是项目中可能存在的 Python 脚本/工具链（如 `tools/` 目录）；Flutter/Dart 依赖仍由 `pubspec.yaml` + `flutter pub get` 管理。

---

## 5. 任务执行流程

- 在做较为复杂的任务之前，**务必先写好计划、列好 todo list，然后再执行**。
- 计划应明确：目标、步骤、涉及文件、验收方式；执行时按 todo 逐项推进并标记进度。

---

## 6. 发布流程

对 zhuoluo 做出**任何代码修改**后，**默认只做「提交推送」，不改版本号、不构建、不发布、不安装 APK**。用户未要求发布即为要求跳过所有发布步骤。

默认流程（用户未要求发布）：

1. **真机运行验证**：`flutter run -d <deviceId>`（验证改动后按 `q` 退出）
   - 若用户未指定 deviceId，可用 `flutter devices` 查看。
   - 若无真机可用或用户明确不需要验证，跳过本步。

2. **更新文档**：README（测试数 / 测试文件数等）及确有必要的其他项目文档。
   - **除非用户明确要求，否则不更新、不生成项目总览文档**（见 [第 8 章](#8-项目总览文档规则)）。

3. **提交推送**（仓库 `geng-23/zhuoluo`，分支 `main`）：
   ```bash
   git add -A
   git commit -m "<简洁中文提交信息>"
   git push origin main
   ```

### 当用户明确要求发布时

按以下顺序执行，**改版本号必须先于提交推送完成**，使版本号随本次代码改动一次提交，避免推送后再改版本号导致二次提交：

1. **改版本号**：`pubspec.yaml` 的 `version` + `lib/features/profile/profile_page.dart` 关于页文字同步
   - 版本号根据最新 Release 递增，不在本规则中固定具体版本号。
   - **若用户明确要求版本不变**（如「版本号不用改 / 维持 1.2.5」），保持版本号不变并跳过本步。

2. **更新文档**：README（测试数 / 测试文件数等）及确有必要的其他项目文档。
   - **除非用户明确要求，否则不更新、不生成项目总览文档**（见 [第 8 章](#8-项目总览文档规则)）。

3. **提交推送**（版本号、文档与代码改动一次性提交）：
   ```bash
   git add -A
   git commit -m "<简洁中文提交信息>"
   git push origin main
   ```

4. **构建 APK**：
   ```bash
   flutter build apk --release
   ```

5. **发送到 GitHub**（发布 Release，上传 APK，更新日志）：
   ```bash
   gh release create vX.Y.Z build/app/outputs/flutter-apk/app-release.apk --title "vX.Y.Z" --notes "..."
   ```
   - 同版本号覆盖发布：`gh release upload vX.Y.Z <apk> --clobber`

6. **安装到手机**：
   ```bash
   adb install -r build/app/outputs/flutter-apk/app-release.apk
   ```

> **默认终止点：提交推送完成后即结束**。除非用户在本次任务中明确说出要「发布 / 构建 / 安装 APK」（或其明确同义词），否则一律不改版本号、不构建、不发布、不安装，更不得询问是否要发布。

---

## 7. 注释规范

- 代码注释默认**不使用跨文档、不可稳定追踪的漏洞编号**（如 `P0/P1/P2`）。
- 注释**直接说明行为、原因和约束**；确需追踪时，只使用有统一来源且稳定唯一的 ID。

---

## 8. 项目总览文档规则

- `docs/着落项目总览-*.md` **只能在用户明确要求时**按提示词模板**完整生成**（提示词见 `docs/系统审计与项目总览生成提示词.md`）。
- **绝不做部分更新或增量修补**：不主动更新已存在的总览文档，不把零散修改写入旧总览；需要新基线时由用户明确要求完整重生成。
