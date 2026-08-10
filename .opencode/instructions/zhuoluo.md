# 着落（zhuoluo）修改提交流程

> 本文件为 opencode 持久记忆（通过 opencode.jsonc 的 `instructions` 自动加载），
> 不占用 AGENTS.md。任何会话涉及 zhuoluo 修改时必须遵守以下流程。

## 注释规范

- 代码注释默认不使用跨文档、不可稳定追踪的漏洞编号（如 `P0/P1/P2`）。
- 注释直接说明行为、原因和约束；确需追踪时，只使用有统一来源且稳定唯一的 ID。

## 项目总览文档规则

- `docs/着落项目总览-*.md` **只能在用户明确要求时按提示词模板完整生成**（提示词见 `docs/系统审计与项目总览生成提示词.md`）。
- **绝不做部分更新或增量修补**：不主动更新已存在的总览文档，不把零散修改写入旧总览；需要新基线时由用户明确要求完整重生成。

## 必须遵守的完整发布流程

对 zhuoluo 做出**任何代码修改**后，按以下顺序执行（用户明确要求跳过某步时除外）：

1. **改版本号**：`pubspec.yaml` 的 `version` + `lib/features/profile/profile_page.dart` 关于页文字同步
   - 版本号根据最新 Release 递增，不在本规则中固定具体版本号
   - **若用户明确要求版本不变**（如"版本号不用改 / 维持 1.1.6"），保持版本号不变并跳过本步，后续走第 5 步的"覆盖发布"
2. **更新文档**：README（测试数/测试文件数等）及确有必要的其他项目文档
   - **除非用户明确要求，否则不更新、不生成项目总览文档**（见上方「项目总览文档规则」）
3. **提交推送**（仓库 `geng-23/zhuoluo`，分支 `main`）：
   ```
   git add -A
   git commit -m "<简洁中文提交信息>"
   git push origin main
   ```
4. **构建 APK**：`& "C:\src\flutter\bin\flutter.bat" build apk --release`
5. **发送到 GitHub**（发布 Release，上传 APK，更新日志）：
   ```
   gh release create vX.Y.Z build\app\outputs\flutter-apk\app-release.apk --title "vX.Y.Z" --notes "..."
   ```
   （若同版本号覆盖发布：`gh release upload vX.Y.Z <apk> --clobber`）
6. **安装到手机**：`& "C:\src\android-sdk\platform-tools\adb.exe" install -r build\app\outputs\flutter-apk\app-release.apk`

## 环境备忘

- 构建 APK：`& "C:\src\flutter\bin\flutter.bat" build apk --release`
- `gh` CLI 路径：`C:\Program Files\GitHub CLI\gh.exe`；当前 shell 的 PATH 不含它，
  调用前需 `$env:Path = "C:\Program Files\GitHub CLI;" + $env:Path`
- 测试：`& "C:\src\flutter\bin\flutter.bat" test`；静态检查：`& "C:\src\flutter\bin\flutter.bat" analyze --no-pub`
- adb：`C:\src\android-sdk\platform-tools\adb.exe`（不在 PATH）
