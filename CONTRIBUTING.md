# 参与贡献

感谢你愿意改进本项目。本文说明如何提出改动、评审的门槛，以及本项目因需长期适配
上游变动 API 而形成的若干约定。

---

## 行为准则

参与即表示你同意遵守[行为准则](CODE_OF_CONDUCT.md)。
如遇不当行为，请通过私有 issue 或仓库主页所列联系方式联系维护者。

## 开始之前

- **先搜索已有 issue 与讨论。** 关于连接本地引擎、网络接入、导出格式等常见问题，
  多数已有解答。
- **较大改动请先开 issue。** 若你打算重构 provider、修改数据模型或重做对话输入区，
  请先开 issue 说明思路。方向达成一致后再写代码，成本远低于返工。
- **缺陷报告需要复现步骤。** 见缺陷报告模板。

## 开发环境

前置条件：

| 依赖 | 说明 |
|---|---|
| Flutter stable | 项目目标 Dart SDK `^3.13.5`，CI 跑在 `stable` 上 |
| Android SDK 36 | 目前仅支持 Android |
| JDK 21 | 与 `app/android/` 的 Gradle 配置一致 |
| Python 3.10+ | 仅 `server-bridge/mock/` 的 mock 服务需要 |

跑起 App：

```bash
git clone https://github.com/Archer0083/Strata-Mobile-Controller.git
cd Strata-Mobile-Controller
cd app
flutter pub get
flutter run
```

### mock 服务

做 UI 开发**不需要**真实引擎。仓库内附带一个实现了相同端点的 mock：

```bash
python server-bridge/mock/mock_strata.py
```

然后把连接配置指向 `http://<你的局域网 IP>:8080`。mock 覆盖对话补全（含 SSE）、
模型列表、指标、加载/卸载生命周期。见
[server-bridge/mock/README.md](server-bridge/mock/README.md)。

## 质量门槛

每个 PR 在提交前必须在本地通过以下两条命令：

```bash
cd app
flutter analyze --no-pub   # 必须输出 "No issues found!"
flutter test --no-pub      # 必须输出 "All tests passed!"
```

CI 在每次 push 与 PR 上跑的就是这两条命令。请不要带着已知的分析器警告或失败测试
提交 PR——一次红灯的 CI 是给评审者最没用的东西。

请为改动新增或更新测试。测试按功能域组织在 `app/test/` 下，回归测试以引发它的
版本命名，例如 `app/test/v0009_ia_rearrange_test.dart`。

## 提交信息

用常规格式的简短祈使句摘要：

```text
<type>(<scope>): <summary>
```

- `type`：`feat` / `fix` / `docs` / `test` / `refactor` / `chore` / `perf` / `build`
- `scope`：功能域，如 `chat` / `monitor` / `control` / `import` / `export` / `ui`
- `summary`：小写开头，句末不加句点，72 字符以内

示例：

```text
feat(export): include attached images in the JSON export payload
```

一个提交只做一件事。请不要把重构和行为变更混在同一次提交里——那会让评审困难得多。

## Pull Request 检查清单

- [ ] `flutter analyze --no-pub` → 无 issue
- [ ] `flutter test --no-pub` → 全部通过
- [ ] 为改动新增或更新了测试
- [ ] 同步更新了已失效的文档（README、用户手册或 `docs/ui-design-spec.md`）
- [ ] 变更已记入 `CHANGELOG.md` 的对应版本条目
- [ ] 不含包含个人数据、真实 API Key、真实私钥或真实 IP 的截图与日志
- [ ] 未提交模型权重、上游源码副本或构建产物

### 关于变更记录

本项目的公开文档以 `CHANGELOG.md` 与 `docs/` 为准。行为或外观的改动请在同一个 PR
内更新对应文档——包括 `docs/ui-design-spec.md`（若涉及布局、间距、配色或措辞）与
`docs/用户手册.md`（若涉及用户可见的操作流程）。

## 改动 UI 时

`docs/ui-design-spec.md` 是布局、间距、配色 token 与措辞的准绳。若你的改动影响了其中
任何一项，请在同一个 PR 里更新它。该文档第 5.1 节也定义了本项目遵循的措辞规范
（含涉及上游项目时的表述方式）——在新增任何面向用户的、提到上游项目的文案之前，
请先读它。

## 面对会变动的上游 API

本客户端通过 HTTP API 与 Strata 引擎通信。该 API 可能在上游版本之间变化，且并非每个
版本都暴露全部端点。当你调用新端点时：

- **优雅降级。** 若用户所用引擎版本缺少该端点，功能应明确告知并保持其余部分可用
  ——参见「已安装模型」列表在 `/models/installed` 缺失时的降级行为。
- **不要假定用户跑的是新版本。** 以你声称支持的最旧版本为准，并在 README 中写明该版本。
- **把线格式处理收敛在 `app/lib/services/strata_client.dart`**，并为其补线格式测试。
  上游的 SSE 流有若干与 OpenAI 规范不同的特性（例如最后一个 chunk 的 `choices` 数组
  仍可能非空），在这上面回归很容易发生。

## 代码风格

- 采用 `dart format` 产出的 Dart 风格；行宽控制在 80 字符以内。
- 优先使用 `const` widget 与 `final` 局部变量。
- 状态管理用 Riverpod；provider 放在 `app/lib/providers/`。
- 未经讨论不要新增第三方依赖——每个依赖都会打进 APK，影响体积与许可审查。

## 报告安全问题

请不要为漏洞开公开 issue。请遵循 [SECURITY.md](SECURITY.md)。

## 许可

参与贡献即表示你的贡献以 MIT 许可授权，与本项目其余部分条款相同。见
[LICENSE](LICENSE)。

第三方组件保留各自许可；`app/assets/fonts/` 下内置的字体以 SIL Open Font Licence 1.1
授权，署名见 [NOTICE](NOTICE)。
