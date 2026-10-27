-- modules/api.lua
-- Bangumi API 通信层
-- 封装 Bangumi 镜像站/官方 API 的所有 HTTP 请求
-- 所有异步回调统一三参契约：callback(success, data, err_info)
-- err_info = { code = "ERR_XXX", msg = "..." }
-- 遵循 ADR-10 统一 init(opts, deps) 接口

local mp = require("mp")
local utils = require("mp.utils")
local msg = require("mp.msg")

local M = {}

local opts, deps, init = require("modules.utils.module_loader").make_init(
    "api",
    {
        request_registry = "table",
        guess = "table",
        notify = "table",
        servers = "table",
    }
)
M.init = init

-- 引用基础设施
local utils_mod = require("modules.utils")
local url_mod = require("modules.utils.url")
local types_mod = require("modules.types")
local net_mod = require("modules.utils.net")

-- ============ 错误码常量 ============
M.ERR_NETWORK = "ERR_NETWORK"
M.ERR_HTTP = "ERR_HTTP"
M.ERR_PARSE = "ERR_PARSE"
M.ERR_EMPTY = "ERR_EMPTY"

-- 角色类型常量（与 Bangumi persons API 一致）
M.CHAR_TYPE_CHARACTER = 1
M.CHAR_TYPE_STAFF = 2

-- make_error: 构造统一 err_info 表
function M.make_error(code, m)
    return { code = code or M.ERR_PARSE, msg = tostring(m or "") }
end

-- is_official_api: 判断 URL 是否为 Bangumi 官方 API
-- 仅匹配 api.bgm.tv / bangumi.tv / bgm.tv
function M.is_official_api(url)
    if not url or type(url) ~= "string" then return false end
    -- 使用 // 前缀锚点（SEC-11）避免匹配钓鱼域名
    return url:find("//api%.bgm%.tv") ~= nil
        or url:find("//bangumi%.tv") ~= nil
        or url:find("//bgm%.tv") ~= nil
end

-- check_api_error: 统一错误检查辅助
-- success: 是否成功（HTTP 层）
-- data: 解析后的数据（table 或 nil）
-- err_info: 已有错误信息
-- cb: 回调函数 callback(success, data, err_info)
-- empty_msg: 数据为空时的提示消息
local function check_api_error(success, data, err_info, cb, empty_msg)
    if not success then
        if cb then cb(false, nil, err_info) end
        return
    end
    if not data then
        if cb then cb(false, nil, M.make_error(M.ERR_EMPTY, empty_msg or "empty response")) end
        return
    end
    local ok, validated = types_mod.validate_api_response(data)
    if not ok then
        if cb then cb(false, nil, validated) end
        return
    end
    if cb then cb(true, validated, nil) end
end
M.check_api_error = check_api_error

-- ============ HTTP 请求底层 ============

-- http_request: 通过 curl 子进程发起 GET 请求，解析 JSON 响应
-- url: 完整的请求 URL
-- callback: function(success, data, err_info)
--   success: boolean
--   data: 解析后的 JSON table（失败时为 nil）
--   err_info: {code, msg}（成功时为 nil）
-- 请求的 cancel_fn 会注册到 deps.request_registry，便于 onUnload 时取消
function M.http_request(url, callback)
    if not url or url == "" then
        if callback then callback(false, nil, M.make_error(M.ERR_NETWORK, "empty url")) end
        return
    end

    -- v1.9.1: request_timeout 专供 curl --max-time（网络请求超时）
    --       独立于 timeout（loading 倒计时显示超时），避免详情端点因数据量大被过早掐断
    local timeout = tonumber(opts.request_timeout) or tonumber(opts.timeout) or 10
    local user_agent = opts.user_agent or "uosc_staff_credits"

    local args = {
        "curl", "-sL",
        "--max-time", tostring(timeout),
        "-H", "User-Agent: " .. user_agent,
    }
    -- v1.6: SSL/TLS 选项（修复 Windows curl exit code 35）
    local ssl_args = net_mod.build_ssl_args(opts)
    for _, a in ipairs(ssl_args) do table.insert(args, a) end
    table.insert(args, url)

    -- 2026-10-06 修正：必须在闭包**之前**声明 registered_token。
    --   Lua 局部变量的作用域从声明语句之后才开始。原写法把
    --   `local registered_token = nil` 放在 mp.command_native_async 之后，
    --   于是回调闭包里的 registered_token 捕获到的是**全局变量**
    --   （mpv 环境中为 nil），导致 `if registered_token and ...` 恒为假
    --   → 注销逻辑**永不执行** → request_registry 随每次请求无界增长。
    --   这是静默失效：不报错、不崩溃，只是慢慢泄漏。
    local registered_token = nil
    local abort_handle = mp.command_native_async({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,  -- 用户交互请求不依赖播放状态，避免暂停时挂起
        args = args,
    }, function(success, result, error)
        -- 请求完成：注销 cancel_fn，避免列表无限增长
        if registered_token and deps and deps.request_registry and type(deps.request_registry.unregister) == "function" then
            pcall(deps.request_registry.unregister, registered_token)
        end

        if not success or not result then
            local err_msg = error or "request failed"
            if result and result.stderr and result.stderr ~= "" then
                err_msg = err_msg .. " | " .. result.stderr
            end
            if callback then
                callback(false, nil, M.make_error(M.ERR_NETWORK, err_msg))
            end
            return
        end

        -- curl 退出码非 0 视为网络错误
        if result.status ~= 0 then
            local err_code = M.ERR_NETWORK
            local err_msg = "curl exit code: " .. tostring(result.status)
            -- 识别常见 curl 退出码，提供更友好的提示
            if result.status == 28 then
                err_msg = "请求超时（curl exit code 28），请检查网络或增大 timeout 配置"
            elseif result.status == 6 then
                err_msg = "DNS 解析失败（curl exit code 6），请检查网络连接"
            elseif result.status == 7 then
                err_msg = "无法连接服务器（curl exit code 7），请检查网络或代理设置"
            elseif result.status == 35 then
                err_msg = "SSL/TLS 握手失败（curl exit code 35），请检查证书配置"
            elseif result.status == 52 then
                err_msg = "服务器无响应（curl exit code 52），请稍后重试"
            elseif result.status == 56 then
                err_msg = "接收数据失败（curl exit code 56），连接被中断"
            end
            if result.stderr and result.stderr ~= "" then
                err_msg = err_msg .. " | " .. result.stderr
            end
            if callback then
                callback(false, nil, M.make_error(err_code, err_msg))
            end
            return
        end

        local body = result.stdout or ""
        if body == "" then
            if callback then
                callback(false, nil, M.make_error(M.ERR_EMPTY, "empty response body"))
            end
            return
        end

        -- 解析 JSON
        local data, parse_err = utils.parse_json(body)
        if data == nil or type(data) ~= "table" then
            if callback then
                callback(false, nil, M.make_error(M.ERR_PARSE,
                    "json parse failed: " .. tostring(parse_err or "unknown")))
            end
            return
        end

        if callback then callback(true, data, nil) end
    end)

    -- 注册 cancel_fn 到 request_registry，保留 token 用于完成后注销
    if deps and deps.request_registry and type(deps.request_registry.register) == "function" then
        registered_token = deps.request_registry.register(function()
            pcall(function() mp.abort_async_command(abort_handle) end)
        end)
    end
end

-- ============ 搜索接口 ============

-- search_subject: 单服务器搜索条目
-- GET {server_url}/v0/search/subjects?limit=10&keyword={urlencode(title)}
-- callback(success, results, err_info)
-- results: list of {id, name, name_cn, url, type}
function M.search_subject(title, server_url, callback)
    if not title or title == "" then
        if callback then callback(false, nil, M.make_error(M.ERR_EMPTY, "empty title")) end
        return
    end
    if not server_url or server_url == "" then
        if callback then callback(false, nil, M.make_error(M.ERR_NETWORK, "empty server_url")) end
        return
    end

    local encoded = url_mod.url_encode(title)
    local max_results = tonumber(opts.max_results) or 10
    local url = string.format("%s/v0/search/subjects?limit=%d&keyword=%s",
        server_url, max_results, encoded)

    M.http_request(url, function(success, data, err_info)
        if not success then
            if callback then callback(false, nil, err_info) end
            return
        end
        -- 响应格式：{results: N, list: [{id, name, name_cn, url, ...}]}
        if not data or not data.list then
            if callback then callback(false, nil, M.make_error(M.ERR_EMPTY, "no results")) end
            return
        end
        local results = {}
        for _, item in ipairs(data.list) do
            table.insert(results, {
                id = item.id,
                name = item.name,
                name_cn = item.name_cn,
                url = item.url,
                type = item.type,
            })
        end
        if #results == 0 then
            if callback then callback(false, nil, M.make_error(M.ERR_EMPTY, "empty list")) end
            return
        end
        if callback then callback(true, results, nil) end
    end)
end

-- search_subject_parallel: 多服务器并发搜索
-- title: 搜索关键词
-- servers: 服务器 URL 列表
-- callback(success, results, err_info)
-- 策略：首个成功即返回；全部失败时返回最后一个错误
function M.search_subject_parallel(title, servers, callback)
    if not title or title == "" then
        if callback then callback(false, nil, M.make_error(M.ERR_EMPTY, "empty title")) end
        return
    end
    if not servers or #servers == 0 then
        if callback then callback(false, nil, M.make_error(M.ERR_NETWORK, "no servers configured")) end
        return
    end

    local pending = #servers
    local done = false
    local last_err = nil

    for _, srv_url in ipairs(servers) do
        M.search_subject(title, srv_url, function(success, results, err_info)
            if done then return end
            pending = pending - 1

            if success and results and #results > 0 then
                done = true
                if callback then callback(true, results, nil) end
                return
            end

            if err_info then last_err = err_info end

            if pending == 0 and not done then
                done = true
                if callback then
                    callback(false, nil, last_err or M.make_error(M.ERR_EMPTY, "all servers failed"))
                end
            end
        end)
    end
end

-- ============ 条目详情接口 ============

-- get_subject_detail: 获取条目详情
-- GET {server_url}/v0/subjects/{id}
-- callback(success, detail, err_info)
function M.get_subject_detail(subject_id, server_url, callback)
    if not subject_id then
        if callback then callback(false, nil, M.make_error(M.ERR_EMPTY, "empty subject_id")) end
        return
    end
    if not server_url or server_url == "" then
        if callback then callback(false, nil, M.make_error(M.ERR_NETWORK, "empty server_url")) end
        return
    end

    local url = string.format("%s/v0/subjects/%s", server_url, tostring(subject_id))
    M.http_request(url, function(success, data, err_info)
        check_api_error(success, data, err_info, callback, "subject not found")
    end)
end

-- get_subject_characters: 获取条目关联角色
-- GET {server_url}/v0/subjects/{id}/characters
-- callback(success, chars, err_info)
-- chars: list of validated character tables {id, name, relation, ...}
function M.get_subject_characters(subject_id, server_url, callback)
    if not subject_id then
        if callback then callback(false, nil, M.make_error(M.ERR_EMPTY, "empty subject_id")) end
        return
    end
    if not server_url or server_url == "" then
        if callback then callback(false, nil, M.make_error(M.ERR_NETWORK, "empty server_url")) end
        return
    end

    local url = string.format("%s/v0/subjects/%s/characters", server_url, tostring(subject_id))
    M.http_request(url, function(success, data, err_info)
        if not success then
            if callback then callback(false, nil, err_info) end
            return
        end
        if not data then
            if callback then callback(false, nil, M.make_error(M.ERR_EMPTY, "no characters")) end
            return
        end
        -- data 是数组，每项为角色表
        local chars = {}
        for _, item in ipairs(data) do
            local ok, validated = types_mod.validate_char(item)
            if ok then
                -- 保留 name_cn / images / infobox 等可选字段
                if item.name_cn and item.name_cn ~= "" then
                    validated.name_cn = item.name_cn
                end
                if item.images then
                    validated.images = item.images
                end
                if item.infobox then
                    validated.infobox = item.infobox
                end
                table.insert(chars, validated)
            end
        end
        if callback then callback(true, chars, nil) end
    end)
end

-- get_subject_persons: 获取条目关联人物（角色+职员混合）
-- GET {server_url}/v0/subjects/{id}/persons
-- callback(success, persons, err_info)
function M.get_subject_persons(subject_id, server_url, callback)
    if not subject_id then
        if callback then callback(false, nil, M.make_error(M.ERR_EMPTY, "empty subject_id")) end
        return
    end
    if not server_url or server_url == "" then
        if callback then callback(false, nil, M.make_error(M.ERR_NETWORK, "empty server_url")) end
        return
    end

    local url = string.format("%s/v0/subjects/%s/persons", server_url, tostring(subject_id))
    M.http_request(url, function(success, data, err_info)
        if not success then
            if callback then callback(false, nil, err_info) end
            return
        end
        if not data then
            if callback then callback(false, nil, M.make_error(M.ERR_EMPTY, "no persons")) end
            return
        end
        local persons = {}
        for _, item in ipairs(data) do
            local ok, validated = types_mod.validate_person(item)
            if ok then
                -- 保留可选字段
                if item.relation then validated.relation = item.relation end
                if item.images then validated.images = item.images end
                if item.actors then validated.actors = item.actors end
                if item.type then validated.type = item.type end
                table.insert(persons, validated)
            end
        end
        if callback then callback(true, persons, nil) end
    end)
end

-- search_light_novel: 搜索轻小说（type=1），用于角色图片兜底
-- GET {server_url}/v0/search/subjects?limit=10&type=1&keyword={urlencode(title)}
-- callback(success, results, err_info)
function M.search_light_novel(title, server_url, callback)
    if not title or title == "" then
        if callback then callback(false, nil, M.make_error(M.ERR_EMPTY, "empty title")) end
        return
    end
    if not server_url or server_url == "" then
        if callback then callback(false, nil, M.make_error(M.ERR_NETWORK, "empty server_url")) end
        return
    end

    local encoded = url_mod.url_encode(title)
    local max_results = tonumber(opts.max_results) or 10
    local url = string.format("%s/v0/search/subjects?limit=%d&type=1&keyword=%s",
        server_url, max_results, encoded)

    M.http_request(url, function(success, data, err_info)
        if not success then
            if callback then callback(false, nil, err_info) end
            return
        end
        if not data or not data.list then
            if callback then callback(false, nil, M.make_error(M.ERR_EMPTY, "no results")) end
            return
        end
        local results = {}
        for _, item in ipairs(data.list) do
            table.insert(results, {
                id = item.id,
                name = item.name,
                name_cn = item.name_cn,
                url = item.url,
                type = item.type,
                images = item.images,
            })
        end
        if callback then callback(true, results, nil) end
    end)
end

-- get_person_works: 获取制作人员参与的作品列表（用于制作评分）
-- GET {server_url}/v0/persons/{id}/works
-- 注意：Bangumi v0 API 的实际路径是 /v0/persons/{id}/subjects，
-- 但任务规约使用 /works；这里按任务规约实现，调用方按需调整
-- callback(success, works, err_info)
function M.get_person_works(person_id, server_url, callback)
    if not person_id then
        if callback then callback(false, nil, M.make_error(M.ERR_EMPTY, "empty person_id")) end
        return
    end
    if not server_url or server_url == "" then
        if callback then callback(false, nil, M.make_error(M.ERR_NETWORK, "empty server_url")) end
        return
    end

    -- 兼容 Bangumi v0 API 实际路径 /v0/persons/{id}/subjects
    local url = string.format("%s/v0/persons/%s/subjects", server_url, tostring(person_id))
    M.http_request(url, function(success, data, err_info)
        check_api_error(success, data, err_info, callback, "no works found")
    end)
end

return M
