# uosc_staff_credits 配置文档

本文档详细说明 `uosc_staff_credits` 脚本的所有配置项、优先级关系及修改方式。

> 配置项默认值定义在 `modules/defaults.lua` 的 `defaults` 表中（SSOT，Single Source of Truth），与 `script-opts/uosc_staff_credits.conf` 中的注释一一对应。

---

## 1. 配置优先级

脚本采用**三级配置合并机制**，优先级从高到低为：

```
runtime_config（运行时持久化） > script-opts（uosc_staff_credits.conf） > defaults（defaults.lua 内置默认值）
```

### 1.1 三级配置说明

| 级别 | 来源 | 修改方式 | 生效时机 | 适用场景 |
|------|------|----------|----------|----------|
| **runtime_config**（最高） | `~~/staff-credits-runtime-config.json` | 通过 mpv 播放器中的「搜索设置」菜单调整 | 实时生效（无需重启），200ms 防抖持久化 | 用户在运行时频繁调整的少量偏好项 |
| **script-opts**（中） | `script-opts/uosc_staff_credits.conf` | 编辑文本文件后重启 mpv | 重启 mpv 后生效 | 启动期固定参数（API 服务器、超时、UA 等） |
| **defaults**（最低） | `modules/defaults.lua` 中的 `defaults` 表 | 修改源代码 | 重启 mpv 后生效 | 代码内置兜底默认值，**不建议直接修改** |

### 1.2 各级别特点

**runtime_config（运行时持久化）**
- 持久化文件路径：`~~/staff-credits-runtime-config.json`（mpv 配置目录下）
- 写入策略：200ms 防抖 + 临时文件 `.tmp` + `os.rename` 原子替换，避免写入中断导致文件损坏
- 修改入口：在 mpv 中打开「Bangumi 工具箱 → 搜索设置」菜单，选择对应项切换
- 脚本消息：`script-message-to <script_name> staff-credits-set-config <key> <value>`（布尔/枚举）或 `script-message-to <script_name> staff-credits-config <key>`（弹出可选值列表）
- 仅覆盖少量适合运行时调整的偏好项（缓存天数、预加载深度、UI 位置、布尔开关等）

**script-opts（脚本配置文件）**
- 文件路径：`script-opts/uosc_staff_credits.conf`
- 读取机制：`defaults.lua` 通过 `mp.get_opt(k)` 读取，按 `defaults` 表中的类型自动转换（boolean 接受 `yes/no/true/false/1/0`，number 用 `tonumber` 转换，其他为字符串）
- 修改后需重启 mpv 才能生效
- 支持全部 27 个配置项

**defaults（内置默认值）**
- 位于 `modules/defaults.lua` 的 `M.defaults` 表
- 是所有配置项的「单一真相源」，`script-opts` 未覆盖时回退到此
- **不建议直接修改**，应通过 `script-opts/uosc_staff_credits.conf` 覆盖

### 1.3 合并规则示例

```lua
-- modules/runtime_config.lua 中的合并逻辑
function M.get(key)
    if runtime_data[key] ~= nil then      -- 1. 优先使用 runtime_config
        return runtime_data[key]
    end
    if type(opts) == "table" then          -- 2. 其次使用 script-opts（已与 defaults 合并）
        return opts[key]
    end
    return nil                              -- 3. 无值
end
```

---

## 2. script-opts 配置项

共 27 项配置，按功能分组说明。所有配置项均可在 `script-opts/uosc_staff_credits.conf` 中覆盖默认值。

> **类型说明**：boolean 类型接受 `yes/no/true/false/1/0`；number 类型接受正整数；string 类型为任意字符串。

### 2.1 Bangumi API 配置

| 名称 | 类型 | 默认值 | 可选值 | 说明 | 示例 |
|------|------|--------|--------|------|------|
| `api_base_url` | string | `https://api.bangumi.one` | 任意 HTTPS URL | 单服务器模式下的 Bangumi API 地址。留空则使用 `api_server`。官方 API 为 `https://api.bgm.tv`（要求 User-Agent 含联系方式，限流 1 次/秒、5000 次/天） | `api_base_url=https://api.bangumi.one` |
| `api_server` | string | `""`（空） | 逗号分隔的多服务器列表，每项可用 `\|` 或 `#` 分隔备注 | 多服务器并发搜索（逗号分隔），首个有效结果即取消其余。包含官方 API 时自动降并发为 1 以避免限流。**注意**：此项仅在首次启动时导入到 `~~/staff-credits-servers.json`，之后以菜单中配置的优先级和启用状态为准 | `api_server=https://api.bgm.tv\|官方,https://api.bangumi.one\|镜像` |
| `bangumi_token` | string | `""`（空） | Bangumi 个人访问令牌 | 用于读写**你自己的**收藏与观看进度（读收藏状态、改收藏、标记单集看过）。注意：**读自己的收藏也要 token** —— `GET /v0/users/-/collections/{id}` 是用户端点。公开数据（搜索、条目、剧集列表）不需要 token。留空时相关功能整体关闭（优雅降级，不会发起任何带 token 的请求）。获取地址：<https://next.bgm.tv/demo/access-token>。**安全提示**：该 token 等同于账号权限，请勿提交到 Git | `bangumi_token=xxxxxxxxxxxxxxxx` |

### 2.2 外部搜索源配置

| 名称 | 类型 | 默认值 | 可选值 | 说明 | 示例 |
|------|------|--------|--------|------|------|
| `enable_extra_search` | boolean | `true` | `yes` / `no` | 是否启用外部 API 搜索源（dandanplay + 360kan + TMDB）。启用后会先用弹幕 API 搜索动漫名称，再用名称去 Bangumi 查询 | `enable_extra_search=yes` |
| `danmaku_api_server` | string | `https://api.dandanplay.net` | 任意 HTTPS URL（逗号分隔多服务器） | dandanplay 弹幕 API 服务器地址，用于搜索动漫名称 | `danmaku_api_server=https://api.dandanplay.net` |
| `tmdb_api_key` | string | `""`（空） | base64 编码的 TMDB API Key | TMDB API Key，用于非中文名转中文。可在 https://www.themoviedb.org 注册获取，需 base64 编码。**安全提示**：base64 仅避免配置解析问题，不提供加密保护，请勿将含 key 的配置提交到 Git | `tmdb_api_key=<base64编码的key>` |

### 2.3 HTTP 请求配置

| 名称 | 类型 | 默认值 | 可选值 | 说明 | 示例 |
|------|------|--------|--------|------|------|
| `timeout` | number | `8` | 正整数（秒） | loading 倒计时**显示**超时，仅决定「剩余 Ns」倒计时何时变为"请求超时，正在等待响应"提示；**不直接掐断**网络请求（v1.9 由 15 降至 8，因 bangumi 搜索通常 5-8s 即可返回） | `timeout=8` |
| `request_timeout` | number | `15` | 正整数（秒） | 网络请求**真实**超时（v1.9.1 新增，从 `timeout` 分离），映射为 api/dandanplay/extra 的 curl `--max-time`，直接决定单次 HTTP 请求最长等待时间。热门番剧 `persons`/`characters` 端点数据量大，需要比搜索更长的窗口；频繁遇到 `curl exit code 28` 可增大此值 | `request_timeout=15` |
| `user_agent` | string | `uosc_staff_credits (https://github.com/user/uosc_staff_credits)` | 任意字符串 | HTTP 请求的 User-Agent 头部。Bangumi 官方 API 要求含联系方式，建议格式：`项目名 (联系方式URL或邮箱)` | `user_agent=uosc_staff_credits (https://github.com/yourname/uosc_staff_credits)` |

### 2.4 SSL/TLS 配置

用于解决 Windows curl `exit code 35` 握手失败问题。

| 名称 | 类型 | 默认值 | 可选值 | 说明 | 示例 |
|------|------|--------|--------|------|------|
| `ssl_no_revoke` | boolean | `true` | `yes` / `no` | 是否禁用证书吊销列表（CRL）检查。Windows 上 curl 默认走 schannel，若 CRL 分发点不可达会报 exit code 35。禁用后仍校验证书链，安全性基本不变，建议保持 `yes` | `ssl_no_revoke=yes` |
| `cacert_path` | string | `""`（空） | CA 证书 bundle 文件绝对路径 | 自定义 CA 证书 bundle 路径，留空使用系统默认。仅在系统证书不可用时配置 | `cacert_path=C:/curl-ca-bundle.crt` |
| `insecure` | boolean | `false` | `yes` / `no` | 是否跳过证书验证。**仅调试用**，生产环境务必保持 `no`，否则存在中间人攻击风险 | `insecure=no` |

### 2.5 标题解析配置

| 名称 | 类型 | 默认值 | 可选值 | 说明 | 示例 |
|------|------|--------|--------|------|------|
| `title_replace` | string（JSON） | `[{"rules": [{"^〔(.-)〕": "%1"}, {"^.*《(.-)》": "%1"}]}]` | 合法的 JSON 字符串 | 自定义标题替换规则（借鉴 uosc_danmaku）。替换模式为 Lua 的 `string.gsub` 函数，只支持 `%n` 捕获组写法。用于在搜索前清理文件名中的干扰字符 | `title_replace=[{"rules": [{"^〔(.-)〕": "%1"}]}]` |

### 2.6 数据源配置

**本节无 script-opts 配置项。** 数据源完全由「网站优先级」列表（`~~/staff-credits-servers.json`）决定，
在 mpv 中通过 **Bangumi 工具箱 → 网站优先级** 菜单配置排序与启用状态。

> 历史说明：v2.0 之前此处有 `data_source`（`bangumi` / `fankuhub` / `auto`）与
> `fankuhub_api_base` 两个配置项，用于在 servers 列表为空时选择数据源。
> 因 `fankuhub` 聚合源已移除、`auto` 与 `bangumi` 语义重合，两项均已删除。

### 2.7 缓存配置

包含图片缓存与本地数据缓存两部分。

#### 2.7.1 图片缓存

| 名称 | 类型 | 默认值 | 可选值 | 说明 | 示例 |
|------|------|--------|--------|------|------|
| `image_cache_days` | number | `30` | `0`（永不过期）/ `7` / `30` / `90` 等正整数 | 角色图片本地缓存有效天数，缓存在系统 TEMP 目录的 bgra 文件中。超过此天数的缓存会自动重新下载，设为 `0` 表示永不过期 | `image_cache_days=30` |

#### 2.7.2 本地数据缓存（v1.7）

| 名称 | 类型 | 默认值 | 可选值 | 说明 | 示例 |
|------|------|--------|--------|------|------|
| `data_cache_days` | number | `30` | `0`（永不过期）/ `1` / `3` / `7` / `15` / `30` 等正整数 | 数据缓存有效天数，缓存 API 响应数据到 `~~/staff-credits-data-cache.json`。超过此天数的缓存会自动重新拉取，设为 `0` 表示永不过期 | `data_cache_days=30` |
| `enable_data_cache` | boolean | `true` | `yes` / `no` | 是否启用本地数据缓存。禁用后每次都实时请求 API | `enable_data_cache=yes` |

### 2.8 静默预加载配置

| 名称 | 类型 | 默认值 | 可选值 | 说明 | 示例 |
|------|------|--------|--------|------|------|
| `silent_preload_depth` | string | `all` | `subject` / `characters` / `persons` / `all` | 静默预加载深度，决定打开视频时后台预取的数据范围。`subject` 仅预取条目 ID（最省流量）；`characters` 预取条目+角色列表；`persons` 预取条目+角色+职员（推荐）；`all` 预取条目+角色+职员+详情（最完整，流量最大） | `silent_preload_depth=all` |
| `autoload_with_danmaku` | boolean | `true` | `yes` / `no` | 是否随 uosc_danmaku 自动静默预加载条目信息。打开视频时若 uosc_danmaku 加载了弹幕，自动后台查询 Bangumi 条目 ID 并缓存，用户后续打开工具箱时缓存命中直接显示 | `autoload_with_danmaku=yes` |

### 2.9 UI 配置

| 名称 | 类型 | 默认值 | 可选值 | 说明 | 示例 |
|------|------|--------|--------|------|------|
| `pagination_position` | string | `bottom` | `top` / `middle` / `bottom` | 翻页按钮位置（职员表/角色介绍面板）。`top` 按钮位于网格顶部上方；`middle` 按钮位于网格中间右侧；`bottom` 按钮位于底部提示栏上方（默认，避开 uosc 控制条） | `pagination_position=bottom` |

### 2.10 其他配置

| 名称 | 类型 | 默认值 | 可选值 | 说明 | 示例 |
|------|------|--------|--------|------|------|
| `debug` | boolean | `true` | `yes` / `no` | 调试日志开关。启用后输出详细日志便于排查问题，生产环境可关闭以减少日志量 | `debug=yes` |
| `max_results` | number | `10` | 正整数 | 搜索最大返回结果数 | `max_results=10` |
| `history_path` | string | `~~/staff-credits-history.json` | 任意文件路径（支持 `~~` 展开） | 搜索历史缓存文件路径，`~~` 会被展开为 mpv 配置目录 | `history_path=~~/staff-credits-history.json` |
| `mpv_path` | string | `""`（空） | mpv 可执行文件绝对路径 | mpv 可执行文件路径，用于图片格式转换。留空则自动检测。**安全提示**：默认留空以避免硬编码绝对路径导致跨机器不可用 | `mpv_path=` |

### 2.11 观看进度同步配置

把「看到哪一集」同步到 Bangumi 收藏。**全部 4 项都依赖 `bangumi_token` 非空**；
token 为空时这 4 项形同不存在（一个请求都不会发）。

| 名称 | 类型 | 默认值 | 可选值 | 说明 | 示例 |
|------|------|--------|--------|------|------|
| `enable_progress_sync` | boolean | `true` | `yes` / `no` | 总开关。设 `no` 时不发起任何带 token 的请求（`progress_sync_mode` 也会被忽略） | `enable_progress_sync=yes` |
| `progress_sync_mode` | string | `off` | `off` / `notify` / `auto` | 行为档位。`off`=打开视频**零网络请求**；`notify`=读一次当前进度并在 OSD 提示；`auto`=播放达阈值后**自动标记本集看过** | `progress_sync_mode=notify` |
| `progress_sync_threshold` | number | `80` | 1-100 | 仅 `auto` 档生效。播放进度百分比达到该值才自动标记 | `progress_sync_threshold=80` |
| `collection_type_on_mark` | integer | `3` | `1` / `2` / `3` / `4` / `5` | 条目**尚未收藏**时写入的收藏类型。已在收藏中的条目不会被改类型 | `collection_type_on_mark=3` |

> ⚠️ **`enable_progress_sync=yes` 不等于「会发请求」**：默认 `progress_sync_mode=off`，
> 两者叠加的结果是**打开视频时零请求**。要真正启用需同时把 mode 设为
> `notify` 或 `auto`。这是刻意设计——避免升级后凭空多出网络活动。
>
> ⚠️ **`collection_type_on_mark` 用 Bangumi 新 API 取值，与很多旧教程相反**：
> `1`=想看 `2`=看过 **`3`=在看** `4`=搁置 `5`=抛弃。
> 也就是说「看过」是 `2`、默认的「在看」是 `3`。
>
> ⚠️ **写操作会返回 `204 No Content`（无响应体）**。这是正常的成功响应，
> 不是失败——实现里已按此处理（见 `apis/bangumi_user.lua`）。

### 2.12 硬编码常量

以下常量定义在 `modules/defaults.lua` 顶部，**无法通过 script-opts 修改**，仅能通过修改源代码调整：

| 名称 | 默认值 | 说明 |
|------|--------|------|
| `MAX_ENTRIES` | `5000` | 搜索历史 LRU 阈值，超过后自动淘汰最旧记录 |
| `DEFAULT_MAX_LAST_SUBJECT_ENTRIES` | `50` | state 中最近条目缓存上限 |
| `DEFAULT_COVER_INTRO_CACHE_TTL` | `1800`（秒） | 封面介绍缓存 TTL，30 分钟 |

> `SCHEMA_VERSION`（servers 配置版本号）定义在 `modules/servers.lua`，当前为 `5`。

---

## 3. 运行时配置项（设置菜单可调整）

以下配置项可通过 mpv 中的「Bangumi 工具箱 → 搜索设置」菜单实时调整，修改后自动持久化到 `~~/staff-credits-runtime-config.json`，无需重启 mpv。

### 3.1 可选值配置项

这些项在菜单中以「可选值列表」形式呈现（定义在 `modules/menu.lua` 的 `CONFIG_OPTIONS` 表），选中后高亮显示当前值。

| 配置项 | 菜单标题 | 可选值 | 当前默认值 | 说明 |
|--------|----------|--------|------------|------|
| `data_cache_days` | 数据缓存天数 | `0`（永不过期）/ `1`（一天）/ `3`（三天）/ `7`（一周）/ `15`（半月）/ `30`（一个月） | `30` | 控制本地数据缓存的有效期 |
| `image_cache_days` | 图片缓存天数 | `0`（永不过期）/ `7`（一周）/ `30`（一个月）/ `90`（三个月） | `30` | 控制角色图片缓存的有效期 |
| `silent_preload_depth` | 静默预加载深度 | `subject`（仅条目ID）/ `characters`（+角色）/ `persons`（+角色+职员）/ `all`（+详情） | `all` | 控制打开视频时后台预取的数据范围 |
| `pagination_position` | 翻页按钮位置 | `top`（顶部上方）/ `middle`（中间右侧）/ `bottom`（底部上方） | `bottom` | 控制职员表/角色面板的翻页按钮位置 |

### 3.2 布尔开关配置项

这些项在菜单中以「切换」形式呈现，点击即翻转状态。

| 配置项 | 菜单标题 | 可选值 | 当前默认值 | 说明 |
|--------|----------|--------|------------|------|
| `enable_data_cache` | 数据缓存开关 | `yes` / `no` | `yes` | 启用/禁用本地数据缓存 |
| `debug` | 调试模式 | `yes` / `no` | `yes` | 启用/禁用调试日志 |

### 3.3 设置菜单结构

「搜索设置」菜单按以下分组组织（见 `modules/menu.lua` 的 `show_settings_menu` 函数）：

1. **缓存管理**
   - 清除当前视频缓存（`staff-credits-clear-cache`）
   - 清除所有缓存（`staff-credits-clear-all`）
2. **缓存设置**
   - 数据缓存天数（`data_cache_days`）
   - 数据缓存开关（`enable_data_cache`）
   - 图片缓存天数（`image_cache_days`）
3. **静默预加载**
   - 预加载深度（`silent_preload_depth`）
4. **UI 设置**
   - 翻页按钮位置（`pagination_position`）
5. **调试**
   - 调试模式（`debug`）

### 3.4 运行时配置脚本消息

可通过 `script-message` 直接修改运行时配置（无需打开菜单）：

```
# 切换布尔开关（直接设置值）
script-message-to <script_name> staff-credits-set-config <key> <value>

# 弹出可选值列表（仅对 CONFIG_OPTIONS 中定义的枚举项有效）
script-message-to <script_name> staff-credits-config <key>
```

示例：
```
# 关闭调试模式
script-message-to uosc_staff_credits staff-credits-set-config debug no

# 弹出"静默预加载深度"选择菜单
script-message-to uosc_staff_credits staff-credits-config silent_preload_depth
```

### 3.5 持久化机制

- **文件路径**：`~~/staff-credits-runtime-config.json`（mpv 配置目录下）
- **写入策略**（见 `modules/runtime_config.lua`）：
  - 200ms 防抖：连续修改时仅最后一次触发写入，避免频繁 IO
  - 原子替换：先写入 `*.tmp` 临时文件，再 `os.rename` 替换原文件，避免写入中断导致文件损坏
  - 写入失败时静默清理临时文件，不影响脚本运行
- **读取策略**：启动时读取，文件不存在或解析失败时静默返回空表
- **合并优先级**：`runtime_config.get(key)` 返回值优先于 `opts[key]`（已与 defaults 合并）

---

## 4. 配置示例

### 4.1 最小配置（仅必要项）

适合首次使用，使用全部默认值：

```ini
# script-opts/uosc_staff_credits.conf
# 留空文件即使用 defaults.lua 中的全部默认值
# 推荐至少配置 User-Agent
user_agent=uosc_staff_credits (https://github.com/yourname/uosc_staff_credits)
```

### 4.2 推荐配置（官方 API + 镜像冗余）

适合追求稳定与数据完整性的用户：

```ini
# script-opts/uosc_staff_credits.conf

# === Bangumi API ===
# 官方 + 镜像冗余，首个有效结果即取消其余
api_server=https://api.bgm.tv|官方,https://api.bangumi.one|镜像

# === HTTP ===
timeout=20
user_agent=uosc_staff_credits (https://github.com/yourname/uosc_staff_credits)

# === SSL/TLS ===
ssl_no_revoke=yes
insecure=no

# === 数据源 ===
data_source=auto
enable_extra_search=yes

# === 缓存 ===
enable_data_cache=yes
data_cache_days=30
image_cache_days=30

# === 静默预加载 ===
autoload_with_danmaku=yes
silent_preload_depth=all

# === UI ===
pagination_position=bottom

# === 其他 ===
debug=no
max_results=10
```

### 4.3 低流量配置（移动网络/限流环境）

适合流量敏感或网络受限环境：

```ini
# script-opts/uosc_staff_credits.conf
api_base_url=https://api.bangumi.one
enable_extra_search=no             # 关闭外部搜索源减少请求
autoload_with_danmaku=no           # 关闭随弹幕静默预加载
silent_preload_depth=subject       # 仅预取条目 ID，最省流量
data_cache_days=90                 # 拉长缓存有效期减少重复请求
image_cache_days=90
debug=no
```

### 4.4 调试配置（排查问题）

适合开发或排查网络/解析问题：

```ini
# script-opts/uosc_staff_credits.conf
debug=yes                          # 启用调试日志
timeout=30                         # 放宽超时便于抓包
insecure=no                        # 保持证书验证
ssl_no_revoke=yes
# 如需抓包明文，可临时将 api_base_url 指向本地代理
# api_base_url=http://127.0.0.1:8080
```

### 4.5 运行时切换示例

不重启 mpv，通过菜单或脚本消息实时切换配置：

```lua
-- 在 mpv input.conf 中绑定快捷键
# 按 s 打开搜索设置菜单
s script-message-to uosc_staff_credits staff-credits-settings

# 按 d 快速切换调试模式
d script-message-to uosc_staff_credits staff-credits-set-config debug yes

# 按 c 快速切换数据缓存开关
c script-message-to uosc_staff_credits staff-credits-set-config enable_data_cache no
```

修改后会自动写入 `~~/staff-credits-runtime-config.json`，下次启动 mpv 仍然生效。

---

## 附录：配置项速查表

按字母顺序排列的全部 29 个 script-opts 配置项：

| 名称 | 类型 | 默认值 | 运行时可调 |
|------|------|--------|------------|
| `api_base_url` | string | `https://api.bangumi.one` | 否 |
| `api_server` | string | `""` | 否（仅首次导入） |
| `autoload_with_danmaku` | boolean | `true` | 否 |
| `bangumi_token` | string | `""` | 否 |
| `cacert_path` | string | `""` | 否 |
| `collection_type_on_mark` | number | `3` | 否 |
| `danmaku_api_server` | string | `https://api.dandanplay.net` | 否 |
| `data_cache_days` | number | `30` | 是 |
| `debug` | boolean | `true` | 是 |
| `enable_data_cache` | boolean | `true` | 是 |
| `enable_extra_search` | boolean | `true` | 否 |
| `enable_progress_sync` | boolean | `true` | 否 |
| `history_path` | string | `~~/staff-credits-history.json` | 否 |
| `image_cache_days` | number | `30` | 是 |
| `insecure` | boolean | `false` | 否 |
| `max_results` | number | `10` | 否 |
| `mpv_path` | string | `""` | 否 |
| `pagination_position` | string | `bottom` | 是 |
| `progress_sync_mode` | string | `off` | 否 |
| `progress_sync_threshold` | number | `80` | 否 |
| `request_timeout` | number | `15` | 否 |
| `silent_preload_depth` | string | `all` | 是 |
| `ssl_no_revoke` | boolean | `true` | 否 |
| `timeout` | number | `8` | 否 |
| `title_replace` | string（JSON） | `[{"rules": [{"^〔(.-)〕": "%1"}, {"^.*《(.-)》": "%1"}]}]` | 否 |
| `tmdb_api_key` | string | `""` | 否 |
| `user_agent` | string | `uosc_staff_credits (https://github.com/user/uosc_staff_credits)` | 否 |

**运行时可调项共 6 个**：`data_cache_days`、`image_cache_days`、`silent_preload_depth`、`pagination_position`、`enable_data_cache`、`debug`。

### 关于 Bangumi 观看进度的 5 项（2026-10-06 新增）

表中 `bangumi_token` 见 **§2.1**，`enable_progress_sync` / `progress_sync_mode` /
`progress_sync_threshold` / `collection_type_on_mark` 见 **§2.11**（含三条易错点警告）。
此处不再重复，以免两处内容走偏。

> ⚠️ 表中 `danmaku_api_server` 列的是**代码默认值**（官方源）。
> 随包附带的 `script-opts/uosc_staff_credits.conf` 把它指向了自建镜像
> （`https://dm.wodenas.xin/xiatianembydmww`），**以实际配置文件为准**。

---

**相关文件**：
- 默认值定义：`scripts/uosc_staff_credits/modules/defaults.lua`
- script-opts 配置：`script-opts/uosc_staff_credits.conf`
- 运行时持久化：`scripts/uosc_staff_credits/modules/runtime_config.lua`
- 设置菜单：`scripts/uosc_staff_credits/modules/menu.lua`（`CONFIG_OPTIONS` 表与 `show_settings_menu` 函数）
