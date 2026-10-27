# Spec: enhance-cache-ui-components

> 点击功能时在 OSD 左上角显示"功能名 · 加载细节"提示，并区分数据来源（本地缓存 / 内存缓存 / 网站 / 搜索结果）。

## 一、需求

1. 用户点击 uosc 控制栏的功能按钮时，OSD 左上角显示 2 秒提示
2. 提示格式：`[Bangumi 工具箱] 功能名 · 加载细节`
3. 加载细节需动态反映数据来源：
   - 点击瞬间：`加载中...`
   - 命中本地持久化缓存：`从本地缓存加载`
   - 命中内存缓存（cover_intro 30 分钟 TTL）：`从内存缓存加载`
   - 从 Bangumi 站点加载：`从 Bangumi 加载`
   - 从 AniList / MAL / 百度百科加载：对应名称
   - 搜索类功能：`搜索中...` / `从 X 加载 N 条结果` / `加载详情中...` / `从 X 加载详情`

## 二、覆盖功能

| 功能名 | 入口命令 | 触发模块 |
|--------|----------|----------|
| 职员表 | `staff-credits` | `features/staff_credits.lua` |
| 角色介绍 | `character-intro` | `features/character_cards.lua` |
| 封面简介 | `cover-intro` | `features/cover_intro_flow.lua` |
| 制作评分 | `staff-credits-production-score` | `features/production_score_flow.lua` |
| BGM 搜索 | `staff-credits-search bangumi` | `features/subject_select.lua` |

## 三、API 设计

### `notify.show_click_hint(feature_name, detail)`

- **参数**
  - `feature_name: string` — 功能名称（必填）
  - `detail: string|nil` — 加载细节（可选）
- **行为**
  - `detail` 为 nil/空：显示 `[Bangumi 工具箱] 功能名`
  - `detail` 非空：显示 `[Bangumi 工具箱] 功能名 · detail`
- **显示时长**：2 秒
- **实现层**：`mp.osd_message(msg, 2)` + `msg.info(msg)` 持久化日志

## 四、调用点矩阵

### 4.1 入口层（app/dispatcher.lua）

每个 `handle_*` 函数在调用 `feature_*.fetch()` 前显示 `功能名 · 加载中...`：
- `handle_staff_credits` → `"职员表", "加载中..."`
- `handle_character_intro` → `"角色介绍", "加载中..."`
- `handle_cover_intro` → `"封面简介", "加载中..."`
- `handle_production_score` → `"制作评分", "加载中..."`
- `handle_search` 固定为 `"BGM 搜索"`，detail=`"加载中..."`（v2.0：番库搜索路由已移除）

### 4.2 数据层（features/*.lua）

| 模块 | 调用点 1 | 调用点 2 |
|------|----------|----------|
| `cover_intro_flow.lua` | 本地缓存命中 → `从本地缓存加载`<br>内存缓存命中 → `从内存缓存加载` | 网络回调成功 → `从 {Bangumi\|AniList\|MAL\|百度百科} 加载` |
| `staff_credits.lua` | 本地缓存命中 → `从本地缓存加载` | 网络回调成功 → `从 {source} 加载` |
| `character_cards.lua` | 本地缓存命中 → `从本地缓存加载` | 网络回调成功 → `从 {source_name} 加载` |
| `production_score_flow.lua` | 本地缓存命中 → `从本地缓存加载` | pending=0 全部作品返回 → `从 {source} 加载` |
| `subject_select.lua` | `search_subject` 入口 → `搜索中...`<br>`handle_bgm_select` 入口 → `加载详情中...` | 搜索回调 → `从 Bangumi 加载 N 条结果`<br>详情回调 → `从 Bangumi 加载详情` |

## 五、实现状态

### 已完成 ✅

| 文件 | 修改 |
|------|------|
| `modules/notify.lua` | `show_click_hint` 增加 `detail` 参数，nil/空时仅显示功能名 |
| `app/dispatcher.lua` | 5 个 `handle_*` 入口添加 `加载中...` 提示；`handle_search` 根据 source 区分名称 |
| `features/cover_intro_flow.lua` | 3 个加载节点（本地缓存 / 内存缓存 / 网络回调）添加提示 |
| `features/staff_credits.lua` | 2 个加载节点（本地缓存 / 网络回调）添加提示 |
| `features/character_cards.lua` | 2 个加载节点（本地缓存 / 网络回调）添加提示 |
| `features/production_score_flow.lua` | 2 个加载节点（本地缓存 / 网络回调全部完成）添加提示 |
| `features/subject_select.lua` | `search_subject` / `handle_bgm_select` 入口 + 回调共 4 个提示点 |

### 待验证 ⏳

- 重启 mpv 实测 OSD 显示效果
- 测试本地缓存命中场景（重复点击同一功能）
- 测试网络加载场景（清空缓存后点击）
- 测试搜索类功能（BGM 搜索）

## 六、非目标

- 不修改 `notify.warn/error/info` 现有签名
- 不修改 `set_tag/get_tag` tag 机制（与 show_click_hint 并存）
- 不增加新的 UI 控件，仅 OSD 文字提示
- 不持久化提示历史

## 七、回归风险

1. **OSD 抢占**：`mp.osd_message` 会覆盖其他 OSD 显示（如 mpv 自带进度条），但 2 秒时长可接受
2. **提示频繁**：搜索结果加载详情时连续显示"加载详情中..." → "从 X 加载详情"，可能视觉跳动。当前 2 秒时长可覆盖，无需特殊处理
3. **回调路径校验**：所有数据层提示点都在 `current_path ~= entry_path` 校验之后调用，避免异步回调污染

## 八、验证清单

- [ ] 启动 mpv 加载视频
- [ ] 点击"封面简介"按钮 → OSD 显示 `[Bangumi 工具箱] 封面简介 · 加载中...`
- [ ] 首次加载完成 → OSD 显示 `[Bangumi 工具箱] 封面简介 · 从 Bangumi 加载`
- [ ] 关闭后再次点击 → OSD 显示 `从本地缓存加载`
- [ ] 同样验证职员表 / 角色介绍 / 制作评分
- [ ] 打开 BGM 搜索面板，输入关键词 → 显示 `BGM 搜索 · 搜索中...` → `从 Bangumi 加载 N 条结果`
- [ ] 选中搜索结果 → 显示 `加载详情中...` → `从 Bangumi 加载详情`
