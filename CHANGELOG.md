# 更新日志

本文件记录 `uosc_staff_credits` 的重要变更，版本号遵循语义化版本 `MAJOR.MINOR.PATCH`。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

## [1.10.0] - 2026-10-27

### 新增

- `modules/title_normalize.lua` 新增 `format_subject_title(subject, fallback, season, episode)`：
  面板标题统一取已选条目的 `name_cn`（繁转简），再拼接已识别的季、集后缀。
- `modules/title_normalize.lua` 新增 `extract_episode_number(text)`：
  从「第 12 话」这类文本安全取集数（不使用 Lua 字节字符类）。
- `app/search_pipeline.lua` 新增 `format_display_title(subject, fallback, context)`，
  作为所有面板可见标题的唯一入口。
- `modules/guess.lua` 新增 `chinese_number_to_int` / `extract_season_episode` 导出，
  覆盖中文数字季数（`第三季`）、中文数字集数（`第九话`）、`2nd Season`、
  独立 `S2`、`2x05`，以及半角 / 全角罗马数字季数提示（`III` / `Ⅲ`）。

### 改进

- `modules/guess.lua` 的季、集识别由「6 个互斥模式」重写为「3 步可叠加」：
  季 + 集同时命中 → 只抽集 → 只抽季。此前「进击的巨人 第三季 第05集」只能拿到集数。
- `guess.parse_title` 现在**总是**被调用以补齐季集，即便弹幕关联已给出中文标题。
- 展示名统一收口：搜索结果列表（`menu.lua`）、制作评分作品名（`production_score.lua`）、
  封面简介标题（`cover_intro.lua`）全部改走 `resolve_display_name`，不再繁简混排。
- `modules/types.lua` / `modules/api.lua` 透传角色与职员的 `name_cn` 与 `infobox`，
  使中文名优先级能在角色 / 声优上生效。

### 修复

- **职员名优先级回退**：`resolve_person` 曾把 `name_en` / `name_jp` 排在 `entity.name` 之前，
  导致无中文译名的职员显示罗马字。现改为日文原名优先、罗马字仅兜底。
- **季数重复追加**：`無職転生 III` 这类把季数嵌进名字的标题会被再拼一个「第 3 季」。
  现在判重覆盖阿拉伯数字、中文数字、`Season X` 与半角 / 全角罗马数字。
- **集数误判**：`[话集回]` 是 Lua 字节字符类，会把「第 3 阶」的「阶」当成集数单位。
  改为逐个字面量单位比较（本项目第 5 次栽在同一个坑上）。
- **集数夹带分辨率**：`S01E22.1080p` 曾解析出 `22.1080`；小数部分 ≥3 位时视为分辨率截断。
- **`Season X` 误读**：`Re:Zero 2nd Season - 26` 曾被读成第 26 季；
  「2nd Season」现排在「Season X」之前，且 `Season` 与数字之间只允许空白 / 点 / 紧邻单连字符。

### 破坏性变更

- `run_subject_pipeline` 的 `on_cached_hit` / `on_search_success` 增加第三个参数 `context`
  （`{ season_num, episode_num }`）。
- `fetch_characters_from_source` 的回调末尾增加 `subject` 参数。
- `resolve_cached_title` 的回调第二个返回值改为 `context`。

Lua 忽略多余实参，旧调用点不会崩溃，但拿不到 `context` 就无法拼出季集后缀。

### 已知限制

共享繁简字典 `uosc_danmaku/dicts/t2s_chars.lua` 是繁体 → 简体，不含日文新字体，
`転` / `撃` 等字不转换（`無職転生 → 无职転生`）。仅影响未命中 Bangumi 条目、
纯靠文件名解析的兜底路径。

## 更早的版本

本仓库直到 2026-10-27 才引入 `CHANGELOG.md`，且此前只有一个提交，
更早的变更**没有可靠记录**，此处不做追溯编造。代码中残留的版本标记
（v1.6 统一中文标题接口、v1.7 五个通用模块、v1.8 `select_best_subject` 季数匹配、
v1.9 / v1.9.1 超时拆分）可作为阅读代码时的时间线参考，具体日期无从考证。
