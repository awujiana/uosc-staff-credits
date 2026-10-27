# uosc_staff_credits 项目文档

> 版本: 1.9.2  ·  最后更新: 2026-08-02  ·  适用代码版本: mpv_config-2025.11.28
>
> ⚠️ **本文档是 v1.9.2 的历史快照，正文未随代码更新。**
> 文中描述的 `fankuhub` 聚合源已于 v2.0 移除（同时删除 `data_source` /
> `fankuhub_api_base` 配置项、`staff-credits-fankuhub-search` 路由、
> `apis/fankuhub.lua` / `features/fankuhub_search.lua`）。
> 移除详情见 `REVIEW_AND_MERGE.md` §12；现行配置见 `CONFIGURATION.md`。

---

## 1. 项目概述

### 1.1 简介

`uosc_staff_credits` 是 mpv 播放器的 uosc 插件扩展脚本，作为 **Bangumi 工具箱**，提供 7 大核心功能：

| # | 功能 | 主菜单 icon | 触发消息 | 说明 |
|---|------|-----------|---------|------|
| 1 | **职员表** | `contact_page` | `staff-credits` | 工作职员列表（ASS overlay 5列网格面板，支持翻页，仅真实名称 + 职位） |
| 2 | **角色介绍** | `person` | `character-intro` | 卡片化展示虚拟角色（含图片、关系标签、CV） |
| 3 | **封面简介** | `book_cover` | `cover-intro` | 番剧封面 + 基本信息 + 多平台评分 + 简介 |
| 4 | **BGM 搜索** | `search` | `staff-credits-search bangumi` | 手动搜索 Bangumi 条目（输入面板 + 结果列表，自动填入中文名） |
| 5 | **番库搜索** | `video_library` | `staff-credits-fankuhub-search` | 搜索 fankuhub 聚合源（含图片+声优，自动填入中文名） |
| 6 | **制作评分** | `sentiment_satisfied` | `staff-credits-production-score` | 制作人员历史作品评分分析 |
| 7 | **番剧中文名搜索** | - | （内嵌于搜索流程） | 非中文标题自动转换为中文后再搜索 |

**辅助功能**：打开视频自动搜索和加载（静默预加载）、网站优先级配置、搜索设置、清除当前视频/全部搜索缓存。

数据来源包括 Bangumi 官方 API、Bangumi 镜像站、fankuhub 聚合源、dandanplay 弹幕库、360kan 视频源、TMDB。

### 1.2 核心特性

1. **打开视频自动搜索和加载（静默预加载）**：进入视频后自动后台预取条目信息并缓存，用户点击功能时秒开。受 `autoload_with_danmaku=true` 控制，调用统一标题接口 `resolve_title_sync`（4 级优先级：弹幕关联→subject 缓存→文件名解析→media-title 兜底），无 uosc_danmaku 时仍可通过文件名解析 + 中文转换独立工作，全程无 UI 干扰
2. **中文标题自动转换**：非中文标题（如英文/日文文件名）自动通过 dandanplay + TMDB + fankuhub 转换为中文译名后再搜索，提升匹配率
3. **统一中文标题获取接口（v1.6）**：所有 feature 共用 `search_pipeline.resolve_title_sync` + `resolve_display_title`，4 级优先级一致，缓存条目无有效标题时自动调用统一接口兜底，与 BGM/番库搜索预填流程完全一致
4. **uosc_danmaku 联动（可选）**：通过 `user-data` 属性跨脚本读取弹幕库实时匹配的中文名；无 uosc_danmaku 时通过 subject 缓存和文件名解析独立工作
5. **BGM / 番库搜索自动填入中文名**：打开搜索面板时调用统一接口 `resolve_title_sync`（4 级优先级：弹幕关联→subject 缓存→文件名解析→media-title 兜底），footnote 显示完整标题避免搜索框右对齐截断
6. **curl 错误码识别**：针对 exit code 28（超时）、6（DNS）、7（连接）、35（SSL）等提供友好中文提示
7. **请求取消机制**：路径切换时自动取消所有进行中的请求，防止旧回调污染新状态
8. **多源并发搜索**：dandanplay + 360kan + TMDB + fankuhub 并发获取中文候选，Jaro-Winkler 相似度选最佳匹配
9. **通用管线复用**：6 个功能均通过 `run_subject_pipeline` 7 步管线协调，复用缓存查询/标题识别/搜索调度/错误处理逻辑
10. **Bangumi SSL 失败兜底**：当所有 Bangumi 服务器 TLS 握手失败（curl exit code 35）时，自动用 fankuhub 聚合源兜底搜索
11. **文件名解析增强**：支持 `Episode.01`、`S2 - 01`、`第1话`、`[01]`、`Season 2` 等多种命名格式，正确提取番剧名和季数
12. **缓存条目标题防御**：缓存写入时校验 name/name_cn 必须为非空字符串，避免空标题污染缓存；缓存命中时若仍无有效标题则调用 `resolve_display_title` 获取中文标题兜底，与 BGM/番库搜索预填逻辑一致
13. **fankuhub 字段兼容增强**：normalize_results 兼容 titleEn/titleRomaji 字段，确保 name 字段始终有兜底值（"未知条目"）
14. **加载性能与防叠加优化（v1.9）**：职员表 / 角色介绍 / 制作评分统一优先走 fankuhub 聚合源（一次请求返回角色+职员+图片，省 3-8s），fankuhub 无数据时自动回退 bangumi；bangumi 的 `characters`/`persons` 改为并行请求（省 2-5s）；loading 倒计时超时（`timeout=8`）与网络请求超时（`request_timeout=15`，curl `--max-time`）分离；`finish_silent()` 立即关闭 loading 菜单并新增 4 个面板防御性 `close_menu`，消除 loading 菜单与 ASS overlay 面板叠加显示

### 1.3 技术栈

| 项 | 内容 |
|----|------|
| 语言 | Lua 5.1（mpv 内嵌 LuaJIT） |
| 运行时 | mpv 播放器 + uosc 插件 |
| UI 渲染 | ASS 字幕 overlay + mpv `overlay-add` 图片层 + uosc 原生菜单 |
| 网络请求 | mpv `command_native_async`（curl 子进程） |
| 配置 | `script-opts/uosc_staff_credits.conf` + `defaults.lua` 默认值 |
| 测试 | `luajit -b` 语法校验 + 真机验证 |

### 1.3 安装位置

```
mpv_config-2025.11.28/
└── portable_config/
    ├── scripts/uosc_staff_credits/        # 脚本主目录
    └── script-opts/uosc_staff_credits.conf # 用户配置（可选）
```

---

## 2. 目录结构

```
uosc_staff_credits/
├── .workbuddy/memory/                # workbuddy 工作记忆
├── apis/                              # 外部数据源 API 封装层
│   ├── dandanplay.lua                 # dandanplay 弹幕库搜索
│   ├── extra.lua                      # 360kan + TMDB 搜索
│   └── fankuhub.lua                   # fankuhub 聚合数据源
├── app/                               # 应用层（组合根 / 编排 / 状态）
│   ├── bootstrap.lua                  # 启动组合根（DI 总线）
│   ├── dispatcher.lua                 # 事件分发器
│   ├── loading_controller.lua         # 加载流程控制器
│   ├── request_registry.lua           # 请求取消注册中心
│   ├── search_pipeline.lua            # 搜索编排管线
│   └── state.lua                      # 应用状态表
├── docs/                              # API 参考文档
│   ├── bangumi_mirror_api.md
│   └── fankuhub_api.md
├── features/                          # 业务逻辑层（用例编排）
│   ├── character_cards.lua            # 角色介绍入口
│   ├── cover_intro_flow.lua           # 封面简介入口
│   ├── fankuhub_search.lua            # fankuhub 扩展搜索
│   ├── production_score_flow.lua      # 制作评分入口
│   ├── shared.lua                     # feature 共享辅助函数
│   ├── staff_credits.lua               # 职员表入口
│   └── subject_select.lua             # 条目选择编排
├── modules/                           # 业务/基础设施层
│   ├── utils/                         # 通用工具子模块
│   │   ├── image.lua                  # 图片转 BGRA
│   │   ├── io.lua                     # IO 工具
│   │   ├── module_loader.lua          # 模块工厂
│   │   ├── net.lua                    # 网络工具
│   │   ├── path.lua                   # 路径工具
│   │   └── url.lua                    # URL 工具
│   ├── api.lua                        # Bangumi API 通信层
│   ├── ass_lib.lua                    # ASS 渲染辅助库
│   ├── cards.lua                      # 角色卡片渲染
│   ├── cover_intro.lua                # 封面简介渲染
│   ├── danmaku_link.lua               # 弹幕关联读取
│   ├── data_cache.lua                 # 本地持久化数据缓存（v1.7）
│   ├── defaults.lua                   # 配置默认值 SSOT
│   ├── guess.lua                      # 文件名解析
│   ├── history.lua                    # 搜索历史缓存
│   ├── input_service.lua              # 鼠标输入服务
│   ├── menu.lua                       # uosc 菜单生成
│   ├── mouse_interaction.lua          # 通用鼠标交互 mixin（v1.7）
│   ├── name_resolver.lua              # 名称优先级解析
│   ├── notify.lua                     # 统一 OSD 提示
│   ├── overlay_manager.lua            # 通用 Overlay 管理器（v1.7）
│   ├── panel_registry.lua             # 面板注册中心
│   ├── pagination.lua                 # 通用翻页组件（v1.7）
│   ├── production_score.lua           # 制作评分面板
│   ├── runtime_config.lua             # 运行时配置持久化（v1.7）
│   ├── servers.lua                    # 数据源优先级配置
│   ├── staff_grid.lua                 # 职员表网格面板（5列布局）
│   ├── types.lua                      # 数据结构类型守卫
│   ├── ui_base.lua                    # UI 公共基础设施
│   └── utils.lua                      # 工具函数门面
└── main.lua                           # 脚本入口（仅 19 行）
```

---

## 3. 入口流程

### 3.1 启动调用链

```
[mpv 加载脚本]
   ↓
[main.lua] pcall → bootstrap.run()
   ↓
[bootstrap.run()]
   ├─ load_options()        合并 defaults + script-opts
   ├─ safe_require 各层模块（基础设施 → 核心 → API → features）
   ├─ init_module(...)      对每个模块调用 mod.init(opts, deps)
   ├─ loading_controller.init(...)
   ├─ search_pipeline.init(...)
   ├─ 各 feature.init(deps)
   ├─ dispatcher.init(deps)
   └─ dispatcher.register_all()
        ├─ register_uosc_buttons()
        ├─ mp.register_script_message(...) × 多个
        ├─ mp.add_key_binding(...) × 多个
        └─ mp.observe_property("path", ...)
```

### 3.2 用户触发示例

**点击 uosc "Bangumi 工具箱" 按钮**：
1. uosc 触发 `script-message-to uosc_staff_credits main-menu`
2. dispatcher 路由 → `menu.show_main_menu()` 显示主菜单
3. 用户选择"职员表"项 → 触发 `staff-credits` 消息
4. dispatcher → `feature_staff_credits.fetch()`
5. → `search_pipeline.run_subject_pipeline(...)` 走通用管线
6. → 缓存查询 / 多源搜索 / 数据源优先级获取
7. → `loading_controller.show_with_countdown` 显示倒计时
8. → 成功后 `menu.show_characters` 显示角色列表

### 3.3 路径切换处理

dispatcher 的 `mp.observe_property("path", ...)` 回调：
1. 若正在加载，调用 `finish_loading()` 重置状态
2. `state.set_current_path(path)` 更新当前路径
3. 关闭所有可见面板（cards / production_score）
4. 取消所有进行中的请求（`request_registry.cancel_all()`）
5. 清理 LRU 缓存（`state.cleanup_search_cache` / `cleanup_cover_intro_cache`）
6. **触发静默加载**（`trigger_silent_load(path)`）：见下方 §3.4

### 3.4 打开视频自动搜索和加载（静默预加载）

文件：`app/dispatcher.lua` 的 `trigger_silent_load(path)`，路径切换后由 path_observer 自动调用。

**触发条件（三重门控）**：
1. `opts.autoload_with_danmaku == true`（默认开启，可在 script-opts 中关闭）
2. `state.loading_state.loading == false`（用户未主动操作，避免冲突）
3. `state.search_state.last_subject_by_path[path] == nil`（缓存未命中，避免重复请求）

**流程**（v1.6 改用统一标题接口）：
1. 调用 `search_pipeline.resolve_title_sync()` 获取基础标题（4 级优先级）：
   - 弹幕关联中文名（`get_danmaku_info().anime`，需 uosc_danmaku 暴露）
   - subject 缓存中文名（`state.get_last_subject(path).name_cn`，独立于 uosc_danmaku）
   - 文件名解析（`get_current_title()`，从 path 提取番剧名）
   - media-title 兜底（URL 等特殊情况）
2. 注册 `cancel_fn` 到 `request_registry`（路径切换时自动取消）
3. `on_progress` 为空函数（不显示任何 loading 菜单、不弹 OSD，完全静默）
4. 调用 `search_pipeline.resolve_chinese_title(base_title, callback)` 异步转换：
   - 中文标题直接 callback 跳过转换
   - 非中文标题并发调用 dandanplay + TMDB + fankuhub 获取中文候选
5. 转换完成后调用 `search_pipeline.search_subject_enhanced(final_title, season_num, on_done, on_progress, true, 2)`：
   - `skip_extra=true` 跳过外部候选搜索（标题已过中文转换）
   - `subject_type=2` 限定动画类型
6. 成功 → `state.set_last_subject(path, info)` 写入缓存，仅 `notify.debug` 日志
7. 失败 → 仅 `notify.debug` 日志，完全静默不打扰用户

**用户感知**：进入视频后无任何 UI 变化，但点击职员表/角色介绍等功能时可秒开（缓存命中）。

**调试方法**：设置 `opts.debug=true`，查看 `[staff-credits]` 日志中的"静默加载成功/失败"条目。

---

## 4. 功能模块说明

### 4.1 核心面板

| 面板 | 文件 | 尺寸 | 触发消息 | 数据来源 |
|------|------|------|---------|---------|
| 职员表 | `features/staff_credits.lua` + `modules/staff_grid.lua` | 全屏自适应（5列网格） | `staff-credits` | fankuhub.search 优先（`get_subject_persons_compatible`），无数据时降级 bangumi `get_subject_persons`（仅职员，过滤 type=1 角色） |
| 角色介绍 | `modules/cards.lua` | 自适应（2 行 × 2~5 列） | `character-intro` | fankuhub 优先（与职员表一致，`fetch_characters_from_source` 始终先尝试 fankuhub.search），无角色时降级 bangumi（仅角色，含图片兜底） |
| 封面简介 | `modules/cover_intro.lua` | 960×580 | `cover-intro` | bangumi → bangumi镜像 → bgm.tv |
| 制作评分 | `modules/production_score.lua` | 960×580 | `staff-credits-production-score` | bangumi |
| BGM 搜索 | `features/subject_select.lua` + `modules/menu.lua` | uosc 输入面板 + 结果列表 | `staff-credits-search bangumi` | bangumi（多服务器并发） |
| 番库搜索 | `features/fankuhub_search.lua` + `modules/menu.lua` | uosc 输入面板 + 结果列表 | `staff-credits-fankuhub-search` | fankuhub（聚合源，含图片+声优） |

### 4.2 数据源

| 数据源 | 文件 | 用途 | 错误码 |
|--------|------|------|--------|
| Bangumi API | `modules/api.lua` | 角色信息/职员表/详情 | `ERR_NETWORK/HTTP/PARSE/EMPTY` |
| dandanplay | `apis/dandanplay.lua` | 通过弹幕库获取番剧中文名 | 同上 |
| 360kan + TMDB | `apis/extra.lua` | 视频源中文名搜索 | 同上 |
| fankuhub | `apis/fankuhub.lua` | 聚合源（一次请求含角色+声优+图片） | 同上 |

### 4.3 菜单

通过 uosc 原生菜单实现，类型常量：

| 常量 | 值 | 用途 |
|------|-----|------|
| `MENU_MAIN` | `staff_credits_main` | 主菜单（Bangumi 工具箱） |
| `MENU_CHARACTERS` | `staff_credits_characters` | 角色列表 |
| `MENU_SEARCH` | `staff_credits_search` | BGM 搜索面板 |
| `MENU_RESULTS` | `staff_credits_results` | 搜索结果列表 |
| `MENU_LOADING` | `staff_credits_loading` | 加载中菜单 |
| `MENU_SETTINGS` | `staff_credits_settings` | 设置菜单 |
| `MENU_SERVERS` | `staff_credits_servers` | 网站优先级菜单 |

### 4.4 主菜单项

1. **职员表** (`contact_page`) — 查看工作职员列表（真实名称 + 职位）
2. **角色介绍** (`person`) — 卡片化显示虚拟角色（含图片、关系标签、CV）
3. **封面简介** (`book_cover`) — 番剧封面+基本信息+简介梗概
4. **BGM 搜索** (`search`) — 手动搜索 Bangumi 条目（自动填入中文名）
5. **番库搜索** (`video_library`) — 搜索 fankuhub 聚合源（自动填入中文名）
6. **制作评分** (`sentiment_satisfied`) — 分析制作人员的历史作品评分
7. ─── 设置 ───
8. **网站优先级** (`swap_vert`) — 配置首选数据源
9. **搜索设置** (`settings`) — 清除缓存等选项
10. **清除当前视频缓存** (`delete`) — 删除当前动漫的搜索记录
11. **清除所有缓存** (`delete_sweep`) — 删除全部搜索记录

### 4.5 7 大功能编排流程

所有 7 个功能均通过 `search_pipeline.run_subject_pipeline` 通用管线协调（BGM 搜索 / 番库搜索为直接搜索入口，不走管线），差异在回调配置：

| 功能 | feature 文件 | on_cached_hit | search_fn | on_search_success |
|------|-------------|---------------|-----------|-------------------|
| 职员表 | `staff_credits.lua` | 用 cached subject 调职员接口（fankuhub 优先 → bangumi 降级，仅职员） | `search_subject_enhanced` | `build_staff_items` 过滤 type≠1 → `staff_grid.show`（5列网格面板） |
| 角色介绍 | `character_cards.lua` | 用 cached name 重新拉取角色（`fetch_characters_from_source` fankuhub 优先） | `fetch_characters_from_source` | 展示卡片（`cards.show`，仅角色） |
| 封面简介 | `cover_intro_flow.lua` | 用 cached subject 拉取详情 | `search_subject_enhanced` | 拉取详情 → `cover_intro.show`（写入 cover_intro_cache） |
| BGM 搜索 | `subject_select.lua` | - | 直接 `api.search_subject_parallel`（不走管线） | `menu.show_search_results` |
| 番库搜索 | `fankuhub_search.lua` | - | 直接 `fankuhub.search` / `fankuhub.search_by_person`（不走管线） | `menu.show_search_results` |
| 制作评分 | `production_score_flow.lua` | 直接进入 persons 阶段（fankuhub 优先 → bangumi 降级） | `search_subject_enhanced` | 拉取制作人员 → 分类 9 组 → 每人查作品 → `production_score.show` |
| 番剧中文名搜索 | （内嵌于管线） | - | - | 在管线第 4.5 步通过 `resolve_chinese_title` 转换标题 |
| 静默预加载 | `dispatcher.lua` | - | `search_subject_enhanced(skip_extra=true)` | 写入 `state.set_last_subject` 缓存，无 UI |

**管线 7 步流程**：
1. 入口守卫：重置 loading 状态
2. 路径解析：`mp.get_property("path")`
3. 缓存查询：`history.get(dir)` / `state.get_last_subject(path)`
4. 标题识别：`get_danmaku_info` → `get_current_title`（管线内部 2 级优先级；feature 入口可先调 `resolve_display_title` 获取完整中文标题）
4.5. **中文标题转换**：`resolve_chinese_title`（非中文标题并发调用 dandanplay + extra + fankuhub 转换）
5. 进度回调：`on_progress("searching" | "detail")`
6. 完成回调：成功写入缓存（校验 name/name_cn 非空）+ 调用 `on_search_success`，失败显示错误菜单
7. 调度搜索：`search_fn(title, season_num, on_progress, on_done, skip_extra)`

### 4.6 统一中文标题获取接口（v1.6）

为解决各 feature 标题获取逻辑不一致问题，在 `search_pipeline.lua` 新增统一入口：

#### `resolve_title_sync()` — 同步获取基础标题（4 级优先级）

| 优先级 | 来源 | 说明 |
|--------|------|------|
| 1 | `get_danmaku_info().anime` | 弹幕关联中文名（uosc_danmaku 实时属性或历史文件，未暴露时返回 nil） |
| 2 | `state.get_last_subject(path).name_cn` | subject 缓存中文名（静默预加载或之前搜索的结果，独立于 uosc_danmaku） |
| 3 | `get_current_title()` | 文件名解析（`guess.parse_title`，从 path 提取番剧名） |
| 4 | `mp.get_property("media-title")` | media-title 兜底（URL 等特殊情况） |

返回 `title, season_num`；极端情况下返回 `"未知条目"`。

#### `resolve_display_title(callback)` — 异步获取显示标题（含中文转换）

流程：
1. 调用 `resolve_title_sync()` 获取基础标题
2. 若已是中文（`utils.is_chinese`），直接 callback
3. 否则调用 `resolve_chinese_title` 转换（dandanplay + extra + fankuhub 并发）
4. 转换失败则返回原标题

`callback(chinese_title, season_num)`。

#### 各 feature 调用方式

| Feature | 文件 | 调用方式 |
|---------|------|----------|
| 职员表 | `staff_credits.lua` | `on_cached_hit` 中缓存无有效标题时调用 `resolve_display_title` 兜底；`on_search_success` 标题优先级（v1.6）：`subject.name_cn` → `search_title_used`（中文）→ `subject.name` → `media-title`，确保显示中文名 |
| 角色介绍 | `character_cards.lua` | `fetch_and_show_from_cache` 中缓存无有效标题时调用 `resolve_display_title` 兜底 |
| 封面简介 | `cover_intro_flow.lua` | 入口 `M.fetch` 调用 `resolve_display_title` 获取中文标题后再查 cover_intro_cache / 走管线 |
| 制作评分 | `production_score_flow.lua` | `on_cached_hit` 中缓存无有效标题时调用 `resolve_display_title` 兜底；`run_persons_phase` 接受 title 参数 |
| BGM 搜索 | `subject_select.lua` | `show_bgm_search_panel` 调用 `resolve_title_sync` 获取预填标题，再用 `resolve_chinese_title` 异步转换 |
| 番库搜索 | `fankuhub_search.lua` | `show_search_panel` 调用 `resolve_title_sync` 获取预填标题，再用 `resolve_chinese_title` 异步转换 |
| 静默预加载 | `dispatcher.lua` | `trigger_silent_load` 调用 `resolve_title_sync` + `resolve_chinese_title` 后静默搜索 |

### 4.7 中文标题转换流程

`search_pipeline.resolve_chinese_title(title, callback)`：

1. `utils.is_chinese(title)` 检测：UTF8 中文范围 `[\228-\233][\128-\191]`，命中直接 callback 原标题
2. 非中文标题并发调用：
   - **dandanplay** `search(title)` → 取 `animeTitle` 数组中首个中文候选
   - **extra** `search(title)` → 取 TMDB 中文译名 + 360kan 候选中首个中文
3. `pending` 计数器跟踪，两个数据源均返回后 `try_finish`
4. 取首个中文候选作为 best_candidate；转换失败回退原标题
5. 转换完成后调用 `callback(chinese_title)`，管线继续走搜索流程

**降级策略**：
- 无 dandanplay / extra 数据源注入 → 直接用原标题搜索
- 数据源请求失败 → 回退原标题
- 中文标题与原标题相同 → 跳过转换

### 4.8 v1.7 新增通用模块

为降低面板间重复代码、统一资源生命周期管理，v1.7 抽取了 5 个通用模块，作为业务/基础设施层的可复用组件。

#### 4.8.1 `modules/data_cache.lua` — 本地持久化缓存管理器

| 项 | 内容 |
|----|------|
| 职责 | 缓存所有 API 响应数据到 `~~/staff-credits-data-cache.json`，跨进程重启保留 |
| 接口 | `save(path, data_type, data)` / `load(path, data_type)` / `remove_path(path)` / `clear_all()` / `has_cache(path, data_type)` |
| 缓存键 | `{path_hash}_{data_type}`（path_hash 为 DJB2 变种哈希低 16 位，4 位十六进制） |
| data_type | `characters` / `persons` / `detail` / `production_score` / `subject` |
| TTL | 默认 30 天（`data_cache_days` 可配，`0` 表示永不过期） |
| LRU 淘汰 | 超过 200 条时按 `_ts` 时间戳删除最旧条目，删到 180 条 |
| 原子写入 | 先写 `.tmp` 再 `os.rename`，200ms 防抖（`mp.add_timeout`） |
| 禁用开关 | `opts.enable_data_cache == false` 时所有操作返回 nil |
| init 行为 | `make_init` 注入 opts/deps 后立即调用 `load_from_disk` 载入磁盘缓存 |

#### 4.8.2 `modules/pagination.lua` — 通用翻页组件

| 项 | 内容 |
|----|------|
| 职责 | 供 `staff_grid.lua` 和 `cards.lua` 复用的翻页按钮组件 |
| 接口 | `compute_layout` / `render` / `hit_test` / `on_click` |
| 依赖 | 纯函数组件，无 `mp` 依赖，`ass_lib` 作为参数传入 |
| 位置策略 | 支持 `pagination_position`（top/middle/bottom），默认 bottom（距底部提示栏 40px，避开 uosc 控制条） |
| 按钮尺寸 | 基础值 100×32，按 `ui_scale` 缩放 |
| 三态显示 | 禁用（`1A1A20`/`606060`/`80`）/ 默认（`2A2930`/`88C0FC`/`C0`）/ 悬停（`3A3940` + 边框 `88C0FC` 2px / `D0`） |
| 状态计算 | `is_first_page`（offset==0）/ `is_last_page`（offset>=max_offset 或 total==0）/ `max_offset`（按 visible_count 向上取整 -1） |

#### 4.8.3 `modules/overlay_manager.lua` — 通用 Overlay 管理器

| 项 | 内容 |
|----|------|
| 职责 | 统一管理图片 overlay id 分配、添加、移除，避免各面板独立管理导致 id 冲突 |
| 接口 | `alloc_id(panel_name, count)` / `add(id, x, y, bgra_path, w, h)` / `remove(id)` / `remove_all()` / `get_active_ids()` |
| MAX_ID | 62（避免与 mpv 最大值 63 冲突，保留给其他用途） |
| 适用面板 | cards（0-31 角色 / 32-47 CV 头像）、cover_intro（62 单张封面）、staff_grid 等 |
| 文件验证 | `add` 前使用 `mp.utils.file_info` 校验文件存在且大小 > 0，失败返回 false 不调用 `overlay-add` |
| 冲突避免 | 在 `[0, 62]` 区间内寻找连续 count 个空闲 id（`is_overlap` 检查已有区间） |
| 重复分配 | 同一面板重复调用 `alloc_id` 时先释放旧分配再重新分配 |
| 异常保护 | 所有 `mp.commandv` 调用均用 `pcall` 包裹 |
| 加载方式 | 不使用 `make_init` 工厂模式，`require` 即可用 |

#### 4.8.4 `modules/mouse_interaction.lua` — 通用鼠标交互 mixin

| 项 | 内容 |
|----|------|
| 职责 | 统一鼠标订阅/取消订阅、悬停高亮、点击处理 |
| 接口 | `enable(input_service, callbacks)` / `disable()` / `get_current_hover()` / `handle_click(mx, my, callbacks)` |
| 单例模式 | 模块级内部状态（`input_service` / `mouse_callback` / `current_hover`），同一时间只有一个面板可见 |
| 依赖 | 纯逻辑组件，不依赖 `mp` 模块，`input_service` 作为参数传入 |
| 悬停管理 | 内部维护 `current_hover`，变化时触发 `callbacks.on_hover_change(old, new)` |
| callbacks 契约 | `hit_test(mx, my)` 必填；`on_hover_change(old, new)` / `on_click(mx, my)` 可选 |
| 异常保护 | `subscribe` / `unsubscribe` / `on_hover_change` / `on_click` 均用 `pcall` 包裹 |
| enable 行为 | 先调用 `disable()` 清理旧订阅避免重复注册 |

#### 4.8.5 `modules/runtime_config.lua` — 运行时配置持久化

| 项 | 内容 |
|----|------|
| 职责 | 持久化运行时配置到 `~~/staff-credits-runtime-config.json` |
| 接口 | `load()` / `save(key, value)` / `get(key)` / `get_all()` |
| 合并优先级 | `runtime_config` > `opts` > `defaults` |
| 原子写入 | 先写 `.tmp` 再 `os.rename`，200ms 防抖（`mp.add_timeout`） |
| init 行为 | `make_init` 注入 opts/deps 后立即调用 `M.load()` 载入磁盘配置 |
| save 副作用 | 同时更新 `opts[key]`（运行时值），保证后续读取一致 |
| get_all 返回 | `runtime_data` 表的浅拷贝（避免外部修改内部状态） |
| 文件不存在/解析失败 | 静默返回空表，不报错 |

### 4.9 显示名规范化（v1.10）

**目标**：同一个条目在四个面板里显示同一个名字，且一律简体中文；季 / 集作为展示后缀。

#### 4.9.1 统一入口

所有面板的可见标题都走 `search_pipeline.format_display_title(subject, fallback, context)`，
内部转调 `title_normalize.format_subject_title`：

| 面板 | 改造点 |
|------|--------|
| 职员表 `features/staff_credits.lua` | `on_search_success` 改为 `format_display_title(subject, search_title_used, context)` |
| 制作评分 `features/production_score_flow.lua` | 同上；`persons` 阶段兜底标题也改用 `resolve_display_name` |
| 封面简介 `features/cover_intro_flow.lua` | `extract_title_or` → `display_title`（`on_cached_hit` / `on_search_success` 两处） |
| 角色介绍 `features/character_cards.lua` | 同职员表 |
| 搜索结果列表 `modules/menu.lua` | `r.name_cn or r.name` → `resolve_display_name(r)`；副标题（`r.name`）也过繁转简 |
| 制作评分面板 `modules/production_score.lua` | `get_work_title` 走 `resolve_display_name` |
| 封面简介面板 `modules/cover_intro.lua` | `get_name_cn` 走 `resolve_display_name` |

#### 4.9.2 管线新增的 context

`run_subject_pipeline` 在 `on_cached_hit` / `on_search_success` 上**多吐一个 `context`**：

```lua
context = { season_num = ..., episode_num = ... }
```

季、集来自三级来源（按顺序，先到先得）：

1. uosc_danmaku 历史的 `episodeNumber`（或 `episodeTitle` 里的「第 N 话」）
2. `guess.parse_title` 从文件名解析
3. 都没有 → nil，标题不追加后缀

即使弹幕关联已经给出了中文名，也**仍然会**调用 `guess.parse_title` 补季集 ——
这是 v1.9 的行为差异：以前只在拿不到标题时才解析文件名，季集因此经常丢失。

#### 4.9.3 回调签名变化（破坏性，仅内部）

| 回调 | 旧签名 | 新签名 |
|------|--------|--------|
| `on_cached_hit` | `(cached, entry_path)` | `(cached, entry_path, context)` |
| `on_search_success` | `(data, entry_path)` | `(data, entry_path, context)` |
| `fetch_characters_from_source` 回调 | `(ok, chars, persons, err, source)` | 末尾多一个 `subject` |
| `resolve_cached_title` 回调 | `(title)` | `(title, context)` |

Lua 忽略多余实参，旧调用点不会崩，但拿不到 `context` 就拼不出季集后缀。

---

## 5. 配置项

通过 `script-opts/uosc_staff_credits.conf` 覆盖默认值（`modules/defaults.lua`）：

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `api_base_url` | `https://api.bangumi.one` | Bangumi API 单服务器（向后兼容） |
| `api_server` | `""` | 多服务器（逗号分隔，并发搜索） |
| `danmaku_api_server` | `https://api.dandanplay.net` | dandanplay API 服务器 |
| `tmdb_api_key` | `""` | TMDB API Key（base64，可空） |
| `timeout` | `8` | loading 倒计时**显示**超时（秒），仅影响「剩余 Ns」倒计时何时变为"请求超时"提示，不直接掐断网络请求 |
| `request_timeout` | `15` | HTTP 请求真实超时（秒），映射为 curl `--max-time`，直接决定单次网络请求最长等待时间（v1.9.1 从 `timeout` 分离） |
| `debug` | `true` | 调试模式 |
| `max_results` | `10` | 最大搜索结果数 |
| `history_path` | `~~/staff-credits-history.json` | 搜索历史缓存路径 |
| `mpv_path` | `""` | mpv 可执行文件路径（空则自动检测） |
| `user_agent` | `uosc_staff_credits (https://github.com/...)` | HTTP UA |
| `title_replace` | `[JSON 字符串]` | 标题替换规则 |
| `enable_extra_search` | `true` | 启用外部搜索源（dandanplay + 360kan） |
| `data_source` | `auto` | 数据源选择：`bangumi` / `fankuhub` / `auto` |
| `fankuhub_api_base` | `https://fankuhub.com` | fankuhub API URL |
| `image_cache_days` | `30` | 图片缓存有效天数 |
| `data_cache_days` | `30` | 本地数据缓存有效天数（`0` 表示永不过期）（v1.7） |
| `enable_data_cache` | `true` | 是否启用本地数据缓存（`yes`/`no`）（v1.7） |
| `silent_preload_depth` | `all` | 静默预加载深度（`subject`/`characters`/`persons`/`all`）（v1.7） |
| `pagination_position` | `bottom` | 翻页按钮位置（`top`/`middle`/`bottom`）（v1.7） |

**配置优先级**（v1.7）：

```
runtime_config (~~/staff-credits-runtime-config.json)
        ↓ 未命中
script-opts (uosc_staff_credits.conf)
        ↓ 未命中
defaults (modules/defaults.lua)
```

运行时通过菜单修改的配置项会写入 `runtime_config`，下次启动自动合并；同一 key 优先级最高的来源生效。

**硬编码常量**：
- `MAX_ENTRIES = 5000`（history LRU 阈值）
- `DEFAULT_MAX_LAST_SUBJECT_ENTRIES = 50`（state 缓存上限）
- `DEFAULT_COVER_INTRO_CACHE_TTL = 1800`（封面缓存 30 分钟）
- `SCHEMA_VERSION = 4`（servers 配置版本）
- `DATA_CACHE_MAX = 200` / `DATA_CACHE_TARGET = 180`（data_cache LRU 阈值，v1.7）
- `OVERLAY_MAX_ID = 62`（overlay_manager 最大可用 id，v1.7）

---

## 6. 脚本消息路由

dispatcher 注册的脚本消息（共 20+ 个）：

| 消息 | 路由 |
|------|------|
| `main-menu` | `menu.show_main_menu()` |
| `staff-credits` | `feature_staff_credits.fetch()` |
| `character-intro` | `feature_character_cards.fetch()` |
| `cover-intro` | `feature_cover_intro_flow.fetch()` |
| `staff-credits-production-score` | `feature_production_score_flow.fetch()` |
| `staff-credits-search {source} [query]` | source=bangumi → `feature_subject_select`；source=fankuhub/fankuhub_person → `feature_fankuhub_search`（query 为空时打开搜索面板，自动填入中文名） |
| `staff-credits-select {id} {source}` | source=bangumi → `feature_subject_select.handle_bgm_select(id)`；source=fankuhub/fankuhub_person → `feature_fankuhub_search.handle_select(id_str)` |
| `staff-credits-fankuhub-search` | `feature_fankuhub_search.show_search_panel(nil, "fankuhub")`（自动填入中文名） |
| `staff-credits-fankuhub-search-by-person` | `feature_fankuhub_search.show_search_panel(nil, "fankuhub_person")`（自动填入中文名） |
| `staff-credits-loading-close` | `loading_controller.handle_loading_close()` |
| `staff-credits-menu-closed` | `menu.clear_visible_type()` |
| `staff-credits-close` | `panel_registry.close_all() + finish_loading` |
| `staff-credits-open-browser` | 浏览器打开 `https://bgm.tv/subject/{id}` |
| `staff-credits-clear-cache` | `history.remove(dir)` |
| `staff-credits-clear-all` | `history.clear_all()` |
| `staff-credits-settings` | `menu.show_settings_menu()` |
| `staff-credits-servers` | `menu.show_servers_menu()` |
| `staff-credits-servers-move` | `servers.move(from, to)` |
| `staff-credits-servers-toggle` | `servers.toggle(url)` |
| `mp.observe_property("path")` | `dispatcher.path_observer` → 清理状态 + **触发静默加载** |

---

## 7. 数据源优先级

`servers.lua` 管理数据源优先级，持久化到 `~~/staff-credits-servers.json`：

**预设数据源池**（4 个）：
1. `https://api.bangumi.lol` — 镜像（首选）
2. `https://fankuhub.com` — 聚合源
3. `https://api.bangumi.one` — 镜像
4. `https://api.bgm.tv` — 官方

**优先级接口**：
- `get_active_bangumi_servers()` — 已启用的 Bangumi URL 列表（并发搜索用）
- `get_active_sources()` — 已启用的数据源列表（含 type/note）
- `move(from, to)` — 拖动排序
- `toggle(url)` — 切换启用状态

**Schema 版本**：当前 `SCHEMA_VERSION = 4`，支持 v1→v4 自动迁移。

---

## 8. 缓存机制

### 8.1 搜索历史缓存

- 文件：`~~/staff-credits-history.json`
- LRU 淘汰：超过 `MAX_ENTRIES=5000` 时删到 90%（4500 条）
- 按视频目录保存成功的搜索结果

### 8.2 共享状态缓存

- `last_subject_by_path`：按路径隔离的条目缓存
- 上限：`DEFAULT_MAX_LAST_SUBJECT_ENTRIES = 50`
- 路径切换时清理：`state.cleanup_search_cache(path, 50)`

### 8.3 封面简介缓存

- `cover_intro_cache`：按 title 缓存详情数据
- 上限：20 条（LRU）
- TTL：`DEFAULT_COVER_INTRO_CACHE_TTL = 1800`（30 分钟）

### 8.4 图片缓存

- 路径：`%TEMP%/staff_credits_*.bgra` 或 `%TEMP%/cover_*.bgra`
- 格式：BGRA 原始位图（4 字节/像素）
- 有效期：`image_cache_days = 30` 天
- 启动后 5 秒异步清理过期文件（最大扫描 2000 个文件）

### 8.5 本地持久化数据缓存（v1.7）

为减少跨进程重启后的重复网络请求，v1.7 新增本地持久化数据缓存层（`modules/data_cache.lua`）。

| 项 | 内容 |
|----|------|
| 缓存文件 | `~~/staff-credits-data-cache.json` |
| 缓存内容 | API 响应数据（`characters` / `persons` / `detail` / `production_score` / `subject`） |
| 缓存键 | `{path_hash}_{data_type}`（path_hash 为 DJB2 变种哈希低 16 位，4 位十六进制） |
| TTL | 默认 30 天（`data_cache_days` 可配，`0` 表示永不过期） |
| LRU 淘汰 | 超过 200 条时按 `_ts` 时间戳删除最旧条目，删到 180 条 |
| 原子写入 | 先写 `.tmp` 再 `os.rename`，200ms 防抖（`mp.add_timeout`） |
| 禁用开关 | `opts.enable_data_cache == false` 时所有操作返回 nil |

**集成点**：
- 4 个 feature（职员表 / 角色介绍 / 封面简介 / 制作评分）在 `fetch_and_show` 前检查 data_cache，命中且未过期则跳过网络请求，直接进入渲染流程
- `trigger_silent_load` 预取的数据写入 data_cache，下次启动可秒开
- `handle_clear_cache`（清除当前视频缓存）调用 `data_cache.remove_path(path)` 同步清理 5 种 data_type
- `handle_clear_all`（清除全部缓存）调用 `data_cache.clear_all()` 清空整个缓存文件

### 8.6 三级缓存架构（v1.7）

```
┌────────────────────────────────────────────────────┐
│ L1: 内存缓存（state.search_state.last_subject_by_path / │
│     cover_intro_cache）                              │
│     进程级，重启失效，命中零延迟                       │
└──────────────────────┬─────────────────────────────┘
                       ↓ 未命中
┌────────────────────────────────────────────────────┐
│ L2: 本地持久化缓存（data_cache）                     │
│     跨进程重启保留，TTL 30 天，LRU 200→180          │
└──────────────────────┬─────────────────────────────┘
                       ↓ 未命中
┌────────────────────────────────────────────────────┐
│ L3: 网络请求（bangumi / fankuhub / dandanplay 等）   │
│     命中后回填 L1 + L2                               │
└────────────────────────────────────────────────────┘
```

| 层级 | 作用域 | 失效条件 | 写入时机 |
|------|--------|----------|----------|
| L1 内存 | 单进程 | 进程退出 / 路径切换清理 | 管线 `on_search_success` / 静默加载成功 |
| L2 持久化 | 跨进程 | TTL 30 天 / LRU 淘汰 / 手动清除 | feature 拉取成功后 / 静默预加载成功后 |
| L3 网络 | 全局 | — | L1、L2 均未命中时发起 |

---

## 9. 错误处理

### 9.1 统一错误码

```lua
api.ERR_NETWORK = "ERR_NETWORK"  -- 网络层失败（curl 超时、DNS 失败）
api.ERR_HTTP    = "ERR_HTTP"     -- HTTP 层失败（4xx/5xx）
api.ERR_PARSE   = "ERR_PARSE"    -- JSON 解析失败
api.ERR_EMPTY   = "ERR_EMPTY"    -- 请求成功但无数据
```

### 9.2 统一回调契约

所有异步 API 遵循三参契约：
```lua
callback(success, data, err_info)
-- err_info = { code = "ERR_XXX", msg = "..." }
```

### 9.3 错误消息转换

`bootstrap.format_error_message(err_info, default_msg)` 将 err_info 转为中文提示：

| 错误码 | 用户提示 |
|--------|---------|
| `ERR_NETWORK` | "网络错误，请检查连接（超时或 DNS 失败）" |
| `ERR_HTTP` | "服务器错误：{msg}" |
| `ERR_PARSE` | "响应解析失败（服务器返回非 JSON 数据）" |
| `ERR_EMPTY` | "{msg}" 或 "未找到匹配结果" |

### 9.4 降级策略

- **fankuhub 优先（v1.9 统一）**：职员表 / 角色介绍 / 制作评分均优先调用 `fankuhub.search`（一次请求返回角色+职员+图片），fankuhub 无数据时自动回退 bangumi
- fankuhub 失败 → 回退 bangumi
- bangumi 角色无图片 → 搜索同名轻小说（type=1）补图
- 所有数据源失败 → 回退到 Bangumi 条目列表搜索
- API 不可用 → 清除缓存重新搜索

---

## 10. uosc 集成

### 10.1 工具栏按钮

```lua
mp.commandv("script-message-to", "uosc", "set-button", "staff_credits_main", json)
-- json = { icon = "menu_book", tooltip = "Bangumi 工具箱",
--          command = {"script-message-to", "uosc_staff_credits", "main-menu"} }
```

### 10.2 菜单交互

- `open-menu` / `update-menu` / `close-menu` 命令与 uosc 通信
- 智能选择：同类型菜单用 `update-menu` 避免闪烁
- `on_close` 必须为有效命令数组（空数组会报错）

### 10.3 菜单状态机

```lua
menu_state = "idle" | "switching"
```

- `open-menu` 进入 `switching`，100ms 后复位 `idle`
- loading-close 处理器在 `switching` 状态下抑制，避免虚假 close

### 10.4 uosc 控制条

面板显示时禁用 uosc 控制条避免干扰：
```lua
ui_base.disable_uosc()  -- mp.commandv("script-message", "uosc", "disable")
-- 面板关闭时调用 ui_base.enable_uosc()
```

---

## 11. 版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| 1.9.2 | 2026-08-02 | 修复「角色介绍」找不到角色信息：对齐职员表策略，`fetch_characters_from_source` 始终优先尝试 fankuhub.search（不再依赖 active_sources 配置），fankuhub 无角色时回退 bangumi/多源 |
| 1.9.1 | 2026-08-02 | 分离网络请求超时与显示超时：`defaults.lua` 新增 `request_timeout=15`（curl `--max-time`），`timeout=8` 仅用于 loading 倒计时显示；职员表 / 制作评分 `fetch_and_show` 增加 fankuhub 优先路径，解决「正在获取职员…」卡 7s 超时失败 |
| 1.9 | 2026-08-01 | 修复 overlay 叠加显示（`finish_silent` 立即关闭 loading 菜单 + 4 面板防御性 `close_menu`）；`timeout` 由 15s 降至 8s；fankuhub 快速路径跳过搜索；bangumi `characters`/`persons` 并行请求 |
| 1.7.3 | 2026-07-31 | 修复 staff_grid 未定义 `is_visible` 导致 panel_registry 注册失败，ASS overlay 面板互斥失效；统一各面板快捷键（←→ 翻页）和右上角关闭按钮 |
| 1.7 | 2026-07-31 | 增强缓存、UI 组件与配置（data_cache、pagination、overlay_manager、mouse_interaction、runtime_config） |
| 1.6 | 2026-07-31 | 多数据源支持（fankuhub/anilist/mal/baike 兼容接口）、SSL/TLS 修复 |
| 1.3 | 2026-07-31 | 自动搜索加载、番库搜索、BGM 中文名自动填充 |

---

## 12. ADR 架构决策记录

| ADR | 主题 | 简述 |
|-----|------|------|
| ADR-01 | search_pipeline 抽离 | main.lua 只保留入口 |
| ADR-02 | cancel_fns 抽出 | 独立 `request_registry` 模块 |
| ADR-03 | state 拆分 | `loading_state` / `search_state` 分离 |
| ADR-04 | panel_registry | 消除 ui_base 反向依赖业务面板 |
| ADR-06 | request_registry | 集中管理 cancel_fn |
| ADR-07 | loading_controller | 抽离加载流程，loading_state 单写者 |
| ADR-08 | features 层 | 从 main.lua 迁移业务编排 |
| ADR-09 | features 业务编排 | dispatcher 仅路由，业务下沉 features |
| ADR-10 | 统一 init 接口 | `module.init(opts, deps)` 工厂模式 |
| ADR-11 | bootstrap 装配 | 配置/加载/DI/事件全迁移 |

---

## 13. 测试与验证

### 13.1 语法校验

```powershell
Get-ChildItem -Path .\scripts\uosc_staff_credits -Recurse -Filter *.lua |
  ForEach-Object { luajit -b $_.FullName }
```

### 13.2 真机验证项

- [ ] mpv 启动无报错
- [ ] Bangumi 工具箱菜单可正常打开/关闭
- [ ] 角色介绍面板可显示/关闭/ESC/翻页
- [ ] 封面简介面板可显示/关闭/ESC
- [ ] 制作评分面板可显示/关闭/ESC/上下切换人员
- [ ] 网站优先级菜单可拖动排序/切换启用
- [ ] 路径切换时所有面板正确关闭
- [ ] ESC 加载菜单可取消请求
- [ ] 图片下载和缓存正常工作
- [ ] ASS overlay 面板互斥（打开新的关闭旧的）
- [ ] uosc 菜单与 ASS overlay 可堆叠显示

---

## 14. 相关文档

- [项目设计文档 (DESIGN.md)](./DESIGN.md) — 架构分层、设计模式、ADR
- [项目 UI 文档 (UI.md)](./UI.md) — 面板布局、ASS 渲染、颜色方案
- [ASS 绘图与职员表生命周期](./ASS_RENDERING.md) — mp.assdraw 圆角绘制、职员表渲染和验证流程
- [Bangumi API 文档](../../../scripts/uosc_staff_credits/docs/bangumi_mirror_api.md)
- [fankuhub API 文档](../../../scripts/uosc_staff_credits/docs/fankuhub_api.md)
