-- tests/external_api/main.lua —— modules/external_api.lua 自包含回归测试
--
-- 不依赖仓库外 harness，自带 mp 桩，可直接跑：
--   cd portable_config/scripts/uosc_staff_credits
--   ../../../luajit.exe tests/external_api/main.lua
-- 判据：exit 0 且 SUMMARY ... ALL_OK

package.path = "./?.lua;./?/init.lua;" .. package.path

local pass, fail = 0, 0
local function check(name, ok, detail)
    if ok then pass = pass + 1 else fail = fail + 1 end
    print(string.format("%s %s%s", ok and "PASS" or "FAIL", name,
        detail and (" | " .. tostring(detail)) or ""))
end

-- 最小 JSON 编码器（测试桩两端都在自己手里，格式确定即可）
local function jenc(v)
    local t = type(v)
    if t == "string" then
        return '"' .. v:gsub('[\\"]', {['\\'] = '\\\\', ['"'] = '\\"'}) .. '"'
    elseif t == "number" then return tostring(v)
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "table" then
        local is_array, n = true, 0
        for k in pairs(v) do
            if type(k) ~= "number" then is_array = false end
            n = n + 1
        end
        if is_array and n == 0 then return "[]" end
        local parts = {}
        if is_array then
            for i = 1, n do parts[#parts + 1] = jenc(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = jenc(tostring(k)) .. ":" .. jenc(v[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

local props, commands, messages, warns = {}, {}, {}, {}
local encoded_by_json = {}

local mp_stub = {}
function mp_stub.get_property(n) return props[n] end
function mp_stub.get_property_native(n) return props[n] end
function mp_stub.set_property_native(n, v) props[n] = v end
function mp_stub.command_native(t) commands[#commands + 1] = t end
function mp_stub.register_script_message(n, fn) messages[n] = fn end
function mp_stub.observe_property() end
function mp_stub.get_time() return 0 end
function mp_stub.get_script_name() return "uosc_staff_credits" end

package.loaded["mp"] = mp_stub
package.loaded["mp.msg"] = {
    info = function() end,
    warn = function(s) warns[#warns + 1] = tostring(s) end,
    error = function() end, debug = function() end, verbose = function() end,
}
package.loaded["mp.utils"] = {
    format_json = function(v)
        local s = jenc(v)
        encoded_by_json[s] = v
        return s
    end,
    parse_json = function(s) return s end,
}

local api = require("modules.external_api")

local function payload_of(cmd)
    return cmd and encoded_by_json[cmd[#cmd]] or nil
end
local function replies()
    local out = {}
    for _, c in ipairs(commands) do
        if c[3] == "uosc_staff_credits-api-response" then out[#out + 1] = c end
    end
    return out
end
local function last_reply()
    local rs = replies()
    return payload_of(rs[#rs])
end
local function clear() commands = {} end

-- 构造被测上下文
props["path"] = "D:/anime/Show - 01.mkv"
props["filename"] = "Show - 01.mkv"
props["media-title"] = "Show - 01"

local subject = {id = 123, name = "Show", name_cn = "示例番剧",
                 url = "https://example/123", _ts = 999, secret = "SHOULD_NOT_LEAK"}
-- ⚠ 闭包不能捕获正在初始化中的 local（Lua 初始化器里 local 尚未进入作用域），
--   所以把 subjects 单独提前声明，否则 pcall 会静默失败、last_subject 变 nil。
local subjects = {[props["path"]] = subject}
local fake_state = {
    loading_state = {loading = true, loading_menu_type = "staff"},
    search_state = {
        current_path = props["path"],
        last_search_query = "示例番剧",
        last_subject_by_path = subjects,
        cover_intro_cache = {a = 1, b = 2},
    },
    get_last_subject = function(p) return subjects[p] end,
}
local ctx = {
    state = fake_state,
    script_name = "uosc_staff_credits",
    danmaku_link = {
        get_info = function()
            return {anime = "示例番剧", episode = "第3话",
                    episode_id = "1024", api_server = "https://api.example",
                    token = "SHOULD_NOT_LEAK"}
        end,
    },
    opts = {autoload_with_danmaku = true, bangumi_token = "SHOULD_NOT_LEAK"},
}

-- ① 快照字段与隐私白名单
local snap = api.build_state(ctx)
check("build-api-version", api.API_VERSION == "1.0.0" and snap.api_version == "1.0.0")
check("build-path-and-title", snap.path == props["path"]
    and snap.filename == "Show - 01.mkv" and snap.media_title == "Show - 01")
check("build-loading", snap.loading == true and snap.loading_menu_type == "staff")
check("build-query-and-counts", snap.last_search_query == "示例番剧"
    and snap.subject_cache_count == 1 and snap.cover_cache_count == 2)
check("build-subject-whitelist", type(snap.last_subject) == "table"
    and snap.last_subject.id == 123 and snap.last_subject.name_cn == "示例番剧"
    and snap.last_subject.secret == nil and snap.last_subject._ts == nil)
check("build-danmaku-whitelist", type(snap.danmaku) == "table"
    and snap.danmaku.episode_id == "1024" and snap.danmaku.token == nil)
local encoded_snap = jenc(snap)
check("build-no-token-leak", not encoded_snap:find("SHOULD_NOT_LEAK", 1, true)
    and not encoded_snap:find("token", 1, true), "len=" .. #encoded_snap)
check("build-features-boolean-only", type(snap.features) == "table"
    and snap.features.autoload_with_danmaku == true)

-- ② 注册与初始广播
api.register(ctx)
check("register-version-property",
    props["user-data/uosc_staff_credits/version"] == "1.0.0")
check("register-initial-state",
    type(props["user-data/uosc_staff_credits/state"]) == "string"
    and #props["user-data/uosc_staff_credits/state"] > 20)
check("register-api-message", type(messages["api"]) == "function")
check("register-native-messages-untouched",
    messages["main-menu"] == nil)   -- 本模块不注册业务入口，由 dispatcher 负责

-- ③ 请求-响应
clear()
messages["api"]("client", "r1", "get-state")
local rs = replies()
check("get-state-reply-shape", #rs == 1 and rs[1][2] == "client"
    and rs[1][3] == "uosc_staff_credits-api-response" and rs[1][4] == "r1",
    "#replies=" .. #rs)
local p1 = last_reply()
check("get-state-ok", p1 and p1.ok == true and type(p1.data) == "table"
    and p1.request_id == "r1")

clear()
messages["api"]("client", "r2", "get", "last_subject.name_cn")
local p2 = last_reply()
check("get-dotted-key", p2 and p2.ok == true and p2.value == "示例番剧")
clear()
messages["api"]("client", "r3", "get", "no.such.key")
check("get-unknown-key", last_reply().error == "unknown_key")
clear()
messages["api"]("client", "r4", "get")
check("get-bad-key", last_reply().error == "bad_key")

-- ④ 参数校验
clear()
messages["api"]("bad target", "r5", "get-state")
messages["api"](nil, "r6", "get-state")
messages["api"]("client", "", "get-state")
check("invalid-tokens-no-reply", #replies() == 0 and #warns >= 2,
    "#replies=" .. #replies() .. " #warns=" .. #warns)

-- ⑤ 动作白名单
clear()
messages["api"]("client", "r7", "no-such-action")
check("unknown-action", last_reply().error == "unknown_action")
clear()
messages["api"]("client", "r8", "list-actions")
local acts = last_reply().actions or {}
local has_sc, has_api = false, false
for _, a in ipairs(acts) do
    if a == "staff-credits" then has_sc = true end
    if a == "api" then has_api = true end
end
check("list-actions-whitelist", has_sc and not has_api, "n=" .. #acts)

clear()
messages["api"]("client", "r9", "call", "staff-credits-search", "示例")
local fwd
for _, c in ipairs(commands) do
    if c[2] == "uosc_staff_credits" and c[3] == "staff-credits-search" then fwd = c end
end
check("call-forwards-native-message",
    fwd ~= nil and fwd[4] == "示例", fwd and table.concat(fwd, "|") or "none")
local p9 = last_reply()
check("call-dispatch-ok", p9 and p9.ok == true
    and p9.dispatched == "staff-credits-search" and p9.async == true)
clear()
messages["api"]("client", "r10", "call", "api")
check("call-rejects-recursive", last_reply().error == "action_not_allowed")
clear()
messages["api"]("client", "r11", "call")
check("call-requires-name", last_reply().error == "bad_action_name")

-- ⑥ 状态变化后 publish 反映新值
fake_state.loading_state.loading = false
fake_state.search_state.last_search_query = "新关键词"
api.publish(ctx)
local published = encoded_by_json[props["user-data/uosc_staff_credits/state"]]
check("publish-refreshes-on-change", published ~= nil
    and published.loading == false and published.last_search_query == "新关键词")

-- ⑦ 容错：缺依赖时不抛错
local ok_empty = pcall(api.build_state, {})
check("build-tolerates-empty-ctx", ok_empty)

print(string.format("SUMMARY external-api-test pass=%d fail=%d %s", pass, fail,
    fail == 0 and "ALL_OK" or "HAS_FAIL"))
os.exit(fail == 0 and 0 or 1)
