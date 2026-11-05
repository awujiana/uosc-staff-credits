-- modules/external_api.lua
-- uosc_staff_credits 对外 API：只读状态广播 + 请求-响应 + 白名单动作转发。
-- 契约见 docs/EXTERNAL_API.md。
--
-- 设计原则：
--   * 纯模块，不持有业务状态；只读 app/state 与少量 mpv 属性，不写任何业务字段。
--   * 快照严禁包含 token / api key / 用户隐私配置（opts 只取布尔开关，且逐个白名单）。
--   * 任何失败都 pcall 兜住，绝不影响演职员表主流程。
--   * 所有既有 script-message 入口原样保留；本模块只新增 `api` 一个入口。

local mp = require("mp")
local msg = require("mp.msg")
local utils = require("mp.utils")

local M = {}

M.API_VERSION = "1.0.0"
local PREFIX = "uosc_staff_credits"
local RESPONSE_NAME = PREFIX .. "-api-response"

-- 可安全由外部脚本触发的既有 dispatcher 入口。
-- 刻意不含 api / 内部调试入口，避免外部脚本递归进入 API 通道。
local API_CALLS = {
    ["main-menu"] = true,
    ["staff-credits"] = true,
    ["character-intro"] = true,
    ["cover-intro"] = true,
    ["staff-credits-production-score"] = true,
    ["staff-credits-search"] = true,
    ["staff-credits-select"] = true,
    ["staff-credits-close"] = true,
    ["staff-credits-settings"] = true,
    ["staff-credits-servers"] = true,
    ["staff-credits-config"] = true,
    ["staff-credits-set-config"] = true,
    ["staff-credits-show-progress"] = true,
    ["staff-credits-mark-watched"] = true,
    ["staff-credits-clear-cache"] = true,
    ["staff-credits-clear-all"] = true,
}

local function valid_token(s)
    return type(s) == "string" and s ~= "" and #s <= 128
        and s:match("^[%w_%.%-]+$") ~= nil
end

local function count_keys(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- 只读快照。ctx = {state, script_name, danmaku_link, opts}
function M.build_state(ctx)
    ctx = ctx or {}
    local st = ctx.state or {}
    local ls = st.loading_state or {}
    local ss = st.search_state or {}
    local path = ss.current_path or mp.get_property("path")

    local subject = nil
    if path and type(st.get_last_subject) == "function" then
        local ok, info = pcall(st.get_last_subject, path)
        if ok and type(info) == "table" then
            -- 只挑对外安全的展示字段，不整表透出（内部可能含 _ts / 原始 API 响应）。
            subject = {id = info.id, name = info.name,
                       name_cn = info.name_cn, url = info.url}
        end
    end

    local danmaku = nil
    if ctx.danmaku_link and type(ctx.danmaku_link.get_info) == "function" then
        local ok, info = pcall(ctx.danmaku_link.get_info)
        if ok and type(info) == "table" then
            danmaku = {anime = info.anime, episode = info.episode,
                       episode_id = info.episode_id, api_server = info.api_server}
        end
    end

    -- 配置只暴露「功能是否开启」这类无敏感信息的布尔值。
    local opts = ctx.opts or {}
    local features = {
        autoload_with_danmaku = opts.autoload_with_danmaku == true,
    }

    return {
        api_version = M.API_VERSION,
        script_name = PREFIX,
        ready = true,
        path = path,
        filename = mp.get_property("filename"),
        media_title = mp.get_property("media-title"),
        loading = ls.loading == true,
        loading_menu_type = ls.loading_menu_type,
        last_search_query = ss.last_search_query,
        last_subject = subject,
        subject_cache_count = count_keys(ss.last_subject_by_path),
        cover_cache_count = count_keys(ss.cover_intro_cache),
        danmaku = danmaku,
        features = features,
    }
end

-- 刷新订阅属性。⚠ user-data 是 node 属性，写入用 native，读取也必须 native。
function M.publish(ctx)
    local ok, json = pcall(utils.format_json, M.build_state(ctx))
    if not ok or type(json) ~= "string" then return false end
    local wrote = pcall(mp.set_property_native,
                        "user-data/" .. PREFIX .. "/state", json)
    return wrote
end

local function get_path(snap, key)
    local node = snap
    for part in tostring(key or ""):gmatch("[^%.]+") do
        if type(node) ~= "table" then return nil end
        node = node[part]
    end
    return node
end

local function reply(reply_to, request_id, payload)
    payload.request_id = request_id
    local ok, json = pcall(utils.format_json, payload)
    if not ok then json = '{"ok":false,"error":"encode_failed"}' end
    pcall(mp.command_native, {"script-message-to", reply_to,
                              RESPONSE_NAME, request_id, json})
end

local function action_list()
    local out = {}
    for name in pairs(API_CALLS) do out[#out + 1] = name end
    table.sort(out)
    return out
end

-- 由 dispatcher 注册的消息入口调用；也可被测试直接调用。
function M.handle(ctx, reply_to, request_id, action, ...)
    if not valid_token(reply_to) or not valid_token(request_id) then
        msg.warn("[external_api] bad reply_to/request_id: "
            .. tostring(reply_to) .. "/" .. tostring(request_id))
        return false
    end
    local args = {...}
    local function send(p) reply(reply_to, request_id, p) end

    if action == "get-state" then
        send({ok = true, data = M.build_state(ctx)})
    elseif action == "get" then
        local key = args[1]
        if not valid_token(key) then
            send({ok = false, error = "bad_key"})
            return true
        end
        local v = get_path(M.build_state(ctx), key)
        if v == nil then
            send({ok = false, error = "unknown_key", key = key})
        else
            send({ok = true, key = key, value = v})
        end
    elseif action == "list-actions" then
        send({ok = true, actions = action_list()})
    elseif action == "call" then
        local name = args[1]
        if not valid_token(name) then
            send({ok = false, error = "bad_action_name"})
            return true
        end
        if not API_CALLS[name] then
            send({ok = false, error = "action_not_allowed", action = name})
            return true
        end
        local target = ctx.script_name or PREFIX
        local cmd = {"script-message-to", target, name}
        for i = 2, #args do cmd[#cmd + 1] = tostring(args[i]) end
        if not pcall(mp.command_native, cmd) then
            send({ok = false, error = "dispatch_failed", action = name})
        else
            -- 异步派发：先回「已派发」，结果请用订阅通道或再次 get-state 观察。
            send({ok = true, dispatched = name, async = true})
        end
    else
        send({ok = false, error = "unknown_action", action = tostring(action)})
    end
    return true
end

-- 注册入口并发布初始状态。由 app/dispatcher.lua 的 register_all() 调用。
function M.register(ctx)
    pcall(mp.set_property_native,
          "user-data/" .. PREFIX .. "/version", M.API_VERSION)
    mp.register_script_message("api", function(reply_to, request_id, action, ...)
        M.publish(ctx)
        M.handle(ctx, reply_to, request_id, action, ...)
    end)
    M.publish(ctx)
    msg.info("[external_api] ready v" .. M.API_VERSION)
end

-- 供测试/其它模块读取白名单（只读副本，避免外部改写）
function M.allowed_actions()
    return action_list()
end

return M
