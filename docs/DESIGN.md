# uosc_staff_credits 项目设计文档

> 版本: 1.9.2  ·  最后更新: 2026-08-02
>
> ⚠️ **本文档是 v1.9.2 的历史快照，正文未随代码更新。**
> 文中描述的 `fankuhub` 聚合源已于 v2.0 移除（同时删除 `data_source` /
> `fankuhub_api_base` 配置项、`staff-credits-fankuhub-search` 路由、
> `apis/fankuhub.lua` / `features/fankuhub_search.lua`）。
> 移除详情见 `REVIEW_AND_MERGE.md` §12；现行配置见 `CONFIGURATION.md`。

---

## 1. 架构总览

### 1.1 分层模型

项目严格遵循「表示层 → 业务层 → 数据层 → 基础设施层」自上而下的单向依赖：

```
┌──────────────────────────────────────────────────────────────┐
│ 表示层 (Presentation)                                         │
│  main.lua                    脚本入口（仅 pcall bootstrap）   │
│  app/bootstrap.lua           组合根：配置/模块加载/DI/事件      │
│  app/dispatcher.lua          脚本消息/按键/observer 路由        │
│  modules/menu.lua            uosc 菜单 JSON 生成               │
├──────────────────────────────────────────────────────────────┤
│ 业务逻辑层 (Service / Feature)                                │
│  features/*.lua              用户用例编排                      │
│  app/search_pipeline.lua     搜索管线协调器                     │
│  app/loading_controller.lua  加载流程控制器                     │
├──────────────────────────────────────────────────────────────┤
│ 数据访问层 (Data / API)                                       │
│  modules/api.lua             Bangumi API 通信层                │
│  apis/*.lua                  外部数据源封装                     │
│  modules/servers.lua         数据源优先级配置                   │
│  modules/history.lua         历史缓存                           │
│  modules/guess.lua           标题解析                          │
│  modules/name_resolver.lua   名称优先级解析                     │
├──────────────────────────────────────────────────────────────┤
│ 基础设施层 (Infrastructure)                                   │
│  modules/utils/*.lua         net/io/image/path/url            │
│  modules/utils/module_loader.lua  模块工厂                     │
│  modules/notify.lua          统一 OSD 提示                     │
│  modules/ass_lib.lua         ASS 绘图辅助                      │
│  modules/types.lua           数据结构类型守卫                  │
│  modules/ui_base.lua         UI 模块公共基础设施                │
│  modules/panel_registry.lua  面板注册中心                      │
│  modules/input_service.lua   鼠标输入服务                      │
│  modules/defaults.lua        默认配置                          │
│  app/state.lua               应用状态表（纯数据）              │
│  app/request_registry.lua    请求取消注册中心                  │
│  modules/cards.lua           角色卡片 ASS 渲染                  │
│  modules/cover_intro.lua     封面简介 ASS 渲染                  │
│  modules/production_score.lua 制作评分 ASS 渲染                │
│  -- v1.7 新增通用组件 --                                      │
│  modules/data_cache.lua      本地持久化数据缓存                │
│  modules/pagination.lua      通用翻页组件                      │
│  modules/overlay_manager.lua 通用 Overlay 管理器               │
│  modules/mouse_interaction.lua 通用鼠标交互 mixin              │
│  modules/runtime_config.lua  运行时配置持久化                  │
└──────────────────────────────────────────────────────────────┘
```

**强制约束**：
- 依赖只能自上而下，上层可引用下层，反之禁止
- 每层间通过 `init(opts, deps)` 接口解耦，禁止直接 `require` 业务实现
- 基础设施层向所有上层提供无副作用工具，不可导入任何业务层模块

---

## 2. 依赖注入机制

### 2.1 组合根：bootstrap.lua

`app/bootstrap.lua` 是唯一的组合根（Composition Root），完成所有装配工作。

**核心流程**：

```
load_options()                    # 合并 defaults + script-opts
   ↓
safe_require 基础设施层            # 失败 return false
   ↓
safe_require 核心模块              # 按依赖顺序加载
   ↓
safe_require API 数据源（optional）
   ↓
safe_require features（optional）
   ↓
init_module(mod, opts, deps)      # 对每个模块调用 init
   ↓
loading_controller.init(deps)
search_pipeline.init(deps)
feature_*.init(deps)
dispatcher.init(deps)
   ↓
dispatcher.register_all()         # 注册所有事件
```

### 2.2 模块工厂：module_loader.lua

提供 4 个工厂函数，全部基于闭包封装：

#### `make_init(name, deps_schema)`

返回 `(opts, deps, init)` 三元组。是 ADR-10 推荐的标准 init 工厂。

```lua
local opts, deps, init = utils_mod.make_init("api", {
    request_registry = "table",
    guess = "table",
    notify = "table",
    servers = "table",
})
api.init = init
```

特点：
- **单次初始化**：`initialized` 标志防止重复 init
- **schema 校验**：deps_schema 声明每个依赖的期望类型，类型不匹配仅 warn 不阻断
- **闭包封装**：opts/deps 是 upvalue，模块外无法直接修改

#### `make_feature_init(name, deps_schema)`

返回 `(deps, init)` 二元组，专为 features 层设计。与 `make_init` 区别是**不接收 opts**（配置通过 state/menu 等依赖间接传递）。

#### `make_set_opts(initial)`

返回 `(opts, set_opts)` 二元组，用于旧式 set_opts 接口兼容。

#### `safe_require(name, optional)`

pcall 保护的 require，可选模块失败仅 warn。

### 2.3 依赖表示例

不同模块注入的 deps 不同：

| 模块 | 注入的 deps |
|------|-------------|
| `api` | `{request_registry, guess, notify, servers}` |
| `menu` | `{servers}` |
| `cards` / `cover_intro` | `{ui_base, panel_registry, input_service}` |
| `production_score` | `{ui_base, panel_registry, input_service, api, request_registry}` |
| `fankuhub` | `{guess}` |
| `loading_controller` | `{menu, ui_base, notify, opts, script_name}` |
| `search_pipeline` | `{api, dandanplay, extra, fankuhub, guess, notify, opts, servers, state, request_registry, menu, history, name_resolver, loading_controller, get_danmaku_info, get_current_title, debug_log}` |
| `feature_staff_credits` | `{notify, state, menu, api, name_resolver, loading_controller, history, request_registry, search_pipeline, fallback_to_subject_list_search, fankuhub}` |
| `feature_cover_intro` | `{notify, state, menu, api, cover_intro, cards, production_score, name_resolver, loading_controller, request_registry, search_pipeline, get_danmaku_info, get_current_title, opts, fankuhub, COVER_INTRO_CACHE_TTL=1800, debug_log}` |
| `dispatcher` | 完整模块表 + `{opts, ui_base, notify, COVER_INTRO_CACHE_TTL=1800, MAX_LAST_SUBJECT_ENTRIES=50}` |

### 2.4 闭包函数注入

bootstrap 还注入若干闭包函数，捕获 `bootstrap.modules` 上下文：
- `format_error_message(err_info, default_msg)` — 错误码转中文提示
- `debug_log(...)` — 受 opts.debug 门控
- `get_current_title()` — 调用 `guess.parse_title()`
- `get_danmaku_info()` — 读取弹幕关联信息（`danmaku_link.get_info()`：实时广播 → user-data → 历史文件）
- `fallback_to_subject_list_search(title, source, danmaku_info)` — 搜索失败回退

---

## 3. 面板模块工厂：make_panel_module

文件：`modules/ui_base.lua`（586-664 行）

### 3.1 工厂签名

```lua
function ui_base.make_panel_module(name, target)
    local M = target or {}            -- 允许传入已存在的模块表
    M.name = name
    M.visible = false
    M.key_bindings = {}
    M._osd_unregistrers = {}
    M._deps = nil
    M._cleanup_fn = nil
    -- 注入 7 个公共方法
    M.register_keys = ...
    M.unregister_keys = ...
    M.register_osd_observers = ...
    M.unregister_osd = ...
    M.set_cleanup = ...
    M.close = ...
    M.init_panel = ...
    return M
end
```

**设计精髓**：`target` 参数允许传入已存在的模块表（如 `cards`），工厂在其上注入公共方法，**保留模块自身的所有自定义字段**。

### 3.2 注入的 7 个公共方法

| 方法 | 职责 |
|------|------|
| `register_keys(key_defs)` | 批量注册按键，先 unregister 旧绑定 |
| `unregister_keys()` | 批量移除所有按键绑定 |
| `register_osd_observers(on_change, properties, debounce_ms, is_visible)` | 注册 OSD 属性观察者（osd-width/height 变化时重渲染） |
| `unregister_osd()` | 注销所有 OSD 观察者 |
| `set_cleanup(cleanup_fn)` | 注册模块特定清理回调 |
| `close()` | 通用骨架：`visible=false → cleanup_fn() → unregister_keys() → unregister_osd() → enable_uosc()` |
| `init_panel(deps, panel_interface)` | 存储 deps，自注册到 panel_registry |

### 3.3 三个面板使用模式

```lua
local base_init = init  -- 保存 make_init 返回的 init
function cards.init(new_opts, new_deps)
    base_init(new_opts, new_deps)                       -- 1. 调用原始 init 注入 opts/deps
    deps.ui_base.make_panel_module("cards", cards)      -- 2. 注入公共方法到 cards 表
    cards.set_cleanup(function()                        -- 3. 注册模块特定清理
        state.visible = false
        state.render_version = state.render_version + 1
        abort_in_flight_downloads()
        clear_image_overlays()
        if state.overlay then state.overlay:remove() end
        -- ...kill timers, off mouse_move
    end)
    cards.init_panel(deps, {                            -- 4. 自注册到 panel_registry
        is_visible = cards.is_visible,
        close = cards.close,
    })
end
```

**达成的目标**：
- **样板消除**：按键注册/OSD 监听/close 骨架完全复用
- **依赖反向消除**：面板自注册到 `panel_registry`，`ui_base` 无需反向 require 业务模块
- **状态隔离**：每个面板的 state 是独立的 local 表

---

## 4. 面板注册中心：panel_registry.lua

文件：`modules/panel_registry.lua`（107 行）

### 4.1 数据结构

```lua
local panels = {}  -- { [name] = { is_visible = function, close = function } }
```

**关键修复**：V4-P3 移除了 `__mode = "v"` 弱值元表。原因是各面板 init 时注册的是新建临时表，弱值模式下会被 GC 回收，导致 `close_all_except` 遍历不到面板，旧面板无法关闭，与新面板叠加显示。面板模块由 `package.loaded` 强引用，不会真正泄漏。

**v1.7.3 修复**：`staff_grid.lua` 未定义 `M.is_visible` 函数，导致 `register` 校验失败（`panel.is_visible` 非 function），staff_grid 未注册到 `panels` 表。其他面板调用 `close_all_except` 时无法关闭 staff_grid，导致 ASS overlay 堆叠显示。修复方式：添加 `function M.is_visible() return state.visible end`，与 cards/cover_intro/production_score 保持一致。

### 4.2 接口

| 接口 | 说明 |
|------|------|
| `register(name, panel)` | 校验 name/panel（含 `is_visible`/`close` 函数），存入 panels 表 |
| `unregister(name)` | 注销面板（一般不调用） |
| `get_panel(name)` | 获取面板对象 |
| `list()` | 列出所有已注册名称（调试用） |
| `close_all_except(except)` | **互斥核心**：关闭其他所有可见面板 |
| `close_all()` | 关闭所有可见面板 |

### 4.3 互斥机制

**设计原则**：
- **ASS overlay 之间互斥**：4 个 ASS overlay 面板（staff_grid/cards/cover_intro/production_score）同一时间仅一个可见
- **uosc 菜单与 ASS overlay 可堆叠**：两者独立渲染层，不互相关闭
- **uosc 菜单内部互斥**：由 `menu.lua` 的 `menu_visible_type` 影子副本管理

**调用链**：各 ASS overlay 的 `show()` → `deps.ui_base.close_other_panels(name)` → `panel_registry.close_all_except(name)` → 遍历 `panels` 表，关闭除 `name` 外所有 `is_visible() == true` 的面板。

```lua
function panel_registry.close_all_except(except)
    local closed_count = 0
    for name, panel in pairs(panels) do
        if name ~= except then
            local ok_visible, visible = pcall(function() return panel.is_visible() end)
            if ok_visible and visible then
                local ok_close, err = pcall(panel.close)
                if ok_close then closed_count = closed_count + 1
                else msg.warn(...) end
            end
        end
    end
    return closed_count
end
```

**关键设计**：
- 每个 close 都用 `pcall` 包裹，单个面板关闭失败不中断后续
- `is_visible` 检查避免对已隐藏面板做无谓 close

**使用入口**：
- 面板 `show()` 内部调用 `ui_base.close_other_panels(self_name)` 关闭其他面板
- `staff-credits-close` 脚本消息和路径切换 observer 调用 `close_all()` 统一关闭

---

## 5. 状态管理：app/state.lua

文件：`app/state.lua`（146 行），纯数据表模块。

### 5.1 三大状态结构

```lua
state.loading_state = {
    loading = false,           -- 是否正在加载
    loading_timer = nil,       -- mp.add_periodic_timer 句柄
    loading_start_time = 0,    -- 计算剩余时间
    loading_menu_type = nil,   -- 当前加载菜单类型
}

state.search_state = {
    current_path = nil,        -- 当前视频路径
    last_search_query = nil,   -- 最近一次搜索关键词
    last_subject_by_path = {}, -- 按 path 隔离的条目缓存
    cover_intro_cache = {},    -- 封面缓存 LRU（限 20 条，TTL 30 分钟）
}
```

**关注点分离（ADR-03）**：原 state 表混合三类关注点，拆分后各表职责单一，降低误用风险。

### 5.2 所有权规则（FF-4 单写者）

| 状态字段 | 唯一写者 |
|---------|---------|
| `loading_state.*` | `loading_controller` |
| `search_state.current_path` | `dispatcher`（path observer） |
| `last_subject_by_path` | features 通过 setter |
| `cover_intro_cache` | features 通过 setter |

### 5.3 6 个 setter 方法

```lua
state.set_current_path(path)
state.set_last_search_query(query)
state.set_last_subject(path, info)
state.clear_search_state(path)
state.set_cover_intro_cache(key, cache)
state.clear_cover_intro_cache(key)
```

设计原则：setter 仅做简单赋值，读取操作仍直接访问字段。

### 5.4 缓存清理函数

- `cleanup_search_cache(current_path, max_entries=50)` — 超阈值清空，仅保留当前路径条目
- `cleanup_cover_intro_cache(ttl_seconds=1800)` — 删除过期封面缓存

由 dispatcher 的 path observer 触发。

### 5.5 缓存层设计（v1.7）

文件：`modules/data_cache.lua`（187 行），本地持久化数据缓存模块。

v1.7 引入三级缓存架构，将 API 响应数据持久化到本地磁盘，减少重复网络请求，加速二次访问。

#### 三级缓存架构

```
┌─────────────────────────────────────────────────┐
│ L1: 内存缓存（state.search_state）               │
│   - last_subject_by_path: path → subject         │
│   - cover_intro_cache: path → {detail, _ts}      │
│   - 进程级，重启失效                              │
│   - cover_intro TTL: 30 分钟                     │
├─────────────────────────────────────────────────┤
│ L2: 本地持久化缓存（data_cache.lua）             │
│   - 缓存文件: ~~/staff-credits-data-cache.json   │
│   - 缓存键: {path_hash}_{data_type}              │
│   - data_type: characters/persons/detail/        │
│                production_score/subject          │
│   - TTL: 30 天（data_cache_days 可配）           │
│   - LRU 淘汰: 超 200 条删到 180 条               │
│   - 原子写入: .tmp + os.rename, 200ms 防抖       │
│   - 跨进程重启持久                               │
├─────────────────────────────────────────────────┤
│ L3: 网络请求（api.lua / apis/*.lua）             │
│   - L1/L2 未命中时发起                            │
│   - 成功响应写入 L2                               │
└─────────────────────────────────────────────────┘
```

#### 缓存查询流程

1. feature 调用 `data_cache.load(path, data_type)` 检查 L2
2. L2 命中且未过期 → 直接使用，跳过网络请求
3. L2 未命中 → 发起网络请求（L3）
4. 网络请求成功 → `data_cache.save(path, data_type, data)` 写入 L2
5. 同时更新 L1 内存缓存（`state.set_last_subject`）

#### 接口

| 接口 | 说明 |
|------|------|
| `save(path, data_type, data)` | 写入缓存，追加 `_ts` 时间戳，触发 LRU + 防抖持久化 |
| `load(path, data_type)` | 读取缓存，TTL 过期返回 nil，剥离 `_ts` 返回纯数据 |
| `remove_path(path)` | 删除指定路径的所有 data_type 缓存（5 种） |
| `clear_all()` | 清空整个缓存并立即持久化（不走防抖） |
| `has_cache(path, data_type)` | 检查键是否存在（不检查 TTL，仅判存在） |

#### 缓存键设计

- **path_hash**：DJB2 变种哈希（初始值 5381，`hash * 33 + byte`），取低 16 位（4 位十六进制大写）
- **避免明文路径**：防止缓存文件包含敏感路径信息
- **data_type 后缀**：`{path_hash}_characters` / `{path_hash}_persons` / `{path_hash}_detail` / `{path_hash}_production_score` / `{path_hash}_subject`

```lua
local function compute_path_hash(path)
    local hash = 5381
    for i = 1, #path do
        hash = (hash * 33 + path:byte(i)) % 65536
    end
    return string.format("%04X", hash)
end
```

#### LRU 淘汰策略

- **触发条件**：缓存条目超过 200 条
- **淘汰目标**：删到 180 条（保留 90%）
- **排序依据**：按 `_ts` 时间戳升序（最旧优先淘汰）
- **执行时机**：每次 `save` 后检查

```lua
local function enforce_lru()
    local count = 0
    for _ in pairs(cache_data) do count = count + 1 end
    if count <= 200 then return end
    -- 按 _ts 升序排序，删除最旧的 (count - 180) 条
    table.sort(entries, function(a, b) return a.ts < b.ts end)
    for i = 1, to_remove do
        cache_data[entries[i].key] = nil
    end
end
```

#### 原子写入机制

```
写入流程:
1. 序列化 cache_data 为 JSON
2. 写入临时文件 ~~/staff-credits-data-cache.json.tmp
3. os.remove(正式文件)
4. os.rename(临时文件, 正式文件)
5. rename 失败时清理临时文件
```

- **200ms 防抖**：`mp.add_timeout(0.2, ...)` 合并多次 save 为一次持久化，避免高频写入
- **原子性**：`os.rename` 是原子操作，避免读写冲突导致文件损坏

#### 缓存清理

- **单路径清理**：`data_cache.remove_path(path)` 删除指定路径的所有 data_type 缓存
- **全量清理**：`data_cache.clear_all()` 清空整个缓存文件
- **集成点**：`handle_clear_cache` 和 `handle_clear_all` 同步清理 L1 + L2

#### 配置项

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `enable_data_cache` | `true` | 是否启用 L2 持久化缓存（false 时 save/load 直接返回 nil） |
| `data_cache_days` | `7` | 缓存 TTL（天），`<= 0` 表示永不过期 |

---

## 6. 请求注册中心：request_registry.lua

文件：`app/request_registry.lua`（102 行），纯逻辑模块。

### 6.1 数据结构

```lua
local cancel_fns = {}        -- 内部 cancel_fn 列表
local cancelling = false    -- cancel_all 进行中标志
```

mpv 的 Lua 是单实例 require 缓存，此状态在脚本生命周期内全局共享。

### 6.2 接口

| 接口 | 说明 |
|------|------|
| `register(fn)` | 注册 cancel_fn；cancelling=true 时立即 pcall(fn) |
| `cancel_all()` | 设 cancelling=true，取出 fns 清空，逐个 pcall(fn)，返回尝试数量 |
| `clear()` | 仅清空列表不调用（请求正常完成时用） |
| `has_pending()` | `next(cancel_fns) ~= nil` |
| `is_cancelling()` | 防御性检查 |
| `size()` | 调试用 |

### 6.3 关键防御：BUG-1.3 修复

```lua
function request_registry.register(fn)
    if type(fn) ~= "function" then return false end
    if cancelling then
        -- cancel_all 期间注册的 cancel_fn 立即调用，避免泄漏
        pcall(fn)
        return false
    end
    table.insert(cancel_fns, fn)
    return true
end
```

**场景**：`cancel_all` 调用 `cancel_fn`（mp.abort_async_command），被 abort 的请求回调可能在 cancel_all 期间触发，回调中发起新请求并 register 新 cancel_fn，但用户已 ESC，新请求不应继续运行。

### 6.4 调用点

`cancel_all` 由三处调用：
- `loading_controller.handle_loading_close()`（用户 ESC）
- `loading_controller.finish()` / `finish_silent()` / `transition_phase()`（请求完成或阶段切换）
- `dispatcher` path observer（路径切换）

---

## 7. 搜索管线：search_pipeline.lua

文件：`app/search_pipeline.lua`（554 行）。

### 7.1 search_subject_enhanced — 多源增强搜索

签名：`search_subject_enhanced(title, season_num, callback, on_progress, skip_extra, subject_type)`

**流程**：
1. 入口校验 → on_progress("searching") 通知调用方
2. 跳过外部搜索的条件：`enable_extra=false` 或 dandanplay/extra 均未注入 或 `skip_extra=true`
3. 并发外部搜索（dandanplay + 360kan）：
   - pending 计数器跟踪未完成的搜索
   - 收集候选 animeTitle / title 到 candidates
   - 所有外部搜索完成（pending=0）后调用 `try_bangumi_with_candidates`
4. 候选选择：用 `guess.best_match_by_jw` 基于 jaro_winkler 选最佳候选（阈值 0.6）
5. Bangumi 并发搜索：用最佳候选（或原始标题回退）调用 `api.search_subject_parallel`
6. 进入详情阶段：`on_progress("detail")` 通知调用方显示倒计时

**回调契约**：`callback(success, result, err_info)`，result 为 `{id, name, name_cn, url}`。

### 7.2 fetch_characters_from_source — 数据源优先级获取角色

签名：`fetch_characters_from_source(title, season_num, on_progress, callback, skip_extra)`

**v1.9.2 统一策略（与职员表 / 制作评分一致）**：只要 fankuhub 模块可用，**始终优先**调用 `fankuhub.search(title)`，不再依赖 `servers.get_active_sources()` 是否包含 fankuhub。fankuhub 无法返回角色时，才回退到原有 bangumi / 多源分发逻辑（`dispatch_fallback`）。

**流程**：
1. **fankuhub 快速路径（优先）**：`try_fankuhub(on_fail)`
   - 一次 `fankuhub.search` 返回 `best.characters`（含角色+声优+图片）
   - 若 `best.characters` 为空 → 调用 `on_fail()` 进入 `dispatch_fallback`（**v1.9.2 关键修复**：此前空角色会直接 `finish_success(空)` 导致"未找到角色信息"）
   - 否则 `finish_success(chars, {}, "fankuhub")`
2. **dispatch_fallback（回退）**：包裹原有 bangumi / 多源遍历逻辑
   - `active_sources` 非空时按优先级遍历（`try_fankuhub` → `try_bangumi`）
   - `active_sources` 为空时回退 `opts.data_source`（`auto`/`fankuhub`/`bangumi`）；`auto` 直接 `try_bangumi`
3. **bangumi 数据源**（fallback 内部）：
   - `search_subject_enhanced` 获取 subject_id
   - `api.get_subject_characters` 获取角色列表
   - 若角色列表为空，回退到 `api.get_subject_persons` + `parse_characters_data`
   - 若角色有图片：`api.get_subject_persons` 合并声优 → callback
   - 若角色无图片：调用 `try_light_novel_fallback` 搜索同名轻小说（type=1）补图
4. **路径校验**：每个回调首行 `if current_path() ~= entry_path then return end`，防止快速切换视频时旧回调污染新状态

> 设计动机（v1.9.2）：早期角色介绍走 `fetch_characters_from_source` 而职员表走独立的 `fankuhub.search` 优先路径，导致两者数据源策略不对称——fankuhub 在 `active_sources` 中未启用时，角色介绍回退到 bangumi `/characters`（常返回空）而职员表正常。统一为"fankuhub 模块可用即优先"后，二者行为一致。

### 7.3 run_subject_pipeline — 通用管线协调器

签名：`run_subject_pipeline(pipeline_opts)`，统一 4 个 feature 入口的通用流程。

**7 步流程**：
1. **入口守卫**：若 loading 已激活则先 `loading_controller.finish()` 重置，然后 `set_loading(true)`
2. **路径解析**：`mp.get_property("path")`，空则 show_error_menu 并 return
3. **缓存查询**：`history.get(dir)` 或 `search_state.last_subject_by_path[path]` 命中则走缓存路径
4. **标题识别**：优先用 `get_danmaku_info()` 的 anime 标题，否则 `get_current_title()` 解析视频标题（管线内部 2 级优先级；feature 入口可先调 `resolve_display_title` 获取完整中文标题，见 §7.4.1）
5. **进度回调创建**：
   ```lua
   local function on_progress(message)
       if message == "searching" then in_search_phase = true
       elseif message == "detail" then
           in_search_phase = false
           loading_controller.show_with_countdown("正在获取详情...", menu_type, title, false)
       elseif in_search_phase then menu.show_loading_menu(message, ...)
       else loading_controller.show_with_countdown(message, ..., true) end
   end
   ```
6. **完成回调创建**：
   - 路径校验 `if search_state.current_path ~= ctx.entry_path then return end`
   - 根据 `keep_loading_after_search` 选择 `transition_phase()` 或 `finish_silent()`
   - 失败则 `fallback_to_subject_list_search`
   - 成功则 `history.save` + `state.set_last_subject` + 调用 `on_search_success`
   - **缓存写入校验（v1.5）**：仅当 `data.id ~= nil` 且 `name`/`name_cn` 至少一个为非空字符串时才写入缓存，避免 fankuhub 兜底返回空标题时污染缓存
7. **调度搜索**：`search_fn(title, season_num, on_progress, on_done, skip_extra)`

**设计精髓**：4 个 feature 只需提供 `menu_type`、`on_cached_hit`、`on_search_success` 等回调，共用整套管线编排逻辑。

### 7.4 中文标题转换 — resolve_chinese_title

签名：`resolve_chinese_title(title, callback)`，集成于 `run_subject_pipeline` 第 4.5 步。

**触发条件**：标题识别后，`utils_mod.is_chinese(title)` 检测 UTF8 中文范围 `[\228-\233][\128-\191]`，未命中才进入转换流程。

**并发数据源**：

| 数据源 | 函数 | 返回中文候选 |
|--------|------|-------------|
| dandanplay | `deps.dandanplay.search(title, cb)` | `candidates = [animeTitle, ...]`，取首个 is_chinese 的 |
| extra (TMDB + 360kan) | `deps.extra.search(title, cb)` | `candidates = [title, ...]`，取首个 is_chinese 的 |
| fankuhub | `deps.fankuhub.search(title, cb)` | `results = [{name_cn, ...}]`，取首个 is_chinese 的 name_cn |

### 7.4.1 统一中文标题获取接口（v1.6）

为解决各 feature 标题获取逻辑不一致问题，新增统一入口：

**`resolve_title_sync()` — 同步获取基础标题（4 级优先级）**

```lua
function M.resolve_title_sync()
    -- 1. 弹幕关联中文名（uosc_danmaku 未暴露时返回 nil）
    -- 2. subject 缓存中文名（独立于 uosc_danmaku，静默预加载或之前搜索的结果）
    -- 3. 文件名解析（guess.parse_title，从 path 提取番剧名）
    -- 4. media-title 兜底（URL 等特殊情况）
    return title, season_num  -- 极端情况返回 "未知条目"
end
```

**`resolve_display_title(callback)` — 异步获取显示标题（含中文转换）**

```lua
function M.resolve_display_title(callback)
    local base_title, season_num = M.resolve_title_sync()
    if utils_mod.is_chinese(base_title) then
        callback(base_title, season_num)  -- 已是中文，直接回调
        return
    end
    resolve_chinese_title(base_title, function(chinese_title)
        callback(chinese_title or base_title, season_num)
    end)
end
```

**`resolve_cached_title(cached, entry_path, callback)` — 缓存条目标题兜底统一入口（v1.6）**

```lua
function M.resolve_cached_title(cached, entry_path, callback)
    -- 1. 优先用缓存条目的 name_cn / name 字段（非空字符串）
    -- 2. 缓存无有效标题时调用 resolve_display_title（4 级优先级 + 中文转换）
    -- 3. 路径校验：异步回调时检查 current_path == entry_path，避免污染
    -- 4. resolve_display_title 不可用时回退 media-title，再兜底 "未知条目"
    callback(title)  -- title 始终为非空字符串
end
```

**设计动机**：
- 各 feature 原标题获取逻辑不一致（cover_intro 仅 2 级，subject_select/fankuhub 4 级，character_cards/staff_credits 仅用缓存字段）
- uosc_danmaku 未暴露时，cover_intro/dispatcher 无法获取中文标题
- 缓存条目（fankuhub 兜底返回）可能无有效标题，需统一兜底流程
- 4 个 feature 的 `on_cached_hit` 中存在近一致的缓存标题判空 + 兜底逻辑（每处 15-20 行重复），抽取 `resolve_cached_title` 消除知识重复

**各 feature 调用约定**：
- **staff_credits / character_cards / production_score_flow**：`on_cached_hit` 中调用 `resolve_cached_title(cached, entry_path, callback)` 统一兜底（v1.6 前为内联重复逻辑）
- **cover_intro_flow**：入口 `M.fetch` 直接调用 `resolve_display_title` 获取中文标题后再查缓存/走管线；`on_cached_hit` / `on_search_success` 中用同步辅助函数 `extract_title_or(subject, fallback)` 提取 subject 标题，无有效标题时用外层 title 兜底（外层已是中文，无需再异步调用 `resolve_cached_title`）
- **subject_select / fankuhub_search**：搜索面板入口调用 `resolve_title_sync` 获取预填标题，再用 `resolve_chinese_title` 异步转换（避免 `resolve_display_title` 重复转换）
- **dispatcher.trigger_silent_load**：调用 `resolve_title_sync` + `resolve_chinese_title` 后静默搜索，独立于 uosc_danmaku

**关键约束**：
- 路径校验：异步回调首行检查 `current_path ~= entry_path` 则 return
- 中文检测：`utils.is_chinese` 命中即跳过转换，避免不必要的网络请求
- 兜底值：极端情况下返回 `"未知条目"`，永不返回 nil/空字符串

### 7.4.2 中文标题转换流程细节

**并发协调**：
```lua
local pending = 0
local done = false
local best_candidate = nil

local function try_finish()
    if done or pending > 0 then return end
    done = true
    callback(best_candidate or title)  -- 失败回退原标题
end

-- 两个数据源各 pending + 1，回调中 pending - 1，并尝试更新 best_candidate
-- pending == 0 时（两源均返回或无源可用）触发 try_finish
```

**降级策略**：
- `deps.dandanplay` 或 `deps.extra` 为 nil / search 非 function → 跳过该源
- 两个源都不可用 → `pending=0` 直接 callback 原标题
- 源请求失败 / 候选无中文 → best_candidate 保持 nil，最终回退原标题
- 已是中文标题 → 跳过整个转换流程（直接 callback）

**关键约束**：
- 单次转换：done 标志防止重复回调
- 路径校验：转换回调中再次检查 `current_path ~= entry_path`，防止切换后旧转换污染新状态
- 日志：受 `opts.debug` 门控的 `debug_log` 输出转换前后的标题

### 7.5 7 大功能编排差异

7 个功能中，5 个走 `run_subject_pipeline` 通用管线，BGM 搜索 / 番库搜索为直接搜索入口（不走管线）。差异仅在 `pipeline_opts`：

| 功能 | feature 文件 | 特殊参数 | on_cached_hit | on_search_success |
|------|-------------|---------|---------------|-------------------|
| **职员表** | `features/staff_credits.lua` | - | 用 cached subject 调职员接口（**fankuhub.search 优先** → bangumi 降级，仅职员） | `build_staff_items` → `menu.show_characters` |
| **角色介绍** | `features/character_cards.lua` | - | 用 cached name 调 `fetch_characters_from_source`（**fankuhub 优先**，与职员表一致）重拉角色 | 调 `cards.show(characters, title)`（仅角色） |
| **封面简介** | `features/cover_intro_flow.lua` | - | 用 cached subject 调 `get_subject_detail` | 写入 `cover_intro_cache`（30 分钟 TTL）→ `cover_intro.show` |
| **BGM 搜索** | `features/subject_select.lua` | 不走管线 | - | 直接 `api.search_subject_parallel` → `menu.show_search_results` |
| **番库搜索** | `features/fankuhub_search.lua` | 不走管线 | - | 直接 `fankuhub.search` / `search_by_person` → `menu.show_search_results` |
| **制作评分** | `features/production_score_flow.lua` | `keep_loading_after_search=true` | 直接进入 persons 阶段（**fankuhub.search 优先** → bangumi 降级） | 进入 persons 阶段（见下） |
| **番剧中文名搜索** | （管线内嵌） | - | - | - |
| **静默预加载** | `app/dispatcher.lua` | `skip_extra=true, subject_type=2` | - | `state.set_last_subject` 写缓存，无 UI |

**关键设计决策**：
- **职员表只展示职员**：`build_staff_items` 过滤 `p.type ~= CHAR_TYPE_CHARACTER`，跳过 type=1 的角色项，避免与角色介绍功能重复。仅调用 `get_subject_persons` 一次请求，不再并发拉取 `get_subject_characters`，减少网络开销
- **角色介绍只展示虚拟角色**：`character_cards.lua` 通过 `fetch_characters_from_source` 获取角色列表，含图片、关系标签、CV 信息
- **BGM 搜索 / 番库搜索自动填入中文名**：打开搜索面板时调用统一接口 `resolve_title_sync`（4 级优先级）获取预填标题，立即显示原始标题，再异步调用 `resolve_chinese_title` 转换为中文名后用 `update-menu` 无缝更新，避免闪烁

**制作评分的两阶段流程**：
1. **阶段 1（搜索条目）**：`run_subject_pipeline` 获取 subject_id，`keep_loading_after_search=true` 让 loading 保持开启
2. **transition_phase**：管线在搜索完成后调用 `loading_controller.transition_phase()`，停定时器 + cancel_all + 清菜单类型，但保持 `loading_state.loading = true`
3. **阶段 2（制作人员）**：feature 调用 `loading_controller.show_with_countdown` 重新启动倒计时，`get_subject_persons` → `classify_persons`（9 组分类）→ 每人 `get_person_works`（并发）→ `calculate_score` → `production_score.show`

**9 个制作组定义**（`features/production_score_flow.lua` GROUP_DEFS）：

| 组名 | 匹配关键词 |
|------|-----------|
| 动画制作 | 动画制作 / アニメーション制作 / Animation Work |
| 系列构成 | 系列构成 / シリーズ構成 |
| 脚本 | 脚本 / 脚本协力 |
| 监督 | 监督 / 总监督 / シリーズ監督 / 監督 |
| 人物设定 | 人物设定 / キャラクターデザイン / 角色设计 |
| 总作画监督 | 总作画监督 / チーフアニメーター / 総作画監督 |
| 音乐 | 音乐 / 音楽 |
| 美术监督 | 美术监督 / 美術監督 |
| 摄影监督 | 摄影监督 / 撮影監督 |

**评分算法**（`calculate_score`）：作品数 × 5，上限 100。

### 7.6 番库搜索 feature — fankuhub_search.lua

文件：`features/fankuhub_search.lua`，封装 fankuhub 聚合源的搜索入口，提供条目搜索 / 人员搜索两个用例，自动填入中文标题。

**与 BGM 搜索的差异**：
| 维度 | BGM 搜索 (`subject_select.lua`) | 番库搜索 (`fankuhub_search.lua`) |
|------|-------------------------------|-------------------------------|
| 数据源 | Bangumi 多服务器并发 | fankuhub 聚合源（单源） |
| 返回字段 | 标准 Bangumi subject | 含完整 characters + actors + images |
| id 类型 | number（Bangumi 数字 id） | 字符串（fankuhub 条目 id） |
| 入口消息 | `staff-credits-search bangumi` | `staff-credits-fankuhub-search` / `staff-credits-fankuhub-search-by-person` |
| 选中后行为 | 写入缓存 → 仅 notify 提示 | 写入缓存 → notify 提示（不直接展示卡片） |

**自动填入中文标题流程**（`show_search_panel`）：

```lua
function M.show_search_panel(suggestion, source)
    -- 1. 获取原始 suggestion（danmaku_info.anime → media-title 兜底）
    if not suggestion or suggestion == "" then
        suggestion = resolve_suggestion()
    end

    -- 2. 立即显示面板（避免延迟感）
    deps.menu.show_search_panel(suggestion, source)

    -- 3. 异步转换为中文标题，转换成功后用 update-menu 更新（避免闪烁）
    if suggestion and suggestion ~= ""
       and deps.search_pipeline
       and type(deps.search_pipeline.resolve_chinese_title) == "function" then
        deps.search_pipeline.resolve_chinese_title(suggestion, function(chinese_title)
            if chinese_title and chinese_title ~= ""
               and chinese_title ~= suggestion then
                deps.menu.show_search_panel(chinese_title, source)
            end
        end)
    end
end
```

**source 分发**：
- `source = "fankuhub"` → 走 `M.search`（条目搜索） → `normalize_results` → `menu.show_search_results`
- `source = "fankuhub_person"` → 走 `M.search_by_person`（人员搜索） → `menu.show_search_results`

**dispatcher 路由分发**：
```lua
-- handle_search 根据 source 分发
if source == "fankuhub" or source == "fankuhub_person" then
    -- 番库搜索路径
    if not query or query == "" then
        feature_fankuhub_search.show_search_panel(nil, source)
    else
        feature_fankuhub_search.search_subject(query, source)
    end
else
    -- Bangumi 搜索路径
    feature_subject_select.show_bgm_search_panel(...) 或 search_subject(...)
end

-- handle_select 根据 source 分发
if source == "fankuhub" or source == "fankuhub_person" then
    feature_fankuhub_search.handle_select(id_str, source)  -- 字符串 id
else
    feature_subject_select.handle_bgm_select(tonumber(id_str), source)  -- 数字 id
end
```

### 7.7 静默预加载 — trigger_silent_load

文件：`app/dispatcher.lua` 的 `trigger_silent_load(path)`，作为 path_observer 的第 7 步自动调用。

**触发条件（三重门控）**：
```lua
if not opts or opts.autoload_with_danmaku ~= true then return end      -- 1. 配置开关
if deps.state.loading_state.loading then return end                     -- 2. 用户未主动操作
if deps.state.search_state.last_subject_by_path[path] ~= nil then return end  -- 3. 缓存未命中
```

**数据流**（v1.6 改用统一标题接口）：
```
path_observer(path)
   ↓
search_pipeline.resolve_title_sync()  -- 4 级优先级同步获取基础标题
   1. get_danmaku_info().anime            (弹幕关联中文名：fork 版实时广播 → user-data → 历史文件)
   2. state.get_last_subject(path).name_cn (subject 缓存中文名，独立于 uosc_danmaku)
   3. get_current_title()                 (文件名解析)
   4. mp.get_property("media-title")      (media-title 兜底)
   ↓
注册 cancel_fn 到 request_registry（路径切换时自动取消）
   ↓
search_pipeline.resolve_chinese_title(base_title, callback)  -- 异步中文转换
   - 中文标题直接 callback 跳过转换
   - 非中文标题并发调用 dandanplay + extra + fankuhub 获取中文候选
   ↓
search_pipeline.search_subject_enhanced(
    title = final_title,           -- 已过中文转换
    season_num = season_num,       -- 来自 get_current_title 的季数
    on_done = 写入 state.set_last_subject,
    on_progress = 空函数（静默，不显示 loading 菜单）,
    skip_extra = true,             -- 标题已过中文转换，跳过外部候选搜索
    subject_type = 2               -- 限定动画类型
)
   ↓
成功 → state.set_last_subject(path, info)，仅 notify.debug 日志
失败 → 仅 notify.debug 日志，完全静默
```

**关键约束**：
- **路径校验**：`on_done` 回调首行检查 `current_path ~= path` 则 return，防止快速切换视频时旧回调污染新状态；`resolve_chinese_title` 回调中也检查路径
- **请求取消**：`cancel_fn` 注册到 `request_registry`，路径切换时由 `cancel_all()` 触发取消
- **完全静默**：`on_progress` 为空函数，不弹任何 OSD、不显示 loading 菜单、不打扰用户
- **降级策略**：uosc_danmaku 未暴露 → 通过 subject 缓存 / 文件名解析获取标题；中文转换失败 → 用原标题搜索；搜索失败 → 仅 debug 日志

**与 ADR-09 的关系**：静默加载是 dispatcher 唯一保留的业务逻辑（其他业务均下沉 features），原因是它必须由 path_observer 直接触发，而 path_observer 本身就是 dispatcher 的职责。`trigger_silent_load` 仅调用 `search_pipeline` 和 `state` 的公共接口，未直接操作 UI 层。v1.6 后改用 `resolve_title_sync` + `resolve_chinese_title`，独立于 uosc_danmaku 工作。

### 7.8 显示名规范化 — modules/title_normalize.lua（v1.10）

文件：`modules/title_normalize.lua`

#### 7.8.1 为什么要有这一层

v1.10 之前，展示名散落在 6 处、各写各的优先级：

| 位置 | 原逻辑 | 问题 |
|------|--------|------|
| `staff_credits.on_search_success` | `name_cn → search_title_used → name` | 只有职员表做了「中文优先」 |
| `production_score_flow.on_search_success` | `name_cn → name → search_title_used` | 顺序与职员表**不一致**，无中文名时退回日文 |
| `cover_intro_flow.extract_title_or` | `name_cn → name → 外层 title` | 拿不到 `search_title_used` |
| `menu.show_search_results` | `r.name_cn or r.name` | 繁体原样显示 |
| `production_score.get_work_title` | `work.name_cn → name` | 繁体原样显示 |
| `cover_intro.get_name_cn` | `detail.name_cn` | 繁体原样显示 |

后果：同一个条目，在四个面板里可能显示出四种不同的名字；繁体条目在部分面板上原样回退。

⇒ v1.10 把「取哪个字段 + 繁转简 + 季集后缀」收敛到一个模块，所有面板共用。

#### 7.8.2 三个对外接口

| 接口 | 用途 | 优先级 |
|------|------|--------|
| `resolve_display_name(entity, fallback)` | 取**单纯的名字**（条目 / 角色 / 职员 / 声优通用） | 显式中文字段（`name_cn` / `name_zh_cn` / `name_zh` / `chinese_name`）→ infobox 中文名 → `fallback` → `entity.name` → `entity.title`，每个候选都过一遍繁转简 |
| `format_subject_title(subject, fallback, season, episode)` | 取**带季集后缀的面板标题** | `resolve_display_name` 的结果 + 「第 X 季」「第 N 集」 |
| `extract_episode_number(text)` | 从「第 12 话」这类文本取集数 | 见 7.8.4 |

`fallback` 之所以排在 `entity.name` **之前**，是为了保留 v1.6 的修复：搜索标题已经过中文转换，而 `entity.name` 很可能是日文原名。

> ⚠️ `resolve_person` 不传 `fallback`：职员的 `name_en` / `name_jp` 只能当兜底。
> 没有中文译名时，日文原名「宮崎駿」对中文用户远好于罗马字「Miyazaki Hayao」。

#### 7.8.3 季 / 集只做展示后缀，不参与搜索

`format_subject_title` 拼出的「第 3 季 / 第 1 集」**只出现在界面文本里**。
调用方仍用不含集数的 `title` 去查 Bangumi —— 把「第 5 集」当条目名去搜会搜不到东西。

已带季数标记的标题不会重复追加，判重覆盖四种写法：

- 阿拉伯：`第3季` / `第3部` / `第3期`
- 中文数字：`第三季`
- 英文：`Season 3`
- 罗马数字：`III`（半角）与 `Ⅲ`（全角）

最后一条是关键：中文正式译名常把季数**嵌进名字里**（「无职转生Ⅲ」「Sword Art Online II」），
不认罗马数字的话会拼成「无职转生Ⅲ ～…～ 第 3 季」这种废话。
罗马数字要求**独立成词**（两侧都不是 `[%w]`），否则 `I` 会命中 `Isekai`、`IX` 会命中 `MIX`。

#### 7.8.4 季集识别：modules/guess.lua 的重写

原实现把季、集识别写成一条 `if/else` 链，六个模式互斥 —— 命中集数就拿不到季数：

```
「进击的巨人 第三季 第05集」→ episode=05，season=nil
「無職転生 III ～…～ - 09」 → episode=09，season=nil（罗马数字没覆盖）
「无职转生 第二部 EP12」    → 中文「第X季 / 第X部」压根没有对应模式
```

v1.10 拆成三步，可叠加：

1. **季 + 集同时命中**：`S01E02`、`2x05`（季数 ≤30，避开 `1920x1080` 这类分辨率）
2. **抽集**：`Episode 09` → `EP09` → `第09话` → `第九话` → `[09]` → `- 09`
3. **抽季**（在第 2 步剩下的串上做）：`第3季` → `第三季` → `2nd Season` → `Season 3` → 独立 `S2`

顺序上「2nd Season」必须排在「Season X」**之前**，否则
`Re:Zero 2nd Season - 26` 会被后面那个 `- 26` 误读成第 26 季。

罗马数字（半角 `III` / 全角 `Ⅲ`）只作为**季数提示**，**不从标题里剥离** ——
中文译名常把它嵌在名字里，剥掉反而搜不到。

#### 7.8.5 ⚠️ Lua 字符类是字节集（本项目第 5 次踩）

`[话集回]` 展开成字节集 `{E8, AF, 9D, E9, 9B, 86, E5, 9B, 9E}`，
于是**任意首字节命中 E5/E8/E9 的汉字**都会被当成集数单位 ——
实测「第 3 阶」的「阶」(`E9 98 B6`) 会被误判成「第 3 集」。
`[一二三四五六七八九十]` 同理（首字节 E4/E5 覆盖大半汉字区）。

⇒ 一律改成「**逐个字面量单位 + 捕获后校验**」：

```lua
local EPISODE_UNITS = { "话", "集", "回", "話" }
local SEASON_UNITS  = { "季", "部", "期" }
```

「第三季 第五集」里有两个「第」，第一个的中文数字段会抓到「三季 第五」这种杂音；
`chinese_number_to_int` 校验失败后**继续往后找下一个「第」**，而不是放弃。

#### 7.8.6 日文新字体转换

共享的繁简字典 `uosc_danmaku/dicts/t2s_chars.lua` 是**繁体 → 简体**，
而日文新字体（shinjitai）很多**既不是繁体也不是简体**，是第三种字形：

```
転（繁 轉 / 简 转）  撃（繁 擊 / 简 击）  変（繁 變 / 简 变）  戦（繁 戰 / 简 战）
```

t2s 查不到它们，所以本仓库自带补充表 `dicts/shinjitai_chars.lua`（约 150 条，
动画标题高频新字体），由 `load_t2s` 在 t2s 加载后**叠加合并**：

- **只补空位、不覆盖**——t2s 里经过验证的繁体映射优先，防止改坏既有行为；
- 补充表缺失只影响新字体字（打 warn），不会禁用整个繁简转换；
- 不含假名，也不含纯日文国字（辻 / 込 / 峠 / 凪 等无对应简体）。

```
無職転生 → 无职转生    呪術廻戦 → 咒术回战
```

新字体转换只作用于**未命中 Bangumi 条目**、靠文件名解析的兜底路径
（含搜索 query 与兜底显示）；命中条目后一律取 `name_cn`，不受影响。

---

## 8. 数据源优先级：servers.lua

文件：`modules/servers.lua`（479 行）

### 8.1 预设数据源池

```lua
local PRESET_SERVERS = {
    { url = "https://api.bangumi.lol", note = "镜像(首选)", type = "bangumi" },
    { url = "https://fankuhub.com",    note = "聚合源",    type = "fankuhub" },
    { url = "https://api.bangumi.one", note = "镜像",      type = "bangumi" },
    { url = "https://api.bgm.tv",      note = "官方",      type = "bangumi", is_official = true },
}
```

**注意**：dandanplay / 360kan / extra 不是 servers.lua 管理的数据源，而是 `apis/` 下的独立模块，仅在 `search_subject_enhanced` 中作为外部搜索源用于获取候选标题。

### 8.2 配置文件与 schema 迁移

- 持久化路径：`~~/staff-credits-servers.json`
- 自定义序列化函数 `serialize_servers_config`：保留 `_schema_version` 字符串键
- `SCHEMA_VERSION = 4`，迁移函数 `migrate_schema(list, from_version)` 支持 v1→v4：
  - v1→v2：补全 enabled/type/is_official 字段
  - v2→v3：补充缺失的预设数据源（如 fankuhub）
  - v3→v4：新增 bangumi.lol 镜像站并插入到列表最前面

### 8.3 优先级管理接口

| 接口 | 说明 |
|------|------|
| `get_all()` | 返回全部服务器（含禁用项） |
| `get_active_bangumi_servers()` | 已启用的 bangumi URL 列表（并发搜索用） |
| `get_active_sources()` | 已启用的数据源列表（含 type/note） |
| `move(from, to)` | 拖动排序 |
| `toggle(url)` | 切换启用状态 |
| `save(immediate)` | 持久化（200ms 防抖） |
| `build_menu_items()` | 构建 uosc 菜单项 |

### 8.4 防抖保存

`save_debounce_timer` 200ms 防抖：用户快速拖动排序时避免每次 on_move 都触发磁盘 IO。init/migration 等关键路径传 `immediate=true` 跳过防抖。

---

## 9. 加载控制器：loading_controller.lua

文件：`app/loading_controller.lua`（278 行）

### 9.1 状态所有权（FF-4 单写者）

`loading_state` 的所有写操作仅由此模块执行：
- `set_loading(flag)` — 写 `loading_state.loading`
- `show_with_countdown` — 写 `loading_start_time` / `loading_timer` / `loading_menu_type`
- `finish` / `finish_silent` / `transition_phase` — 重置上述字段

### 9.2 倒计时实现（timeout 默认 8s，仅显示用）

`show_with_countdown(message, menu_type, title, keep_timer)`：

> **timeout 语义（v1.9.1 澄清）**：此处 `timeout`（默认 `8`）仅控制「剩余 Ns」倒计时何时变为"请求超时，正在等待响应"提示，**不直接掐断** curl 请求。真正的网络超时由 `request_timeout`（默认 `15`，映射 curl `--max-time`）决定，二者已分离。

1. **重置开始时间**：`keep_timer=false` 时 `loading_state.loading_start_time = mp.get_time()`
2. **停止旧定时器**：`stop_loading_timer()`
3. **首次立即显示**：`menu.show_loading_menu(build_msg(), menu_type, title)`，消息格式 `"正在搜索... (剩余 10s)"`
4. **注册 forced ESC binding**（仅首次，`esc_binding_registered` 标志防重复）：
   ```lua
   deps.ui_base.safe_add_key("ESC", "staff_credits_loading_esc", function()
       mp.commandv("script-message-to", deps.script_name, "staff-credits-loading-close")
   end, true)  -- forced=true 优先级高于 mpv 内置 ESC
   ```
5. **每秒刷新定时器**：
   ```lua
   loading_state.loading_timer = mp.add_periodic_timer(1, function()
       if not loading_state.loading then stop_loading_timer(); return end
       local elapsed = mp.get_time() - loading_state.loading_start_time
       local remaining = math.max(0, timeout - elapsed)
       if remaining <= 0 then
           stop_loading_timer()
           if request_registry.has_pending() then request_registry.cancel_all() end
           deps.menu.show_loading_menu("请求超时,正在等待响应(按 ESC 取消)...", menu_type, title)
           return
       end
       deps.menu.show_loading_menu(message .. " (剩余 " .. math.ceil(remaining) .. "s)", menu_type, title)
   end)
   ```

### 9.3 ESC 取消机制

**双轨取消**：
1. **uosc on_close**：加载菜单设置 `on_close = staff-credits-loading-close` 脚本消息
2. **forced ESC binding**：作为备用机制

`handle_loading_close()` 处理流程：
1. `menu.get_state() == "switching"` 时直接 return（open-menu 引发的旧菜单 on_close）
2. `loading=false` 但加载菜单可能仍可见（0.3s 兜底窗口），若 visible 则 close_menu
3. `loading=true`：调用 `finish()`，内部顺序 `loading=false → cancel_all → close_menu`（BUG-1.3 修复顺序）

### 9.4 三种完成方式

| 方法 | 场景 | 行为 |
|------|------|------|
| `finish()` | 请求完成 / ESC / 超时 | 注销 ESC binding + 停定时器 + loading=false + cancel_all + close_menu |
| `finish_silent()` | 请求成功需紧接着打开同类型新菜单 | 停定时器 + loading=false + cancel_all + **立即 `close_menu(MENU_LOADING)`** + 设 0.3s 兜底定时器（检测新 loading 已开始则跳过） |
| `transition_phase()` | fetch_production_score 搜索阶段 → persons 阶段 | 停定时器 + cancel_all + 清菜单类型，**保持 loading=true** 支撑下一阶段倒计时 |

---

## 10. 错误处理体系

### 10.1 统一错误码

```lua
api.ERR_NETWORK = "ERR_NETWORK"  -- 网络层失败
api.ERR_HTTP    = "ERR_HTTP"     -- HTTP 层失败
api.ERR_PARSE   = "ERR_PARSE"    -- JSON 解析失败
api.ERR_EMPTY   = "ERR_EMPTY"    -- 请求成功但无数据
```

### 10.2 统一 err_info 结构

所有错误均以 `{code=..., msg=...}` 表传递：

```lua
local function make_error(code, msg)
    return { code = code, msg = tostring(msg or "") }
end
```

回调契约统一为三参：`callback(success, data, err_info)`。

### 10.3 错误检查辅助

`api.lua` 内部的 `check_api_error(success, data, err_info, cb, empty_msg)` 统一处理：
- `not success` → cb(false, nil, err_info) 透传
- `not data` → cb(false, nil, make_error(ERR_EMPTY, empty_msg))
- `types_mod.validate_api_response(data)` 失败 → cb(false, nil, v_err)

### 10.4 错误消息面向用户转换

`bootstrap.format_error_message(err_info, default_msg)`：

| 错误码 | 用户提示 |
|--------|---------|
| `ERR_NETWORK` | "网络错误，请检查连接（超时或 DNS 失败）" |
| `ERR_HTTP` | "服务器错误：" .. (err_info.msg or "HTTP 错误") |
| `ERR_PARSE` | "响应解析失败（服务器返回非 JSON 数据）" |
| `ERR_EMPTY` | err_info.msg or "未找到匹配结果" |

### 10.5 数据结构类型守卫

`modules/types.lua` 在数据入口校验结构：
- `validate_char` / `validate_person` / `validate_subject` / `validate_api_response`
- 校验失败返回 `(false, nil)` 或 `(false, err_info)`

### 10.6 错误处理原则

- **不静默吞错**：所有 pcall 失败均记录日志
- **路径校验**：所有回调首行 `if current_path() ~= entry_path then return end`
- **降级策略（v1.9 统一 fankuhub 优先）**：职员表 / 角色介绍 / 制作评分均优先走 fankuhub（一次请求返回角色+职员+图片），fankuhub 无数据 → bangumi，bangumi 失败 → 条目列表搜索
- **缓存失效**：API 不可用时清除缓存重新搜索

---

## 11. uosc 集成

### 11.1 工具栏按钮

```lua
local json = utils.format_json({
    icon = "menu_book",
    tooltip = "Bangumi 工具箱",
    command = {"script-message-to", "uosc_staff_credits", "main-menu"}
})
mp.commandv("script-message-to", "uosc", "set-button", "staff_credits_main", json)
```

### 11.2 菜单命令

通过 `mp.commandv("script-message-to", "uosc", cmd, json_props)` 通信：
- `open-menu` — 打开新菜单
- `update-menu` — 更新同类型菜单（避免闪烁）
- `close-menu` — 关闭指定类型菜单

**智能选择**：通过 `menu_visible_type` 影子副本判断（V4-P2-26 修复，降低对 uosc user-data 的依赖）。

### 11.3 菜单状态机（FF-8 单写者）

```lua
local menu_state = "idle"  -- "idle" | "switching"
```

- `open_menu` 进入 `"switching"`，100ms 后自动复位 `"idle"`（覆盖 uosc 异步 on_close 触发窗口）
- `loading_controller.handle_loading_close` 只读消费 `menu.get_state()`，不写入（FF-9）

### 11.4 on_close 处理（关键修复）

uosc 会保留之前菜单的 on_close 回调。修复策略：
- **open-menu**：必须显式设置 on_close，未提供时用 `staff-credits-menu-closed` 清除之前的回调
- **update-menu**：仅在调用方提供时才更新 on_close（保留原菜单的 on_close）

### 11.5 uosc 控制条禁用/启用

```lua
function ui_base.disable_uosc()
    pcall(function() mp.commandv("script-message", "uosc", "disable") end)
end
```

四个 ASS overlay 面板显示时禁用 uosc 控制条避免干扰，关闭时恢复。

---

## 12. ADR 架构决策记录

| ADR | 主题 | 简述 | 影响文件 |
|-----|------|------|---------|
| ADR-01 | search_pipeline 抽离 | main.lua 只保留入口 | app/search_pipeline.lua, main.lua |
| ADR-02 | cancel_fns 抽出 | 独立 `request_registry` 模块 | app/request_registry.lua |
| ADR-03 | state 拆分 | `loading_state` / `search_state` 分离 | app/state.lua |
| ADR-04 | panel_registry | 消除 ui_base 反向依赖业务面板 | modules/panel_registry.lua, modules/ui_base.lua |
| ADR-06 | request_registry | 集中管理 cancel_fn | app/request_registry.lua |
| ADR-07 | loading_controller | 抽离加载流程，loading_state 单写者 | app/loading_controller.lua |
| ADR-08 | features 层 | 从 main.lua 迁移业务编排 | features/*.lua |
| ADR-09 | features 业务编排 | dispatcher 仅路由，业务下沉 features | app/dispatcher.lua, features/subject_select.lua, features/fankuhub_search.lua |
| ADR-10 | 统一 init 接口 | `module.init(opts, deps)` 工厂模式 | modules/utils/module_loader.lua |
| ADR-11 | bootstrap 装配 | 配置/加载/DI/事件全迁移 | app/bootstrap.lua |
| ADR-12 | 中文标题转换 | 集成于管线第 4.5 步，并发 dandanplay + extra，失败回退原标题 | app/search_pipeline.lua, modules/utils.lua（is_chinese） |

---

## 13. 核心设计模式汇总

| 模式 | 应用位置 |
|------|---------|
| **组合根模式** | bootstrap.lua 是唯一装配点 |
| **依赖注入** | 所有模块通过 init 接收 deps，闭包封装 |
| **工厂模式** | make_init / make_feature_init / make_panel_module |
| **注册中心模式** | panel_registry / request_registry |
| **单写者原则（FF-4）** | loading_state 仅 loading_controller 写、menu_state 仅 menu.open_menu 写 |
| **状态隔离** | 每个面板独立 state 表 |
| **路径校验** | 所有异步回调首行校验 `current_path ~= entry_path` |
| **类型守卫** | types.lua 在数据入口校验结构 |
| **三参契约** | `callback(success, data, err_info)` 统一异步回调签名 |
| **降级策略** | fankuhub 失败 → bangumi → 条目列表搜索 |
| **防抖** | servers.save 200ms 防抖 |
| **弱引用警示** | panel_registry V4-P3 移除弱值元表（GC 导致面板丢失） |
| **策略模式（v1.7）** | pagination.lua 翻页按钮位置策略（top/middle/bottom） |
| **单例 + 分配器模式（v1.7）** | overlay_manager.lua 模块级状态 + First-Fit id 分配 |
| **Mixin 模式（v1.7）** | mouse_interaction.lua 通用鼠标交互混入 |
| **三级缓存（v1.7）** | L1 内存 / L2 data_cache 持久化 / L3 网络 |
| **原子写入（v1.7）** | data_cache / runtime_config 的 .tmp + rename 模式 |

---

## 14. 通用组件设计模式（v1.7）

### 14.1 设计目标

v1.7 前，`staff_grid.lua` 和 `cards.lua` 各自独立实现约 100 行高度重复的翻页按钮代码、overlay id 管理、鼠标交互逻辑。v1.7 抽取 3 个通用组件消除重复：

| 组件 | 设计模式 | 复用方 | 消除重复 |
|------|---------|--------|---------|
| `modules/pagination.lua` | 策略模式 | staff_grid.lua、cards.lua | 翻页按钮布局/渲染/命中/点击 |
| `modules/overlay_manager.lua` | 单例 + 分配器模式 | cards.lua（48 id）、cover_intro.lua（1 id） | overlay id 分配/添加/移除 |
| `modules/mouse_interaction.lua` | Mixin 模式 | staff_grid.lua、cards.lua | 鼠标订阅/悬停高亮/点击处理 |

### 14.2 pagination.lua（策略模式）

文件：`modules/pagination.lua`（135 行），纯函数组件。

- **职责**：封装翻页按钮的布局计算、渲染、命中检测、点击处理
- **设计要点**：
  - 纯函数组件，无 `mp` 依赖，`ass_lib` 作为参数传入
  - 支持位置策略（top/middle/bottom）通过 `pagination_position` 配置切换
  - 三态渲染（禁用/默认/悬停）由调用方传入 `state.hover_button`

**4 个接口**：

| 接口 | 说明 |
|------|------|
| `compute_layout(parent_layout, offset, total, visible_count)` | 计算按钮位置（btn_w/btn_h/btn_y/prev_btn_x/next_btn_x）+ 翻页状态（is_first_page/is_last_page/max_offset） |
| `render(ass_parts, layout, state, ass_lib)` | 三态渲染 ◀ ▶ 按钮：禁用（灰底）/默认（深底）/悬停（高亮边框） |
| `hit_test(mx, my, layout)` | 返回 `"prev"` / `"next"` / `nil` |
| `on_click(mx, my, layout, page_up_fn, page_down_fn)` | 命中后调用对应回调 |

**位置策略**：

```lua
local pos = parent_layout.pagination_position or "bottom"
if pos == "top" then
    btn_y = grid_top - btn_h - s(8)        -- 网格顶部上方
elseif pos == "middle" then
    btn_y = grid_top + (grid_h - btn_h) / 2 -- 网格垂直居中
else
    btn_y = hint_y - btn_h - s(40)          -- 底部提示栏上方 40px（避开 uosc 控制条）
end
```

### 14.3 overlay_manager.lua（单例 + 分配器模式）

文件：`modules/overlay_manager.lua`（160 行），通用图片 overlay 管理器。

- **职责**：统一管理 overlay id 分配、添加、移除
- **设计要点**：
  - 模块级状态（`allocations` 表 + `active_ids` 表），无需 init
  - `alloc_id` 采用首次适配（First-Fit）算法在 `[0, 62]` 区间寻找连续空闲 id
  - `add` 含文件验证（`file_info.is_file` + 大小 > 0）+ pcall 包裹 `mp.commandv`
  - `remove_all` 批量清理，面板关闭时统一调用
- **复用方**：cards.lua（48 个 id）、cover_intro.lua（1 个 id）
- **降级机制**：`alloc_id` 失败时调用方使用旧固定 id 逻辑

**id 分配算法**：

```lua
local MAX_ID = 62  -- 63 保留给其他用途
function M.alloc_id(panel_name, count)
    release_allocation(panel_name)  -- 同一面板重复调用时先释放旧分配
    local start_id = 0
    while start_id + count - 1 <= MAX_ID do
        local end_id = start_id + count - 1
        local conflict = false
        for _, range in pairs(allocations) do
            if is_overlap(start_id, end_id, range.start_id, range.end_id) then
                conflict = true; break
            end
        end
        if not conflict then
            allocations[panel_name] = {start_id = start_id, end_id = end_id}
            return {start_id = start_id, end_id = end_id}
        end
        start_id = start_id + 1
    end
    return nil  -- 分配失败
end
```

**接口**：

| 接口 | 说明 |
|------|------|
| `alloc_id(panel_name, count)` | 分配连续 id 范围，返回 `{start_id, end_id}` 或 nil |
| `add(id, x, y, bgra_path, w, h)` | 添加 overlay（含文件验证 + pcall 包裹） |
| `remove(id)` | 移除单个 overlay |
| `remove_all()` | 批量移除所有已添加 overlay |
| `get_active_ids()` | 获取已添加 id 列表（浅拷贝） |

### 14.4 mouse_interaction.lua（Mixin 模式）

文件：`modules/mouse_interaction.lua`（79 行），通用鼠标交互 mixin。

- **职责**：统一鼠标订阅/取消订阅、悬停高亮、点击处理
- **设计要点**：
  - 单例模式（模块级 `internal_state`），同一时间只有一个面板可见
  - `enable`/`disable` 配对调用，`enable` 内部先 `disable` 避免重复订阅
  - 内部维护 `current_hover`，变化时触发 `on_hover_change` 回调
  - 所有回调用 pcall 包裹，避免异常中断

**接口**：

| 接口 | 说明 |
|------|------|
| `enable(input_service, callbacks)` | 订阅鼠标输入，callbacks 含 `hit_test`/`on_hover_change`/`on_click` |
| `disable()` | 取消订阅，清理内部状态 |
| `get_current_hover()` | 获取当前悬停项标识 |
| `handle_click(mx, my, callbacks)` | 处理点击事件（pcall 包裹 `on_click`） |

**悬停状态管理**：

```lua
local function mouse_callback(mx, my)
    local new_hover = callbacks.hit_test(mx, my)
    if new_hover ~= internal_state.current_hover then
        local old = internal_state.current_hover
        internal_state.current_hover = new_hover
        if type(callbacks.on_hover_change) == "function" then
            pcall(callbacks.on_hover_change, old, new_hover)  -- 触发重绘
        end
    end
end
```

### 14.5 设计收益

- **代码量减少**：消除约 200 行重复代码
- **一致性**：翻页按钮位置、三态颜色、悬停行为跨面板统一
- **可维护性**：修改翻页逻辑只需改一处
- **可测试性**：纯函数组件（pagination）可独立测试，无 mp 依赖

---

## 15. 运行时配置持久化（v1.7）

文件：`modules/runtime_config.lua`（99 行），运行时配置持久化模块。

### 15.1 职责

持久化用户在设置菜单中修改的配置项，使配置变更在 mpv 重启后仍然生效。遵循 ADR-10 统一 `init(opts, deps)` 接口。

### 15.2 存储设计

- **存储位置**：`~~/staff-credits-runtime-config.json`
- **合并优先级**：`runtime_config` > `opts`（script-opts）> `defaults`
- **写入策略**：200ms 防抖 + 原子写入（`.tmp` + `os.rename`）

### 15.3 接口

| 接口 | 说明 |
|------|------|
| `init(opts, deps)` | 调用 base_init 注入 opts/deps，再触发 `load()` 从磁盘读取 |
| `load()` | 读取持久化文件到内存表；文件不存在或解析失败时静默返回空表 |
| `save(key, value)` | 更新单个配置项并持久化（200ms 防抖）；同时更新 `opts[key]` 运行时值 |
| `get(key)` | 获取配置项（优先 runtime_data，回退 opts） |
| `get_all()` | 获取所有运行时配置（浅拷贝） |

### 15.4 合并优先级实现

```lua
function M.get(key)
    if runtime_data[key] ~= nil then
        return runtime_data[key]   -- 1. 运行时持久化值（最高优先级）
    end
    if type(opts) == "table" then
        return opts[key]            -- 2. script-opts 配置
    end
    return nil                      -- 3. defaults 由 defaults.lua 在 load_options 时已合并入 opts
end
```

### 15.5 写入策略

`save` 同时做两件事：
1. 写入 `runtime_data[key] = value` 并触发防抖持久化
2. 同步更新 `opts[key] = value`，确保当前会话立即生效（无需重启）

```lua
function M.save(key, value)
    if type(key) ~= "string" or key == "" then return end
    runtime_data[key] = value
    if type(opts) == "table" then
        opts[key] = value           -- 立即生效
    end
    persist()                       -- 200ms 防抖持久化
end
```

**原子写入流程**（与 data_cache.lua 一致）：

```
1. 序列化 runtime_data 为 JSON
2. 写入临时文件 ~~/staff-credits-runtime-config.json.tmp
3. os.remove(正式文件)
4. os.rename(临时文件, 正式文件)
5. rename 失败时清理临时文件
```

### 15.6 集成点

- **读取配置**：`menu.show_settings_menu` 读取配置时优先调用 `runtime_config.get(key)`，而非直接读 `opts`
- **写入配置**：`dispatcher.handle_set_config` 接收 `staff-credits-set-config {key} {value}` 脚本消息，调用 `runtime_config.save(key, value)` 持久化
- **即时生效**：`save` 同时更新 `opts` 运行时值，确保当前会话立即生效，无需重启 mpv

---

## 16. 相关文档

- [项目文档 (PROJECT.md)](./PROJECT.md) — 项目概述、目录结构、配置项
- [项目 UI 文档 (UI.md)](./UI.md) — 面板布局、ASS 渲染、颜色方案
