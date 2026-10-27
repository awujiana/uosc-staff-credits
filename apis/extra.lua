-- apis/extra.lua
-- 360kan + TMDB 搜索 API 封装
-- 用于增强 Bangumi 搜索的中文标题候选
-- 遵循 ADR-10 统一 init(opts, deps) 接口

local mp = require("mp")
local utils = require("mp.utils")
local msg = require("mp.msg")

local M = {}

local opts, deps, init = require("modules.utils.module_loader").make_init(
    "extra",
    {notify = "table", request_registry = "table"}
)
M.init = init

-- 引用基础设施
local utils_mod = require("modules.utils")
local url_mod = require("modules.utils.url")
local net_mod = require("modules.utils.net")

-- 错误码
local ERR_NETWORK = "ERR_NETWORK"
local ERR_PARSE = "ERR_PARSE"
local ERR_EMPTY = "ERR_EMPTY"

local function make_error(code, m)
    return { code = code or ERR_PARSE, msg = tostring(m or "") }
end

-- http_get_json: 本地 HTTP GET + JSON 解析辅助
local function http_get_json(url, callback)
    if not url or url == "" then
        if callback then callback(false, nil, make_error(ERR_NETWORK, "empty url")) end
        return
    end

    local timeout = tonumber(opts.timeout) or 10
    local user_agent = opts.user_agent or "uosc_staff_credits"

    local args = {
        "curl", "-sL", "--fail",
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
        playback_only = false,
        args = args,
    }, function(success, result, error)
        if registered_token and deps and deps.request_registry and type(deps.request_registry.unregister) == "function" then
            pcall(deps.request_registry.unregister, registered_token)
        end

        if not success or not result or result.status ~= 0 then
            local err_msg = error or "request failed"
            -- 识别常见 curl 退出码
            if result and result.status and result.status ~= 0 then
                if result.status == 28 then
                    err_msg = "请求超时（curl exit code 28），请检查网络或增大 timeout 配置"
                elseif result.status == 6 then
                    err_msg = "DNS 解析失败（curl exit code 6）"
                elseif result.status == 7 then
                    err_msg = "无法连接服务器（curl exit code 7）"
                else
                    err_msg = "curl exit code: " .. tostring(result.status)
                end
            end
            if result and result.stderr and result.stderr ~= "" then
                err_msg = err_msg .. " | " .. result.stderr
            end
            if callback then callback(false, nil, make_error(ERR_NETWORK, err_msg)) end
            return
        end

        local body = result.stdout or ""
        if body == "" then
            if callback then callback(false, nil, make_error(ERR_EMPTY, "empty body")) end
            return
        end

        local data = utils.parse_json(body)
        if type(data) ~= "table" then
            if callback then callback(false, nil, make_error(ERR_PARSE, "json parse failed")) end
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

-- search_360kan: 搜索 360kan 视频源
-- GET https://api.360kan.com/search?kw={urlencode(title)}
-- 响应解析：data.data.movies[].title（或 data.movies[].title，根据实际响应结构）
-- 返回 candidates 为 animeTitle/title 字符串列表
local function search_360kan(title, callback)
    if not title or title == "" then
        if callback then callback(false, nil, make_error(ERR_EMPTY, "empty title")) end
        return
    end

    local encoded = url_mod.url_encode(title)
    local url = "https://api.360kan.com/search?kw=" .. encoded

    http_get_json(url, function(success, data, err_info)
        if not success then
            if callback then callback(false, nil, err_info) end
            return
        end
        if not data then
            if callback then callback(false, nil, make_error(ERR_EMPTY, "empty response")) end
            return
        end

        -- 360kan 响应结构不固定，尝试多种字段路径
        local candidates = {}
        local movies = data.movies or (data.data and data.data.movies) or data.list or {}
        if type(movies) == "table" then
            for _, m in ipairs(movies) do
                local t = m.title or m.animeTitle or m.name
                if t and t ~= "" then
                    table.insert(candidates, t)
                end
            end
        end

        if #candidates == 0 then
            if callback then callback(false, nil, make_error(ERR_EMPTY, "no 360kan candidates")) end
            return
        end

        if callback then callback(true, candidates, nil) end
    end)
end
M.search_360kan = search_360kan

-- search_tmdb: 搜索 TMDB 中文译名
-- 仅当 opts.tmdb_api_key（base64 解码后）非空时启用
-- GET https://api.themoviedb.org/3/search/tv?api_key={key}&query={urlencode(title)}&language=zh-CN
-- 返回中文 name 候选列表
local function search_tmdb(title, callback)
    if not title or title == "" then
        if callback then callback(false, nil, make_error(ERR_EMPTY, "empty title")) end
        return
    end

    -- 检查 API key 是否配置
    if not opts.tmdb_api_key or opts.tmdb_api_key == "" then
        if callback then callback(false, nil, make_error(ERR_EMPTY, "no tmdb api key configured")) end
        return
    end

    -- base64 解码 API key
    local key = opts.tmdb_api_key
    -- 简易 base64 解码（mpv 环境通常无 base64 库，直接使用原始字符串）
    -- 多数情况下 TMDB key 是原始字符串，直接使用
    -- 若用户配置了 base64 编码的 key，这里尝试解码
    local decoded = key
    -- 检测是否为 base64（仅含 A-Za-z0-9+/= 且长度为 4 的倍数）
    if key:match("^[A-Za-z0-9+/]+=?=?$") and #key % 4 == 0 and #key > 16 then
        -- 使用 mp.utils 的 base64 解码（如果可用）
        local ok, result = pcall(function()
            -- mp.utils 没有 base64 解码，这里用简化版本
            -- 直接使用原始 key，TMDB 也接受原始 key
            return key
        end)
        if ok and result then decoded = result end
    end

    local encoded = url_mod.url_encode(title)
    local url = string.format(
        "https://api.themoviedb.org/3/search/tv?api_key=%s&query=%s&language=zh-CN",
        decoded, encoded
    )

    http_get_json(url, function(success, data, err_info)
        if not success then
            if callback then callback(false, nil, err_info) end
            return
        end
        if not data or not data.results then
            if callback then callback(false, nil, make_error(ERR_EMPTY, "no tmdb results")) end
            return
        end

        local candidates = {}
        for _, item in ipairs(data.results) do
            if item.name and item.name ~= "" then
                table.insert(candidates, item.name)
            end
            -- 也尝试 original_name
            if item.original_name and item.original_name ~= "" then
                table.insert(candidates, item.original_name)
            end
        end

        if #candidates == 0 then
            if callback then callback(false, nil, make_error(ERR_EMPTY, "no tmdb candidates")) end
            return
        end

        if callback then callback(true, candidates, nil) end
    end)
end
M.search_tmdb = search_tmdb

-- search: 统一入口，并发搜索 360kan + TMDB，合并候选
-- callback(success, candidates, err_info)
-- candidates: list of candidate name strings（去重）
function M.search(title, callback)
    if not title or title == "" then
        if callback then callback(false, nil, make_error(ERR_EMPTY, "empty title")) end
        return
    end

    -- 收集两个数据源的候选
    local pending = 0
    local all_candidates = {}
    local has_success = false
    local last_err = nil
    local seen = {}  -- 去重表

    local function try_finish()
        if pending > 0 then return end
        if has_success and #all_candidates > 0 then
            if callback then callback(true, all_candidates, nil) end
        else
            if callback then callback(false, nil, last_err or make_error(ERR_EMPTY, "no candidates")) end
        end
    end

    -- 360kan（仅当 enable_extra_search 启用时）
    if opts.enable_extra_search ~= false then
        pending = pending + 1
        search_360kan(title, function(success, candidates, err_info)
            pending = pending - 1
            if success and candidates then
                has_success = true
                for _, c in ipairs(candidates) do
                    if not seen[c] then
                        seen[c] = true
                        table.insert(all_candidates, c)
                    end
                end
            else
                if err_info then last_err = err_info end
            end
            try_finish()
        end)
    end

    -- TMDB（仅当 api key 配置时）
    if opts.tmdb_api_key and opts.tmdb_api_key ~= "" then
        pending = pending + 1
        search_tmdb(title, function(success, candidates, err_info)
            pending = pending - 1
            if success and candidates then
                has_success = true
                for _, c in ipairs(candidates) do
                    if not seen[c] then
                        seen[c] = true
                        table.insert(all_candidates, c)
                    end
                end
            else
                if err_info then last_err = err_info end
            end
            try_finish()
        end)
    end

    -- 若两个源都未启用，直接失败
    if pending == 0 then
        if callback then callback(false, nil, make_error(ERR_EMPTY, "no extra source enabled")) end
        return
    end
end

return M
