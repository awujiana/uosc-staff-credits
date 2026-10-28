# uosc_staff_credits 项目 UI 文档

> 2026-10-27 ASS 绘图基线与职员表生命周期补充见 [ASS_RENDERING.md](./ASS_RENDERING.md)。

> 版本: 1.9.2  ·  最后更新: 2026-08-02
>
> ⚠️ **本文档是 v1.9.2 的历史快照，正文未随代码更新。**
> 文中描述的 `fankuhub` 聚合源已于 v2.0 移除，主菜单「番库搜索」一项也随之删除
> （其后各项编号 6→5 … 12→11）。移除详情见 `internal/REVIEW_AND_MERGE.md` §12。

---

## 0. UI 形态概览

本项目 UI 分两种形态：

| 形态 | 实现 | 用途 | 文件 |
|------|------|------|------|
| **uosc 原生菜单** | `mp.commandv("script-message-to", "uosc", "open-menu", json)` | 列表选择、输入面板、加载提示、设置 | `modules/menu.lua` |
| **ASS overlay 面板** | `mp.create_osd_overlay('ass-events')` + `overlay-add` | 卡片化角色介绍、封面简介、制作评分、职员表 | `modules/cards.lua` / `cover_intro.lua` / `production_score.lua` / `staff_grid.lua` |

### 0.1 面板显示规则（v1.9.2）

> **v1.9 叠加修复**：loading 菜单（uosc 层）与 ASS overlay 面板（ASS 层）原本可堆叠显示。修复后 `loading_controller.finish_silent()` 在搜索成功时**立即关闭** loading 菜单（不再等待 0.5s），且 4 个面板 `show()` 入口均增加防御性 `close_menu(MENU_LOADING)`，确保 loading 菜单不会与新面板同屏残留。

| 组合 | 行为 | 说明 |
|------|------|------|
| ASS overlay + ASS overlay | **互斥**（旧的关闭，新的显示） | 4 个 ASS overlay 面板同一时间仅一个可见，由 `panel_registry.close_all_except` 管理 |
| uosc 菜单 + ASS overlay | **可堆叠**（同时显示） | 两者独立渲染层，不冲突 |
| uosc 菜单 + uosc 菜单 | uosc 自身管理 | `menu_visible_type` 影子副本 + `open-menu`/`update-menu` 智能选择 |

**互斥实现**：每个 ASS overlay 面板的 `show()` 入口调用 `deps.ui_base.close_other_panels(name)` → `panel_registry.close_all_except(name)`，关闭其他已可见的 ASS overlay。

**堆叠实现**：uosc 菜单通过 `mp.commandv("script-message-to", "uosc", "open-menu")` 在 uosc 渲染层显示，不干扰 ASS overlay 的 `mp.create_osd_overlay('ass-events')` 渲染层。

**7 大功能 UI 形态分布**：

| # | 功能 | UI 形态 |
|---|------|---------|
| 1 | 职员表 | ASS overlay 面板（5 列网格，支持翻页，仅工作职员：真实名称 + 职位） |
| 2 | 角色介绍 | ASS overlay 面板（2 行 × 2~5 列卡片网格，仅虚拟角色 + 地位 + CV） |
| 3 | 封面简介 | ASS overlay 面板（960×580 左右分栏） |
| 4 | BGM 搜索 | uosc 菜单（输入面板 → 结果列表，自动填入中文名） |
| 5 | 番库搜索 | uosc 菜单（输入面板 → 结果列表，自动填入中文名） |
| 6 | 制作评分 | ASS overlay 面板（960×580 左右分栏） |
| 7 | 番剧中文名搜索 | 无独立 UI（后台转换 + 日志） |
| - | 静默预加载 | 无 UI（路径切换后后台预取，仅 debug 日志） |

---

## 1. 四个核心面板

### 1.0 职员表面板 (modules/staff_grid.lua)

#### 1.0.1 面板尺寸

**全屏自适应布局**（非固定尺寸），5 列网格 + 翻页按钮 + 底部提示栏。

**LAYOUT 常量表**：

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `title_h` | 40 | 标题区域高度 |
| `separator_h` | 8 | 标题下分隔线高度 |
| `hint_h` | 30 | 底部提示高度 |
| `margin` | 40 | 上下边距 |
| `cell_spacing` | 10 | 单元格间距 |
| `cell_h` | 50 | 单元格高度 |
| `visible_rows` | 14 | 可见行数（动态计算，限制 3-20） |
| `name_fs` | 18 | 职员名字号 |
| `role_fs` | 12 | 职位字号 |
| `title_fs` | 28 | 标题字号 |
| `per_row` | 5 | 每行显示列数 |
| `btn_w` | 100 | 翻页按钮宽度 |
| `btn_h` | 32 | 翻页按钮高度 |
| `btn_arrow_fs` | 20 | 翻页按钮箭头字号 |

#### 1.0.2 网格布局算法 (compute_layout)

- **基准缩放**：`ui_scale = osd_w / 1920`（以 1920×1080 为基准）
- **列数固定**：`per_row = 5`（5 列显示）
- **单元格宽度**：`cell_w = floor((avail_w - spacing * (per_row - 1)) / per_row)`
- **可见行数动态计算**：根据可用高度计算 `visible_rows`，限制在 `[3, 20]`
- **水平居中**：`start_x = floor((osd_w - total_w) / 2)`，但不小于 margin
- **垂直布局**：标题 → 分隔线 → 网格 → 翻页按钮 → 底部提示

#### 1.0.3 单元格内容布局

| 元素 | 字号 (× ui_scale) | 颜色 | 对齐 |
|------|------------------|------|------|
| 背景矩形 | - | `2A2930` alpha `C0`；悬停 `3A3940` alpha `D0` + 边框 `88C0FC` 2px | - |
| 职员名 | `fs=18` bold | `FFFBFF` | 居中 `\an5`，位于单元格 35% 处 |
| 职位 | `fs=12` | `A8D4F7` | 居中 `\an5`，位于单元格 72% 处 |

#### 1.0.4 翻页机制

- **翻页按钮**：左右两个按钮，位于网格下方、底部提示上方
- **按钮位置（v1.7）**：由 `modules/pagination.lua` 统一计算 Y 坐标（详见第 13.5.1 节）
  - 旧位置（v1.6）：`hint_y - btn_h - 4`（距底部提示栏 4px）
  - 新位置（v1.7）：`hint_y - btn_h - s(40)`（上移 40px 避开 uosc 控制条）
  - 支持 `pagination_position` 配置（top/middle/bottom），默认 `bottom`
- **上一页按钮**：左对齐，箭头 `◀`（Unicode U+25C0）
- **下一页按钮**：右对齐，箭头 `▶`（Unicode U+25B6）
- **按钮状态**：
  - 禁用（首页/末页）：背景 `1A1A20`，文字 `606060`，alpha `80`
  - 默认：背景 `2A2930`，文字 `88C0FC`，alpha `C0`
  - 悬停：背景 `3A3940`，边框 `88C0FC` 2px，文字 `88C0FC`，alpha `D0`
- **鼠标交互**：点击按钮触发翻页，悬停时高亮
- **键盘交互**：`PgUp`/`PgDn` 翻页（通过 input_service 注册）

#### 1.0.5 底部提示栏

**位置**：`hint_y = osd_h - floor(40 * ui_scale)`

**样式**：
- `fs = floor(14 * ui_scale)`
- 颜色 `808080`（暗灰）
- `\an5` 居中对齐

**内容**：
```
ESC 关闭 · ↑↓/PgUp/PgDn 翻页 · 第 X/Y 页 · 共 N 人
```

#### 1.0.6 overlay id 分配

职员表面板不使用图片 overlay，仅使用 ASS overlay 渲染文本和矩形。

#### 1.0.7 关闭按钮（v1.7.2 引入，v1.7.4 补悬停反馈）

**位置**：右上角，`close_x = start_x + total_w + s(12) - close_size`，`close_y = title_y`

| 状态 | 背景 | 文字色 | 边框 | 说明 |
|------|------|--------|------|------|
| 默认 | `2A2930` alpha `60` | `A0A0A0` | 无 | - |
| 悬停 | `3A3940` alpha `60` | `E06C75` | `88C0FC` 2px | v1.7.4 新增 |

**尺寸**：`close_size = s(28)`，字号 `floor(close_size * 0.6)`

**实现要点（坐标同源）**：渲染时把矩形写入 `state.close_btn = {x, y, size}`，
命中检测（`hit_test` 与 `on_mouse_click`）**直接读取该值**，不另算一套公式 —— 这是按钮"位置不偏"的根本保障。

**v1.7.4 修复**：关闭按钮此前未纳入 `mouse_interaction` 的 `hit_test`（只返回翻页按钮与单元格），
导致鼠标悬停 ✕ 无任何视觉反馈。现已在 `hit_test` 中优先返回 `"close"`，
`on_hover_change` 据此把 `state.hover_button` 置为 `"close"` 触发重绘。

---

### 1.1 角色介绍面板 (modules/cards.lua)

#### 1.1.1 尺寸与布局

**全屏自适应布局**（非固定尺寸），横排两行卡片网格 + 底部无图角色文字横排。

**LAYOUT 常量表**：

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `title_h` | 40 | 标题区域高度 |
| `separator_h` | 8 | 标题下分隔线高度 |
| `hint_h` | 30 | 底部提示高度 |
| `margin` | 40 | 上下边距 |
| `no_image_line_h` | 24 | 无图角色文字行高 |
| `no_image_max_lines` | 3 | 无图角色最多显示行数 |
| `no_image_per_line` | 6 | 无图角色每行最多展示数 |
| `no_image_padding` | 28 | 无图区域上下额外内边距 |
| `visible_rows` | 2 | 固定显示行数 |
| `card_spacing` | 12 | 卡片之间间距 |
| `card_w` | 200 | 单张卡片宽度（V4-P2-36: 180→200） |
| `min_card_h` | 220 | 卡片最小高度 |
| `max_card_h` | 420 | 卡片最大高度 |
| `cv_line_h` | 24 | CV 信息行高度 |
| `min_per_row` | 2 | 每行最少列数 |
| `max_per_row` | 5 | 每行最多列数 |
| `img_padding` | 6 | 图片在卡片内的内边距 |
| `img_h_ratio` | 0.70 | 图片高度占卡片高度 70% |
| `text_area_h` | 0.30 | 文字区域占卡片高度 30% |
| `title_start_offset` | 10 | 卡片起始 Y 距离 separator 的偏移 |

#### 1.1.2 网格布局算法 (compute_layout)

- **基准缩放**：`ui_scale = osd_w / 1920`（以 1920×1080 为基准）
- **列数自适应**：`per_row = floor((avail_w + card_spacing) / (card_w + card_spacing))`，限制在 `[2, 5]`
- **动态扩大卡片**：当 per_row 达到 max_per_row 后仍有空间，动态扩大 card_w 填满可用宽度，最大 `s(240)`
- **卡片高度**：`card_h = floor((avail_h - card_spacing*(visible_rows-1)) / visible_rows) + s(cv_line_h)`，限制在 `[s(220), s(420)]`
- **水平居中**：`start_x = floor((osd_w - total_w) / 2)`，但不小于 margin
- **垂直居中**：在标题/分隔线/提示栏/无图区域之间的可用空间内居中

#### 1.1.3 卡片内容布局

**v1.6 两行布局**：每张卡片文字区仅显示两行，简化视觉，避免信息过载。

| 元素 | 字号 (× ui_scale) | 颜色 | 对齐 |
|------|------------------|------|------|
| 背景矩形 | - | `2A2930` alpha `C0`；悬停 `3A3940` alpha `D0` + 边框 `88C0FC` 2px | - |
| 图片区域 | - | 占卡片高度 70%，padding 6px | - |
| 文字区域底色 | - | `000000` alpha `90` | - |
| 第一行：角色名 | `fs=22` bold | `FFFBFF` | 居中 `\an5`，位于文字区 30% 处 |
| 第二行：关系 + CV | `fs=14` | `A8D4F7` | 居中，位于文字区 75% 处；有 CV 头像时偏右 16px |
| CV 小头像 | 24×24 px | - | 懒加载延迟 0.5s |

**第二行文本格式**（`build_relation_cv_line(char)`）：
- 有关系：`关系 CV cv_name`（例：`主角 CV 内田雄馬`）
- 无关系：`CV cv_name`（例：`CV 未知`）
- 关系字段来自 bangumi `relation`（`主角`/`配角`/`客串`）
- CV 名优先级：`actor.name_cn` → `actor.nameCn` → `actor.name` → `"未知"`
- 无图角色区底部文字格式：`角色名 关系 CV cv_name`（与卡片第二行一致）

**CV 头像 overlay id 范围**：32-47（角色图片 0-31 之外）

#### 1.1.4 翻页机制

- `page_right()`：向后翻页（RIGHT/WHEEL_DOWN），offset += visible_count，显示 ↓ 箭头反馈 200ms
- `page_left()`：向前翻页（LEFT/WHEEL_UP），offset -= visible_count（不小于 0），显示 ↑ 箭头反馈 200ms
- 翻页前调用 `abort_in_flight_downloads()` 取消进行中下载
- 重置 `hover_index=0`，递增 `render_version` 使旧回调失效
- **翻页按钮位置（v1.7）**：由 `modules/pagination.lua` 统一计算（详见第 13.5.1 节）
  - 默认 `bottom`：`hint_y - btn_h - s(40)`（上移 40px 避开 uosc 控制条，原为 4px）
  - 支持 `pagination_position` 配置（top/middle/bottom）

**翻页反馈箭头**：
- 字号 `fs=32*ui_scale`，bold
- 颜色 `88C0FC`（浅蓝）
- 居中于屏幕中心 X
- 距顶/底 `60*ui_scale` 像素

---

### 1.2 封面简介面板 (modules/cover_intro.lua)

#### 1.2.1 面板尺寸

**960×580 基准**（居中显示，按 `osd_w/1920` 比例缩放）。

- OSD 高度不足时按高度比例缩小：`h_scale = min(1.0, max_panel_h / s(580))`，其中 `max_panel_h = osd_h - s(80)`（上下各留 40px）
- 面板内边距 `pad = s(24)`
- 标题区高度 `title_h = s(36)`
- 分隔线高度 `separator_h = s(1)`
- 提示栏高度 `hint_h = s(24)`

#### 1.2.2 左右分栏

| 区域 | 宽度 | 内容 |
|------|------|------|
| 左侧封面区 | `left_w = s(280)` | 封面图 2:3 比例（`cover_h = cover_w * 1.5`），居中于左侧 |
| 右侧内容区 | `right_w = content_w - left_w - s(20)`（最小 `s(300)`） | 番剧名称、评分、标签、制作信息、简介 |

内容区起点：`content_y = panel_y + title_h + separator_h + s(12)`

#### 1.2.3 右侧内容字段

| 字段 | 字号 (× ui_scale) | 颜色 | 说明 |
|------|------------------|------|------|
| 番剧名称（中文） | `fs=22` bold | `F0F0F0` | 左对齐 `\an4`，truncate 40 字符 |
| 别名行（日/英/罗马音） | `fs=14` | 标签 `88C0FC` / 值 `B0B0B0` | truncate 44 字符 |
| 评分行（多平台） | - | 平台名 `FFD700` 金色 | 每平台一行，格式 `平台名 评分 (投票数)` |
| 评分行（单平台） | - | `FFD700` | `评分` 或 `Bangumi` 标签 |
| 元数据（类型/首播/集数/时长） | `fs=14` | 标签 `808080` / 值 `D0D0D0` | - |
| 制作信息 | `fs=14` | 标题 `808080` / 值 `C8C8C8` | 导演/原作/制作/改编，truncate 14-16 字符 |
| 标签 | `fs=13` | 标题 `808080` / 块背景 `2A4A6A` alpha `40` / 文字 `A8D4F7` | 最多 10 个，行高 `20*ui_scale`，间距 `5*ui_scale` |
| 简介标题 | `fs=20` bold | `88C0FC` | - |
| 简介正文 | `fs=18` | `E8E8E8` | 行高 `26*ui_scale`，软换行算法（中文 1em，英文 0.55em） |

**字段回退顺序**：summary → synopsis → description → intro → "暂无简介信息"

---

### 1.3 制作评分面板 (modules/production_score.lua)

#### 1.3.1 面板尺寸

**960×580 基准**（居中显示，按 `osd_w/1920` 缩放）。

- `PANEL_BASE_W = 960`
- `PANEL_BASE_H = 580`
- 高度不足时缩小：`h_scale = min(1.0, max_panel_h / s(580))`

**LAYOUT 常量**：

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `pad` | 24 | 面板内边距 |
| `title_h` | 40 | 标题区高度 |
| `footer_h` | 30 | 底部提示区高度 |
| `list_width` | 300 | 左侧列表宽度 |
| `list_gap` | 16 | 左右分栏间距 |
| `row_height` | 28 | 列表行高 |
| `detail_pad` | 20 | 右侧详情内边距 |

#### 1.3.2 左右分栏

| 区域 | 位置 | 说明 |
|------|------|------|
| 左侧人员列表 | `list_x = panel_x + s(24)`, `list_w = s(300)` | 从 `content_y` 开始 |
| 右侧详情区 | `detail_x = list_x + list_w + s(16)`, `detail_w = panel_x + panel_w - s(24) - detail_x` | - |

内容区：`content_y = panel_y + s(40)`，`content_h = panel_h - s(40) - s(30)`

#### 1.3.3 左侧人员列表

- **列表背景**：颜色 `2A2930`，alpha `C0`
- **行高**：`s(28)`，最多显示 `floor((visible_h - s(20)) / row_h)` 行
- **选中行高亮**：背景 `4A4950` alpha `E0`，左侧 4px 蓝色指示条 `88C0FC`
- **行内容**：`[组标签] 人员名`
  - 字号 `fs=14*ui_scale`
  - 选中色 `FFFBFF`，未选中色 `D0D0D0`

**9 个角色组**：动画制作 / 系列构成 / 脚本 / 监督 / 人物设定 / 总作画监督 / 音乐 / 美术监督 / 摄影监督

#### 1.3.4 右侧详情面板

| 元素 | 字号 (× ui_scale) | 颜色 | 说明 |
|------|------------------|------|------|
| 背景 | - | `2A2930` alpha `C0` | 同左侧 |
| 关闭按钮 | size `s(28)` | 背景 `2A2930` alpha `60` / X `A0A0A0` | 距边缘 `s(8)`，line_w `max(1, floor(size * 0.08))` |
| 人员名 | `fs=18` bold | `FFFBFF` | - |
| 大分数 | `fs=28` bold | 按分数着色（见下表） | 右对齐 |
| 有效作品数 | `fs=11` | `A0A0A0` | - |
| 担任角色 | `fs=13` | `88C0FC` | - |
| 分隔线 | - | `555555` alpha `AA` | - |
| 子指标（两列） | `fs=12` | 标签 `A0A0A0` | 基础加权分/近作分/有效作品数/翻车作（红色），最多 6 项 |
| 历史作品列表 | `fs=12` | `D0D0D0`，按评分着色 | 年份 + 标题 + 评分 |

#### 1.3.5 评分颜色映射

| 分数范围 | 颜色 | 含义 |
|---------|------|------|
| ≥7.5 | `6FCF87` | 绿色（优秀） |
| ≥6.5 | `FFD93D` | 黄色（良好） |
| ≥5.5 | `FF9F43` | 橙色（一般） |
| <5.5 | `FF6B6B` | 红色（较差） |
| nil | `A0A0A0` | 灰色（无评分） |

---

## 2. ASS 渲染机制 (modules/ass_lib.lua)

### 2.1 提供的函数

| 函数 | 签名 | 说明 |
|------|------|------|
| `get_osd_size()` | `() -> osd_w, osd_h` | 读取 `osd-width`/`osd-height`，默认 1280×720 |
| `get_video_display_rect()` | `() -> {osd_w, osd_h, disp_x, disp_y, disp_w, disp_h, video_w, video_h}` | 视频在 OSD 中的显示区域 |
| `osd_to_video_coords(osd_x, osd_y, rect?)` | `-> video_x, video_y` | OSD 坐标转视频像素坐标 |
| `hex_to_ass(hex)` | `(RRGGBB) -> BBGGRR` | ASS 颜色转换（无效返回 `FFFFFF`） |
| `ass_escape(text)` | `(text) -> escaped` | ASS 文本转义（处理 `\ { } \n \r \t \z`） |
| `draw_rect(x, y, w, h, fill_color?, border_color?, border_w?, fill_alpha?, border_alpha?)` | `-> ASS string` | 矩形绘制（描边+填充） |
| `draw_text(x, y, text, style?)` | `-> ASS string` | 单行文本绘制 |
| `render_empty_state(overlay, msg, hint?)` | `-> void` | 渲染统一空状态提示 |

**注意**：ass_lib.lua 不提供 `draw_image_overlay`。图片 overlay 通过 mpv 的 `overlay-add` 命令实现。

### 2.2 draw_rect 实现细节

**统一模式**（V4-P3）：`\an7\pos(0,0)` + 绝对坐标 `m x y l x2 y2 l x3 y3 l x4 y4`

```lua
-- 填充
"{\\fs1\\1c&H{bbggrr}&\\1a&H{alpha}&\\bord0\\shad0\\an7\\p1\\pos(0,0)}m x y l (x+w) y l (x+w) (y+h) l x (y+h){\\p0}\n"
```

- `\an7`：左上角对齐（基准点在矩形左上角）
- `\pos(0,0)`：将锚点放在 OSD 原点（0,0）
- `\fs1`：字体大小 1（绘图模式不显示文字，但需设置）
- `\p1`：进入绘图模式
- `m x y`：移动到起点（绝对坐标）
- `l x y`：画线到指定点
- `{\\p0}`：退出绘图模式
- 4 个顶点顺序：左上 → 右上 → 右下 → 左下（闭合矩形）

**边框实现**：不用 `\bord`（避免内外扩展覆盖填充），改为画 4 条矩形边（顶/底/左/右），每条边向外扩展 `bs = max(1, floor(border_w))` 像素。

---

## 3. OSD overlay 机制

### 3.1 创建方式

```lua
state.overlay = mp.create_osd_overlay('ass-events')
state.overlay.res_x = layout.osd_w
state.overlay.res_y = layout.osd_h
state.overlay.data = table.concat(ass_parts)
state.overlay:update()
```

### 3.2 关键约束

- `res_x`/`res_y` **必须等于** `osd_w`/`osd_h`（V4-P3 修复），确保 ASS 坐标 → 像素 1:1 映射，无缩放
- 若设为 `display_w`/`display_h`（通常 > osd），libass 在更大画布渲染后 mpv 再缩放回 OSD，导致所有元素位置偏移
- overlay 类型为 `'ass-events'`（ASS 事件流）
- 关闭时调用 `state.overlay:remove()` 并置 nil

### 3.3 图片 overlay

通过 mpv 命令实现：

```lua
mp.commandv("overlay-add", overlay_id, video_x, video_y, bgra_path, 0, "bgra", w, h, 4 * w, "osd-cover")
```

- `osd-cover` flag（V4-P2-31 修复）：让 overlay 使用 OSD 坐标空间，与 ASS overlay 共用同一坐标系
- 移除：`mp.commandv("overlay-remove", overlay_id)`
- BGRA 格式：stride = `4 * w`，每个像素 4 字节

### 3.4 overlay id 分配

**v1.7 起：overlay id 由 `overlay_manager.alloc_id(panel_name, count)` 动态分配**（详见第 13.5.2 节）。

- **MAX_ID**：62（63 保留给其他用途，因 mpv 上限为 63）
- **分配策略**：在 `[0, 62]` 区间内寻找连续空闲 id，避免不同面板冲突
- **同一面板重复调用**：先释放旧分配再重新分配
- **降级模式**：`alloc_id` 失败时回退到 v1.6 静态范围

**v1.6 静态范围（兼容降级使用）**：

| 面板 | 范围 | 用途 |
|------|------|------|
| cards.lua | 0-31 | 角色图片（最多 32 张） |
| cards.lua | 32-47 | CV 头像（最多 16 张） |
| cover_intro.lua | 62 | 单张封面（使用 62 避免与 cards 0-47 冲突，63 是 mpv 最大值） |

---

## 4. 坐标系统

### 4.1 OSD 逻辑坐标（V4-P3 统一）

- **原点**：左上角 (0, 0)
- **X 轴**：向右
- **Y 轴**：向下
- **单位**：逻辑像素（已应用 DPI 缩放）
- **获取**：`mp.get_property_native("osd-width")` / `mp.get_property_native("osd-height")`
- **默认值**：1280×720（防御性处理，属性可能返回 0 或 nil）

### 4.2 ui_scale 缩放

```lua
ui_scale = osd_w / 1920  -- 以 1920×1080 为基准
s(v) = math.floor(v * ui_scale)
```

保证 1080p/4K 等不同物理分辨率下视觉大小一致。

### 4.3 关键修复记录

- V4-P3：compute_layout 用 osd_w/osd_h 计算坐标，但 res_x/res_y 设为 display_w/display_h 导致矩形和文字偏移量不同
- **修复**：`res_x`/`res_y` 必须等于 `osd_w`/`osd_h`
- mouse-pos 已返回 OSD 逻辑坐标，无需转换

---

## 5. 字体设置

### 5.1 默认字体

mpv 默认 `osd-font="Noto Sans Mono CJK SC"`（等宽字体，部分中文字符/标点字形不全）。

### 5.2 强制中文字体（cover_intro.lua ISSUE-013 修复）

对所有 `{\\fs` 样式块插入 `\\fnNoto Sans CJK SC`，排除绘图指令（`{\\fs1` 且包含 `\\p1` 的块保持原样）：

```lua
ass_str:gsub("{\\fs(%d+)([^}]*)}", function(fs_num, rest)
    if rest and rest:find("\\p1") then
        return "{\\fs" .. fs_num .. rest .. "}"  -- 绘图块保持原样
    end
    return "{\\fs" .. fs_num .. "\\fnNoto Sans CJK SC" .. rest .. "}"
end)
```

### 5.3 字号层级

| 面板 | 元素 | 字号 (基准值，乘 ui_scale) |
|------|------|------|
| cards | 标题 | 28 |
| cards | 角色名（第一行） | 22 |
| cards | 关系 + CV（第二行） | 14 |
| cards | 无图角色标题/名 | 15 |
| cards | 底部提示 | 14 |
| cards | 翻页按钮箭头 | 20 |
| cards | 翻页反馈箭头 | 32 |
| cards | 图片加载失败提示 | 12 |
| cover_intro | 面板标题 | 32 |
| cover_intro | 中文名 | 22 |
| cover_intro | 别名 | 14 |
| cover_intro | 评分/元数据 | 14 |
| cover_intro | 制作信息 | 14 |
| cover_intro | 标签 | 13 |
| cover_intro | 分节标题 | 14 |
| cover_intro | 简介标题 | 20 |
| cover_intro | 简介正文 | 18 |
| cover_intro | 提示 | 16 |
| cover_intro | 无封面/失败 | 18-20 |
| production_score | 标题 | 22 |
| production_score | 副标题 | 12 |
| production_score | 列表项 | 14 |
| production_score | 人员名 | 18 |
| production_score | 大分数 | 28 |
| production_score | 子指标 | 12 |
| production_score | 历史作品 | 12 |
| production_score | 提示 | 12 |

---

## 6. 颜色方案

### 6.1 通用色板

| 用途 | 颜色 (RRGGBB) | Alpha | 说明 |
|------|---------------|-------|------|
| 面板背景 | `121018` | `80` | 深紫黑，半透明 |
| 顶部装饰线 | `88C0FC` | `00` | 浅蓝色，不透明 |
| 列表/卡片背景 | `2A2930` | `C0` | 深灰 |
| 选中/悬停高亮 | `3A3940` / `4A4950` | `D0`/`E0` | 略浅 |
| 悬停边框 | `88C0FC` | - | 浅蓝，2px |
| 选中指示条 | `88C0FC` | - | 浅蓝，4px |
| 标题/强调色 | `88C0FC` | - | 浅蓝 |
| 主文字 | `FFFBFF` / `F0F0F0` / `E8E8E8` | - | 近白色 |
| 次文字 | `D0D0D0` / `C8C8C8` | - | 浅灰 |
| 弱文字 | `AAAAAA` / `B0B0B0` | - | 中灰 |
| 提示文字 | `A0A0A0` / `808080` / `707070` | - | 暗灰 |
| 分隔线 | `505050` / `555555` | - | 灰色 |
| 标签背景 | `2A4A6A` | `40` | 深蓝 |
| 标签文字 | `A8D4F7` | - | 浅蓝 |
| 关闭按钮悬停 | `E06C75` | - | 红色 |
| 关闭按钮默认 | `2A2930` | `60` | 深灰 |
| 关闭按钮 X | `FFFFFF` (cards) / `A0A0A0` (production_score) | - | 白/灰 |

### 6.2 评分颜色映射

| 分数范围 | 颜色 | 含义 |
|---------|------|------|
| ≥7.5 | `6FCF87` | 绿色（优秀） |
| ≥6.5 | `FFD93D` | 黄色（良好） |
| ≥5.5 | `FF9F43` | 橙色（一般） |
| <5.5 | `FF6B6B` | 红色（较差） |
| nil | `A0A0A0` | 灰色（无评分） |

### 6.3 评分数字色

- 平台评分值：`FFD700`（金色）
- Bangumi 评分：`FFD700`

### 6.4 错误/警告色

| 类型 | 颜色/前缀 |
|------|---------|
| 错误文字 | `FF6B6B`（红色） |
| 警告 OSD 前缀 | `⚠ `（黄色） |
| 错误 OSD 前缀 | `✖ `（红色） |
| 信息 OSD 前缀 | `ℹ `（蓝色） |

### 6.5 文字区域半透明底色

| 位置 | 颜色 | Alpha |
|------|------|-------|
| cards 文字区底色 | `000000` | `90` |
| production_score 分隔线 | `555555` | `AA` |

---

## 7. 按键绑定

### 7.1 角色介绍面板 (cards.lua)

| 按键 | 名称 | 功能 | forced |
|------|------|------|--------|
| `RIGHT` | `cards-right` | 向后翻页 | 否 |
| `LEFT` | `cards-left` | 向前翻页 | 否 |
| `WHEEL_DOWN` | `cards-wdown` | 向后翻页（滚轮） | 否 |
| `WHEEL_UP` | `cards-wup` | 向前翻页（滚轮） | 否 |
| `ESC` | `cards-close` | 关闭面板 | **是** |
| `Ctrl+MBTN_RIGHT` | `cards-close-m` | 关闭面板（避免与 mpv 默认右键菜单冲突） | 否 |
| `MBTN_LEFT` | `cards-mouse-click` | 点击关闭按钮 | **是** |

### 7.2 封面简介面板 (cover_intro.lua)

| 按键 | 名称 | 功能 | forced |
|------|------|------|--------|
| `ESC` | `cover-intro-close` | 关闭面板 | **是** |
| `Ctrl+MBTN_RIGHT` | `cover-intro-close-m` | 关闭面板 | **是** |

**注意**：V4-P3-16 修复移除了 `MBTN_LEFT` 全局绑定（forced=true 会拦截所有左键点击，影响截图工具、uosc 拖拽）。

### 7.3 制作评分面板 (production_score.lua)

| 按键 | 名称 | 功能 | forced | opts |
|------|------|------|--------|------|
| `up` | `production_score_up` | 选择上一人 | **是** | `{repeatable=true}` |
| `down` | `production_score_down` | 选择下一人 | **是** | `{repeatable=true}` |
| `esc` | `production_score_close` | 关闭面板 | **是** | - |
| `mbtn_left` | `production_score_mbtn_left` | 点击 ✕ 关闭按钮（10px 容差） | **是** | - |

### 7.4 加载菜单 ESC 强制绑定 (loading_controller.lua)

- 按键：`ESC`
- 名称：`staff_credits_loading_esc`
- forced: **是**
- 触发：`script-message-to {script_name} staff-credits-loading-close`
- 仅首次 `show_with_countdown` 注册（`esc_binding_registered` 标志防重复）

### 7.5 按键注册统一接口

```lua
-- ui_base.safe_add_key(key, name, fn, forced, opts)
-- forced=true 时优先 mp.add_forced_key_binding（pcall 保护）
-- 失败回退到 mp.add_key_binding
```

V4-P2-36 修复：`mp.add_forced_key_binding` 在多数 mpv 版本返回 nil，改用 pcall 成功与否判断。

---

## 8. uosc menu 集成 (modules/menu.lua)

### 8.1 菜单类型常量

| 常量 | 值 | 用途 |
|------|-----|------|
| `MENU_MAIN` | `staff_credits_main` | 主菜单（Bangumi 工具箱） |
| `MENU_CHARACTERS` | `staff_credits_characters` | 职员表菜单 |
| `MENU_SEARCH` | `staff_credits_search` | BGM 搜索输入面板 |
| `MENU_RESULTS` | `staff_credits_results` | 搜索结果列表 |
| `MENU_LOADING` | `staff_credits_loading` | 加载中菜单 |
| `MENU_SETTINGS` | `staff_credits_settings` | 设置菜单 |
| `MENU_SERVERS` | `staff_credits_servers` | 网站优先级菜单 |

### 8.2 主菜单 (menu.show_main_menu)

- 标题：`Bangumi 工具箱`
- `search_style = "disabled"`

**菜单项**：

| 序号 | 标题 | icon | 说明 | 触发消息 |
|------|------|------|------|---------|
| 1 | 职员表 | `contact_page` | 查看工作职员列表（真实名称 + 职位） | `staff-credits` |
| 2 | 角色介绍 | `person` | 卡片化显示虚拟角色（含图片、关系标签、CV） | `character-intro` |
| 3 | 封面简介 | `book_cover` | 番剧封面+基本信息+简介梗概 | `cover-intro` |
| 4 | BGM 搜索 | `search` | 手动搜索 Bangumi 条目（自动填入中文名） | `staff-credits-search bangumi` |
| 5 | 番库搜索 | `video_library` | 搜索 fankuhub 聚合源（自动填入中文名） | `staff-credits-fankuhub-search` |
| 6 | 制作评分 | `sentiment_satisfied` | 分析制作人员的历史作品评分 | `staff-credits-production-score` |
| 7 | ─── 设置 ─── | - | 分隔项（italic, unselectable, keep_open） | - |
| 8 | 网站优先级 | `swap_vert` | 配置首选获取的网站 · ctrl+↑↓ 排序 | `staff-credits-servers` |
| 9 | 搜索设置 | `settings` | 清除缓存等选项 | `staff-credits-settings` |
| 10 | 清除当前视频缓存 | `delete` | 删除当前动漫的搜索记录 | `staff-credits-clear-cache` |
| 11 | 清除所有缓存 | `delete_sweep` | 删除全部搜索记录 | `staff-credits-clear-all` |

### 8.3 职员表菜单 (menu.show_characters)

- 标题：番剧中文名（fallback "职员表"）
  - 优先级（v1.6）：`subject.name_cn` → `search_title_used`（已过中文转换，必为中文）→ `subject.name` → `media-title` → "未知条目"
  - `on_cached_hit` 通过 `resolve_cached_title` 统一获取中文标题
- 宽度：`560`（v1.6 从 440 增大，避免职员名+职位被截断）
- `search_style = "on_demand"`
- footnote：`共 N 名职员 | 滚动查看全部 · 输入文字筛选`（仅职员场景）/ `共 N 人（角色 X · 职员 Y） | 滚动查看全部 · 输入文字筛选`（混合场景兜底）
- 菜单项 icon：职员 `badge`
- 职员项 hint：`relation` 字段（职位，如"监督"、"脚本"、"作画监督"）
- **全部职员加载**：所有职员一次性加入菜单项，uosc 菜单自适应屏幕高度并支持滚动查看全部

**职员表流程**（`features/staff_credits.lua`，仅职员，不含角色）：
1. 通过 `run_subject_pipeline` 获取条目 subject
2. **仅调用** `api.get_subject_persons(subject.id, server_url, ...)`（不再并发拉取角色，减少请求量）
3. `build_staff_items(persons)` 过滤 `p.type ~= CHAR_TYPE_CHARACTER`（跳过 type=1 的角色项），构造职员 items：
   - 职员项：`{kind="staff", name, role, cv="", images}`（仅真实名称 + 职位）
4. `menu.show_characters(title, items)` 渲染为 uosc 菜单

**菜单项字段映射**：

| 字段 | 来源 | 示例 |
|------|------|------|
| `title` | `name_resolver.resolve_person` | "汤浅政明" / "新房昭之" |
| `icon` | kind == "staff" → `badge` | `badge` |
| `hint` | staff: `{role}` (relation 字段) | `监督` / `脚本` / `作画监督` |

**注意**：角色展示由"角色介绍"功能（`character_cards.lua` + `cards.lua`）负责，与职员表严格分离。

### 8.4 BGM 搜索面板 (menu.show_search_panel)

- 标题：`在此处输入番剧名称`
- `search_style = "palette"`
- `search_debounce = "submit"`
- `on_search = script-message-to {name} staff-credits-search {source}`
- `search_suggestion`：预填文本（自动填入中文名，见下方流程）
- footnote：`建议标题: {完整标题} · 按 Enter 直接搜索`（有 suggestion 时）或 `使用enter或ctrl+enter进行搜索 · 可直接修改输入框内容`（无 suggestion 时）
- 顶部项（可选）：
  - 已关联弹幕提示（icon `link`，bold+italic）
  - 上次匹配缓存（icon `history`，italic）
  - 搜索语法提示项

**⚠️ uosc palette 搜索框右对齐行为**：

uosc palette 模式下，`search_suggestion` 预填的文本使用 `\an6`（右中对齐）渲染（见 `uosc/elements/Menu.lua` 的 `search_input` 绘制逻辑）。当文本超出搜索框可视宽度时：
- **显示尾部**（头部被截断）
- 无法通过配置改为左对齐（uosc 固定行为）

**解决方案**：在 `footnote` 中显示完整标题，用户即使看到搜索框尾部也能在下方确认完整内容。用户可全选（Ctrl+A）、左右方向键编辑输入框。

**BGM 搜索完整流程**（`features/subject_select.lua`，自动填入中文名）：

1. **打开搜索面板** `show_bgm_search_panel(suggestion, source)`：
   - v1.6 起调用统一接口 `search_pipeline.resolve_title_sync()` 获取 suggestion（4 级优先级）：
     1. `get_danmaku_info().anime`（弹幕库已匹配的中文名，含 uosc_danmaku 实时属性和历史文件）
     2. `state.get_last_subject(path).name_cn`（subject 缓存的中文名，独立于 uosc_danmaku）
     3. `get_current_title()`（文件名解析的番剧名，避免使用单集标题如 "Episode.01イレギュラー"）
     4. `media-title`（URL 等特殊情况兜底）
   - 立即调 `menu.show_search_panel(suggestion, source)` 显示原始标题（避免延迟感）
   - **异步转换**：若 suggestion 非中文，调 `search_pipeline.resolve_chinese_title(suggestion, cb)`：
     - 转换成功且与原标题不同 → 用 `menu.show_search_panel(chinese_title, source)` 触发 `update-menu` 无缝更新（避免闪烁）
     - 转换失败/无变化 → 保留原标题

2. **用户输入并提交** → uosc 触发 `staff-credits-search {source} {query}` 脚本消息
   - dispatcher 路由（按 source 分发）：
     - `source = "bangumi"` → `feature_subject_select.search_subject(query, source)`
     - `source = "fankuhub"` / `"fankuhub_person"` → `feature_fankuhub_search.search_subject(query, source)`
   - `state.set_last_search_query(query)` 记录
   - bangumi 路径：`api.search_subject_parallel(query, servers, callback)` 并发搜索所有已启用的 bangumi 服务器
   - fankuhub 路径：`fankuhub.search(query, callback)` 或 `fankuhub.search_by_person(query, callback)`

3. **结果展示** `show_search_results(results, source)`：
   - `menu.show_search_results(results, source)` 显示结果列表
   - 标题：`搜索结果 (N)`
   - 首项：`← 返回搜索`（icon `arrow_back` → `staff-credits-search {source}`）
   - 类型 icon 映射：1=TV(`tv`), 2=OVA(`video_library`), 3=剧场版(`theaters`), 4=WEB(`public`), 6=其它(`category`)
   - 菜单项 value：`script-message-to {name} staff-credits-select {id} {source}`

4. **用户选择条目**：
   - `source = "bangumi"` → `feature_subject_select.handle_bgm_select(id, source)`（id 为 number）：
     - `api.get_subject_detail(id, server_url, ...)` 获取详情
     - `cache_selected_subject(detail)`：`state.set_last_subject(path, info)` + `history.save(dir, info)`
     - `notify.info("已选择: " .. name)` 提示用户
   - `source = "fankuhub"` / `"fankuhub_person"` → `feature_fankuhub_search.handle_select(id_str, source)`（id 为字符串）：
     - `fankuhub.get_subject_detail(id, callback)` 获取详情
     - 写入 `state.set_last_subject` + `history.save`
     - `notify.info("已选择番库条目: " .. name)` 提示用户

**BGM 搜索的 UI 状态切换**：

```
[搜索面板] --Enter--> [搜索结果列表] --选择--> [详情缓存]
                            |
                            +--返回搜索---> [搜索面板]
```

**自动填入中文名的 UI 体验**：
- 打开面板瞬间显示原始标题（避免白屏延迟）
- 0.3~1s 后异步更新为中文名（update-menu 无闪烁）
- 用户可在转换期间直接修改输入框内容
- 若原标题已是中文，跳过转换，直接显示

### 8.5 番库搜索（无独立 UI，复用 BGM 搜索面板）

番库搜索复用 `menu.show_search_panel` / `menu.show_search_results` 的同一套 UI，差异在数据源和 dispatcher 路由。

**入口消息**：
- `staff-credits-fankuhub-search` → `feature_fankuhub_search.show_search_panel(nil, "fankuhub")`（条目搜索）
- `staff-credits-fankuhub-search-by-person` → `feature_fankuhub_search.show_search_panel(nil, "fankuhub_person")`（人员搜索）

**自动填入中文名流程**（与 BGM 搜索完全一致，v1.6 起统一调用 `resolve_title_sync`）：
1. `search_pipeline.resolve_title_sync()` 获取原始 suggestion（4 级优先级：弹幕关联 → subject 缓存 → 文件名解析 → media-title 兜底）
2. 立即显示面板（原始标题）
3. 异步调用 `resolve_chinese_title` 转换为中文，转换成功后 `update-menu` 更新

**与 BGM 搜索的 UI 差异**：
| 维度 | BGM 搜索 | 番库搜索 |
|------|---------|---------|
| source 标识 | `bangumi` | `fankuhub` / `fankuhub_person` |
| 标题 | `在此处输入番剧名称` | 同上（复用 show_search_panel） |
| footnote | `使用enter或ctrl+enter进行搜索 · 可直接修改输入框内容` | 同上 |
| 结果列表首项 | `← 返回搜索` → `staff-credits-search bangumi` | `← 返回搜索` → `staff-credits-search fankuhub` |
| 错误提示 | `未找到匹配的 Bangumi 条目` | `未找到匹配的 Bangumi 条目`（复用，文案相同） |
| 选中后提示 | `已选择: {name}` | `已选择番库条目: {name}` |

### 8.6 搜索结果列表 (menu.show_search_results)

- 标题：`搜索结果 (N)`
- `search_style = "on_demand"`
- footnote：`共 N 条结果 | 输入文字筛选`
- 首项：`← 返回搜索`（icon `arrow_back` → `staff-credits-search {source}`）
- 类型映射：1=TV(`tv`), 2=OVA(`video_library`), 3=剧场版(`theaters`), 4=WEB(`public`), 6=其它(`category`)
- 菜单项 value：`script-message-to {name} staff-credits-select {id} {source}`
- 空结果时显示错误项 `未找到匹配的 Bangumi 条目`

### 8.7 设置菜单 (menu.show_settings_menu)

- 标题：`搜索设置`
- `search_style = "disabled"`

**v1.7 菜单分组**：设置菜单扩展为 5 个分组（每组以分隔项 `─── 标题 ───` 起始，italic + unselectable + keep_open），共 9 项可选菜单项：

| 分组 | 菜单项 | icon | 触发消息 |
|------|--------|------|---------|
| **缓存管理** | 清除当前视频缓存 | `delete` | `staff-credits-clear-cache` |
|  | 清除所有缓存 | `delete_sweep` | `staff-credits-clear-all` |
| **缓存设置** | 数据缓存天数 | `schedule` | `staff-credits-config data_cache_days` |
|  | 数据缓存开关（yes/no 切换） | `toggle_on` | `staff-credits-set-config enable_data_cache {yes\|no}` |
|  | 图片缓存天数 | `image` | `staff-credits-config image_cache_days` |
| **静默预加载** | 预加载深度（subject/characters/persons/all） | `layers` | `staff-credits-config silent_preload_depth` |
| **UI 设置** | 翻页按钮位置（top/middle/bottom） | `swap_vert` | `staff-credits-config pagination_position` |
| **调试** | 调试模式（yes/no 切换） | `bug_report` | `staff-credits-set-config debug {yes\|no}` |

> 原有 `staff-credits-clear-cache` / `staff-credits-clear-all` 直接触发清理，不进入二级菜单；其余 7 项选中后调用 `show_config_value_menu(key)` 显示可选值列表。

**CONFIG_OPTIONS 预定义可选值**（由 `show_config_value_menu` 渲染为单选列表）：

| 配置 key | 标题 | 可选值（默认项标注"默认"） |
|---------|------|--------|
| `data_cache_days` | 数据缓存天数 | 0 - 永不过期 / 1 - 一天 / 3 - 三天 / 7 - 一周（默认）/ 15 - 半月 / 30 - 一个月 |
| `image_cache_days` | 图片缓存天数 | 0 - 永不过期 / 7 - 一周 / 30 - 一个月（默认）/ 90 - 三个月 |
| `silent_preload_depth` | 静默预加载深度 | subject - 仅条目ID / characters - +角色 / persons - +角色+职员（默认推荐）/ all - +详情（流量大） |
| `pagination_position` | 翻页按钮位置 | top - 顶部上方 / middle - 中间右侧 / bottom - 底部上方（默认，避开 uosc） |

> `enable_data_cache` 与 `debug` 为布尔开关，直接通过 `staff-credits-set-config {key} {yes|no}` 切换，不进入 CONFIG_OPTIONS 列表。

**当前值高亮**：选中项使用 `check_circle` icon（其它 `radio_button_unchecked`），`active=true`。当前值优先级：`runtime_config.get(key)` → `opts[key]` → `defaults`。

**持久化流程**：
1. 用户在 `show_config_value_menu` 列表中选中一项
2. 触发 `staff-credits-set-config {key} {value}` 脚本消息
3. dispatcher 调用 `runtime_config.set(key, value)` 写入 `~~/staff-credits-runtime-config.json`
4. 下次打开菜单时 `show_config_value_menu` 通过 `runtime_config.get` 读取最新值（回退到 `opts[key]`）

### 8.8 网站优先级菜单 (menu.show_servers_menu)

- 标题：`网站优先级`
- `search_style = "disabled"`
- `on_move = script-message-to {name} staff-credits-servers-move`
- footnote：`ctrl+↑↓ 调整优先级 · 点击切换启用 · ctrl+pgup/pgdn 快速移动`
- 空列表时显示提示项 `暂无配置网站`（icon `info`，italic, unselectable, keep_open）
- 菜单项由 `servers_module.build_menu_items()` 构造

### 8.9 加载中菜单 (menu.show_loading_menu)

- 标题：`查询中`（可自定义）
- 菜单项：`menu.build_loading_item(message)`（icon `spinner`，italic, keep_open, unselectable）
- `on_close = script-message-to {name} staff-credits-loading-close`

### 8.10 错误菜单 (menu.show_error_menu)

- 标题：`错误`（可自定义）
- 菜单项：`menu.build_error_item(message)`（icon `error`，italic, keep_open, unselectable）

### 8.11 菜单状态机

- 状态：`"idle"` / `"switching"`
- `SWITCH_RESET_DELAY = 0.1`（100ms，覆盖 uosc 异步 on_close 触发窗口）
- open-menu 时进入 "switching"，100ms 后自动复位 "idle"
- loading_controller 通过 `menu.get_state()` 只读消费，抑制虚假 close

### 8.12 open-menu vs update-menu 选择

```lua
local current_type = menu_visible_type or mp.get_property_native("user-data/uosc/menu/type")
local cmd = "open-menu"
if current_type and tostring(current_type) == tostring(menu_type) then
    cmd = "update-menu"  -- 同类型菜单用 update-menu 避免闪烁
end
```

`menu_visible_type` 是影子副本（V4-P2-26 修复），降低对 uosc user-data 的依赖。

---

## 9. 加载菜单实现 (loading_controller.lua)

### 9.1 show_with_countdown

**参数**：`(message, menu_type, title, keep_timer)`

> **timeout 语义（v1.9.1 澄清）**：`timeout`（默认 `8`）仅控制「剩余 Ns」倒计时显示，不直接掐断网络请求；真实网络超时由 `request_timeout`（默认 `15`，curl `--max-time`）决定。

**实现细节**：
1. **重置开始时间**（非进度更新时）：`loading_state.loading_start_time = mp.get_time()`
2. **停止旧倒计时定时器**：`stop_loading_timer()`
3. **记录菜单类型**：`loading_state.loading_menu_type = menu_type`
4. **构建消息函数** `build_msg()`：
   ```lua
   local elapsed = mp.get_time() - loading_state.loading_start_time
   local remaining = math.max(0, timeout - elapsed)
   return message .. " (剩余 " .. math.ceil(remaining) .. "s)"
   ```
5. **首次立即显示**：`deps.menu.show_loading_menu(build_msg(), menu_type, title)`
6. **注册 forced ESC binding**（V4-P1-24，仅首次）：
   ```lua
   deps.ui_base.safe_add_key("ESC", "staff_credits_loading_esc", function()
       mp.commandv("script-message-to", deps.script_name, "staff-credits-loading-close")
   end, true)
   ```
7. **每秒刷新定时器** `mp.add_periodic_timer(1, ...)`：
   - 竞态保护：`if not loading_state.loading then stop_loading_timer(); return end`
   - 剩余时间 ≤0 时：
     - 停止定时器
     - 调用 `request_registry.cancel_all()` 主动取消请求
     - 显示 `请求超时,正在等待响应(按 ESC 取消)...`
   - 否则：`deps.menu.show_loading_menu(message .. " (剩余 Ns)", menu_type, title)`

### 9.2 三种完成方式

| 方法 | 场景 | 行为 |
|------|------|------|
| `finish()` | 请求完成 / ESC / 超时 | 注销 ESC binding + 停定时器 + loading=false + cancel_all + close_menu |
| `finish_silent()` | 请求成功需紧接着打开同类型新菜单 | 停定时器 + loading=false + cancel_all + **立即 `close_menu(MENU_LOADING)`** + 设 0.3s 兜底定时器 |
| `transition_phase()` | fetch_production_score 搜索阶段 → persons 阶段 | 停定时器 + cancel_all + 清菜单类型，**保持 loading=true** |

### 9.3 handle_loading_close

ESC 触发流程：
1. 检查 `menu.get_state() == "switching"` → 抑制
2. 若 `loading=false`：
   - 检查 `menu.get_visible_type()`，若仍有加载菜单可见，关闭它
   - 否则忽略（spurious on_close）
3. 若 `loading=true`：直接调用 `finish()`

---

## 10. 通知系统 (modules/notify.lua)

### 10.1 实现详情

| 方法 | 前缀 | 默认时长 | 颜色（隐含） |
|------|------|---------|------|
| `notify.warn(msg, duration?)` | `[职员表] ⚠ ` | 3 秒 | 黄色 ⚠ |
| `notify.error(msg, duration?)` | `[职员表] ✖ ` | 5 秒 | 红色 ✖ |
| `notify.info(msg, duration?)` | `[职员表] ℹ ` | 2 秒 | 蓝色 ℹ |
| `notify.debug(msg, ...)` | `[staff-credits-debug] ` | - | mp.msg.debug 日志 |

### 10.2 实现细节

- 底层调用 `mp.osd_message(text, duration)`
- 统一前缀 `[职员表]` + 图标符号
- `debug` 受 `opts.debug` 门控（false 时完全不执行字符串拼接，避免性能开销）
- `debug` 支持 `string.format` 占位符

---

## 11. 图片下载和缓存

### 11.1 download_image_with_cache (ui_base.lua)

**参数**：`(url, target_w, target_h, opts, callback)`

| opts 字段 | 默认值 | 说明 |
|-----------|--------|------|
| `prefix` | - | 缓存文件名前缀（cards 用 `staff_credits_`，cover_intro 用 `cover_`） |
| `cache_days` | 30 | 缓存有效期（天） |
| `timeout` | 10 | 下载超时（秒） |
| `mpv_path` | "" | mpv 可执行文件路径（空则自动检测） |
| `max_concurrent` | 4 | 最大并发下载数 |
| `in_flight_list` | - | 进行中下载列表（用于 abort 跟踪） |
| `pending_retry_list` | - | per-module 重试定时器列表 |

**callback 签名**：`function(success, bgra_path, w, h)`

### 11.2 流程

1. **URL 校验**：空 URL 或非 `http(s)://` scheme 直接失败
2. **路径计算**：
   - `temp_dir = os.getenv("TEMP") or "/tmp"`
   - `hash = url:gsub("[^%w]", ""):sub(1, 32)`（SEC-03 截断 32 字符）
   - `ext = url:match("%.([%w]+)$") or "jpg"`（限制 ≤10 字符）
   - `img_path = temp_dir/sep/prefix_hash.ext`
   - `bgra_path = temp_dir/sep/prefix_hash_WxH_c.bgra`（`_c` 后缀表示 crop）
3. **缓存命中检查** `is_cache_valid(bgra_path, cache_days)`：
   - `cache_days <= 0`：仅检查文件存在
   - 否则：`age < cache_days * 86400` 有效
   - 命中直接 callback(true, bgra_path, target_w, target_h)
4. **并发限制**：超出 `max_concurrent` 时延迟 0.1s 重试
5. **同 URL+尺寸下载去重**：检查 `in_flight_list`，命中则挂起 callback
6. **第一步下载** `utils_mod.http_download(url, img_path, ...)`：
   - 下载失败：清理 img_path，失败
   - 下载成功后检查文件大小：≤0 或 >10MB 都失败
7. **第二步 bgra 转换** `utils_mod.image_to_bgra(img_path, bgra_path, target_w, target_h, mpv_path, callback)`：
   - 转换失败：清理 img_path，错误信息截断 200 字符并过滤 URL/Cookie/Proxy
   - 转换成功后验证 bgra 文件大小 = `4 * target_w * target_h`
   - 清理原始图片文件（只保留 bgra 缓存）

### 11.3 image_to_bgra (utils/image.lua)

**mpv 子进程参数**：

```
mpv_path
--no-config --msg-level=all=error --really-quiet --no-terminal
--load-scripts=no --osc=no --ytdl=no --load-stats-overlay=no
--load-osd-console=no --load-auto-profiles=no
--vid=auto --no-audio --no-sub
--frames=1
--vf=scale=W:H:force_original_aspect_ratio=decrease,pad=W:H:-1:-1:0x00000000,scale=W:H,format=bgra
--ovc=rawvideo --of=rawvideo --o=bgra_path
img_path
```

**关键点**：
- `force_original_aspect_ratio=decrease`：等比缩放不变形
- `pad=W:H:-1:-1:0x00000000`：居中填充黑色透明背景
- `format=bgra`：转换为 BGRA 原始格式
- `--frames=1`：只解码第一帧
- `--no-config` 等参数：避免加载用户配置干扰转换

### 11.4 mpv 路径自动检测

顺序：
1. 用户配置的 `mpv_path`
2. `config-dir` 上层目录（便携版）
3. `package.path` 中的 lua 目录上层（便携版）
4. PATH 中的 `mpv` / `mpv.exe`

### 11.5 缓存清理 (ui_base.cleanup_expired_cache)

- 启动时扫描 TEMP 目录
- 删除匹配前缀（`staff_credits_`、`cover_`）且超过 `cache_days` 的文件
- `max_files = 2000`（防止 TEMP 目录过大时阻塞过久）

---

## 12. 底部提示栏

### 12.1 角色介绍 (cards.lua)

**位置**：`hint_y = layout.osd_h - floor(40 * layout.ui_scale)`（OSD 底部 40×ui_scale 像素处）

**样式**：
- `fs = floor(14 * layout.ui_scale)`
- 颜色 `A0A0A0`（暗灰）
- `\an5` 居中对齐
- `\pos(osd_w/2, hint_y)`

**内容**：
```
ESC/Ctrl+右键 关闭 | 左右翻页 | 第 X/Y 页 | 有图 N + 无图 M = 共 K 角色
```

### 12.2 封面简介 (cover_intro.lua)

**位置**：`hint_y = layout.osd_h - floor(40 * layout.ui_scale)`

**样式**：
- `fs = floor(16 * layout.ui_scale)`
- 颜色 `A0A0A0`
- `\an5` 居中
- `\pos(osd_w/2, hint_y)`

**内容**：
```
ESC 关闭 | 数据来源: {番库|Bangumi|未知}
```

### 12.3 制作评分 (production_score.lua)

**位置**：`footer_y = panel_y + panel_h - floor(s(LAYOUT.footer_h) / 2)`

**样式**：
- 字体：`Noto Sans CJK SC`
- `fs = s(12)`
- 颜色 `A0A0A0`
- `\an5` 居中
- `\pos(panel_x + panel_w/2, footer_y)`（居中于面板，非 OSD）

**内容**：
```
ESC 关闭 | ↑/↓ 切换人员 | 鼠标悬停选择
```

### 12.4 翻页视觉反馈 (cards.lua 独有)

**触发**：`page_right()`/`page_left()` 时设置 `state.page_feedback = "down"/"up"`，200ms 后清除

**位置**：
- `"down"`（向后翻页）：`fb_y = osd_h - floor(60 * layout.ui_scale)`（底部边缘）
- `"up"`（向前翻页）：`fb_y = floor(60 * layout.ui_scale)`（顶部边缘）

**样式**：
- 箭头：`↓` 或 `↑`
- `fs = floor(32 * layout.ui_scale)`
- bold
- 颜色 `88C0FC`（浅蓝）
- `\an5` 居中
- `\pos(osd_w/2, fb_y)`

**清除定时器**：
```lua
state.page_feedback_timer = mp.add_timeout(0.2, function()
    state.page_feedback = nil
    if state.visible then update_hover_highlight() end
end)
```

连续翻页时复用定时器（先 kill 旧的再创建新的）。

---

## 13. 鼠标输入服务 (modules/input_service.lua)

**统一 mouse-pos 观察服务**（P2-6）：
- 单一 `observe_property` 监听器，惰性初始化
- 首个订阅者时注册，无订阅者时释放
- 订阅/取消订阅模式，避免 cards/cover_intro/production_score 三模块各自管理鼠标输入

---

## 13.5 通用 UI 组件（v1.7 新增）

v1.7 抽取了 3 个通用组件，替代各面板中重复的内联代码，统一布局计算、overlay 管理和鼠标交互逻辑。所有组件均为纯逻辑模块，不依赖 `mp` 全局状态（`overlay_manager` 例外，内部使用 `mp.commandv`/`mp.utils.file_info`），通过参数注入依赖。

### 13.5.1 modules/pagination.lua（通用翻页组件）

**用途**：供 `staff_grid.lua` 和 `cards.lua` 复用，替代内联翻页按钮代码，统一计算按钮位置和渲染三态样式。

**接口**：

| 函数 | 签名 | 说明 |
|------|------|------|
| `compute_layout` | `(parent_layout, offset, total, visible_count) -> layout_table` | 计算翻页按钮位置，返回 `{btn_w, btn_h, btn_y, prev_btn_x, next_btn_x, is_first_page, is_last_page, max_offset, ui_scale}` |
| `render` | `(ass_parts, layout, state, ass_lib) -> void` | 渲染翻页按钮（三态：禁用/默认/悬停）；`state.hover_button` 为 `"prev"`/`"next"`/`nil` |
| `hit_test` | `(mx, my, layout) -> "prev"\|"next"\|nil` | 鼠标命中检测 |
| `on_click` | `(mx, my, layout, page_up_fn, page_down_fn) -> void` | 点击处理，命中时调用对应回调 |

**位置策略**（支持 `pagination_position` 配置）：

| 值 | 位置 | 计算公式 |
|----|------|---------|
| `top` | 网格顶部上方 | `grid_top - btn_h - s(8)`（最小 0） |
| `middle` | 网格垂直中间 | `grid_top + floor((grid_h - btn_h) / 2)` |
| `bottom`（默认） | 底部提示栏上方 | `hint_y - btn_h - s(40)`（上移 40px 避开 uosc 控制条） |

**按钮尺寸**：基础值 100×32，按 `ui_scale` 缩放。

**三态颜色**：

| 状态 | 背景 | 文字 | 边框 | Alpha |
|------|------|------|------|-------|
| 禁用（首页/末页） | `1A1A20` | `606060` | 无 | `80` |
| 默认 | `2A2930` | `88C0FC` | 无 | `C0` |
| 悬停 | `3A3940` | `88C0FC` | `88C0FC` 2px | `D0` |

**箭头 Unicode**：上一页 `◀`（U+25C0），下一页 `▶`（U+25B6）。

### 13.5.2 modules/overlay_manager.lua（通用 Overlay 管理器）

**用途**：统一管理图片 overlay id 分配、添加、移除，替代 `cards.lua` 和 `cover_intro.lua` 中分散的 id 管理。直接 `require` 即可用（无 make_init 工厂模式）。

**接口**：

| 函数 | 签名 | 说明 |
|------|------|------|
| `alloc_id` | `(panel_name, count) -> {start_id, end_id} \| nil` | 分配连续 id 范围；分配失败（超出 MAX_ID）返回 nil |
| `add` | `(id, x, y, bgra_path, w, h) -> true\|false` | 添加 overlay（含文件验证）；失败返回 false |
| `remove` | `(id) -> void` | 移除单个 overlay |
| `remove_all` | `() -> void` | 批量移除所有已添加 overlay |
| `get_active_ids` | `() -> id_array` | 获取已添加 id 列表（浅拷贝） |

**常量**：`MAX_ID = 62`（63 保留给其他用途，mpv 上限 63）

**分配策略**：
- 在 `[0, MAX_ID]` 区间内寻找连续 `count` 个空闲 id，避免与已有分配重叠
- 同一面板重复调用 `alloc_id` 时，先释放旧分配再重新分配
- 起始 id 从 0 开始，最大 id 不超过 62

**文件验证**（`add` 内部）：
1. 参数类型校验（id/x/y/w/h 为 number，bgra_path 为非空字符串，w/h > 0）
2. `mp.utils.file_info(bgra_path)` 检查 `is_file` 字段
3. 文件大小 `> 0`（防御 0 字节损坏文件）
4. 验证通过后执行 `mp.commandv("overlay-add", id, x, y, bgra_path, 0, "bgra", w, h, 4*w)`

**pcall 包裹**：所有 `mp.commandv` 调用（`overlay-add`/`overlay-remove`）用 pcall 保护，避免异常冒泡。

**降级模式**：`alloc_id` 失败时回退到 v1.6 静态范围（详见第 3.4 节）：
- cards.lua：0-31（角色图片）/ 32-47（CV 头像）
- cover_intro.lua：62（单张封面）

### 13.5.3 modules/mouse_interaction.lua（通用鼠标交互 mixin）

**用途**：统一鼠标订阅/取消订阅、悬停高亮、点击处理，替代 `staff_grid.lua` 和 `cards.lua` 中重复的鼠标交互代码。

**单例模式**：使用模块级内部状态（`internal_state`），同一时间只有一个面板可见，无需实例化。

**接口**：

| 函数 | 签名 | 说明 |
|------|------|------|
| `enable` | `(input_service, callbacks) -> void` | 订阅鼠标；启用前先 `disable()` 防止重复注册 |
| `disable` | `() -> void` | 取消订阅，清理内部状态 |
| `get_current_hover` | `() -> hover_id \| nil` | 获取当前悬停项标识 |
| `handle_click` | `(mx, my, callbacks) -> void` | 处理点击事件（供 MBTN_LEFT 按键绑定调用） |

**callbacks 参数**（传入 `enable`）：

| 字段 | 类型 | 说明 |
|------|------|------|
| `hit_test(mx, my)` | function（必填） | 返回悬停项标识（数字索引/字符串/nil） |
| `on_hover_change(old, new)` | function（可选） | 悬停项变化时触发（用于重绘） |
| `on_click(mx, my)` | function（可选） | 鼠标点击处理 |

**内部状态**：

| 字段 | 说明 |
|------|------|
| `input_service` | 输入服务模块引用（提供 `subscribe`/`unsubscribe`） |
| `mouse_callback` | 内部鼠标回调函数（供 `unsubscribe` 使用） |
| `current_hover` | 当前悬停项标识 |

**异常保护**：所有外部回调调用（`callbacks.on_hover_change`、`callbacks.on_click`、`input_service.subscribe`、`input_service.unsubscribe`）均用 `pcall` 包裹。

**与 input_service 配合**：基于第 13 章的 `input_service` 单一 `mouse-pos` 观察服务，本组件提供更高层级的"悬停状态管理"抽象，面板只需实现 `hit_test`/`on_hover_change`/`on_click` 三个回调即可获得完整的鼠标交互能力。

---

## 14. 相关文件路径汇总

路径均相对于脚本目录 `~~/scripts/uosc_staff_credits/`：

| 文件 | 路径 |
|------|------|
| 主入口 | `main.lua` |
| 职员表 feature | `features/staff_credits.lua` |
| 角色介绍 feature | `features/character_cards.lua` |
| 封面简介 feature | `features/cover_intro_flow.lua` |
| BGM 搜索 feature | `features/subject_select.lua` |
| 制作评分 feature | `features/production_score_flow.lua` |
| 角色介绍面板 | `modules/cards.lua` |
| 封面简介面板 | `modules/cover_intro.lua` |
| 制作评分面板 | `modules/production_score.lua` |
| ASS 渲染库 | `modules/ass_lib.lua` |
| UI 基础设施 | `modules/ui_base.lua` |
| uosc menu 集成 | `modules/menu.lua` |
| 搜索管线（含中文标题转换） | `app/search_pipeline.lua` |
| 加载控制器 | `app/loading_controller.lua` |
| 通知系统 | `modules/notify.lua` |
| 图片转换工具 | `modules/utils/image.lua` |
| 鼠标输入服务 | `modules/input_service.lua` |
| 默认配置 | `modules/defaults.lua` |
| 通用翻页组件（v1.7） | `modules/pagination.lua` |
| 通用 Overlay 管理器（v1.7） | `modules/overlay_manager.lua` |
| 通用鼠标交互 mixin（v1.7） | `modules/mouse_interaction.lua` |

---

## 15. 番剧中文名搜索（无独立 UI）

**特性**：非中文标题自动转换为中文后再搜索，对用户透明。

**触发位置**（v1.6 起统一调用 `search_pipeline.resolve_title_sync` + `resolve_chinese_title`）：
1. `search_pipeline.run_subject_pipeline` 第 4.5 步，标题识别完成后（职员表 / 角色介绍 / 封面简介 / 制作评分）
2. BGM 搜索 / 番库搜索面板打开时（`show_bgm_search_panel` / `show_search_panel`，调用 `resolve_title_sync` 获取预填标题后异步转换）
3. 静默预加载 `trigger_silent_load`（独立于 uosc_danmaku，无 uosc_danmaku 时通过文件名解析 + 中文转换工作）
4. 各 feature 缓存命中但无有效标题时（调用 `resolve_display_title` 兜底）

**可见性**：
- 无独立 UI（不弹面板、不显示菜单）
- 仅通过 `mp.msg.debug` 日志输出转换前后标题（受 `opts.debug` 门控）
- 转换流程并发进行，不阻塞用户操作
- BGM / 番库搜索面板打开时，转换完成后用 `update-menu` 无缝更新输入框内容（无闪烁）

**日志示例**（`opts.debug=true`）：
```
[staff-credits-debug] resolve_chinese_title: non-chinese title, converting: Arifureta
[staff-credits-debug] resolve_chinese_title: converted to: 平凡职业造就世界最强
[staff-credits-debug] run_subject_pipeline: title converted "Arifureta" -> "平凡职业造就世界最强"
[staff-credits-debug] resolve_display_title: non-chinese, converting: Arifureta
```

**用户感知**：
- 走管线功能（职员表/角色介绍等）：搜索结果显示中文名（Bangumi `name_cn` 字段），无需手动输入中文
- BGM / 番库搜索：打开面板瞬间显示原始标题，0.3~1s 后无缝更新为中文名（update-menu），用户可在转换期间直接修改
- 缓存命中但无有效标题：自动调用 `resolve_display_title` 获取中文标题，不再显示 "缓存条目无有效标题" 错误
- uosc_danmaku 未暴露：通过文件名解析 + 中文转换独立工作，体验与暴露时一致

详见 [DESIGN.md §7.4 中文标题转换](./DESIGN.md#74-中文标题转换--resolve_chinese_title) 和 [§7.4.1 统一中文标题获取接口](./DESIGN.md#741-统一中文标题获取接口v16)。

---

## 16. 静默预加载（无 UI）

**特性**：进入视频后自动后台预取条目信息并缓存，用户点击功能时秒开。

**触发位置**：`app/dispatcher.lua` 的 `path_observer` 第 7 步，路径切换后自动调用 `trigger_silent_load(path)`。

**可见性**：
- 完全无 UI（不弹面板、不显示菜单、不弹 OSD）
- 仅通过 `notify.debug` 日志输出（受 `opts.debug` 门控）
- 全程不打扰用户

**触发条件（三重门控）**：
1. `opts.autoload_with_danmaku == true`（默认开启，可在 script-opts 中关闭）
2. `state.loading_state.loading == false`（用户未主动操作，避免冲突）
3. `state.search_state.last_subject_by_path[path] == nil`（缓存未命中，避免重复请求）

**标题获取流程**（v1.6 起改用统一接口，独立于 uosc_danmaku）：
1. 调用 `search_pipeline.resolve_title_sync()` 获取基础标题（4 级优先级：弹幕关联 → subject 缓存 → 文件名解析 → media-title 兜底）
2. 调用 `search_pipeline.resolve_chinese_title(base_title, callback)` 异步转换为中文
3. 转换完成后调用 `search_pipeline.search_subject_enhanced(final_title, season_num, on_done, on_progress, true, 2)` 静默搜索

**日志示例**（`opts.debug=true`）：
```
[staff-credits] 静默加载成功: 平凡职业造就世界最强
[staff-credits] 静默加载失败: 某某番剧
```

**用户感知**：
- 进入视频后无任何 UI 变化
- 点击职员表 / 角色介绍 / 封面简介 / 制作评分时可秒开（缓存命中）
- 失败时不报错、不提示，完全静默
- 无 uosc_danmaku 时仍可工作（通过文件名解析 + 中文转换）

**关闭方法**：在 `script-opts/uosc_staff_credits.conf` 中设置 `autoload_with_danmaku=no`。

详见 [DESIGN.md §7.7 静默预加载](./DESIGN.md#77-静默预加载--trigger_silent_load) 和 [PROJECT.md §3.4 打开视频自动搜索和加载](./PROJECT.md#34-打开视频自动搜索和加载静默预加载)。

---

## 17. 相关文档

- [项目文档 (PROJECT.md)](./PROJECT.md) — 项目概述、目录结构、配置项
- [项目设计文档 (DESIGN.md)](./DESIGN.md) — 架构分层、设计模式、ADR
- [ASS 绘图与职员表生命周期](./ASS_RENDERING.md) — 当前 mp.assdraw 使用方式、面板流程和烟测说明
