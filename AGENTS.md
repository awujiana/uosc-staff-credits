# AGENTS.md

> 本文件供 **AI 编码 / 写作 agent**（如 WorkBuddy、Copilot、Claude）阅读，用于了解本仓库的结构、约定与禁忌，从而在自动改动时保持风格一致。
> 人类贡献者请阅读 [`CONTRIBUTING.md`](CONTRIBUTING.md)（含完整命名规范）。

## 项目概述

- **名称**：Bangumi 工具箱（中文名）
- **GitHub 仓库名（英文名）**：uosc-staff-credits
- **类型**：代码仓库（AGPL-3.0）
- **维护者**：awujiana
- **一句话**：mpv + uosc 的 Bangumi 扩展脚本：职员表、角色介绍、封面简介、条目搜索、制作评分，一键直达。

## 仓库结构

| 路径 | 用途 | 是否发布 |
| --- | --- | --- |
| `main.lua` / `app/` | 入口、调度器、搜索管线（`run_subject_pipeline` 7 步管线） | ✅ |
| `features/` | 功能编排（职员表 / 角色介绍 / 封面简介 / 制作评分 / 选条目） | ✅ |
| `modules/` | 通用模块（菜单、ASS 渲染、标题规范化、缓存、分页等） | ✅ |
| `apis/` | 数据源适配（Bangumi / 镜像 / dandanplay / TMDB / 360kan） | ✅ |
| `dicts/` | 字典数据（`shinjitai_chars.lua` 日文新字体 → 简体补充表） | ✅ |
| `docs/` | 操作文档（配置 / 渲染 / 界面 / 架构） | ✅ |
| `docs/internal/` | 内部维护记录（审查归档、隐私清理），不进 README 索引 | ✅（仅存档） |
| `tests/` | 回归测试（`title_parse_flow` / `ass_render_flow`） | ✅（不进文档索引） |
| `CHANGELOG.md` | 更新日志（按版本累积记录） | ✅ |
| `README.md` / `CONTRIBUTING.md` / `AGENTS.md` / `LICENSE` | 仓库四件套 | ✅ |

## 必须遵守的约定

1. **命名规范（不缩写）**：仓库 `kebab-case`、Lua 文件 `snake_case.lua`、函数 `snake_case` 动词开头全拼、名称不重复。详见 `CONTRIBUTING.md` 的「命名规范（不缩写）」。
2. **显示名收口**：条目展示名一律走 `search_pipeline.format_display_title`（内部调用 `title_normalize.format_subject_title`），人名走 `name_resolver`，禁止在面板里手写 `name_cn → name → fallback` 兜底链——历史上 6 处各写一套导致同一条目在四个面板显示四种名字。
3. **搜索与展示分离**：季数 / 集数只作为展示后缀（`第X季 第X集`），**绝不**拼进 Bangumi 搜索 query。季集解析在 `modules/guess.lua`，模式必须可叠加（季 + 集同时命中）。
4. **Lua 字符类禁令**：非 ASCII 字符类（如 `[话集回]`、`[ぁ-ゖ]`）一律禁止——Lua 按「字节集」语义解释多字节区间，会误匹配全部 CJK 汉字。需要匹配具体汉字时用字面量单位逐个比较。本项目已踩坑多次，`tests/title_parse_flow` 里有回归用例。
5. **繁简转换**：字典来自 `~~/scripts/uosc_danmaku/dicts/t2s_chars.lua`（共享，勿改动兄弟仓库），本仓库的 `dicts/shinjitai_chars.lua` 日文新字体补充表由 `title_normalize.load_t2s` **只补空位、不覆盖**地叠加。新增新字体映射时改本仓库的补充表，不动 t2s。
6. **README 风格**：顶部 shields.io 徽章 → `[!WARNING]` AI 声明 → 目录 → 正文 → 底部三节（关联仓库 / 作者联系方式 / 开源协议）；双名标题（中文 `<h1>` 在上、`uosc-staff-credits` `<h2>` 在下）。
7. **协议**：AGPL-3.0，`LICENSE` 不许改动。
8. **文档索引**：README「文档」节只列操作文档；`tests/` 不进索引，最多一句话提示。
9. **提交信息**：说明「做了什么 / 为什么」；`main` 分支直接提交（单人仓库）或从 `main` 切特性分支。
10. **提交身份**：`git config user.email` 必须是 `bingshanlengtie@qq.com`。旧邮箱一旦进了提交元数据，「改文件」和 `force push` 都清不掉——普通仓库要靠删库重建，fork 仓库只能请 GitHub Support 做 GC。详见 `docs/internal/GITHUB_PRIVACY_CLEANUP.md`。

## 改动前检查

- **改 Lua 代码**：`luajit -e "assert(loadfile('文件.lua'))"` 过语法；涉及解析 / 展示名的改动跑 `tests/title_parse_flow`（luajit + mp 桩可跑，参考仓库外 harness），渲染改动跑 `tests/ass_render_flow`。
- **改标题解析**：先读 `docs/DESIGN.md` §7（标题解析）与 `modules/guess.lua` 顶部注释，理解既有模式的互斥 → 叠加演进史。
- **改字典**：只改 `dicts/shinjitai_chars.lua`，新条目不得覆盖 t2s 已有键。
- **改文档**：`docs/PROJECT.md` 是历史快照（v1.9.2），正文与代码不一致时以代码为准并更新 `docs/DESIGN.md` 与 `CHANGELOG.md`。
- **提交**：更新 `CHANGELOG.md`（Keep a Changelog 格式，语义化版本）。

## 不要做的事

- 不要手写 `⚠️ Warning` 代替 GitHub 警示块 `> [!WARNING]`。
- 不要缩写命名、不要同名文件（含仅大小写不同）、不要用数字后缀解决冲突（`user_card2` ❌）。
- 不要在面板代码里直接读 `subject.name_cn` 拼显示标题（收口到管线）。
- 不要把季数 / 集数拼进搜索关键词。
- 不要写非 ASCII 的 Lua 字符类。
- 不要改动兄弟仓库 `uosc_danmaku` 的共享字典；缺口在本仓库补充表里填。
- 不要删除 `AGENTS.md` / `CONTRIBUTING.md`；它们承载协作与 AI 约定。
- 不要动 `docs/新建 Markdown.md` 等未整理草稿（未纳入版本管理）。
