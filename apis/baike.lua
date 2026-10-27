-- apis/baike.lua
-- 百度百科 API 封装（中文标题与简介兜底数据源）
-- 接口：https://baike.baidu.com/api/openapi/BaikeLemmaCardApi
-- 返回结构化 card 数组（中文名/导演/原作/类型等 infobox）+ desc/summary
-- 用途：作为第三个数据源，在 bangumi 失败时获取中文标题与简介
-- 限制：
--   - 不返回图片 URL（封面/角色图仍需 bangumi）
--   - 无角色列表与声优信息
--   - 无评分机制
--   - card 字段为 HTML 富文本，需清洗 <a>/<sup> 等标签
--   - 同名作品歧义较多，取首个结果作为兜底
-- 遵循 ADR-10 统一 init(opts, deps) 接口

local mp = require("mp")
local utils = require("mp.utils")
local msg = require("mp.msg")

local M = {}

local opts, deps, init = require("modules.utils.module_loader").make_init(
    "baike",
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

-- strip_html: 清洗 HTML 标签，提取纯文本
-- 百度百科 card 字段含 <a>/<sup>/<br> 等标签
local function strip_html(s)
    if type(s) ~= "string" then return "" end
    -- 移除 <a ...>text</a> 保留 text
    s = s:gsub("<[^>]+>", "")
    -- HTML 实体解码
    s = s:gsub("&amp;", "&")
    s = s:gsub("&lt;", "<")
    s = s:gsub("&gt;", ">")
    s = s:gsub("&quot;", '"')
    s = s:gsub("&#39;", "'")
    s = s:gsub("&nbsp;", " ")
    -- 移除引用锚点（如 [1][2]）
    s = s:gsub("%[%d+%]", "")
    -- 压缩空白
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", "")
    s = s:gsub("%s+$", "")
    return s
end

-- http_get_json: HTTP GET + JSON 解析
local function http_get_json(url, callback)
    if not url or url == "" then
        if callback then callback(false, nil, make_error(ERR_NETWORK, "empty url")) end
        return
    end

    local timeout = tonumber(opts.timeout) or 15
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
        if registered_token and deps and deps.request_registry
           and type(deps.request_registry.unregister) == "function" then
            pcall(deps.request_registry.unregister, registered_token)
        end

        if not success or not result or result.status ~= 0 then
            local err_msg = error or "request failed"
            if result and result.status and result.status ~= 0 then
                if result.status == 28 then
                    err_msg = "请求超时（curl exit code 28）"
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

-- get_api_base: 获取百度百科 API base URL
local function get_api_base()
    return opts.baike_api_base or "https://baike.baidu.com/api/openapi/BaikeLemmaCardApi"
end

-- parse_card: 解析 card 数组，提取结构化字段
-- 返回 { name_cn, summary, infobox: [{key, value}], staff: [{name, positions}] }
local function parse_card(data)
    if type(data) ~= "table" then return nil end

    local result = {
        name_cn = strip_html(data.title or ""),
        summary = strip_html(data.desc or data.abstract or ""),
        infobox = {},
        staff = {},
    }

    -- card 数组 → infobox
    if type(data.card) == "table" then
        for _, c in ipairs(data.card) do
            if type(c) == "table" and c.name then
                local value_str = ""
                if type(c.value) == "table" then
                    local parts = {}
                    for _, v in ipairs(c.value) do
                        table.insert(parts, strip_html(tostring(v)))
                    end
                    value_str = table.concat(parts, ", ")
                else
                    value_str = strip_html(tostring(c.value or ""))
                end
                if value_str ~= "" then
                    table.insert(result.infobox, { key = c.name, value = value_str })
                end
            end
        end
    end

    -- 从 infobox 提取制作人员（导演/原作/动画制作/脚本等）
    -- 转换为 staff 数组，positions 为字段名
    for _, item in ipairs(result.infobox) do
        local k = item.key or ""
        local label = nil
        if k:find("导演") or k:find("監督") then label = "动漫监督"
        elseif k:find("原作") and not k:find("载体") then label = "原作者"
        elseif k:find("原作载体") then label = "原作类型"
        elseif k:find("动画制作") or k:find("制作") then label = "制作"
        elseif k:find("脚本") then label = "脚本"
        elseif k:find("音乐") or k:find("音楽") then label = "音乐"
        end
        if label then
            -- value 可能是 "刘伟强、麦兆辉" 多人，按顿号/逗号分隔
            for name in item.value:gmatch("[^、,，]+") do
                name = name:gsub("^%s+", ""):gsub("%s+$", "")
                if name ~= "" then
                    table.insert(result.staff, { name = name, positions = { label } })
                end
            end
        end
    end

    return result
end

-- search: 搜索百度百科（聚合源）
-- GET {api_base}?scope=103&format=json&appid=379020&bk_key={urlencode(title)}&bk_length=600
-- callback(success, results, err_info)
-- results: list of {id, name, name_cn, url, summary, _source="baike"}
function M.search(title, callback)
    if not title or title == "" then
        if callback then callback(false, nil, make_error(ERR_EMPTY, "empty title")) end
        return
    end

    local api_base = get_api_base()
    local encoded = url_mod.url_encode(title)
    local url = string.format(
        "%s?scope=103&format=json&appid=379020&bk_key=%s&bk_length=600",
        api_base, encoded
    )

    http_get_json(url, function(success, data, err_info)
        if not success then
            if callback then callback(false, nil, err_info) end
            return
        end
        if not data then
            if callback then callback(false, nil, make_error(ERR_EMPTY, "empty response")) end
            return
        end

        -- 百度百科 API 返回单个词条，非搜索结果数组
        -- 若 key 与请求 title 完全相同或非空，视为命中
        local key = data.key or data.title or ""
        if key == "" then
            if callback then callback(false, nil, make_error(ERR_EMPTY, "no result")) end
            return
        end

        local parsed = parse_card(data)
        if not parsed then
            if callback then callback(false, nil, make_error(ERR_PARSE, "parse failed")) end
            return
        end

        -- 构造兼容的 results 数组（单元素）
        local results = {
            {
                id = tostring(data.newLemmaId or data.id or ""),
                name = key,
                name_cn = parsed.name_cn ~= "" and parsed.name_cn or key,
                url = "https://baike.baidu.com/item/" .. url_mod.url_encode(key),
                summary = parsed.summary,
                _source = "baike",
            }
        }
        if callback then callback(true, results, nil) end
    end)
end

-- get_subject_detail_compatible: 获取条目详情（bangumi 兼容格式）
-- 百度百科无独立的 detail 接口，搜索即返回完整 card，故直接复用 search
-- 返回格式与 api.get_subject_detail 兼容：{id, name, name_cn, summary, infobox, staff, ...}
-- subject_id: 百度百科 newLemmaId（字符串），若为空则用 title 字段
-- callback(success, detail, err_info)
function M.get_subject_detail_compatible(subject_id, callback)
    if not subject_id or subject_id == "" then
        if callback then callback(false, nil, make_error(ERR_EMPTY, "empty subject_id")) end
        return
    end

    -- 百度百科 newLemmaId 无法直接查详情，需要用 title 重新搜索
    -- 这里假设 subject_id 实际上是 title（由 search_pipeline 构造时传入）
    -- 或是缓存的 newLemmaId（用于后续查询时仍需用 title）
    -- 简化处理：直接用 subject_id 作为关键词重新搜索
    M.search(subject_id, function(success, results, err_info)
        if not success or not results or #results == 0 then
            if callback then callback(false, nil, err_info) end
            return
        end

        local r = results[1]
        -- 再次调用 parse_card 获取完整 infobox/staff
        -- 由于 search 已调用 parse_card，但 results 中只保留了部分字段
        -- 这里需要重新获取完整数据
        local api_base = get_api_base()
        local encoded = url_mod.url_encode(r.name)
        local url = string.format(
            "%s?scope=103&format=json&appid=379020&bk_key=%s&bk_length=600",
            api_base, encoded
        )

        http_get_json(url, function(ok, data, perr)
            if not ok or not data then
                -- 退化为 search 返回的最小信息
                local detail = {
                    id = r.id,
                    name = r.name,
                    name_cn = r.name_cn,
                    summary = r.summary or "",
                    images = nil,  -- 百度百科不提供图片
                    _source = "baike",
                }
                if callback then callback(true, detail, nil) end
                return
            end

            local parsed = parse_card(data)
            local detail = {
                id = r.id,
                name = r.name,
                name_cn = r.name_cn,
                summary = (parsed and parsed.summary) or r.summary or "",
                infobox = (parsed and parsed.infobox) or {},
                staff = (parsed and parsed.staff) or {},
                images = nil,  -- 百度百科不提供图片
                _source = "baike",
            }
            if callback then callback(true, detail, nil) end
        end)
    end)
end

-- get_subject_persons_compatible: 获取职员（bangumi 兼容格式）
-- 从 detail.staff 提取并转换为 bangumi persons 格式
-- callback(success, persons, err_info)
function M.get_subject_persons_compatible(subject_id, callback)
    if not subject_id or subject_id == "" then
        if callback then callback(false, nil, make_error(ERR_EMPTY, "empty subject_id")) end
        return
    end

    M.get_subject_detail_compatible(subject_id, function(success, detail, err_info)
        if not success then
            if callback then callback(false, nil, err_info) end
            return
        end

        local persons = {}
        if detail and type(detail.staff) == "table" then
            for _, s in ipairs(detail.staff) do
                if type(s) == "table" and s.name then
                    local relation = ""
                    if type(s.positions) == "table" and #s.positions > 0 then
                        relation = table.concat(s.positions, "、")
                    end
                    table.insert(persons, {
                        id = nil,  -- 百度百科无人员 id
                        name = s.name,
                        name_cn = nil,
                        type = 2,  -- CHAR_TYPE_STAFF
                        relation = relation,
                        images = nil,  -- 百度百科不提供图片
                    })
                end
            end
        end

        if callback then callback(true, persons, nil) end
    end)
end

return M
