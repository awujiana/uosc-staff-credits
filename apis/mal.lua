-- apis/mal.lua
-- MyAnimeList API v2 封装
-- 接口：https://api.myanimelist.net/v2
-- 认证：需要 Client ID（免费申请 https://myanimelist.net/apiconfig）
--       在 script-opts/uosc_staff_credits.conf 中配置 mal_client_id
-- 特点：国际权威评分、rank、popularity、synopsis、图片、staff、characters
-- 限制：未配置 Client ID 时模块不可用（init 检查）
-- 遵循 ADR-10 统一 init(opts, deps) 接口

local mp = require("mp")
local utils = require("mp.utils")
local msg = require("mp.msg")

local M = {}

local opts, deps, init = require("modules.utils.module_loader").make_init(
    "mal",
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
local ERR_CONFIG = "ERR_CONFIG"

local function make_error(code, m)
    return { code = code or ERR_PARSE, msg = tostring(m or "") }
end

-- is_available: 检查 MAL 是否可用（需配置 mal_client_id）
function M.is_available()
    return type(opts.mal_client_id) == "string" and opts.mal_client_id ~= ""
end

-- http_get_json: HTTP GET + JSON 解析（带 MAL Client ID 头）
local function http_get_json(url, callback)
    if not url or url == "" then
        if callback then callback(false, nil, make_error(ERR_NETWORK, "empty url")) end
        return
    end

    if not M.is_available() then
        if callback then callback(false, nil, make_error(ERR_CONFIG, "mal_client_id 未配置")) end
        return
    end

    local timeout = tonumber(opts.timeout) or 15
    local user_agent = opts.user_agent or "uosc_staff_credits"

    local args = {
        "curl", "-sL", "--fail",
        "--max-time", tostring(timeout),
        "-H", "User-Agent: " .. user_agent,
        "-H", "X-MAL-Client-ID: " .. opts.mal_client_id,
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

local API_BASE = "https://api.myanimelist.net/v2"

-- strip_html: 清洗 HTML 标签
local function strip_html(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("<br%s*/?>", "\n")
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("&amp;", "&")
    s = s:gsub("&lt;", "<")
    s = s:gsub("&gt;", ">")
    s = s:gsub("&quot;", '"')
    s = s:gsub("&#39;", "'")
    s = s:gsub("&nbsp;", " ")
    return s
end

-- parse_anime: 将 MAL anime 转换为兼容 subject 结构
local function parse_anime(anime)
    if type(anime) ~= "table" then return nil end

    local title = anime.title or ""
    local alt_titles = anime.alternative_titles or {}

    -- 中文名优先级：中文（无） → english → japanese → 原标题
    -- MAL 不提供中文译名，japanese 作为 name_cn
    local name_cn = alt_titles.ja or title
    local name = title

    -- 简介
    local summary = ""
    if anime.synopsis then
        summary = strip_html(anime.synopsis)
    end

    -- 图片
    local images = nil
    local main_picture = anime.main_picture
    if main_picture and (main_picture.large or main_picture.medium) then
        images = {
            large = main_picture.large,
            medium = main_picture.medium,
            common = main_picture.large or main_picture.medium,
        }
    end

    -- 评分：MAL score 是 0-10
    local score = nil
    if anime.mean and anime.mean > 0 then
        score = anime.mean
    end

    -- 标签：genres
    local tags = {}
    if type(anime.genres) == "table" then
        for _, g in ipairs(anime.genres) do
            if type(g) == "table" and g.name then
                table.insert(tags, g.name)
            end
        end
    end

    -- 评分详细信息
    local rating = nil
    if anime.mean then
        rating = {
            platform = "MAL",
            score = anime.mean,
            votes = anime.scoring_users or 0,
        }
    end

    return {
        id = tostring(anime.id),
        name = name,
        name_cn = name_cn,
        url = "https://myanimelist.net/anime/" .. tostring(anime.id),
        summary = summary,
        images = images,
        score = score,
        tags = tags,
        rating = rating,
        _source = "mal",
        _raw = anime,  -- 保留原始数据
    }
end

-- search: 搜索 MAL
-- GET {API_BASE}/anime?q={title}&limit=5&fields=id,title,alternative_titles,main_picture,mean,synopsis,genres
-- callback(success, results, err_info)
-- results: list of {id, name, name_cn, url, summary, images, score, tags, _source="mal"}
function M.search(title, callback)
    if not title or title == "" then
        if callback then callback(false, nil, make_error(ERR_EMPTY, "empty title")) end
        return
    end

    if not M.is_available() then
        if callback then callback(false, nil, make_error(ERR_CONFIG, "mal_client_id 未配置")) end
        return
    end

    local encoded = url_mod.url_encode(title)
    local fields = "id,title,alternative_titles,main_picture,mean,synopsis,genres,status,episodes,start_date,source,studios"
    local url = string.format(
        "%s/anime?q=%s&limit=5&fields=%s",
        API_BASE, encoded, url_mod.url_encode(fields)
    )

    http_get_json(url, function(success, data, err_info)
        if not success then
            if callback then callback(false, nil, err_info) end
            return
        end

        -- MAL 响应：{ data: [{node: {...}}, ...] }
        if not data.data or type(data.data) ~= "table" or #data.data == 0 then
            if callback then callback(false, nil, make_error(ERR_EMPTY, "no results")) end
            return
        end

        local results = {}
        for _, item in ipairs(data.data) do
            if type(item) == "table" and item.node then
                local r = parse_anime(item.node)
                if r then table.insert(results, r) end
            end
        end

        if #results == 0 then
            if callback then callback(false, nil, make_error(ERR_EMPTY, "parse failed")) end
            return
        end
        if callback then callback(true, results, nil) end
    end)
end

-- get_subject_detail_compatible: 获取条目详情（bangumi 兼容格式）
-- GET {API_BASE}/anime/{id}?fields=...
-- callback(success, detail, err_info)
function M.get_subject_detail_compatible(subject_id, callback)
    if not subject_id or subject_id == "" then
        if callback then callback(false, nil, make_error(ERR_EMPTY, "empty subject_id")) end
        return
    end

    if not M.is_available() then
        if callback then callback(false, nil, make_error(ERR_CONFIG, "mal_client_id 未配置")) end
        return
    end

    local fields = "id,title,alternative_titles,main_picture,mean,synopsis,genres,status,episodes,start_date,end_date,source,studios,opening_themes,ending_themes"
    local url = string.format("%s/anime/%s?fields=%s", API_BASE, tostring(subject_id), url_mod.url_encode(fields))

    http_get_json(url, function(success, data, err_info)
        if not success then
            if callback then callback(false, nil, err_info) end
            return
        end

        local r = parse_anime(data)
        if not r then
            if callback then callback(false, nil, make_error(ERR_PARSE, "parse failed")) end
            return
        end

        -- 构造 infobox（bangumi 兼容）
        local infobox = {}
        local function add_infobox(key, value)
            if value and value ~= "" then
                table.insert(infobox, { key = key, value = tostring(value) })
            end
        end
        add_infobox("中文名", r.name_cn)
        add_infobox("英文名", r._raw.alternative_titles and r._raw.alternative_titles.en or "")
        add_infobox("话数", r._raw.episodes and tostring(r._raw.episodes) or "")
        add_infobox("放送开始", r._raw.start_date or "")
        add_infobox("原作类型", r._raw.source or "")
        add_infobox("播放状态", r._raw.status or "")

        -- 制作公司
        if type(r._raw.studios) == "table" then
            local studio_names = {}
            for _, s in ipairs(r._raw.studios) do
                if type(s) == "table" and s.name then
                    table.insert(studio_names, s.name)
                end
            end
            if #studio_names > 0 then
                add_infobox("动画制作", table.concat(studio_names, ", "))
            end
        end

        -- 评分信息
        if r.score then
            add_infobox("MAL 评分", string.format("%.2f", r.score))
        end
        if r._raw.scoring_users then
            add_infobox("评分人数", tostring(r._raw.scoring_users))
        end
        if r._raw.rank then
            add_infobox("排名", "#" .. tostring(r._raw.rank))
        end
        if r._raw.popularity then
            add_infobox("人气", "#" .. tostring(r._raw.popularity))
        end

        r.infobox = infobox
        r.staff = {}  -- MAL anime 详情不含 staff，需调用 anime/{id}/staff
        r.characters = {}  -- 同上

        if callback then callback(true, r, nil) end
    end)
end

-- get_subject_persons_compatible: 获取职员（bangumi 兼容格式）
-- GET {API_BASE}/anime/{id}/staff?limit=50&fields=role
-- callback(success, persons, err_info)
function M.get_subject_persons_compatible(subject_id, callback)
    if not subject_id or subject_id == "" then
        if callback then callback(false, nil, make_error(ERR_EMPTY, "empty subject_id")) end
        return
    end

    if not M.is_available() then
        if callback then callback(false, nil, make_error(ERR_CONFIG, "mal_client_id 未配置")) end
        return
    end

    local url = string.format(
        "%s/anime/%s/staff?limit=50&fields=role",
        API_BASE, tostring(subject_id)
    )

    http_get_json(url, function(success, data, err_info)
        if not success then
            if callback then callback(false, nil, err_info) end
            return
        end

        local persons = {}
        if data.data and type(data.data) == "table" then
            for _, item in ipairs(data.data) do
                if type(item) == "table" and item.node then
                    local node = item.node
                    local name_obj = node.name or {}
                    table.insert(persons, {
                        id = tostring(node.id or ""),
                        name = name_obj.full or name_obj.first or "",
                        name_cn = nil,  -- MAL 人员无中文名
                        type = 2,  -- CHAR_TYPE_STAFF
                        relation = item.role or "",
                        images = nil,  -- MAL staff 端点默认不含图片
                    })
                end
            end
        end

        if callback then callback(true, persons, nil) end
    end)
end

-- get_subject_characters_compatible: 获取角色（bangumi 兼容格式）
-- GET {API_BASE}/anime/{id}/characters?limit=50
-- callback(success, characters, err_info)
function M.get_subject_characters_compatible(subject_id, callback)
    if not subject_id or subject_id == "" then
        if callback then callback(false, nil, make_error(ERR_EMPTY, "empty subject_id")) end
        return
    end

    if not M.is_available() then
        if callback then callback(false, nil, make_error(ERR_CONFIG, "mal_client_id 未配置")) end
        return
    end

    local url = string.format(
        "%s/anime/%s/characters?limit=50",
        API_BASE, tostring(subject_id)
    )

    http_get_json(url, function(success, data, err_info)
        if not success then
            if callback then callback(false, nil, err_info) end
            return
        end

        local characters = {}
        if data.data and type(data.data) == "table" then
            for _, item in ipairs(data.data) do
                if type(item) == "table" and item.node then
                    local node = item.node
                    local name_obj = node.name or ""

                    -- 声优
                    local actors = {}
                    if type(item.voice_actors) == "table" then
                        for _, va in ipairs(item.voice_actors) do
                            if type(va) == "table" and va.node then
                                local va_node = va.node
                                table.insert(actors, {
                                    id = tostring(va_node.id or ""),
                                    name = va_node.name or "",
                                    name_cn = nil,
                                    images = nil,
                                })
                            end
                        end
                    end

                    table.insert(characters, {
                        id = tostring(node.id or ""),
                        name = name_obj,
                        name_cn = nil,
                        type = 1,  -- CHAR_TYPE_CHARACTER
                        relation = item.role or "",  -- Main/Supporting
                        images = nil,
                        actors = actors,
                    })
                end
            end
        end

        if callback then callback(true, characters, nil) end
    end)
end

return M
