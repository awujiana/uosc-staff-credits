# uosc_staff_credits 对外 API

> 适用版本：子仓库 `awujiana/uosc-staff-credits`，API 版本 `1.0.0`（随 v2.1 引入）。
> 面向「别的 mpv 脚本 / 自定义按键」读取演职员表脚本的当前状态、触发其菜单动作。
> 姊妹契约：`docs/api-uosc-subtitle-style.md`（主配置仓库）。

## 1. 设计边界

| 项目 | 约定 |
|---|---|
| 脚本名（`script-message-to` 目标） | `uosc_staff_credits` |
| API 版本 | `1.0.0`（独立于脚本版本；只增可选字段不升版本） |
| 传输 | mpv `script-message` + `user-data` 属性 |
| 方向 | ① 状态广播（订阅）② 请求-响应（查询）③ 白名单动作转发 |
| 隐私 | 快照**逐字段白名单**，绝不输出 `bangumi_token` / API key / 原始 `opts` / 原始 API 响应 |
| 兼容性 | 纯附加；所有 v2.0 及更早的 `script-message` 入口原样保留，参数与副作用不变 |
| 失败策略 | 参数错误只回 `ok=false` 或写日志；所有 mpv 调用 `pcall` 兜住，不影响主流程 |

实现位于 `modules/external_api.lua`（纯模块，不持有业务状态），由
`app/dispatcher.lua` 的 `register_all()` 注册；每个既有菜单动作执行后、
以及 `path` 变化时自动刷新广播。

## 2. 通道一：`user-data` 状态广播

| 属性 | 类型 | 说明 |
|---|---|---|
| `user-data/uosc_staff_credits/version` | string | `1.0.0`，注册时写一次 |
| `user-data/uosc_staff_credits/state` | string | JSON 字符串，字段见 §3；菜单动作 / 换片 / API 请求时刷新 |

```lua
local mp, utils = require('mp'), require('mp.utils')
mp.observe_property('user-data/uosc_staff_credits/state', 'native', function(_, raw)
    if type(raw) ~= 'string' then return end
    local ok, st = pcall(utils.parse_json, raw)
    if ok and st and st.last_subject then
        mp.msg.info('当前条目：' .. tostring(st.last_subject.name_cn or st.last_subject.name))
    end
end)
local raw = mp.get_property_native('user-data/uosc_staff_credits/state')
```

> ⚠ **必须用 `native`**：`user-data` 是 node 属性，`mp.get_property()` /
> `observe_property(..., 'string')` 拿到的是带引号、二次转义的 JSON 文本表示，
> 不能直接 `parse_json`。真机断言见主配置仓库 `tools/sub-style-probe-api.lua`。

## 3. `state` 字段表

值为 JSON 对象；`nil` 字段由 `utils.format_json` 省略，取值前请判空。

| 字段 | 类型 | 说明 |
|---|---|---|
| `api_version` | string | 固定 `1.0.0` |
| `script_name` | string | 固定 `uosc_staff_credits` |
| `ready` | boolean | 注册完成，固定 `true` |
| `path` | string? | 当前视频路径（`search_state.current_path` 优先，`path` 属性兜底） |
| `filename` | string? | mpv `filename` |
| `media_title` | string? | mpv `media-title` |
| `loading` | boolean | 是否正在加载（来自 `loading_state`） |
| `loading_menu_type` | string? | 当前加载菜单类型 |
| `last_search_query` | string? | 最近一次搜索关键词 |
| `last_subject` | object? | 当前路径缓存的条目，仅 `id` / `name` / `name_cn` / `url` 四个展示字段 |
| `subject_cache_count` | number | 按路径缓存的条目数 |
| `cover_cache_count` | number | 封面/简介缓存条目数 |
| `danmaku` | object? | 来自 `modules/danmaku_link.get_info()`，仅 `anime` / `episode` / `episode_id` / `api_server` |
| `features.autoload_with_danmaku` | boolean | 静默预加载开关（**唯一**对外暴露的配置项） |

**不含**：任何 token、api key、请求头、原始 API 响应、缓存内容正文。
`tests/external_api/main.lua` 的 `build-no-token-leak` 用例会遍历序列化结果做字面检查。

## 4. 通道二：请求-响应

```text
script-message-to uosc_staff_credits api <reply_to> <request_id> <action> [args...]
```

回复：

```text
script-message-to <reply_to> uosc_staff_credits-api-response <request_id> <json>
```

接收方需注册 `mp.register_script_message('uosc_staff_credits-api-response', fn)`。
`reply_to` / `request_id` 只允许 `[A-Za-z0-9_.-]` 且 ≤128 字符；非法时只写 `warn`，
不向未知目标发消息。所有响应都含 `ok` 与 `request_id`（原样回填）。

| action | 额外参数 | 成功响应 |
|---|---|---|
| `get-state` | 无 | `{ok, request_id, data=<§3 快照>}` |
| `get` | `<dotted.key>` | `{ok, request_id, key, value}`，如 `last_subject.name_cn`、`loading`、`features.autoload_with_danmaku` |
| `list-actions` | 无 | `{ok, request_id, actions=[...]}`（16 个白名单动作） |
| `call` | `<action_name> [args...]` | `{ok, request_id, dispatched, async=true}` |

### 错误码

| `error` | 触发条件 | 是否回复 |
|---|---|---|
| `bad_key` / `unknown_key` | `get` 缺 key / 路径不存在 | ✅ |
| `unknown_action` | 不支持的 action | ✅ |
| `bad_action_name` / `action_not_allowed` | `call` 缺名字 / 不在白名单 | ✅ |
| `dispatch_failed` | 内部转发抛错 | ✅ |
| `encode_failed` | JSON 编码失败 | ✅ |
| — | `reply_to` / `request_id` 非法 | ❌ 只写日志 |

### `call` 语义

`call` 把请求转发给 `dispatcher` 已注册的原生入口：

```text
script-message-to uosc_staff_credits api my_script c1 call staff-credits-search 示例
→ script-message-to uosc_staff_credits staff-credits-search 示例   # 内部转发
→ script-message-to my_script uosc_staff_credits-api-response c1 {"ok":true,...}
```

- **`async=true`**：先回「已派发」，动作随后执行；观察结果请订阅 §2 或再次 `get-state`。
- 白名单 16 项（`main-menu` / `staff-credits` / `character-intro` / `cover-intro` /
  `staff-credits-*` 系列等），动态获取用 `list-actions`。
- **不含 `api` 自身**，防止递归；不含内部调试入口。
- 会真实触发菜单/网络请求，调用方应自行判断时机。

## 5. 完整调用示例

```lua
local mp, utils = require('mp'), require('mp.utils')
local SELF = mp.get_script_name() or 'my_script'
local pending = {}

mp.register_script_message('uosc_staff_credits-api-response', function(rid, json)
    local ok, res = pcall(utils.parse_json, json)
    if not ok or not res then return end
    local cb = pending[rid]
    if cb then pending[rid] = nil; cb(res) end
end)

local function request(action, cb, ...)
    local rid = 'q' .. tostring(math.random(100000, 999999))
    pending[rid] = cb
    mp.command_native({'script-message-to', 'uosc_staff_credits',
                       'api', SELF, rid, action, ...})
end

request('get-state', function(res)
    if res.ok then mp.msg.info('条目=' .. tostring(res.data.last_search_query)) end
end)
request('get', function(res) mp.msg.info('loading=' .. tostring(res.value)) end, 'loading')
```

## 6. 门禁覆盖

| 层 | 位置 | 判据 |
|---|---|---|
| 单测（自包含 mp 桩） | `tests/external_api/main.lua`，**26 条** | 快照字段与隐私白名单、无 token 泄漏、注册与初始广播、四类 action、错误码、非法 token 不回复、白名单不含 `api`、`call` 转发参数、状态变化刷新、空 ctx 容错 |
| 真机 E2E | 主配置仓库 `tools/sub-style-probe-api.lua` 的 `staff-api-*` 7 条 | 真实 mpv 下 `user-data` 可读、state 字段完整且无 token、`get-state` 回复可达且 id 回填、`list-actions` 非空 |
| 语法 | `luajit -e "assert(loadfile('modules/external_api.lua'))"` | 模块与 dispatcher 均可加载 |

运行方式：

```bash
cd portable_config/scripts/uosc_staff_credits
../../../luajit.exe tests/external_api/main.lua
```

## 7. 版本与兼容承诺

- API `1.0.0` 起：§3 已列字段**只增不删**；新增可选字段不升 MINOR。
- 删除字段、改变类型/单位、改变 `error` 值语义 → 升 MINOR；改变调用格式或回复消息名 → 升 MAJOR。
- 本子仓库是主配置仓库的 submodule；API 改动须先在子仓库提交推送，
  主配置仓库再更新 gitlink 指向。
