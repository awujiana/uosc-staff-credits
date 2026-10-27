# uosc_staff_credits 脚本审查与合并评估报告

> 审查对象：`portable_config/scripts/uosc_staff_credits/`（约 21,800 行 / 60 个 Lua 文件）
> 审查目的：① 学习其 OSD 面板与按钮组件实现；② 检查脚本问题；③ 判断与本地 `osd-button` 组件的合并取舍
> 审查日期：2026-10-05
> 结论摘要：**不合并为一个脚本。仅吸收 3 项实现亮点，另有 6 处问题需修。**

---

## 0. 结论速览

| 维度 | 结论 |
|------|------|
| 与 `osd-button` 组件的关系 | **互补而非重复**。本项目已有 3 个通用 UI 组件（`pagination` / `overlay_manager` / `mouse_interaction`），无需引入外部按钮组件 |
| 是否合并 | **不合并**。合并会破坏其单例鼠标模型与纯函数组件约定 |
| 值得吸收 | ① 关闭按钮"绘制+命中"同源；② 位置单位与尺寸单位来源统一；③ 三态按钮配色 |
| 必须修 | 6 处（见 §3），其中 3 处已修复（见 §8） |
| 集成现状 | ✅ 已接入 —— conf / `input.conf` 绑定 / .gitignore 均已补齐（见 §5） |

---

## 1. 项目架构速览

### 1.1 分层

```
main.lua (19 行，仅引导)
  └─ app/
      ├─ bootstrap.lua        启动装配、依赖注入
      ├─ dispatcher.lua       脚本消息路由 + path_observer
      ├─ search_pipeline.lua  搜索管线（含中文标题转换）
      ├─ loading_controller.lua 加载菜单倒计时
      ├─ request_registry.lua 请求注册与取消
      └─ state.lua            全局状态
  └─ features/   业务功能（staff_credits / character_cards / cover_intro_flow /
                 subject_select / fankuhub_search / production_score_flow）
  └─ modules/    UI 与工具（4 面板 + 3 通用组件 + utils/*）
  └─ apis/       数据源适配（bangumi / fankuhub / anilist / mal / baike / dandanplay）
```

### 1.2 三种模块工厂（`modules/utils/module_loader.lua`）

| 工厂 | 返回 | 用途 |
|------|------|------|
| `make_init(name, schema)` | `(opts, deps, init)` | 普通模块，可收配置 |
| `make_feature_init(name, schema)` | `(deps, init)` | features 层，配置经 deps 间接传递 |
| `make_set_opts(initial)` | `(opts, set_opts)` | 旧式兼容 |

均带**单次初始化保护**（重复 init 仅 warn）与 **deps schema 校验**（类型不符仅 warn 不阻断）。

### 1.3 面板模块工厂（`ui_base.make_panel_module(name, target)`）

注入 7 个公共成员，是 4 个面板的统一骨架：

| 成员 | 作用 |
|------|------|
| `register_keys(key_defs)` | 批量注册（先自动 `unregister_keys()`），每项 `{key, name, fn, forced?, opts?}` |
| `unregister_keys()` | 批量移除 |
| `register_osd_observers(on_change, props, debounce_ms, is_visible)` | OSD 属性观察 + 防抖 + 可见性门控 |
| `unregister_osd()` | 注销全部 observer |
| `set_cleanup(fn)` | 注册模块私有清理回调 |
| `close()` | 通用关闭骨架：`visible=false → cleanup → unregister_keys → unregister_osd → enable_uosc` |
| `init_panel(deps, iface)` | 存 deps 并自注册到 `panel_registry` |

**面板互斥**由 `panel_registry.close_all_except(name)` 实现：先收集待关闭列表再逐个 `pcall(close)`，避免遍历中改表。

### 1.4 关键约定：`ui_scale` 与 overlay 分辨率

```lua
ui_scale = osd_w / 1920            -- 以 1920 为基准（注意是宽，不是高）
s(v) = math.floor(v * ui_scale)
overlay.res_x = osd_w              -- 必须等于 osd_w
overlay.res_y = osd_h              -- 必须等于 osd_h
```

> ⚠️ 与 `chapterskip.lua` 的差异：后者用 `scale = 高度 / 1080`，本项目用 `ui_scale = 宽 / 1920`。
> 16:9 下两者等价；**非 16:9 或非 1080p 时不等价**。这是本项目既有约定，跨项目搬代码时需换算。

---

## 2. 值得吸收的实现亮点（3 项）

### 2.1 关闭按钮：绘制与命中共用同一份坐标 ✅

```lua
-- 渲染时写入：state.close_btn = {x = close_x, y = close_y, size = close_size}
-- 命中时直接读：
if state.close_btn then
    local cb = state.close_btn
    if mx >= cb.x and mx < cb.x + cb.size
       and my >= cb.y and my < cb.y + cb.size then
        M.close()
        return
    end
end
```

**做对了什么**：命中矩形不是另算一套，而是**渲染时把矩形存进 state，命中时直接复用**。
彻底消除"绘制坐标改了、命中坐标忘了改"的漂移——这正是按钮"位置不偏"的根本保障。

> 对比 `chapterskip.lua`：那里是每次命中时用公式**重新推导** `button_x/button_y`，两处公式必须永远同步。
> 本项目"存储而非重算"更稳，值得反向吸收。

### 2.2 位置与尺寸全部源自同一组 `s()` ✅

```lua
local s = layout.s                              -- 由 osd_w 派生的缩放函数
local close_size = layout.s(28)                  -- 尺寸
local close_x = layout.start_x + layout.total_w + layout.s(12) - close_size  -- 位置
local close_y = layout.title_y                   -- 位置
```

尺寸与位置**用同一个 `s()`**，因此窗口缩放时两者同比例变化，不存在"字变大了、边距没变"的错位。
这正是 `chapterskip.lua` 中 `scale` 单一基准的同构做法，但本项目把它封装进 `layout.s` 更整洁。

### 2.3 三态按钮配色 + 九宫格布局语义 ✅

`pagination.lua` 的三态（禁用 / 默认 / 悬停）是干净的可复用设计：

| 状态 | 背景 | 文字 | 边框 | Alpha |
|------|------|------|------|-------|
| 禁用（首页/末页） | `1A1A20` | `606060` | 无 | `80` |
| 默认 | `2A2930` | `88C0FC` | 无 | `C0` |
| 悬停 | `3A3940` | `88C0FC` | `88C0FC` 2px | `D0` |

且支持 `pagination_position = top/middle/bottom`，`bottom` 特意 **上移 40px 避开 uosc 控制条**——
这是"按钮不被遮挡"的实战经验，可移入 `osd-button` 作为默认避让策略。

---

## 3. 发现的问题（6 处，按严重度排序）

### 🔴 P1-1：`state.hover_button` 未在状态表中初始化

**证据**：

```lua
-- modules/staff_grid.lua:44-55  状态表只有 hover_index，没有 hover_button
local state = {
    visible = false, items = {}, title = "", offset = 0,
    layout = nil, overlay = nil, render_version = 0,
    hover_index = 0,       -- 由 mouse_interaction 管理
    close_btn = nil,
}

-- :346  show() 里才第一次赋值
state.hover_button = nil

-- :441  清理时才赋值
state.hover_button = nil
```

**影响**：`pagination.render()` 首行执行 `local hover_button = state.hover_button`（读 nil，Lua 中合法），
渲染层不会崩；但 `state.hover_index = 0` 与 `hover_button = nil` 语义上应同时初始化。
目前靠"nil 读取合法"侥幸通过，属**隐性依赖**，一旦有人在 `pagination.render` 里写
`#state.hover_button` 或 `state.hover_button:sub(...)` 就会崩。

**修复**：在状态表初始化处补一行

```lua
hover_button = nil,    -- 由 pagination/mouse_interaction 管理（"prev"/"next"/nil）
```

---

### 🟠 P2-2：`show(new_deps, items, title)` 首参实为废弃参数，文档未同步

**证据**（修复前的原始代码）：

```lua
-- modules/staff_grid.lua:323（修复前）
function M.show(new_deps, items, title)
    -- new_deps 是签名参数（cards 模块使用闭包注入的 deps），此处忽略
```

**调用方**（修复前）：

```lua
-- features/staff_credits.lua:104 与 :222
deps.staff_grid.show(deps, items, title)
```

**影响**：传入的 `deps` 被**静默丢弃**，函数体改用 upvalue `deps`（来自 `make_init`）。
功能上正确，但签名与行为不符，极易误导后续维护者以为传参生效（例如想给某次调用传临时配置）。

**状态**：✅ 已修（2026-10-05）—— 签名改为 `show(items, title)`，两处调用同步。

**修复**（二选一）：
- **推荐**：调用方改为 `deps.staff_grid.show(items, title)`，签名同步为 `show(items, title)`
- 或：保留签名但加注释说明"首参仅为兼容旧签名，实际使用模块级 deps"

---

### 🟠 P2-3：`register_osd_observers` 每次 `show()` 都重新注册

**证据**（修复前的原始代码）：

```lua
-- modules/staff_grid.lua:375-379（修复前）
M.unregister_osd()
M.register_osd_observers(function()
    if state.visible then render() end
end, {"osd-width", "osd-height"}, 100, M.is_visible)
```

**影响**：每次打开面板都 `unobserve` + `observe` 一遍，产生无谓的属性订阅抖动；
且 `ui_base` 内部闭包 `debounce_timer` 每次重建，若上一次的防抖定时器尚未触发，
旧 `unreg_fn` 虽被调用但其闭包已与新实例解耦——存在**防抖定时器泄漏**的边界风险。

**状态**：✅ 已修（2026-10-05）—— 移至 `M.init()` 一次性注册。
`is_visible` 门控已能保证不可见时不重绘，无需在 `show()` 里重建。

---

### 🟠 P2-4：关闭按钮未纳入 `mouse_interaction` 的 `hit_test`

**证据**：

```lua
-- :143-151  on_mouse_click 里手动优先检测关闭按钮
if state.close_btn then ... M.close() ... end
pagination.on_click(...)
```

但 `hit_test`（`:379-400`）**只返回翻页按钮与单元格**，不含关闭按钮。

**影响**：鼠标移到右上角 ✕ 上**不会高亮**（`hit_test` 返回 nil → `hover_index=0`）；
用户无法从视觉上确认 ✕ 可点。功能可用（点击走 `on_mouse_click`），但交互反馈缺失。

**修复**：`hit_test` 中加入关闭按钮分支，返回标识 `"close"`，
并在 `on_hover_change` 中据此渲染 ✕ 的悬停色（`E06C75` 红色，UI.md 6.1 已定义该色但未使用）。

---

### 🟡 P3-5：ui_scale 基准（宽/1920）与 chapterskip 基准（高/1080）不统一

本项目 4 个面板统一 `ui_scale = osd_w / 1920`，`chapterskip.lua` 统一 `scale = h / 1080`。
16:9 下二者恒等，但：
- **21:9 超宽屏**：本项目 `ui_scale` 偏大 → 元素显得偏大
- **4:3 屏**：本项目 `ui_scale` 偏小 → 元素显得偏小

**不影响本项目内部一致性**（4 面板同基准），但**跨项目搬按钮组件时必须换算**，
否则会出现"照抄过来尺寸不对"的假 bug。

**修复**：无需改代码，但**必须在合并文档与组件注释中标明基准口径差异**（本报告即在此记录）。

---

### 🟡 P3-6：`osd-button` 组件尚无对应实现，仅有设计

前一轮已论证按钮自适应缩放机制（`chapterskip.lua` 的四步法）并规划 `script-modules/osd-button.lua`，
但**该文件目前并不存在**（`script-modules/` 下仅有 `file-browser-addons`）。

**结论**：因此不存在"两个按钮组件冲突需要合并"的情况。
真正要做的是**让 `osd-button` 组件吸收本项目 §2.1–2.3 的做法**，而非反向合并。

---

## 4. 合并建议

### 4.1 不合并的理由

| 理由 | 说明 |
|------|------|
| 已有等价能力 | `pagination.lua` 已覆盖按钮布局/渲染/命中/点击四接口，功能完整 |
| 破坏单例模型 | `mouse_interaction.lua` 是**模块级单例**（同一时间只有一个面板可见）。引入 `osd-button` 会使其脱离既有 `input_service` 统一鼠标订阅，产生**双订阅冲突** |
| 破坏纯函数约定 | 该组件被设计为"纯逻辑、`ass_lib` 作为参数传入"。`osd-button` 自带 overlay，会打破依赖注入边界 |
| 无收益 | 现有 3 面板（cards / cover_intro / production_score）已稳定复用，重写引入回归风险 |

### 4.2 应采取的动作：反向吸收

把本项目已验证的做法**提取为 `osd-button` 的设计规范**，用于校正 `chapterskip.lua` 的按钮实现：

| 序号 | 从本项目吸收 | 用于修正 `chapterskip.lua` 的哪一点 |
|------|------------|--------------------------------|
| 1 | 关闭按钮"渲染存矩形 → 命中读矩形"（§2.1） | 改掉"两处分别重算 `button_x/button_y`"，消除漂移隐患 |
| 2 | 位置与尺寸共用 `layout.s`（§2.2） | 已是同构做法，可对齐命名 |
| 3 | 三态配色表（§2.3） | 补齐禁用态（当前只有默认/悬停两态） |
| 4 | `bottom` 位置自动避让 40px | 作为 `osd-button` 的默认避让策略 |
| 5 | 单一 `mouse-pos` 订阅服务（`input_service`） | 替代 `chapterskip` 中直接 `observe_property("mouse-pos")` 的裸写法 |

### 4.3 若坚持合并：最低成本方案

只在 **`osd-button.lua` 内部**做接口对齐，**不动 uosc_staff_credits 任何文件**：

```lua
-- osd-button.lua 暴露与 pagination.lua 同形的四接口
-- compute_layout(parent_layout, ...) / render(parts, layout, state, ass_lib)
-- hit_test(mx, my, layout)           / on_click(mx, my, layout, ...)
```

这样两边共享同一套"布局→渲染→命中→点击"契约，**零侵入**即可互通。

### 4.4 已落地：`script-modules/osd-button.lua` ✅（2026-10-05）

§4.2 的五项吸收清单**已全部实现**为独立模块 `script-modules/osd-button.lua`（非上游脚本，
本项目自建通用件）。它把「随播放器等比缩放、不移位、不偏位」固化成四条纪律：

| 纪律 | 内容 | 对应吸收项 |
|------|------|-----------|
| 1 | **单一缩放基准**：字号/内边距/圆角/描边/行距统一乘 `layout.s`，绝不出现两个基准 | 2 |
| 2 | **贴边反推**：`x = 屏宽 - 按钮宽 - 边距`，不用绝对坐标 | 2、4 |
| 3 | **渲染存矩形 → 命中读矩形**：矩形只算一次，命中只读不重算 | 1 |
| 4 | **每次渲染重取屏幕尺寸**，不缓存，窗口缩放/全屏/换显示器即时响应 | — |

**关键设计：纪律 3 是杜绝漂移的根本。** 文字宽度只能按 `字符数 × font_size × 0.6` 估算
（ASS 无回读文字度量能力），估算本身必然有误差。若渲染和命中各估算一次，两处误差叠加
就会产生「看得见点不着」的死区。本模块让**估算只发生一次**并存入 `self._hit_rect`，
命中判定永远读同一份结果 —— 误差再大也不会自相矛盾。

**与 §4.2 吸收项 5 的偏差说明**：`input_service` 的单一订阅是 uosc_staff_credits 内部
私有服务，通用模块不应依赖它。本模块改用**进程内共享订阅**：所有 Button 实例共用
一个 `mouse-pos` observer，回调分发给实例表，最后一个实例销毁时自动 `unobserve`。
既避免「每个按钮各订阅一次」的裸写法，也不引入跨模块耦合。

**自检内置**：`M.self_test()` 含 16 条断言，覆盖缩放等比性、贴边间距恒定、
21:9 超宽屏 / 4:3 窄屏 / 极窄屏不出框、九宫格锚点、避让控制栏、布局确定性等，
可在纯 luajit（无 mpv 运行时）下运行：

```bash
../luajit.exe tools/osd-button-selftest.lua
```

实测结果：**16/16 PASS**。

### 4.5 反向落地：`chapterskip.lua` 已切换到本模块 ✅（2026-10-05）

§4.2 吸收项 1 说的「改掉两处分别重算 `button_x/button_y`」**已真正执行** ——
不是停留在建议，而是把 `chapterskip.lua` 的按钮整体换成了 `osd-button`。

**旧实现的两个根因**（比 §4.2 当时的判断更具体）：

| 层次 | 问题 |
|------|------|
| 时序 | 命中判定读 `button_state.mouse_hover`，该布尔值虽在同一次 `render` 内算出，却隐含依赖「render 一定先于判定」。鼠标事件早于 render 时（show 后立刻点击、`osd-dimensions` 未就绪）读到的就是上一帧陈旧值 |
| 度量 | 文字宽度按 `#message * font_size * 0.6` 估算，与实际字体度量不符时绘制与判定各偏一次，且**无处对账** |

**改造结果**：

- 删除 **131 行**内联几何计算（`button_x/y/width/height`、`scale`、`0.6` 估算全部消失）
- 几何计算唯一化进模块：渲染写 `self._hit_rect`，命中只读它 —— 全项目**再无第二处按钮坐标计算**
- 点击改调 `prompt_button:on_mouse_click(x, y)`
- 删除裸的 `mouse-pos` observer（原每次鼠标移动都全量 render），悬停改由模块内共享订阅驱动
- 按钮实例复用（非每次 `new`），`on_unload` 增加 `:destroy()`

**度量提升**：`chapterskip.lua` 净减约 90 行（-177/+... 见提交），代码量变化：

```
script-modules/osd-button.lua         |  78 +++++++--   (扩展进度条支持)
scripts/chapterskip.lua               | 288 ++++++++++++++--------------------
tools/osd-button-drift-regression.lua |  67 ++++++++
```

**新增回归测试 `tools/osd-button-drift-regression.lua`**：把隐患变成可复现的断言。
构造「绘制发生在 1080p、判定时屏幕已切到 4K」的场景对照：

```
[旧] 绘制矩形 x=1647.2 y=862.0   判定矩形 x=3294.4 y=1724.0
[旧] 坐标漂移 dx=1647.2 dy=862.0  ← 两者不自洽
[旧] 点在按钮中心 → 未命中           ← 应命中却漏判（看得见点不着）
[新] 判定读同一份 → 命中 ✅
```

**为进度条扩展了模块**：`set_progress(p)` + `progress_fg/progress_bg` 三态联动配色。
进度**只影响填充宽度**，不影响按钮尺寸与位置 —— 所以不会引起抖动，也无需重新布局。
六参双半径 `round_rect_cw(x0,y0,x1,y1,r,0)` 沿用原 `chapterskip.lua:462` 验证过的形式。

---

## 5. 集成现状：已接入 ✅（2026-10-05 补全）

| 检查项 | 状态 | 说明 |
|--------|------|------|
| `script-opts/uosc_staff_credits.conf` | ✅ 已补齐 | 与 `defaults.lua` 的 30+ 配置项对应 |
| `input.conf` 键位绑定 | ✅ 已补齐 | `B  script-message-to uosc_staff_credits main-menu`（工具 > Bangumi 工具箱） |
| `scripts/uosc_staff_credits/` 本体 | ✅ 已就位 | 60 个 lua 文件完整 |
| `.gitignore` | ✅ 已补齐 | 覆盖 WorkBuddy 私有目录、运行时状态文件 |

### 5.1 入口绑定（已落地）

```conf
B  script-message-to uosc_staff_credits main-menu   #menu: 工具 > Bangumi 工具箱
```

> ⚠️ **路由名必须核对**：实际注册名是 **`main-menu`**（`app/dispatcher.lua:608`），
> 而非直觉上的 `staff-credits-main`。dispatcher 实际注册的完整路由清单：

| 路由名 | 用途 |
|--------|------|
| `main-menu` | **主菜单（本入口使用）** |
| `staff-credits` | 职员表 |
| `character-intro` | 角色介绍 |
| `cover-intro` | 封面简介 |
| `staff-credits-production-score` | 制作评分 |
| `staff-credits-search` / `-select` | BGM 搜索 / 选中条目 |
| `staff-credits-fankuhub-search` / `-search-by-person` | 番库搜索 |
| `staff-credits-settings` / `-config` / `-set-config` | 设置与配置读写 |
| `staff-credits-servers` / `-servers-move` / `-servers-toggle` | 网站优先级 |
| `staff-credits-clear-cache` / `-clear-all` | 清理缓存 |
| `staff-credits-close` / `-loading-close` / `-menu-closed` | 关闭与状态回调 |
| `staff-credits-open-browser` | 打开浏览器 |

### 5.2 键位冲突核查

`B` 与既有的 `BS`（重置速度）**不冲突** —— mpv 中二者是不同键名。
已确认 `input.conf` 中无其他未注释的 `B` 开头绑定。

---

## 6. 问题清单汇总

| 编号 | 严重度 | 问题 | 位置 | 状态 |
|------|--------|------|------|------|
| P1-1 | 🔴 高 | `state.hover_button` 未初始化 | `staff_grid.lua:44-55` | ✅ 已修 |
| P2-2 | 🟠 中 | `show(new_deps,...)` 首参被忽略 | `staff_grid.lua:328` / `staff_credits.lua:104,222` | ✅ 已修 |
| P2-3 | 🟠 中 | OSD observer 每次 show 重注册 | `staff_grid.lua:438-443` | ✅ 已修 |
| P2-4 | 🟠 中 | 关闭按钮无悬停反馈 | `staff_grid.lua:384-395` | ✅ 已修 |
| P3-5 | 🟡 低 | ui_scale 基准与 chapterskip 不一致 | 全局 | 📄 已记录口径 |
| P3-6 | 🟡 低 | `osd-button.lua` 尚不存在 | `script-modules/` | ✅ 已实现 |
| — | ✅ 已解 | 无 conf、无 input 绑定 | `script-opts/` `input.conf` | ✅ 已补齐 |

---

## 7. 相关文档

- 本项目自带：`docs/UI.md`（1,291 行）、`docs/DESIGN.md`（1,307 行）、`docs/PROJECT.md`（718 行）——**质量很高，是本次审查的主要依据**
- 上一轮产出：`chapterskip.lua` 按钮自适应缩放机制分析（四步法：取基准 → 乘 scale → 贴边反推 → 写回 res_x/res_y）
- 本地差异核对：[README.md §本地脚本与上游 wiki 说明的差异核对](../../../README.md)

---

## 7.5 关键机制勘误：`script-modules/` 不在 `package.path` 上 ⚠️

**这是本次最重要的发现，因为它让「语法全过」的代码实际完全无法运行。**

上一轮我把 `chapterskip.lua` 改为 `require 'osd-button'`，指向
`script-modules/osd-button.lua`。语法检查 **185/185 全过**，但实测启动 mpv 时：

```
[chapterskip] Lua error: chapterskip.lua:354: module 'osd-button' not found:
    no field package.preload['osd-button']
    no file 'D:\...\mpv-20260831\lua\osd-button.lua'
    no file 'D:\...\mpv-20260831\lua\osd-button\init.lua'
    no file 'D:\...\mpv-20260831\osd-button.dll'
```

**实测得到的 `package.path`（在脚本内打印）**：

```
D:\...\mpv-20260831\lua\?.lua;D:\...\mpv-20260831\lua\?\init.lua
```

即：mpv 只搜索 **`<mpv 根目录>/lua/`**，`script-modules/` **根本不在搜索路径上**。
`script-modules/` 只是社区约定（mpv 官方 wiki 建议的放置位置），
**并非自动可 require**。

**正确做法**（沿用本项目 `scripts/file-browser/main.lua:16` 的既有约定）：

```lua
-- 把 ~~ 展开为 mpv 配置目录后 prepend 到 package.path
package.path = mp.command_native({"expand-path", "~~/script-modules"}) .. "/?.lua;" .. package.path
local osd_button = require 'osd-button'
```

> **教训**：`loadstring` 语法检查**无法发现模块解析失败** —— 它只解析当前文件的语法，
> 不会真的执行 `require`。这类「运行期才炸」的问题**必须靠真实启动 mpv 验证**。
> 静态检查的绿灯不等于能跑。

---

## 8. 本次已落地的修改（2026-10-05）

### 8.0 uosc 控制栏按钮修正与扩充

**发现一个静默失效的绑定**（`script-opts/uosc.conf` 的 `controls` 行）：

```conf
# 修正前（错误，且不报错、点了没反应）
<video>command:people:script-binding uosc_staff-credits/staff-credits?职员表
```

两处错误：

| 错误 | 说明 |
|------|------|
| 脚本名写错 | `uosc_staff-credits`（连字符）vs 实际目录 `uosc_staff_credits`（下划线） |
| 机制用错 | `script-binding foo/bar` 要求 `bar` 是脚本内 `register_key_binding` 注册的**按键绑定**；而本脚本的对外入口是 **`script-message` 路由**，用 `script-binding` 调不到 |

**正确做法**：本脚本自己已通过 uosc 的 `set-button` 注册了具名按钮
（`modules/menu.lua:113`），名为 **`staff_credits_main`**（图标 `menu_book`，
提示「Bangumi 工具箱」）。所以只需引用 `button:staff_credits_main`。

**uosc 的坑**：`lib/buttons.lua:14` 对未注册的按钮名**不报错**，而是返回

```lua
{icon = 'help_center', tooltip = 'Uninitialized button "' .. name .. '"'}
```

即：**名字拼错只会显示一个问号图标**，极难察觉。故必须静态比对（见 §8.4 的核验脚本）。

**扩充的业务按钮**（按业务链路新增，均实测可触发）：

| 按钮 | 引用形式 | 对应路由 |
|------|---------|---------|
| 职员表 / 主菜单 | `button:staff_credits_main` | `main-menu`（脚本自注册） |
| 角色介绍 | `command:person_search:script-message-to … character-intro` | `character-intro` |
| 封面简介 | `command:image_search:script-message-to … cover-intro` | `cover-intro` |
| 制作评分 | `command:star_rate:script-message-to … staff-credits-production-score` | `staff-credits-production-score` |

> 用 `command:…:script-message-to` 而非 `script-binding`，因为这些是 **script-message 路由**。

### 8.1 代码修复（3 处）

| 文件 | 修改 | 说明 |
|------|------|------|
| `modules/staff_grid.lua:54` | 补 `hover_button = nil` | 原仅在 `show()`/`cleanup` 里赋值，属隐性依赖 |
| `modules/staff_grid.lua:328` | `show(new_deps, items, title)` → `show(items, title)` | 首参被静默忽略，删除以免误导 |
| `feature/staff_credits.lua:104,222` | 调用同步改为 `show(items, title)` | 与签名对齐 |
| `modules/staff_grid.lua:438-443` | OSD observer 移入 `M.init()` 一次性注册 | 消除订阅抖动与防抖定时器泄漏风险 |
| `modules/staff_grid.lua:384-395` | `hit_test` 增加 `"close"` 分支 | 使 ✕ 可被识别为悬停目标 |
| `modules/staff_grid.lua:199-220` | 关闭按钮三态渲染 | 悬停时背景 `3A3940` + 边框 `88C0FC` + 文字 `E06C75` |

### 8.2 配置与集成（3 项）

| 文件 | 动作 |
|------|------|
| `script-opts/uosc_staff_credits.conf` | 补齐；另将 `debug=yes` 改为 `debug=no`（避免生产环境刷屏） |
| `input.conf:313` | 新增 `B  script-message-to uosc_staff_credits main-menu` |
| `.gitignore` | 补齐 WorkBuddy 私有目录、运行时状态文件、`file_browser_favourites.txt` 例外 |

### 8.3 验证方式

本机**无需单独安装 Lua** —— 直接复用 mpv 自带的 `luajit.exe`（在 `portable_config` 的上一级，
即 `mpv.exe` 同目录），配套检查脚本 `tools/lua-syntax-check.lua`。

```bash
cd portable_config
../luajit.exe tools/lua-syntax-check.lua
```

**实测结果：全项目 185 个 .lua 文件，语法 OK 185，FAIL 0。**

其他验证：

- 键位冲突核查：`B` 与 `BS` 不同键，无冲突
- 路由名核对：`main-menu` 已在 `app/dispatcher.lua:608` 验证存在

> ⚠️ **但语法检查有明确的能力边界**：它只解析当前文件，**不执行 `require`**，
> 因此**发现不了模块解析失败**（§7.5 就是这么踩的坑：185/185 全过，
> 实际 `chapterskip.lua` 因为 `require 'osd-button'` 失败而**完全无法运行**）。
> 结论：**语法绿灯 ≠ 能跑，必须真机启动一次**。

### 8.3.1 真机冒烟测试（重要，补语法检查之不足）

```bash
cd mpv-20260831
./mpv.exe --vo=null --ao=null --frames=1 --msg-level=all=info "av://lavfi:testsrc=d=1"
```

用 mpv 内置 lavfi 测试源（无需外部媒体文件），`--vo=null` 便于纯日志验证。
**判据：日志中不得出现 `Lua error` / `module ... not found` / `traceback`。**

实测修复前的对比：

| 阶段 | `--vo=null` 启动日志 |
|------|---------------------|
| 修复前 | `[chapterskip] Lua error: ...: module 'osd-button' not found` ← 脚本整个没加载 |
| 修复后 | 无 Lua error，chapterskip 正常加载 |

### 8.3.2 业务链路端到端测试

```bash
./mpv.exe --vo=null --ao=null --script=tools/biz-smoke.lua "av://lavfi:testsrc=d=3"
```

依次触发 4 个业务路由，确认均被 dispatcher 接收：

```
[biz] === [1/4] 触发按钮「职员表(主菜单)」→ route=main-menu
[biz] === [2/4] 触发按钮「角色介绍」→ route=character-intro
[uosc_staff_credits] [Bangumi 工具箱] 角色介绍 · 加载中...
[biz] === [3/4] 触发按钮「封面简介」→ route=cover-intro
[uosc_staff_credits] [Bangumi 工具箱] 封面简介 · 加载中...
[biz] === [4/4] 触发按钮「制作评分」→ route=staff-credits-production-score
[uosc_staff_credits] [Bangumi 工具箱] 制作评分 · 加载中...
```

四个路由全部响应，无 Lua error。（测试图案无番剧数据，故后续网络请求
自然失败 —— 这属于**预期行为**，不是缺陷。）

### 8.4 静态核验工具（防止按钮名/路由名写错）

uosc 对未注册按钮名会静默降级为 `help_center` 占位图标，故必须静态比对：

```bash
python tools/uosc-verify-buttons.py   # 核验 controls 里每个 button:NAME 是否真被注册
python tools/uosc-verify-routes.py    # 核验每个 script-message-to 路由是否真被注册
```

实测：**button 未注册 0 个，路由未注册 0 个。**

### 8.5 全项目扫描「被 nil 守卫掩盖的错误调用」

#### 8.5.1 这一类缺陷为什么值得单独建工具

本项目的 4 处缺陷（见 §8.1）共享同一个**失效模式**：

> 调用失败 → 返回 nil（而非抛错）→ 下游的 `if not x then return end` 守卫接住
> → **不崩溃，但功能静默不工作**。

它的危险在于**没有任何信号**：不报错、不告警、日志干净。语法检查（§8.3）也查不出。
而且它比「直接崩溃」更糟 —— 崩溃会逼你修，静默失效可能潜伏数月。

> **核心教训：`有 nil 守卫` ≠ `安全`。**
> 守卫只是把「崩溃」转换成了「静默不工作」，后者更难发现。

#### 8.5.2 工具与规则

`tools/lua-audit-nilguards.py`，四类规则：

| 规则 | 检查内容 | 级别 | 为什么定这个级别 |
|---|---|---|---|
| **A** | `command_native({"command", …})` 首元素多余包装 | P0 | 必然返回 nil，mpv 报 `Command 'command' not found` |
| **B** | `notify.*` 被当 printf 用（首参含格式符且传了额外参数） | P0 | `duration` 收到字符串 → `mp.osd_message` 做算术 → 抛错 |
| **C** | `command_native(…):method()` 无守卫 | **INFO** | 是否抛错取决于命令名，静态无法判定（见下） |
| **D** | `require 'script-modules/x'` 但未 prepend `package.path` | P0 | mpv 只搜 `<mpv根>/lua/`，加载必失败 |

#### 8.5.3 用实测校准规则，而不是拍脑袋定级别

**规则 C 从 P1 降为 INFO** —— 因为实测发现 `expand-text` **不会**返回 nil：

`tools/probe-expand-text.lua` 在真机跑出的数据：

| 输入 | 返回 |
|---|---|
| `"plain text"` | `"plain text"`（原样） |
| `"${不存在属性}"` | `"(error)"`（替换为字面量，**不是 nil**） |
| `"${}"/"${不存在} ${path}"` | `"(error) …"` |
| `"${"`（非法/未闭合模板） | `"${"`（原样返回） |

⇒ 故 `TopBar.lua:40` 的 `command_native({'expand-text',tpl}):gsub(…)` **永远安全**，
既不会抛错也不会静默失效。报 P0/P1 都是误报 → 改为 INFO 并在规则里跳过 `expand-text`。
反之 `expand-path` **会**返回 nil（正是缺陷 2 的成因）。

**规则 B 重构判定逻辑**，以消除唯一一处真实误报：
之前用「`%s` 后跟逗号」的朴素正则，会把**已修正**的
`notify.info(string.format("已更新: %s = %s", …))` 再报一次 ——
因为字面量在**嵌套调用内部**。现新增 `strip_nested_calls()` 剥掉嵌套实参，
只有「格式符字面量确实是 notify 的**第一个实参**」且「后面还有额外实参」才命中。
格式符全集也从 `%[sd]` 扩到 Lua 标准全集（`%d %i %u %o %x %X %e %E %f %g %G %c %q`）。

#### 8.5.4 工具自身也要有反例测试（金丝雀自检）

> **一个不报错的坏工具，比没有工具更危险。**
> 规则若悄悄失效（如某次改动后正则不再匹配），工具照样输出
> 「未发现可疑模式 ✅」，所有人都以为干净了。

故 `tools/lua-audit-nilguards-selftest.py` 做**双向断言**：

- **正向**：故意重新注入 4 类原始缺陷 → 必须全部命中（A×1、B×3、C×1）
- **反向**：注入 3 个**正确写法** → 必须**一条都不报**
  （`string.format` 包装、无格式符的纯文本、`expand-text` 链式调用）

实测结果：

```
  ✓ 期望 [P0] A/   命中 1 次，实际 1 次
  ✓ 期望 [P0] B/   命中 3 次，实际 3 次
  ✓ 期望 [INFO] C/ 命中 1 次，实际 1 次
  ✓ 正确写法（第 8 行）保持静默
  ✓ 正确写法（第 9 行）保持静默
  ✓ 正确写法（第 10 行）保持静默
金丝雀自检通过 —— 审计规则有效且无已知误报 ✅
```

#### 8.5.5 全项目扫描结果

```
扫描 185 个 Lua 文件
未发现可疑模式 ✅
P0（必然静默失效/抛错）: 0
P1（潜在隐患）: 0
INFO（需人工确认，非缺陷）: 0
退出码=0
```

⇒ 4 处已知缺陷已全部修复，且全项目**无同类残留**。

### 8.6 业务链路的「判据陷阱」（重要）

§8.3.2 的 `biz-smoke.lua` 一度把 `main-menu` 判为「无响应」——**这是误判**，
根因值得记录，因为它是一个通用的观测方法学错误：

`main-menu` 的响应**不走 notify 回执**，而是
`mp.commandv("script-message-to", "uosc", "open-menu", <json>)` 去开 uosc 菜单。
测试脚本用 `mp.register_script_message("open-menu", …)` 去抓，**永远抓不到** ——
因为：

> **mpv 的 script-message 不会回放给「后注册者」。**
> 测试脚本的加载顺序在 uosc 之后，那条消息早就发过了。

用 `--msg-level=all=trace` 看 **mpv 自身的命令日志**，真相立刻显现：

```
[cplayer] Run command: script-message-to, flags=64,
  args=[target="uosc", args="open-menu",
        args="{\"search_style\":\"disabled\",\"title\":\"Bangumi 工具箱\",\"items\":[…11 项…]}"]
```

⇒ 结论：**不能用「本进程能否收到某个 script-message」当判据**，
必须改看 mpv 自身的命令日志或可观测副作用。
现 `biz-smoke.lua` 已把这一点写进注释，并标注 `main-menu` 需 trace 级核验。

四条路由的最终结论：

| 路由 | 判据 | 结果 |
|---|---|---|
| `main-menu` | trace 日志出现 `args="open-menu"` + 完整 items | ✅ 通 |
| `character-intro` | `[Bangumi 工具箱] 角色介绍 · 加载中...` | ✅ 通 |
| `cover-intro` | `[Bangumi 工具箱] 封面简介 · 加载中...` | ✅ 通 |
| `staff-credits-production-score` | `[Bangumi 工具箱] 制作评分 · 加载中...` | ✅ 通 |

### 8.7 门禁清单（8 项，全部通过）

```bash
cd portable_config
../luajit.exe tools/lua-syntax-check.lua            # 1. 语法：185/185
../luajit.exe tools/osd-button-selftest.lua         # 2. 自测：16/16
../luajit.exe tools/osd-button-drift-regression.lua # 3. 漂移：旧漏判/新命中
python tools/uosc-verify-buttons.py                 # 4. 按钮：未注册 0
python tools/uosc-verify-routes.py                  # 5. 路由：未注册 0
python tools/lua-audit-nilguards.py                 # 6. 审计：P0/P1 = 0
python tools/lua-audit-nilguards-selftest.py        # 7. 金丝雀：规则有效
# 8. 真机（在 mpv 根目录）
cd .. && ./mpv.exe --vo=null --ao=null --msg-level=all=info \
    --script=portable_config/tools/biz-smoke.lua "av://lavfi:testsrc=d=3"
```

> ⚠️ 真机测试的两条纪律：
> 1. **不要加 `--no-config`** —— 那会让 `portable_config` 完全不被加载，测了个寂寞。
> 2. 输出重定向到文件再 grep，别直接管道 —— mpv 以 SIGTERM 收尾会让管道丢输出。

---

## 9. 搜索链路修复：繁体标题 + 集数解析（2026-10-05 二轮）

### 9.0 用户报告

播放 `無職転生 III ～異世界行ったら本気だす～ - 09` 时：

1. **搜索框里预填的是繁体日文原名**，不是中文 —— Bangumi 搜不到条目。
2. **对应集数查不到**。

要求：「参考本项目的另一个脚本 `uosc_danmaku`，至少做到和它的搜索一模一样」。

### 9.1 根因一：`is_chinese()` 的字节区间把「中文」当成「简体中文」

```lua
-- modules/utils.lua 原实现
str:find("[\228-\233][\128-\191]")
```

Lua 字符类里 `\228-\233` 是**字节**范围，而 UTF-8 中 `E4..E9` 恰好是**全部 CJK 汉字**的首字节区间：

| 字 | 首字节 | 简/繁/日 |
|---|---|---|
| 无 职 | E6 E8 | 简体 |
| 無 職 | E7 E8 | 繁体 |
| 進 撃 | E9 E6 | 日文汉字 |

⇒ `is_chinese("無職転生") == true`。

而 `resolve_chinese_title()` 的第一句就是

```lua
if utils_mod.is_chinese(title) then return title end
```

于是繁体标题被判定为「已经是中文」，**直接原样返回，从不送去做转换**。

> **关键认知：「是中文」和「是简体中文」是两回事。**
> 原代码把前者当后者用，这个偷换概念让整条转换链路静默失效 ——
> 没有报错、没有日志，只是搜索结果为空。

### 9.2 根因二：缺 ` - 09` 的 DashEpisode 模式

`guess.lua` 原有 5 个集数模式（SxxExx / Episode / EP?\d+ / 第N话 / `[\d+]` / Season N），
**没有一个能匹配 `無職転生 … - 09`**。实测 6 个模式对该文件名全部返回 `None`。

双重伤害：

- `episode` 保持 `nil`
- **且 `title_part` 保持整个文件名**（含 ` - 09`）
- ⇒ 搜索关键词 = `無職転生 III ～異世界行ったら本気だす～ - 09`

### 9.3 根因三（新发现）：Lua 字符类是「字节集」，不是「码点集」

这是本轮**最有价值的发现**，且**同一个坑连续踩了三次**：

| # | 字符类 | 位置 | 后果 |
|---|---|---|---|
| 1 | `[～〜~]` | `guess.lua` `strip_subtitle` | 字节集含 `80/9C/9E` 等**续接字节** → 从汉字中间匹配 → 丢掉「す～」6 字节 |
| 2 | `[ぁ-ゖァ-ヺーｦ-ﾟ]` | `title_normalize.lua` `has_kana` | `ぁ`=E3 81 81 … 字节区间使首字节 ≥E3 全部命中 → **误匹配所有汉字** |
| 3 | `[\228-\233][\128-\191]` | `utils.lua` `is_chinese` | 简/繁/日汉字全算「中文」 |

实测证据（`tools/` 下的 probe 脚本产出）：

```text
[～〜~] 展开字节集 = {7E, 80, 9C, 9E, BD, E3, EF}
  → 含 80/9C/9E，均为 UTF-8 续接字节
「無職転生 III ～異世界行ったら本気だす～」#56
  过 [～〜~] 规则后 → #55（尾部「～」被吃掉，而这串本无「～…～」结构）
  叠加 [%-–—] 两条规则 + repeat 迭代 → #50，丢 6 字节

KANA 类 find() 实测：
  进 无 间 鬼 巨 人 の あ ア  → 全部 true
  ⇒ is_simplified_chinese("进击的巨人") == false（明明是简体！）
  ⇒ resolve_chinese_title 第 2 步「已是简体就早退」永远不成立
     每次搜索都白跑一轮网络请求
```

**结论（写进纪律）：凡是非 ASCII 的 Lua 字符类，一律不可信。**
必须先把字符串解码成**码点**，再按码点区间判断。

### 9.4 修复内容

| 文件 | 改动 |
|---|---|
| `modules/title_normalize.lua` | **新增**。复用 `uosc_danmaku/dicts/t2s_chars.lua`（4113 条单字映射）；新增 UTF-8 解码器 `utf8_codepoints` + `has_kana`/`has_han`（码点判定）；`is_simplified_chinese` 全面改用码点 |
| `modules/guess.lua` | `strip_subtitle` 从「字节类正则」重写为「UTF-8 字符序列 + 尾部回扫」；新增**模式 6 DashEpisode**，并支持尾部发布组标签 |
| `app/search_pipeline.lua` | `resolve_chinese_title` 3 步化（本地转换 → 是简体则零网络早退 → 否则联网）；`resolve_display_title` 与 fankuhub 结果过滤改用 `is_simplified_chinese` |
| `features/subject_select.lua` | 预填前**同步**做本地繁→简，消除「先显示错标题再刷新」的闪烁 |
| `features/fankuhub_search.lua` | 同上 |
| `modules/menu.lua` | 新增 `parse_query_class`（`名称\|class` 语法）+ hint 行 `追加\|ds或\|dy或\|dm可搜索电视剧\|电影\|国漫`（与 `uosc_danmaku` 逐字一致）+ `status_text` 状态行 |
| `app/dispatcher.lua` | `handle_search` 接入 `\|class` 解析，映射到 Bangumi subject type |

### 9.5 `uosc_danmaku` 对齐清单

| 能力 | uosc_danmaku | 本项目（修复后） |
|---|---|---|
| 繁体→简体字典 | `dicts/t2s_chars.lua` 4113 条 | ✅ 直接复用同一份 |
| 逐字符转换（UTF-8 安全） | `modules/parse.lua` `convert()` | ✅ `title_normalize.to_simplified()` |
| 「已是简体」判定 | — | ✅ `is_simplified_chinese`（码点） |
| `名称\|class` 后缀 | `ds`/`dy`/`dm` | ✅ `parse_query_class` |
| 语法提示行 | `追加\|ds或\|dy或\|dm…` | ✅ 逐字一致 |
| `已关联…` 状态行 | ✅ | ✅ `status_text` 参数 |
| 集数解析（` - 09`） | `format_filename()` 14 条正则 | ✅ 新增模式 6 + 标签剥离 |

### 9.6 新增回归测试（2 个）

```bash
cd ..   # mpv 根目录
./luajit.exe portable_config/tools/guess-title-test.lua        # 13/13
./luajit.exe portable_config/tools/title-normalize-test.lua    # 34/34
```

两个测试都**内置字节安全断言**：

- `guess-title-test.lua` 的 `is_valid_utf8()` —— 任何残缺 UTF-8 一律判 FAIL
- `title-normalize-test.lua` 的「★字节类 bug 红线」组 ——
  把 `has_kana('进击的巨人') == false` 这类断言固化，防止有人再把字节类写回来

**反向验证（证明测试不是空测试）**：把旧的 `strip_subtitle` 塞回去跑，
**4/4 全部 FAIL**（每次丢 6 字节且从不真正剥掉副标题）；新实现 13/13 PASS。

### 9.7 真机验证（语法绿灯 ≠ 能跑）

字典是**懒加载**（首次转换才 `dofile`），启动阶段不触发，
所以专门跑了探针确认真机路径可达：

```text
[_tn_probe] expand-path ~~/scripts = D:/…/portable_config/scripts
[_tn_probe] dict path  = …/uosc_danmaku/dicts/t2s_chars.lua
[_tn_probe] io.open 成功?  true
[_tn_probe] dofile ok? true type: table
[_tn_probe] 字典条数 = 4113
[_tn_probe] 無職転生 → 无职転生
[uosc_staff_credits] [title_normalize][PROBE] t2s 字典已载入   ← 模块自身也载入成功
```

### 9.8 门禁清单（**第二轮快照，已过时** —— 当前清单见 §11.9）

> 📌 本节数字是 2026-10-05 第二轮当时的实测值，保留作历史记录。
> **不要照抄**：语法已从 186 涨到 188，繁简测试已从 34 涨到 58，
> 且新增了 3 个测试与 1 道门禁。以 §11.9 为准。

```bash
cd portable_config
../luajit.exe tools/lua-syntax-check.lua            # 1. 语法：186/186  ← 现为 188/188
../luajit.exe tools/osd-button-selftest.lua         # 2. 自测：16/16
../luajit.exe tools/osd-button-drift-regression.lua # 3. 漂移：旧漏判/新命中
../luajit.exe tools/guess-title-test.lua            # 4. 标题解析：13/13
../luajit.exe tools/title-normalize-test.lua        # 5. 繁简转换：34/34  ← 现为 58/58
python tools/uosc-verify-buttons.py                 # 6. 按钮：未注册 0
python tools/uosc-verify-routes.py                  # 7. 路由：未注册 0
python tools/lua-audit-nilguards.py                 # 8. 审计：P0/P1 = 0
python tools/lua-audit-nilguards-selftest.py        # 9. 金丝雀：规则有效
# 10. 真机（在 mpv 根目录）
cd .. && ./mpv.exe --vo=null --ao=null --frames=1 --msg-level=all=info \
    "av://lavfi:testsrc=d=1"
```

> ⚠️ 上面第 10 条的真机命令**已过时**：`--frames=1` 拿不到日志，
> 且 `mpv.conf` 设了 `idle=yes` 会挂住被超时杀掉（日志全丢）。
> 现行写法见 §11.9（必须加 `--no-idle`）。

> ✅ **测试的 cwd 依赖已消除（2026-10-06）**：本节原先警告
> 「`guess-title-test` / `title-normalize-test` 必须从 mpv 根目录跑」。
> 现已把 **5 个 `*-test.lua`** 改为从**脚本自身位置**反推 `portable_config`，
> 任意 cwd 均可运行（详见 §11.10）。
>
> ⚠️ **但下面这 2 个脚本仍然必须从 `portable_config/` 跑**，本次**没有**改：
>   - `lua-syntax-check.lua` —— 用 `glob` 扫相对路径，从别处跑会报
>     「未找到 .lua 文件」（exit 1）
>   - `osd-button-drift-regression.lua` —— `dofile("script-modules/osd-button.lua")`
>     是相对路径，从别处跑会 `cannot open ... Invalid argument`
>
> 两者都已实测确认（从 `$TEMP` 跑均 exit 1）。上面代码块第 1~3 条
> 之所以写 `cd portable_config`，正是因为这个原因，**别删那一行**。

---

## 11. 弹幕 API 接入 + 标准名清洗 + Bangumi 观看进度（2026-10-06 三轮）

### 11.1 需求与落点

| 需求 | 落点 |
|------|------|
| 自定义弹幕 API 接进 `uosc_danmaku` | `script-opts/uosc_danmaku.conf` 的 `api_server` |
| 弹幕 API 的「剧集标准名」流程接进本项目 | `apis/dandanplay.lua` 的 `M.search` |
| 只取**能在 Bangumi 搜到**的标准名 | 新增 `modules/title_normalize.lua::to_standard_name` |
| 用 token 保存观看集 | 新增 `apis/bangumi_user.lua` + `features/progress_sync.lua` |
| 弹幕 API 与 token 都可配 | `script-opts/uosc_staff_credits.conf`（5 个新配置项） |

### 11.2 弹幕 API：token 在**路径**里，所以只需改配置

`https://dm.wodenas.xin/xiatianembydmww` 与 `dm.ljiaovm.com` 都是
`huangxd-/danmu_api`（LogVar弹幕API）的部署，对外提供 **dandanplay 兼容端点**，
所以 `uosc_danmaku` 可直接用。关键发现：

- 鉴权 token 是 **URL 路径的一段**（`http://{ip}:9321/{TOKEN}`），**不是** HTTP 头；
- 配置项 `api_server` 会被原样拼上 `/api/v2/...`，所以整串（含 token）填进去即可；
- 结论：**纯配置改动，无需动脚本** —— 满足「能就加到配置文件中」。
- `dm.ljiaovm.com` 拿不到 token（无 token 与默认 `87654321` 均 401），已移除并注明。

真机验证（临时探针，验完即删）：搜索返回真实结果，`load-danmaku` 加载
**2538 条弹幕**，`danmaku-count=2538`。

> 两个测试坑：`uosc_danmaku/main.lua` 的 `duration < 60` 门槛会拦住短视频的自动加载；
> `playback_only="yes"` 的 curl 会在播放结束时被 SIGTERM（看起来像网络错误）。

### 11.3 标准名清洗：`to_standard_name`

弹幕 API 返回的 `animeTitle` 形如 `某番【TV动画】from dandan`，
直接拿去搜 Bangumi 会失败。新增 `to_standard_name` 逐层剥掉：

1. `from <来源>` —— ⚠️ 真实格式里 `】` 与 `from` **之间没有空格**，
   初版按 `%s+from` 匹配，结果一条都剥不掉；
   同时**不能**用宽松的 `from%s+%w+$`，否则会误伤 `Escape from Tarkov`。
   现判据：`from` 之前必须是 `】` / `)` / `）`。
2. `【...】` 包裹的标签
3. 结尾的 `(1999)` 年份
4. 结尾的 `（第一部）` 这类**纯数字/序号**括号（带 `digits_only` 开关，
   否则会误伤 `The Girl from the Other Side`）

### 11.4 Bangumi 用户端点：按官方规格逐条核对后才发现的三处错误

规范源：`github.com/bangumi/api` → `open-api/v0.yaml`（经 jsDelivr 取，见 §11.7）。

| 项 | 初版（凭记忆写的旧文档） | 规范实际 | 后果 |
|----|------------------------|---------|------|
| 批量更新集进度 | `POST .../episodes` | **`PATCH`** | 405 |
| 更新单集进度 | `PATCH .../-/episodes/{id}` | **`PUT`** | 405 |
| 写操作响应体 | 当作必须有 JSON | **204 无响应体** | 写成功却报「空响应」失败 |

三者叠加后特别难查：curl 未加 `--fail`，405 的响应体不是 `ErrorDetail`，
会被报成「json 解析失败」——**报错信息指向完全无关的地方**。

修正后：
- `M.request(method, path, body, cb, expect_body)`，
  `expect_body` 省略时**按方法推断**（`GET` 才有 body）；
- 内部拆出 `do_request(..., token, ...)`，token 为 nil 时不带鉴权头，
  供**公开端点** `GET /v0/episodes?subject_id=` 复用（取剧集列表**不需要 token**）；
- 错误体判据收敛为 `title and description`（= `ErrorDetail` 的 required），
  删掉多余的 `and not data.id and not data.type`（已核对三个成功 schema 都不含
  `title`/`description`，那两个守卫是死代码）。

「集数 → `episode_id`」用 `GET /v0/episodes` 的 `sort` 字段映射
（退而比 `ep`）。越界时明确报 `ERR_NOT_FOUND`，**绝不静默标错集**。

### 11.5 观看进度：三档语义与「不该写就绝不写」

`progress_sync_mode`：
- `off`（默认）—— 只在手动点菜单时联网，**打开视频零网络请求**；
- `notify` —— 打开视频读一次进度并提示；
- `auto` —— 再叠加：播放进度达 `progress_sync_threshold`%（默认 80）后自动标记，
  每个视频只标一次。

卡阈值的理由：一打开就标记会把「点错、看 30 秒就关掉」也记成看过，弄脏收藏记录。

菜单项在**未配 token 时返回空表**（不在主菜单留点不动的死项）；
配了 token 但暂不可用（没搜索过 / 认不出集数）则显示**置灰项 + 原因**。

### 11.6 顺带修掉的真缺陷：`staff_grid.lua` 翻页必崩

扩展静态审计规则 E（见 §11.7）后扫出来的**既有**缺陷：

```lua
local function page_up()  ... render() ... end   -- 106 行
local function render()   ...                end  -- 157 行 ← 太晚
```

Lua 局部量作用域从声明之后才开始 ⇒ `page_up`/`page_down` 里的 `render`
编译成**全局读取**。触发条件很普通：职员表条目多到能翻页时按 LEFT/RIGHT
或点翻页箭头。实测证据：

```
staff_grid.lua:114: attempt to call global 'render' (a nil value)
staff_grid.lua:130: attempt to call global 'render' (a nil value)
debug.getupvalue(page_down) → 上值只有 state，没有 render
```

已改为标准前向声明（先 `local render`，后 `render = function() ... end`），
并新增回归测试 `tools/staff-grid-paging-test.lua`。

> 初版探针只给 40 个条目 —— 一屏装得下，`max_offset=0`，翻页分支提前 return，
> 测试「静静地通过」了。必须给 500 个条目才能让分支可达。

### 11.7 门禁与工具的改动

| 工具 | 改动 |
|------|------|
| `lua-audit-nilguards.py` | Rule E 从「只看缩进」升级为 4 道抑制 + 支持 `local function` |
| 同上 | 修 `is_comment`：块注释改为**一次性预扫**（原来块内第 2 行起判不出来） |
| `lua-audit-nilguards-selftest.py` | E 用例扩到 9 个（3 必报 / 6 必静默），行号改用 `--E:EXPECT` 标记反查 |
| `uosc-verify-menu-routes.py` | **新增**：菜单项发出的 `script-message` 必须有注册 |

Rule E 的收敛过程值得记一笔：初版只看「引用缩进 > 声明缩进」，一跑 **22 条全是误报**
（字符串内容 `"servers"`、表字段 `title = title`、别的函数里的同名局部量…）。
误报比没有工具更糟，于是加抑制：先剥字符串与注释、排除字段位置、
排除「更早处已有同名绑定」（local / for 循环变量 / 函数参数）。
现在 187 个真实文件 **0 命中**，同时 3 类真缺陷必报。

新门禁 `uosc-verify-menu-routes.py` 补的是一个**实测确认过的盲区**：
原有两道「路由」门禁都只解析 `uosc.conf` 的 `controls=` 行（只管工具栏按钮），
菜单项里的 `value = "script-message-to ... <route>"` **完全没人检查**。
把 `register_script_message("staff-credits-mark-watched", ...)` 整行删掉，
`uosc-verify-routes.py` 依然报「未注册: 0」。

### 11.8 新增测试

| 测试 | 断言数 | 覆盖 |
|------|-------|------|
| `tools/bangumi-user-test.lua` | 79 | 方法/URL/鉴权头/204 空体/错误体/编排/脱敏/剧集映射 |
| `tools/progress-sync-test.lua` | 55 | 三档语义、零请求克制、解析失败不写、防重复标记 |
| `tools/staff-grid-paging-test.lua` | 7 | 翻页回调不再读到全局 `render` |

三个测试都做过**变异验证**（把缺陷改回去，确认测试真的报错），
并记录了 1 个**等价变异**（`auto_tick` 里的 `auto_marked` 守卫冗余），
避免后人误以为是漏测而补假用例。

> `progress-sync-test.lua` 的定时器桩踩过一个坑：初版 `tick()` 边遍历边触发，
> 于是刚挂上的定时器在同一轮就跑了并被自己 kill —— 两个防重复守卫互相掩盖，
> 变异测试才发现。现改为**先快照再触发**（真实周期定时器不会在创建瞬间回调）。

### 11.9 门禁清单（本轮实测）

```bash
# 在 portable_config/ 下
../luajit.exe tools/lua-syntax-check.lua             # 1. 语法：188/188
../luajit.exe tools/osd-button-selftest.lua          # 2. 自测：16/16
../luajit.exe tools/osd-button-drift-regression.lua  # 3. 漂移：旧漏判/新命中
python tools/uosc-verify-buttons.py                  # 4. 按钮：未注册 0
python tools/uosc-verify-routes.py                   # 5. 工具栏路由：未注册 0
python tools/uosc-verify-menu-routes.py              # 6. 菜单路由：本项目未注册 0  ★新
python tools/lua-audit-nilguards.py                  # 7. 审计：P0/P1 = 0
python tools/lua-audit-nilguards-selftest.py         # 8. 金丝雀：规则有效

# 下列 5 个测试**任意 cwd 均可**（2026-10-06 起，见 §11.10）
../luajit.exe tools/bangumi-user-test.lua            #  9. 79/79  ★新
../luajit.exe tools/progress-sync-test.lua           # 10. 55/55  ★新
../luajit.exe tools/staff-grid-paging-test.lua       # 11.  7/7  ★新
../luajit.exe tools/guess-title-test.lua             # 12. 13/13
../luajit.exe tools/title-normalize-test.lua         # 13. 58/58
```

> ⚠️ 真机冒烟**必须加 `--no-idle`**：本项目 `mpv.conf` 第 105 行设了 `idle=yes`，
> 裸跑会一直挂着，被外层超时 SIGTERM 掉，**日志一条都拿不到**（表现为「无任何输出」）。
> 正确写法：
> ```bash
> cd <mpv根> && ./mpv.exe --vo=null --ao=null --no-idle --length=2 \
>     --msg-level=all=info "av://lavfi:testsrc=d=3"
> # 业务链路冒烟（不加 --length，脚本自己退出）
> ./mpv.exe --vo=null --ao=null --msg-level=all=info \
>     --script=portable_config/tools/biz-smoke.lua "av://lavfi:testsrc=d=3"
> ```

### 11.10 收尾修正：测试不再依赖 cwd（2026-10-06）

**发现方式**：收尾复核门禁时，我在 `portable_config/` 下顺手跑了
`bangumi-user-test.lua`，`tail -3` 显示的是
```
  [PASS] 编码数组字段
  [PASS] 坏输入不抛异常、返回 nil（对齐 mpv 契约）
  [PASS] 空串返回 nil
```
**看起来完全是通过**。但把 stdout / stderr 分开重跑，真相是：

```text
exit=1
luajit.exe: tools/bangumi-user-test.lua:230: module 'modules.utils.module_loader' not found
```

它**崩在 require 上**，而那 3 行 PASS 是崩溃前 §0 JSON 编解码器自检的
最后输出 —— 恰好落在 `tail` 窗口里。**这是「绿灯假象」的又一变体**，
和 §8.3.1「语法绿灯 ≠ 能跑」、§7.5「script-modules 不在 package.path」
是同一族问题：**判据取错了，失败会伪装成成功。**

**根因**：5 个测试都写死了 cwd 相对路径
```lua
package.path = "portable_config/scripts/uosc_staff_credits/?.lua;"
```
于是「从哪个目录跑」变成了一条**没人写在命令行里、却决定成败**的隐式参数。

**修法**：不再假设 cwd，改从脚本自身位置反推 ——
脚本在 `<mpv根>/portable_config/tools/`，上溯两级即 `portable_config`：

```lua
local _src = debug.getinfo(1, "S").source or "@."
local _tools_dir = _src:match("^@(.*)[/\\][^/\\]*$") or "."
local _pc = _tools_dir:match("^(.*)[/\\][^/\\]*$") or "."
package.path = _pc .. "/scripts/uosc_staff_credits/?.lua;"
    .. _pc .. "/scripts/uosc_staff_credits/?/init.lua;" .. package.path
```

`title-normalize-test.lua` 另有两处 cwd 依赖（stub 的 `expand-path` 返回值、
`DICT_PATH`），一并改为 `_pc` 前缀。

**验证**：从 **3 个不同目录**（mpv 根 / `portable_config/` / 无关的 `D:/`）
各跑一遍 5 个测试，`exit` 全为 0、断言数全对：

| 测试 | 断言 | mpv 根 | portable_config | D:/ |
|------|-----|--------|-----------------|-----|
| guess-title-test | 13 | ✅ | ✅ | ✅ |
| title-normalize-test | 58 | ✅ | ✅ | ✅ |
| bangumi-user-test | 79 | ✅ | ✅ | ✅ |
| progress-sync-test | 55 | ✅ | ✅ | ✅ |
| staff-grid-paging-test | 7 | ✅ | ✅ | ✅ |

> 教训：**测试的「通过判据」不能是 `tail` 出来的几行**。
> 判据必须是 **`exit code` + 汇总行**（本项目统一打印
> `结果：N/N 通过` 或 `通过 N，失败 0`）。
> 批量跑测试时一律用 `exit=$?` 判定，别用肉眼看输出尾部。

---

## 12. 移除 `fankuhub` 聚合源（2026-10-07 四轮）

### 12.1 起因与决定

用户决定不再使用 `fankuhub`（`https://fankuhub.com`）。选项有「仅停用」与「彻底删除」，
选定的是**彻底删除**：不留死代码。

### 12.2 影响面比预估大得多

一开始按 `grep` 的印象判断为「bootstrap / dispatcher / menu 几处引用」，
实测是 **31 个文件**（含 `app/search_pipeline.lua` 51 处、`modules/cover_intro.lua` 20、
`features/staff_credits.lua` 17、`features/production_score_flow.lua` 12）。

> 教训：**动手前先数引用数**，别凭印象报影响面。

### 12.3 删除清单

| 类别 | 内容 |
|------|------|
| 整个文件（3） | `apis/fankuhub.lua`（447 行）、`features/fankuhub_search.lua`（326 行）、`docs/fankuhub_api.md`（759 行） |
| 代码分支 | `search_pipeline` 的 `try_fankuhub` / 「fankuhub 优先快速路径」/ `resolve_chinese_title` 数据源 3；`staff_credits` 与 `production_score_flow` 的 persons 快速路径；`cover_intro` / `cards` / `name_resolver` / `character_cards` 的 fankuhub 专有字段分支 |
| 配置项 | `data_source`（`auto` 与 `bangumi` 语义重合后已无意义）、`fankuhub_api_base` |
| 菜单项 | 主菜单「番库搜索」及其后续编号（6→5 … 12→11） |
| 路由 | `staff-credits-fankuhub-search`、`staff-credits-fankuhub-search-by-person` |
| 字段兼容 | `nameCn` / `imageUrl` / `img` / `titleZh` / `titleJa` / `titleEn` / `titleRomaji` / `coverUrl` / `aggregateScore` / `airDate`（均已无生产者） |

改名：`try_fankuhub_fallback` → **`try_multi_source_fallback`**
（该函数早已是通用链，名字却停在「只有 fankuhub」的时代 —— 误导性命名）。
现链为 **anilist → mal → baike**。

### 12.4 老用户数据迁移（只删预设是不够的）

`modules/servers.lua` 的 `SCHEMA_VERSION` 4 → **5**，新增 `migrate_v4_to_v5(list)`：
按 `srv.type == "fankuhub"` 或 URL 含 `fankuhub%.com` 过滤掉该条目。

> 为什么必须有迁移：`~~/staff-credits-servers.json` 是**用户本地文件**，
> 老用户里面已经写进了 `{ "url": "https://fankuhub.com", "type": "fankuhub", ... }`。
> 只把 `PRESET_SERVERS` 里的条目删掉，对老用户**完全无效** ——
> 结果就是拿 fankuhub 的 URL 去请求 bangumi API，白白失败一次。

### 12.5 顺带清掉的一处「会骗人的常量」

`modules/defaults.lua` 里的 `M.SCHEMA_VERSION = 4` 全仓库无人引用，
但版本号已升到 5，留着就是一处**看起来权威、实际说谎**的定义。
已删除，并在原位注明真正的持有者是 `modules/servers.lua`。

### 12.6 门禁实测

| 门禁 | 结果 |
|------|------|
| `tools/lua-syntax-check.lua` | 186 文件 OK 186 / FAIL 0 |
| `tools/lua-audit-nilguards.py` | P0 0 / P1 0 / INFO 0 |
| `tools/uosc-verify-routes.py` | 未注册 0 |
| `tools/uosc-verify-buttons.py` | 未注册 0 |
| `tools/uosc-verify-menu-routes.py` | 本项目未注册 0 |
| `tools/runtime-config-test.lua` | 42/42 |
| `tools/bangumi-user-test.lua` | 79/79 |
| `tools/progress-sync-test.lua` | 55/55 |
| `tools/staff-grid-paging-test.lua` | 7/7 |
| `tools/osd-button-selftest.lua` | 16/16 |
| `tools/osd-button-drift-regression.lua` | 对比成立 |
| `tools/guess-title-test.lua` | 13/13 |
| `tools/title-normalize-test.lua` | 58/58 |
| `tools/biz-smoke.lua`（真机） | 5 条业务路由全部派发，无 Lua error |

> 一个真实的踩坑：删「persons 快速路径」时多留了一个 `end`，
> `production_score_flow.lua` 语法直接挂。**语法检查先跑，别等测试** ——
> 它 1 秒就能定位到行号。

### 12.7 文档处理原则

- **现行参考文档**（`CONFIGURATION.md`、`bangumi_mirror_api.md`、
  `spec_enhance_cache_ui_components.md`）→ **改内容**，删掉已不存在的配置项与流程，
  只在原位留一句「历史说明」解释为什么没了。
- **版本化快照文档**（`DESIGN.md` / `PROJECT.md` / `UI.md`，均停在 v1.9.2）→
  **不改正文**，只加头部提示。它们是历史记录，改写等于伪造历史。

> 另外 `CONFIGURATION.md` 里两处配置项计数（「24 项」「29 项」）本来就互相矛盾且都已过期。
> 现按 `modules/defaults.lua` 的实际项数统一为 **27**（`load_options` 遍历 `M.defaults`
> 全部键调 `mp.get_opt`，所以每一项都可被 script-opts 覆盖）。

---

## 13. 全流程审计（2026-10-07 五轮）

本轮任务原文是「**检查所有的任务流程**」——不是改功能，是把两个自研脚本的
全部链路扫一遍，看有没有「语法/审计全过但流程是断的」地方。

### 13.1 审计方法（四条判据，都是被前几轮教出来的）

| 判据 | 为什么不能省 |
|---|---|
| 全量门禁 + 真机冒烟打底 | 绿了不代表对，但红了肯定不对，先排除低阶问题 |
| **跨模块消息链路闭环** | 已有三道「路由」门禁只查 `uosc.conf` 的 `controls=`（工具栏按钮）与菜单项，**不查脚本内部 `script-message`** |
| **模块可达性** | 抓「写了但没人加载」的死模块 |
| **判据必须匹配完整调用形态** | 只查名字必被动态拼串骗过（见 13.4 的三次误报） |

### 13.2 审计结果总览

| 链路 | 结论 |
|---|---|
| 语法 / 按钮 / 工具栏路由 / 菜单路由 / nil 守卫审计 | 全绿（0 未注册、0 缺陷） |
| 真机业务冒烟（staff_credits 4 条路由） | 5/5 派发，0 Lua error |
| 跨模块消息链路（52 个注册项 × 全仓库引用方） | **P0 = 0**（无死信）；5 条「仅注册」经核实 3 条是合法外部入口 |
| 模块可达性（51 + 23 个模块） | **0 死模块**（唯一「未被引用」的是 `main.lua`，由 mpv 直接加载） |
| 弹幕自动加载入口（`init` vs `file-loaded`） | 无双份加载：`options.auto_load` 为真时 `return` 早退，`init()` 走不到 |
| `FALLBACK_TRIGGER` 缺陷闭合性 | 三处一致（声明 `main.lua:35` / 置位 `:789` / 重置 `render.lua:260`） |
| 搜索历史读写 | 正确（`save_*` 的每个调用点都在 `load_*` 之后，`search_history_records` 不会是 nil） |
| 服务器迁移 v1→v5 | 正确（含迁移后立即回写；空列表时 `try_bangumi` 有 nil 守卫，优雅降级而非崩溃） |

### 13.3 查实的问题与处置

**P1 — `uosc_danmaku` 零测试（最严重）**

19 个源文件（11 模块 + 6 站点解析 + 2 API）**此前没有任何自动化测试**，
而最近一次提交（`972d27f`）恰好把它的排版引擎**整体重写**了。当时的验证是
一次性的、**没有留存**，于是重写后的引擎处于零回归保护状态。

⇒ 新增 `tools/danmaku-layout-test.lua`（**34 条断言全过**）。判据设计见 13.5。

**P2 — `staff-credits-open-browser` 从未接线**

`handle_open_browser()` 自 `6c538bf` 首次接入起就**没有任何发送方**：
函数写得很完整（URL scheme 白名单校验、跨平台打开、`mp.commandv` 传 argv 防注入），
但菜单里没有对应条目 —— 用户根本点不到，是典型的「写了但从未接线」。

⇒ 按用户决定**接入主菜单**（第 7 项「在浏览器打开」）。取值链：
`state.get_last_subject(当前 path)` → `https://bgm.tv/subject/{id}`。
沿用第 6 项（观看进度）的约定：**拿不到条目信息就整个不显示**，不留点不动的死项。

**P2 — `show_danmaku_count` 无文档**

与 `clear-source` / `immediately_save_danmaku` 同类（用户自绑 `input.conf` 的入口），
但 README 里漏了它。

⇒ 补 README 一节。

**P3 — 主菜单编号重复**

`-- 9.` 出现两次（网站优先级 / 搜索设置）。是 `883a2bd` 移除番库搜索时
重编号漏改的。⇒ 已重排为 9~12。

**记录在案、本轮不改 — `dispatch_fallback` 的「用重复搜索换重试」**

`try_bangumi(server_url, on_fail)` 内部调 `search_subject_enhanced`，而后者
**不看传入的 `server_url`**，自己取 `get_active_bangumi_servers()` 并行搜全部源。
外层 `dispatch_fallback` 又按 `active_sources` 逐个调 `try_bangumi`：

- 移除 fankuhub 后，所有源 `type == "bangumi"`，两个取用函数返回同一组 URL；
- 于是「搜索全部失败」时会把**同一轮并行搜索重跑 N 遍**（默认 3 源 ⇒ 9 次请求而非 3 次，
  失败路径最坏 3 倍等待）。

但它**不是纯冗余**：`on_fail` 在「取角色失败」时也会触发，那时换 `server_url`
重取角色是条真实的重试路径。⇒ 经用户确认**暂不改，仅记录**（改法是把首次成功的
`subject` 缓存下来供后续迭代复用，属重构）。

### 13.4 三次「判据错了，不是代码错了」——本轮最重要的教训

这一轮我三次报出「问题」，三次都是**我的审计工具/探针有 bug**：

| # | 假象 | 根因 |
|---|---|---|
| 1 | `input_open` 每次调用都注册一个 `input-event` 处理器 ⇒ 疑为回调队列错乱 | **mpv 对同名 `script-message` 是「后注册覆盖前者」**。真机实证：注册 2 个处理器、发 1 次消息，只触发 1 次且是后注册的那个。故重复注册无害 |
| 2 | 排版测试 §3 三档密度**整齐地 100% 失败**（111/111、876/876、4836/4836） | 我的重叠判据把半宽写成 `(x1-x2)/2`，而 `\move` 的锚点是**文本中心** ⇒ `x1-x2 = res_x + 文本宽`，半宽虚高 960px ⇒ 阈值虚高近 2000px。**「整齐的失败率」本身就是判据错了的信号** |
| 3 | 真机探针报「菜单项没有 `hint`」 | 两次探针假象：① 连开两次菜单时第二次被状态机挡住**没发出**，`captured[#captured]` 静默复用上一轮载荷 ⇒ 假阴性；② 用 `%b{}` 切 JSON 匹配到了**外层对象**，且 `i-60` 的窗口切在了 `value` 字符串中间 |

⇒ 沉淀三条纪律：
- **探针的索引必须校验「这次真的捕获到了」**（比较 `#captured` 前后），
  否则一次 no-op 调用会静默复用上次的载荷，把「没触发」伪装成「触发了但内容不对」。
- **打印 JSON 不要用固定字节窗口**：LuaJIT 默认随机化字符串哈希 ⇒
  `format_json` 的键序**每个进程都不同**，窗口必然时对时错。要么整段打印，要么用括号配对。
- **静态判据的假阳性会教人忽略告警**（`MEMORY.md` 已有此条）。本轮
  「模块可达性」审计 v1 只认 `require`，把 34 个活模块全报成死模块（假阳性率 100%）——
  因为 `uosc_staff_credits` 的加载入口是 `bootstrap` 里的 `load_mod("modules.xxx")`。

### 13.5 新增测试的判据设计（`tools/danmaku-layout-test.lua`）

核心选择：**不复刻算法，从真正被渲染的产物反推**。

```
合成弹幕 → convert_danmaku_to_ass_events() → ASS 事件
                                              ↓
        用事件的 \move / \pos 坐标独立复算「两条弹幕在时间轴上是否真的重叠」
```

复刻算法 = 在测「我对它的理解」（算法改错时判据跟着一起错）；
查产物 = 在测「它实际画了什么」。

§3 的判据还先跑一条**坐标系自检**：若「锚点是文本中心」成立，则
`(x1 - x2) - 文本宽` 应恒等于 `res_x`（实测恒为 1920）。
**先证明尺子是对的，再量东西。**

实测结果（滚动弹幕，同 y 带且时间相交的对数 / 实际重叠数）：

| 档位 | 输入 | 产出事件 | 滚动事件 | 同带对 | 重叠 |
|---|---|---|---|---|---|
| 稀疏 | 200 | 200 | 119 | 111 | **0** |
| 中等 | 800 | 800 | 483 | 876 | **0** |
| 密集 | 3000 | 3000 | 1871 | 4836 | **0** |

**变异验证（证明测试有牙）**：把 `find_y_from_top` 的碰撞判定改成恒假
（`if false and y_intersects(...)`），重叠立刻爆到 **103 / 1401 / 21702**，
§4 固定弹幕也一并红。还原后回到 0。

> ⚠️ 记一笔**无效变异**：最初想把 `find_y_from_top` 改成「恒 `return 1`」，
> 但 Lua 要求 `return` 必须是块的最后一条语句 ⇒ 后面还跟着 `local y = 1` 就是**语法错误**，
> 测试报的是「模块加载失败」而不是「碰撞违例」——**信号错了，等于没测**。

### 13.6 本轮门禁清单（16 项，全部通过）

```bash
# 在 portable_config/ 下
../luajit.exe tools/lua-syntax-check.lua             #  1. 语法：186/186
../luajit.exe tools/osd-button-selftest.lua          #  2. 自测：16/16
../luajit.exe tools/osd-button-drift-regression.lua  #  3. 漂移回归
python tools/uosc-verify-buttons.py                  #  4. 按钮：未注册 0
python tools/uosc-verify-routes.py                   #  5. 工具栏路由：未注册 0
python tools/uosc-verify-menu-routes.py              #  6. 菜单路由：本项目未注册 0
python tools/lua-audit-nilguards.py                  #  7. 审计：P0/P1/INFO = 0
python tools/lua-audit-nilguards-selftest.py         #  8. 金丝雀：规则有效

../luajit.exe tools/bangumi-user-test.lua            #  9.
../luajit.exe tools/progress-sync-test.lua           # 10.
../luajit.exe tools/staff-grid-paging-test.lua       # 11.
../luajit.exe tools/runtime-config-test.lua          # 12. 42/42
../luajit.exe tools/guess-title-test.lua             # 13. 13/13
../luajit.exe tools/title-normalize-test.lua         # 14. 58/58
../luajit.exe tools/danmaku-layout-test.lua          # 15. 34/34  ★本轮新增
```

真机：`biz-smoke`（5 个业务路由派发，0 Lua error）+ 常规启动冒烟（0 错误）。
