## 本次改动

<!-- 简要说明改动内容与它解决的问题。 -->

## 原因

<!-- 动机说明。若有关联 issue 请写上："Closes #123" -->

## 如何验证

<!-- 你是怎么测试的？写明跑过的命令与观察到的结果。 -->

- [ ] `cd app && flutter analyze --no-pub` → 无 issue
- [ ] `cd app && flutter test --no-pub` → 全部通过
- [ ] 真机验证：Android __
- [ ] 对着 mock 服务验证（`server-bridge/mock/`）

## 截图

<!-- UI 改动的改前 / 改后对比。请遮盖 API Key、VPN 私钥与内网 IP。 -->

## 检查清单

- [ ] 为改动新增或更新了测试
- [ ] 同步更新了已失效的文档（README / 用户手册 / `docs/ui-design-spec.md`）
- [ ] 已在 `CHANGELOG.md` 对应版本条目中记录变更
- [ ] 不含密钥、个人数据、模型权重、上游源码或构建产物
- [ ] 若改动涉及面向用户、且提到上游项目的文案，已遵循 `docs/ui-design-spec.md` §5.1
