-- apis/anilist.lua
-- AniList GraphQL API 封装
-- 接口：https://graphql.anilist.co
-- 特点：无需认证，GraphQL 灵活查询，数据丰富（中文标题/简介/图片/评分/staff/characters）
-- 限制：速率限制 90 请求/分钟，复杂查询受限
-- 用途：作为 bangumi 失败后的第三数据源
-- 遵循 ADR-10 统一 init(opts, deps) 接口

local mp = require("mp")
local utils = require("mp.utils")
local msg = require("mp.msg")

local M = {}

local opts, deps, init = require("modules.utils.module_loader").make_init(
    "anilist",
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

-- http_post_json: HTTP POST + JSON 解析（GraphQL 需要 POST）
local function http_post_json(url, post_body, callback)
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
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/json",
        "--data", post_body,
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

local GRAPHQL_ENDPOINT = "https://graphql.anilist.co"

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

-- graphql_query: 构造搜索查询
local function build_search_query(title)
    -- GraphQL 查询：按标题搜索，返回首个结果
    -- 支持 romaji/english/native/original 多语言标题
    local query = [[
query ($search: String) {
  Page(page: 1, perPage: 5) {
    media(type: ANIME, search: $search, sort: SEARCH_MATCH) {
      id
      idMal
      title {
        romaji
        english
        native
      }
      coverImage {
        large
        medium
      }
      bannerImage
      averageScore
      meanScore
      popularity
      episodes
      status
      season
      seasonYear
      format
      source
      genres
      description
      startDate { year month day }
      endDate { year month day }
    }
  }
}]]
    local variables = utils.format_json({ search = title })
    return utils.format_json({ query = query, variables = variables })
end

-- build_detail_query: 构造详情查询（含 staff + characters）
local function build_detail_query(anilist_id)
    local query = [[
query ($id: Int) {
  Media(id: $id, type: ANIME) {
    id
    idMal
    title {
      romaji
      english
      native
    }
    coverImage {
      large
      medium
    }
    bannerImage
    averageScore
    meanScore
    popularity
    episodes
    status
    season
    seasonYear
    format
    source
    genres
    synonyms
    description
    startDate { year month day }
    endDate { year month day }
    staff {
      edges {
        node {
          id
          name {
            full
            native
            alternative
          }
        }
        role
      }
    }
    characters {
      edges {
        role
        node {
          id
          name {
            full
            native
            alternative
          }
          image {
            large
            medium
          }
        }
        voiceActors {
          id
          name {
            full
            native
          }
          image {
            large
            medium
          }
        }
      }
    }
  }
}]]
    local variables = utils.format_json({ id = tonumber(anilist_id) or 0 })
    return utils.format_json({ query = query, variables = variables })
end

-- parse_media: 将 AniList Media 转换为兼容 subject 结构
local function parse_media(media)
    if type(media) ~= "table" then return nil end

    local title_obj = media.title or {}
    local cover = media.coverImage or {}

    -- 中文名优先级：native → english → romaji
    -- 实际 AniList 不提供中文译名，native 是日文原名
    local name = title_obj.romaji or title_obj.english or title_obj.native or ""
    local name_cn = title_obj.native or ""  -- 日文原名作为 name_cn（无中文时）

    -- 简介：AniList description 是 HTML，需清洗
    local summary = ""
    if media.description then
        summary = strip_html(media.description)
    end

    -- 图片
    local images = nil
    if cover.large or cover.medium then
        images = {
            large = cover.large,
            medium = cover.medium,
            common = cover.large or cover.medium,
        }
    end

    -- 评分：AniList averageScore 是 0-100，转换为 0-10
    local score = nil
    if media.averageScore and media.averageScore > 0 then
        score = media.averageScore / 10.0
    end

    -- 标签：genres
    local tags = {}
    if type(media.genres) == "table" then
        for _, g in ipairs(media.genres) do
            table.insert(tags, tostring(g))
        end
    end

    return {
        id = tostring(media.id),
        name = name,
        name_cn = name_cn,
        url = "https://anilist.co/anime/" .. tostring(media.id),
        summary = summary,
        images = images,
        score = score,
        tags = tags,
        _source = "anilist",
        _raw = media,  -- 保留原始数据供 detail 解析
    }
end

-- parse_staff: 从 detail Media 解析职员（bangumi 兼容格式）
local function parse_staff(media)
    local persons = {}
    if type(media.staff) ~= "table" or type(media.staff.edges) ~= "table" then
        return persons
    end
    for _, edge in ipairs(media.staff.edges) do
        if type(edge) == "table" and type(edge.node) == "table" then
            local node = edge.node
            local name_obj = node.name or {}
            table.insert(persons, {
                id = tostring(node.id or ""),
                name = name_obj.full or name_obj.native or "",
                name_cn = name_obj.native,
                type = 2,  -- CHAR_TYPE_STAFF
                relation = edge.role or "",
                images = nil,  -- AniList staff 无图片在此查询中
            })
        end
    end
    return persons
end

-- parse_characters: 从 detail Media 解析角色（bangumi 兼容格式）
local function parse_characters(media)
    local characters = {}
    if type(media.characters) ~= "table" or type(media.characters.edges) ~= "table" then
        return characters
    end
    for _, edge in ipairs(media.characters.edges) do
        if type(edge) == "table" and type(edge.node) == "table" then
            local node = edge.node
            local name_obj = node.name or {}
            local img = node.image or {}

            -- 声优
            local actors = {}
            if type(edge.voiceActors) == "table" then
                for _, va in ipairs(edge.voiceActors) do
                    if type(va) == "table" then
                        local va_name = va.name or {}
                        local va_img = va.image or {}
                        table.insert(actors, {
                            id = tostring(va.id or ""),
                            name = va_name.full or va_name.native or "",
                            name_cn = va_name.native,
                            images = (va_img.large or va_img.medium) and {
                                medium = va_img.medium,
                                large = va_img.large,
                            } or nil,
                        })
                    end
                end
            end

            table.insert(characters, {
                id = tostring(node.id or ""),
                name = name_obj.full or name_obj.native or "",
                name_cn = name_obj.native,
                type = 1,  -- CHAR_TYPE_CHARACTER
                relation = edge.role or "",  -- MAIN/SUPPORTING
                images = (img.large or img.medium) and {
                    medium = img.medium,
                    large = img.large,
                    common = img.large or img.medium,
                } or nil,
                actors = actors,
            })
        end
    end
    return characters
end

-- search: 搜索 AniList
-- callback(success, results, err_info)
-- results: list of {id, name, name_cn, url, summary, images, score, tags, _source="anilist"}
function M.search(title, callback)
    if not title or title == "" then
        if callback then callback(false, nil, make_error(ERR_EMPTY, "empty title")) end
        return
    end

    local post_body = build_search_query(title)

    http_post_json(GRAPHQL_ENDPOINT, post_body, function(success, data, err_info)
        if not success then
            if callback then callback(false, nil, err_info) end
            return
        end

        -- GraphQL 响应：{ data: { Page: { media: [...] } }, errors: [...] }
        local page = data.data and data.data.Page
        if not page or type(page.media) ~= "table" or #page.media == 0 then
            if callback then callback(false, nil, make_error(ERR_EMPTY, "no results")) end
            return
        end

        local results = {}
        for _, media in ipairs(page.media) do
            local r = parse_media(media)
            if r then table.insert(results, r) end
        end

        if #results == 0 then
            if callback then callback(false, nil, make_error(ERR_EMPTY, "parse failed")) end
            return
        end
        if callback then callback(true, results, nil) end
    end)
end

-- get_subject_detail_compatible: 获取条目详情（bangumi 兼容格式）
-- 返回格式与 api.get_subject_detail 兼容：{id, name, name_cn, summary, images, infobox, staff, ...}
-- subject_id: AniList 条目 id（字符串）
-- callback(success, detail, err_info)
function M.get_subject_detail_compatible(subject_id, callback)
    if not subject_id or subject_id == "" then
        if callback then callback(false, nil, make_error(ERR_EMPTY, "empty subject_id")) end
        return
    end

    local post_body = build_detail_query(subject_id)

    http_post_json(GRAPHQL_ENDPOINT, post_body, function(success, data, err_info)
        if not success then
            if callback then callback(false, nil, err_info) end
            return
        end

        local media = data.data and data.data.Media
        if not media then
            if callback then callback(false, nil, make_error(ERR_EMPTY, "no result")) end
            return
        end

        local r = parse_media(media)
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
        add_infobox("话数", media.episodes and tostring(media.episodes) or "")
        add_infobox("放送开始", media.startDate and media.startDate.year
            and string.format("%d-%02d-%02d",
                media.startDate.year,
                media.startDate.month or 0,
                media.startDate.day or 0) or "")
        add_infobox("原作类型", media.source or "")
        add_infobox("播放状态", media.status or "")

        -- 评分信息
        if r.score then
            add_infobox("AniList 评分", string.format("%.1f", r.score))
        end
        if media.popularity then
            add_infobox("人气", tostring(media.popularity))
        end

        r.infobox = infobox
        r.staff = parse_staff(media)
        r.characters = parse_characters(media)

        if callback then callback(true, r, nil) end
    end)
end

-- get_subject_persons_compatible: 获取职员（bangumi 兼容格式）
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
        local persons = (detail and detail.staff) or {}
        if callback then callback(true, persons, nil) end
    end)
end

-- get_subject_characters_compatible: 获取角色（bangumi 兼容格式）
-- callback(success, characters, err_info)
function M.get_subject_characters_compatible(subject_id, callback)
    if not subject_id or subject_id == "" then
        if callback then callback(false, nil, make_error(ERR_EMPTY, "empty subject_id")) end
        return
    end

    M.get_subject_detail_compatible(subject_id, function(success, detail, err_info)
        if not success then
            if callback then callback(false, nil, err_info) end
            return
        end
        local characters = (detail and detail.characters) or {}
        if callback then callback(true, characters, nil) end
    end)
end

return M
