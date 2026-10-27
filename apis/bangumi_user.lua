-- apis/bangumi_user.lua
-- Bangumi 用户鉴权 API（需要 access token）
--
-- ============================================================================
-- 用途
-- ============================================================================
-- 读写**你自己的** Bangumi 收藏与观看进度，例如：
--   · 查询某条目当前的收藏状态与已看集数
--   · 把某集标记为「看过」
--   · 把条目标记为「在看 / 看过」
--
-- 与 apis/api.lua 的区别：
--   api.lua        —— 公开端点（搜索/条目/角色/职员），无需鉴权
--   bangumi_user   —— 用户端点（/-/ 路径），**必须**带 access token
--
-- ============================================================================
-- token 从哪来
-- ============================================================================
--   1. 打开 https://next.bgm.tv/demo/access-token
--   2. 登录后生成，复制 access token
--   3. 填到 **staff-credits-runtime-config.json**（mpv 配置目录下）：
--          { "bangumi_token": "你的40位token" }
--
--   ⚠️ 为什么不填 script-opts/uosc_staff_credits.conf：
--      那个文件受 Git 跟踪，填进去会把令牌明文写进版本历史。
--      runtime-config.json 已被 .gitignore 忽略，且优先级更高
--      （runtime_config > opts > defaults），启动时经 runtime_config.load()
--      合并进 opts —— 本模块读的就是 opts.bangumi_token，故完全等效。
--
-- 安全：token 等同于账号权限。日志里**绝不**打印 token 本身。
--       本模块所有日志只输出「是否已配置」，不输出值。
--
-- ============================================================================
-- 端点（已按官方 OpenAPI 规范逐条核对，2026-10-06）
--   规范源：github.com/bangumi/api → open-api/v0.yaml
-- ============================================================================
--   GET    /v0/me                                          校验 token，返回当前用户
--   GET    /v0/users/-/collections/{subject_id}            读收藏状态
--   POST   /v0/users/-/collections/{subject_id}            改收藏状态（不存在则创建）
--   PATCH  /v0/users/-/collections/{subject_id}/episodes   批量更新剧集进度
--   PUT    /v0/users/-/collections/-/episodes/{episode_id} 更新单集进度
--
-- ⚠️ 两个易错点（曾按旧文档写错，已实测纠正）：
--   1. `.../episodes` 只有 **get / patch**，没有 post —— 用 POST 会 405。
--   2. `.../-/episodes/{episode_id}` 只有 **get / put**，没有 patch。
--   3. **所有写操作成功都返回 204 No Content，没有响应体**；
--      只有读操作（GET）才带 JSON。判空体时必须按方法区分，否则
--      写成功会被误报成「空响应」失败。
--
-- 鉴权头：Authorization: Bearer <access_token>
--
-- ============================================================================
-- ⚠️ 枚举取值陷阱（务必看清）
-- ============================================================================
-- Bangumi **新 API** 的 CollectionType 与旧版文档顺序**不同**：
--     1 = 想看   2 = 看过   3 = 在看   4 = 搁置   5 = 抛弃
--                    ^^^^^^    ^^^^^^
--   注意 2 是「看过」、3 是「在看」—— 很多旧教程写成 2=在看 3=看过，是错的。
--   （依据：官方 OpenAPI 中 SubjectCollectionType 的 x-enum-varnames
--     为 Wish / Done / Doing / OnHold / Dropped）
--
-- EpisodeCollectionType：
--     0 = 未收藏   1 = 想看   2 = 看过   3 = 抛弃
--
-- 遵循 ADR-10 统一 init(opts, deps) 接口

local mp = require("mp")
local utils = require("mp.utils")
local msg = require("mp.msg")

local M = {}

local opts, deps, init = require("modules.utils.module_loader").make_init(
    "bangumi_user",
    { notify = "table", request_registry = "table" }
)
M.init = init

-- 引用基础设施
local net_mod = require("modules.utils.net")

-- ============================================================================
-- 枚举常量
-- ============================================================================
M.COLLECTION_WISH = 1      -- 想看
M.COLLECTION_DONE = 2      -- 看过
M.COLLECTION_DOING = 3     -- 在看
M.COLLECTION_ON_HOLD = 4   -- 搁置
M.COLLECTION_DROPPED = 5   -- 抛弃

M.EP_NONE = 0              -- 未收藏
M.EP_WISH = 1              -- 想看
M.EP_DONE = 2              -- 看过
M.EP_DROPPED = 3           -- 抛弃

-- EpType（剧集类型，GET /v0/episodes 的 type 参数）
--   0=本篇 1=特别篇 2=OP 3=ED 4=预告/宣传 5=其他 6=其他
M.EP_TYPE_MAIN = 0

-- 错误码（与 api.lua 保持一致，便于上层统一处理）
local ERR_NETWORK = "ERR_NETWORK"
local ERR_HTTP = "ERR_HTTP"
local ERR_PARSE = "ERR_PARSE"
local ERR_EMPTY = "ERR_EMPTY"
local ERR_NO_TOKEN = "ERR_NO_TOKEN"
local ERR_NOT_FOUND = "ERR_NOT_FOUND"

local function make_error(code, m)
    return { code = code or ERR_PARSE, msg = tostring(m or "") }
end

-- ============================================================================
-- token 与基础地址
-- ============================================================================

-- has_token: 是否已配置 token（只返回布尔，绝不返回 token 值）
function M.has_token()
    local t = opts and opts.bangumi_token
    return type(t) == "string" and t ~= ""
end

-- is_enabled: 是否同时满足「配了 token」+「开了开关」
function M.is_enabled()
    if not M.has_token() then return false end
    -- enable_progress_sync 默认 true；显式 false 时整体关闭
    if opts and opts.enable_progress_sync == false then return false end
    return true
end

-- get_base_url: 取 Bangumi 基础地址（与搜索用同一套配置）
-- 优先 api_base_url；为空时取 api_server 列表的第一项
function M.get_base_url()
    local base = opts and opts.api_base_url
    if type(base) == "string" and base ~= "" then
        return (base:gsub("/+$", ""))
    end
    local list = opts and opts.api_server
    if type(list) == "string" and list ~= "" then
        -- 逗号分隔，取第一项；去掉 |/# 备注
        local first = list:match("^%s*([^,]+)")
        if first then
            first = first:match("^(.-)[|#]") or first
            first = first:gsub("^%s*(.-)%s*$", "%1")
            if first ~= "" then return (first:gsub("/+$", "")) end
        end
    end
    return "https://api.bgm.tv"
end

-- ============================================================================
-- 请求核心
-- ============================================================================

-- do_request: 真正的请求实现。token 为 nil 时不带鉴权头（公开端点用）。
local function do_request(method, path, body, token, expect_body, callback)
    if type(method) ~= "string" or type(path) ~= "string" then
        if callback then callback(false, nil, make_error(ERR_PARSE, "invalid args")) end
        return
    end

    -- ⚠️ 2026-10-06 实测（open-api/v0.yaml）：Bangumi 的**写操作**
    --    （POST/PATCH/PUT）成功一律返回 **204 No Content 且无响应体**，
    --    只有读操作（GET）才带 JSON。若不区分，写操作成功会被误判成
    --    ERR_EMPTY「空响应」—— 明明写进去了却报失败。
    if expect_body == nil then
        expect_body = (method == "GET")
    end

    local base = M.get_base_url()
    local url = base .. path
    local timeout = tonumber(opts.request_timeout) or tonumber(opts.timeout) or 15
    local user_agent = opts.user_agent or "uosc_staff_credits"

    local args = {
        "curl", "-sL",
        "--max-time", tostring(timeout),
        "-X", method,
        "-H", "User-Agent: " .. user_agent,
        "-H", "Accept: application/json",
    }
    if token then
        -- ⚠️ 唯一出现 token 的地方。绝不把它写进日志
        table.insert(args, "-H")
        table.insert(args, "Authorization: Bearer " .. token)
    end
    if body ~= nil then
        local ok, json_body = pcall(utils.format_json, body)
        if not ok or type(json_body) ~= "string" then
            if callback then callback(false, nil, make_error(ERR_PARSE, "body encode failed")) end
            return
        end
        table.insert(args, "-H")
        table.insert(args, "Content-Type: application/json")
        table.insert(args, "-d")
        table.insert(args, json_body)
    end
    local ssl_args = net_mod.build_ssl_args(opts)
    for _, a in ipairs(ssl_args) do table.insert(args, a) end
    table.insert(args, url)

    local registered_token = nil
    local abort_handle = mp.command_native_async({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
        args = args,
    }, function(success, result, error)
        if registered_token and deps and deps.request_registry
           and type(deps.request_registry.unregister) == "function" then
            pcall(deps.request_registry.unregister, registered_token)
        end

        if not success or not result then
            if callback then
                callback(false, nil, make_error(ERR_NETWORK, tostring(error or "request failed")))
            end
            return
        end

        -- 状态码判定：这里拿到的是 **curl 退出码**，不是 HTTP 状态码。
        -- 说明：curl 未加 --fail，所以 HTTP 4xx/5xx 时退出码仍为 0 ——
        --       服务端错误只能靠响应体（ErrorDetail）识别，见下。
        local body_str = result.stdout or ""
        local code = tonumber(result.status) or 0

        if code ~= 0 then
            local err_msg = "curl exit code: " .. tostring(code)
            if code == 28 then
                err_msg = "请求超时（curl exit code 28）"
            elseif code == 6 then
                err_msg = "DNS 解析失败（curl exit code 6）"
            elseif code == 7 then
                err_msg = "无法连接服务器（curl exit code 7）"
            end
            if result.stderr and result.stderr ~= "" then
                err_msg = err_msg .. " | " .. result.stderr
            end
            if callback then callback(false, nil, make_error(ERR_NETWORK, err_msg)) end
            return
        end

        if body_str == "" then
            if expect_body then
                if callback then callback(false, nil, make_error(ERR_EMPTY, "empty body")) end
            else
                -- 204 No Content = 写操作成功
                if callback then callback(true, {}, nil) end
            end
            return
        end

        local data = utils.parse_json(body_str)
        if type(data) ~= "table" then
            if callback then callback(false, nil, make_error(ERR_PARSE, "json parse failed")) end
            return
        end

        -- Bangumi 错误响应 = ErrorDetail，其 **required 恰好就是 title + description**；
        -- 而三个成功 schema（User / UserSubjectCollection / UserEpisodeCollection）
        -- 都**不含**这两个字段（已逐条核对 open-api/v0.yaml）。
        -- 所以「title and description」就是充要判别式 —— 曾多写的
        -- `and not data.id and not data.type` 是死代码，已删除。
        if data.title and data.description then
            local em = tostring(data.title) .. ": " .. tostring(data.description)
            if callback then callback(false, nil, make_error(ERR_HTTP, em)) end
            return
        end

        if callback then callback(true, data, nil) end
    end)

    if deps and deps.request_registry and type(deps.request_registry.register) == "function" then
        registered_token = deps.request_registry.register(function()
            pcall(function() mp.abort_async_command(abort_handle) end)
        end)
    end
end

-- request: 发起一个带 token 的 Bangumi 请求
--   method:   "GET" / "POST" / "PATCH" / "PUT"
--   path:     "/v0/me" 这类以 / 开头的路径
--   body:     可选 table，会被序列化为 JSON 作为请求体
--   callback(success, data, err_info)
--   expect_body: 可选。true = 必须有 JSON 响应体，空体算失败；
--                false = 允许 204 空体（写操作成功的正常形态）。
--                省略时按 method 推断（见下）。
--
-- 说明：playback_only = false —— 标记进度属于用户主动操作，
--       不应因为视频暂停就被掐断。
function M.request(method, path, body, callback, expect_body)
    local token = opts and opts.bangumi_token
    if type(token) ~= "string" or token == "" then
        if callback then
            callback(false, nil, make_error(ERR_NO_TOKEN, "未配置 bangumi_token"))
        end
        return
    end
    do_request(method, path, body, token, expect_body, callback)
end

-- ============================================================================
-- 业务接口
-- ============================================================================

-- get_me: 校验 token 是否有效，返回当前用户
-- callback(success, user, err_info)；user 含 id / username / nickname
function M.get_me(callback)
    M.request("GET", "/v0/me", nil, callback)
end

-- ============================================================================
-- 剧集列表（**公开端点，不需要 token**）
-- ============================================================================
-- 为什么要它：标记「看过」用的是 Bangumi 的 **episode_id**，不是文件名里的集数。
-- 两者必须经过一次映射：GET /v0/episodes?subject_id=X → data[].sort 就是集数。
--
-- ⚠️ limit 上限 200（规范限制）。单季番远够用；超长番（如 300+ 集的长寿番）
--    只会取到前 200 集，届时映射不到会明确报 ERR_NOT_FOUND，不会静默标错。

local episode_cache = {}          -- subject_id -> {data=..., _ts=...}
local EPISODE_CACHE_TTL = 1800    -- 30 分钟

-- clear_episode_cache: 清空剧集列表缓存（设置菜单的「清除缓存」会调）
function M.clear_episode_cache()
    episode_cache = {}
end

-- get_episodes: 取某条目的本篇剧集列表
-- callback(success, list, err_info)；list 为数组，每项含 id / sort / ep / name / name_cn
function M.get_episodes(subject_id, callback)
    local sid = tonumber(subject_id)
    if not sid then
        if callback then callback(false, nil, make_error(ERR_PARSE, "no subject_id")) end
        return
    end

    local cached = episode_cache[sid]
    if cached and (mp.get_time() - cached._ts) < EPISODE_CACHE_TTL then
        if callback then callback(true, cached.data, nil) end
        return
    end

    do_request("GET", "/v0/episodes?subject_id=" .. tostring(sid)
        .. "&type=" .. tostring(M.EP_TYPE_MAIN) .. "&limit=200",
        nil, nil, true,
        function(ok, data, err)
            if not ok then
                if callback then callback(false, nil, err) end
                return
            end
            local list = type(data) == "table" and data.data or nil
            if type(list) ~= "table" then
                if callback then
                    callback(false, nil, make_error(ERR_PARSE, "响应里没有 data 数组"))
                end
                return
            end
            episode_cache[sid] = { data = list, _ts = mp.get_time() }
            if callback then callback(true, list, nil) end
        end)
end

-- resolve_episode_id: 把「集数」映射成 Bangumi 的 episode_id
--   优先比 sort（Bangumi 的集数序号，与文件名里的集数一致）；
--   退而比 ep（展示用的集数串，特别篇常写成 1.5 这种）。
-- callback(success, episode_id, err_info)
function M.resolve_episode_id(subject_id, ep_number, callback)
    local want = tonumber(ep_number)
    if not want then
        if callback then
            callback(false, nil, make_error(ERR_PARSE,
                "无法从文件名识别集数: " .. tostring(ep_number)))
        end
        return
    end

    M.get_episodes(subject_id, function(ok, list, err)
        if not ok then
            if callback then callback(false, nil, err) end
            return
        end
        for _, ep in ipairs(list) do
            if tonumber(ep.sort) == want then
                if callback then callback(true, tonumber(ep.id), nil) end
                return
            end
        end
        for _, ep in ipairs(list) do
            if tonumber(ep.ep) == want then
                if callback then callback(true, tonumber(ep.id), nil) end
                return
            end
        end
        if callback then
            callback(false, nil, make_error(ERR_NOT_FOUND,
                "该条目下找不到第 " .. tostring(want) .. " 集（共 "
                .. tostring(#list) .. " 集）"))
        end
    end)
end

-- get_collection: 读取某条目的收藏状态
-- callback(success, collection, err_info)
-- collection 含 type（收藏类型）/ ep_status（已看集数）等
function M.get_collection(subject_id, callback)
    if not subject_id then
        if callback then callback(false, nil, make_error(ERR_PARSE, "no subject_id")) end
        return
    end
    M.request("GET", "/v0/users/-/collections/" .. tostring(subject_id), nil, callback)
end

-- update_collection: 修改收藏状态
-- ctype: 用 M.COLLECTION_* 常量（注意 2=看过 3=在看）
function M.update_collection(subject_id, ctype, callback)
    if not subject_id or not ctype then
        if callback then callback(false, nil, make_error(ERR_PARSE, "no subject_id/type")) end
        return
    end
    M.request("POST", "/v0/users/-/collections/" .. tostring(subject_id),
        { type = tonumber(ctype) }, callback)
end

-- update_episode_progress: 批量更新剧集进度
-- episode_ids: 数组，如 {123, 456}
-- etype: 用 M.EP_* 常量（2 = 看过）
--
-- ⚠️ 方法是 **PATCH** 不是 POST —— 该路径只定义了 get / patch
--    （open-api/v0.yaml）。用 POST 会拿到 405，而且因为 curl 没加 --fail，
--    405 的响应体不是 ErrorDetail，会被当成「解析失败」，很难定位。
function M.update_episode_progress(subject_id, episode_ids, etype, callback)
    if not subject_id or type(episode_ids) ~= "table" or #episode_ids == 0 then
        if callback then callback(false, nil, make_error(ERR_PARSE, "no subject_id/episodes")) end
        return
    end
    local ids = {}
    for _, e in ipairs(episode_ids) do
        local n = tonumber(e)
        if n then table.insert(ids, n) end
    end
    if #ids == 0 then
        if callback then callback(false, nil, make_error(ERR_PARSE, "no valid episode ids")) end
        return
    end
    M.request("PATCH",
        "/v0/users/-/collections/" .. tostring(subject_id) .. "/episodes",
        { episode_id = ids, type = tonumber(etype) or M.EP_DONE }, callback)
end

-- update_single_episode: 更新单集进度
--
-- ⚠️ 方法是 **PUT** 不是 PATCH —— 该路径只定义了 get / put（open-api/v0.yaml）。
function M.update_single_episode(episode_id, etype, callback)
    if not episode_id then
        if callback then callback(false, nil, make_error(ERR_PARSE, "no episode_id")) end
        return
    end
    M.request("PUT", "/v0/users/-/collections/-/episodes/" .. tostring(episode_id),
        { type = tonumber(etype) or M.EP_DONE }, callback)
end

-- mark_episode_watched: 便捷封装 —— 把某集标记为「看过」
-- 流程：先读收藏状态 → 若尚未收藏则先收藏（用 collection_type_on_mark）→ 再标集
-- callback(success, info, err_info)
function M.mark_episode_watched(subject_id, episode_id, callback)
    if not subject_id or not episode_id then
        if callback then callback(false, nil, make_error(ERR_PARSE, "no subject_id/episode_id")) end
        return
    end

    local function do_mark_episode()
        M.update_episode_progress(subject_id, { episode_id }, M.EP_DONE,
            function(ok, data, err)
                if not ok then
                    if callback then callback(false, nil, err) end
                    return
                end
                if callback then
                    callback(true, { subject_id = subject_id, episode_id = episode_id }, nil)
                end
            end)
    end

    -- 先查收藏状态，决定是否需要补一个「收藏」
    M.get_collection(subject_id, function(ok, coll, _err)
        if ok and type(coll) == "table" and coll.type then
            -- 已收藏，直接标集
            do_mark_episode()
            return
        end
        -- 未收藏（404 或读取失败）：先收藏再标集
        local want = tonumber(opts and opts.collection_type_on_mark) or M.COLLECTION_DOING
        M.update_collection(subject_id, want, function(ok2, _d, err2)
            if not ok2 then
                -- 收藏失败不阻塞标集：有些条目可能已在别的收藏里
                msg.warn("[bangumi_user] 收藏失败，仍尝试标记集进度: " .. tostring(err2 and err2.msg))
            end
            do_mark_episode()
        end)
    end)
end

-- ============================================================================
-- 供上层做友好提示
-- ============================================================================
M.ERR_NO_TOKEN = ERR_NO_TOKEN
M.ERR_NOT_FOUND = ERR_NOT_FOUND

-- describe_collection_type: 数值 → 中文（用于 UI 提示）
function M.describe_collection_type(t)
    local n = tonumber(t)
    if n == M.COLLECTION_WISH then return "想看" end
    if n == M.COLLECTION_DONE then return "看过" end
    if n == M.COLLECTION_DOING then return "在看" end
    if n == M.COLLECTION_ON_HOLD then return "搁置" end
    if n == M.COLLECTION_DROPPED then return "抛弃" end
    return "未收藏"
end

return M
