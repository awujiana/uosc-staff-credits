<div align="center">

[![协议](https://img.shields.io/badge/协议-AGPL--3.0-blue)](LICENSE)
[![PRs](https://img.shields.io/badge/PRs-welcome-brightgreen)](CONTRIBUTING.md)
[![AI 辅助生成](https://img.shields.io/badge/AI辅助生成-是-orange)](https://github.com/awujiana)

<h1>贡献指南</h1>

<strong>欢迎参与「Bangumi 工具箱（uosc-staff-credits）」的共建</strong>

</div>

---

> [!WARNING]
> 本项目的相当一部分代码由 AI 辅助生成，并经过持续的人工作业、联调和重构，但它仍然可能存在遗漏、边界情况处理不足或行为与预期不完全一致的问题。如果你在使用过程中发现 Bug、兼容性问题、异常行为或文档缺失，欢迎积极提交 Issue。最好附上复现步骤、日志、截图和系统版本信息，这会非常有帮助。

感谢你关注 **Bangumi 工具箱（uosc-staff-credits）** 并愿意贡献。本协议与流程用于确保协作顺畅、输出风格统一、许可证一致。

> 维护者：awujiana ｜ 开源协议：以仓库 `LICENSE` 为准（代码 AGPL-3.0）

## 📚 目录

- [我能如何参与](#-我能如何参与)
- [提交 Issue 前](#-提交-issue-前)
- [提交 Pull Request 前](#-提交-pull-request-前)
- [命名规范（不缩写）](#-命名规范不缩写)
- [代码与文档约定](#-代码与文档约定)
- [行为准则](#-行为准则)
- [许可证](#-许可证)

## 🤝 我能如何参与

- **提交 Issue**：反馈 Bug（解析错误、面板渲染异常、网络超时提示不准等）、兼容性问题或新需求。
- **修复代码**：`modules/`（通用模块）、`app/`（管线与调度）、`features/`（功能编排）、`apis/`（数据源）。
- **完善文档**：`docs/CONFIGURATION.md`、`docs/DESIGN.md`、`docs/UI.md` 等操作与设计文档。
- **补充测试**：`tests/` 下的回归测试（季集解析、展示名、ASS 渲染冒烟）。

## 🐞 提交 Issue 前

1. 先搜索确认问题未被重复提出。
2. 说明场景：mpv / uosc / 本脚本版本、视频文件命名格式（这一项直接影响标题解析复现）。
3. 附上 mpv 终端日志（含 `[staff_credits]` / `[title_normalize]` / `[guess]` 前缀的输出）。
4. 面板类问题请附截图，解析类问题请附完整文件名。

## 🔀 提交 Pull Request 前

1. 从 `main` 分支切出特性分支，命名如 `fix/season-parse` 或 `feat/new-panel`。
2. 遵守本仓库的硬性约定：
   - 命名一律全拼、禁止缩写、名称不重复（见下文「命名规范（不缩写）」）；
   - Lua 文件统一 `snake_case.lua`，模块导出通过 `return M`；
   - 不安全的 Lua 字符类（非 ASCII 区间，如 `[话集回]`）一律禁止——多字节字符会被按字节拆开误匹配，本项目已踩坑多次；
   - 涉及显示名的一律走 `title_normalize` / `search_pipeline.format_display_title`，不要在面板里手写 `name_cn` 兜底链。
3. 提交前自测：`luajit -e "assert(loadfile('改动的文件.lua'))"` 通过语法检查；涉及解析 / 展示名改动的，`tests/title_parse_flow` 回归测试需保持通过。
4. 提交信息清晰说明「做了什么 / 为什么」。
5. 中文表述准确，链接有效，占位内容明确标注「待补充」。

## 📝 命名规范（不缩写）

> 本节为**硬性命名规范**，所有改动都必须遵守。

### 总则

- **一律全拼，禁止缩写**：`usr`→`user`、`cfg`→`config`、`btn`→`button`、`img`→`image`、`idx`→`index`。
- **名称不重复**：项目名全局唯一；同目录文件名唯一（大小写不敏感）；同模块导出名唯一。
- **名称即语义**：只看名字即可判断用途；禁止 `utils`、`common`、`misc`、`temp`、`data1` 等泛化名。
- **同一项目内形态统一**：同类文件 / 符号只用一种命名风格。

### 项目（仓库）命名

- `kebab-case`，全小写，单词间用 `-`，2–5 个单词，能表达用途（本仓库：`uosc-staff-credits`）。
- 禁止含版本号、日期、作者名，以及 `test` / `demo` / `untitled` 等无信息量名称。

### 文件命名

| 类型 | 规则 | 示例 |
| --- | --- | --- |
| 文档 | `kebab-case.md` | `release-notes.md`、`naming-conventions.md` |
| Lua 脚本 | `snake_case.lua`（本项目统一） | `title_normalize.lua`、`search_pipeline.lua` |
| 测试 | `<被测目录>/main.lua` | `tests/title_parse_flow/main.lua` |
| 静态资源 | 小写英文 + 连字符 | `ui-example.svg`、`sponsor-qrcode.jpg` |

- **同一目录内不得出现同名文件**，包括仅大小写不同。
- 字典类数据文件放在 `dicts/`，以 `<用途>_chars.lua` / `<用途>_dict.lua` 命名（如 `shinjitai_chars.lua`）。

### 函数与模块命名

- **函数**：`snake_case`（本项目统一），**动词开头 + 名词**，全拼，如 `resolve_display_title`、`parse_title`、`format_subject_title`。
- **模块**：文件名即模块名，`require("modules.title_normalize")` 返回 `M`；同一模块内不得出现同名导出。
- 不同模块同名函数须加业务限定词（`resolve_display_title` / `resolve_person`）。

### 冲突处理

加**语义限定词**，而不是数字后缀。`user_card2` ❌；应为 `user_profile_card` / `user_settings_card` ✅。

## 📋 代码与文档约定

- 正文以简体中文为主，专有名词保留英文原文。
- 命令行、配置片段使用围栏代码块并标注语言。
- 对比 / 参数类信息优先使用表格。
- 标题层级连续，不跳级。
- 注释写「为什么」而非「是什么」；踩过的坑（Lua 字节字符类、mpv API 语义等）必须在注释里留痕。

## 🤗 行为准则

请保持友善、专业、就事论事。尊重不同经验水平的贡献者，对技术分歧以讨论达成共识，不人身攻击、不贬低他人工作。

## 📄 许可证

向本仓库提交贡献，即表示你同意以仓库 `LICENSE` 所载协议（AGPL-3.0）发布你的贡献，并确认你拥有相应的授权。详见仓库内 [LICENSE](LICENSE)。

[![AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)
