<div align="center">

[![协议](https://img.shields.io/badge/协议-AGPL--3.0-blue)](LICENSE)
[![平台](https://img.shields.io/badge/平台-mpv_播放器-black?logo=mediamarkt&logoColor=white)](https://mpv.io)
[![语言](https://img.shields.io/badge/语言-Lua_5.1-blueviolet)](https://www.lua.org)
[![依赖](https://img.shields.io/badge/依赖-uosc-9cf)](https://github.com/tomasklaen/uosc)
[![作者](https://img.shields.io/badge/作者-awujiana-orange)](https://github.com/awujiana)
[![状态](https://img.shields.io/badge/状态-维护中-green)](https://github.com/awujiana/uosc-staff-credits)

<h1>Bangumi 工具箱</h1>
<h2>uosc-staff-credits</h2>

<strong>mpv + uosc 的 Bangumi 扩展脚本：职员表、角色介绍、封面简介、条目搜索、制作评分，一键直达</strong>

</div>

---

> [!WARNING]
> 本项目的相当一部分代码由 AI 辅助生成，并经过持续的人工作业、联调和重构，但它仍然可能存在遗漏、边界情况处理不足或行为与预期不完全一致的问题。如果你在使用过程中发现 Bug、兼容性问题、异常行为或文档缺失，欢迎积极提交 Issue。最好附上复现步骤、日志、截图和系统版本信息，这会非常有帮助。

## 📚 目录

- [项目简介](#-项目简介)
- [核心功能](#-核心功能)
- [展示图](#-展示图)
- [快速开始](#-快速开始)
- [注意事项](#-注意事项)
- [文档](#-文档)
- [反馈建议](#-反馈建议)
- [参考与致谢](#-参考与致谢)
- [关联仓库](#-关联仓库)
- [作者联系方式](#-作者联系方式)
- [开源协议](#-开源协议)

## 🚀 项目简介

`Bangumi 工具箱`（`uosc-staff-credits`）是一个运行在 **mpv 播放器 + uosc 界面**上的 Lua 扩展脚本，由 **awujiana** 维护。

它解决的核心问题是：看番时想查「这集的 staff 是谁」「这个声优还配过什么」「这部番讲什么、评分如何」，必须暂停、切浏览器、搜词条。本脚本把这些查询搬进播放器——按一次快捷键，条目识别、中文转换、数据拉取、面板渲染全部自动完成。

它围绕以下目标设计：

- **零打扰**：打开视频即后台静默预加载，点击功能时秒开，全程无 UI 干扰；
- **中文优先**：日文 / 英文 / 罗马字文件名自动解析并转换为简体中文名后再搜索，季数、集数识别与条目搜索分离，不会污染检索词；
- **无依赖可用**：与 `uosc_danmaku` 联动可共享实时匹配标题；没有它，也能靠文件名解析 + 多源中文转换独立工作。

简单来说：

> 把 Bangumi 的条目信息装进 mpv 的每一帧画面里。

项目基于：

- Lua 5.1（mpv 内嵌 LuaJIT）
- uosc 原生菜单 + ASS 字幕 overlay + `overlay-add` 图片层渲染 UI
- mpv `command_native_async`（curl 子进程）发起网络请求

## ✨ 核心功能

- **职员表**：ASS 五列网格面板展示制作人员名单（真实名称 + 职位），支持翻页。
- **角色介绍**：卡片化展示虚拟角色，含角色图片、关系标签、声优信息。
- **封面简介**：番剧封面 + 基本信息 + 多平台评分 + 剧情简介。
- **BGM 搜索**：手动搜索 Bangumi 条目，输入面板 + 结果列表，命中后自动填入中文名。
- **制作评分**：分析制作人员历史作品的评分走势。
- **中文名自动转换**：非中文标题经 dandanplay / TMDB 等多源并发转换为简体中文再搜索（Jaro-Winkler 相似度选最佳匹配）；繁体、日文新字体（`転` / `撃` / `戦` 等）统一转简体。
- **辅助能力**：多源并发搜索、缓存（当前视频 / 全部可清除）、请求取消机制、curl 错误码友好提示、Bangumi TLS 全失败时自动走镜像兜底。

## 📷 展示图

> 界面截图待补充（建议 16:9，宽度 ≥ 1200px；可放职员表面板与角色卡片各一张）。

## 📦 快速开始

<details open>
<summary><strong>方式一：从 Releases 下载</strong></summary>

前往 [Releases](https://github.com/awujiana/uosc-staff-credits/releases) 下载最新包，解压到 mpv 的脚本目录：

```text
portable_config/
├── scripts/
│   └── uosc_staff_credits/     ← 本脚本
└── script-opts/
    └── uosc_staff_credits.conf ← 配置文件（可选，有默认值）
```

</details>

<details>
<summary><strong>方式二：从源码安装</strong></summary>

```bash
git clone https://github.com/awujiana/uosc-staff-credits.git \
  <mpv配置目录>/portable_config/scripts/uosc_staff_credits
```

</details>

**使用**：mpv 加载 uosc 后，通过 uosc 菜单或 `script-message` 触发各功能：

```bash
# 通过 IPC 触发（示例）
script-message main-menu                          # 主菜单
script-message staff-credits                      # 职员表
script-message character-intro                    # 角色介绍
script-message cover-intro                        # 封面简介
script-message staff-credits-production-score     # 制作评分
script-message staff-credits-search bangumi       # 条目搜索
```

## ⚠️ 注意事项

- 必须安装 [uosc](https://github.com/tomasklaen/uosc)，本脚本的菜单与面板依赖它渲染。
- 可选安装 `uosc_danmaku` 弹幕扩展脚本：两者同时存在时通过 `user-data` 与 `danmaku-anime-info` 消息共享实时匹配的中文名；没有也不影响本脚本独立工作。
- 推荐使用 [awujiana/uosc_danmaku](https://github.com/awujiana/uosc_danmaku)（fork 版）：它在 `show_loaded` 后主动导出匹配结果（番剧名 / 集数 / episodeId）。装上游原版时会自动降级为读历史文件猜测，功能不中断但可能滞后。
- 中文转换依赖 `~~/scripts/uosc_danmaku/dicts/t2s_chars.lua` 共享字典；该文件缺失时繁体转换自动禁用（新字体补充表随本仓库自带）。
- 所有数据来自公开 API（Bangumi / dandanplay / TMDB / 360kan），请遵守各数据源的使用频率约束，脚本内置缓存与请求取消机制。
- 配置项与默认值见 [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md)，修改 `script-opts/uosc_staff_credits.conf` 即可。

## 📖 文档

> 本节仅索引**项目操作文档**（面向使用者）。

- [配置说明](docs/CONFIGURATION.md)
- [渲染实现](docs/ASS_RENDERING.md)
- [界面设计](docs/UI.md)
- [架构设计](docs/DESIGN.md)
- [uosc_danmaku 集成参考](docs/UOSC_DANMAKU_API.md)
- [项目总览](docs/PROJECT.md)

> 测试见 `tests/` 目录（测试文档与用例默认不展开，需要时再补充）。

## 💬 反馈建议

提交 Issue 时建议附上：

- mpv 与 uosc 版本（`mpv --version`）
- 复现步骤（视频文件命名格式很重要）
- 终端日志（含 `[staff_credits]` 前缀的输出）
- 截图或录屏

## 🙏 参考与致谢

- [uosc](https://github.com/tomasklaen/uosc) — mpv 现代化 UI 框架，本脚本的菜单与交互基础
- [awujiana/uosc_danmaku](https://github.com/awujiana/uosc_danmaku) — mpv 弹幕扩展脚本 fork，导出实时匹配结果并共享繁简字典
- [Bangumi API](https://github.com/bangumi/api) — 条目、角色、职员数据
- [dandanplay](https://www.dandanplay.com/) — 文件名匹配与中文标题转换
- [TMDB](https://www.themoviedb.org/) — 中文标题候选

## 🔗 关联仓库

- [awujiana/uosc-staff-credits](https://github.com/awujiana/uosc-staff-credits) — 本仓库
- [awujiana/uosc_danmaku](https://github.com/awujiana/uosc_danmaku) — 配套弹幕脚本 fork（提供 `danmaku-anime-info` 出站广播）

## 📮 作者联系方式

- **作者**：awujiana
- **GitHub**：[@awujiana](https://github.com/awujiana)
- **邮箱**：待补充（欢迎通过 Issue 联系）

## 📄 开源协议

本项目基于 **[AGPL-3.0](LICENSE)**（GNU Affero General Public License v3.0）开源。

根据 AGPL-3.0 的要求：任何人使用、修改或分发本项目代码，若以网络服务器形式向用户提供交互服务，必须同样以 AGPL-3.0 公开其完整对应源代码。

版权所有 © awujiana。
