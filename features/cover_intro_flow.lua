-- features/cover_intro_flow.lua
-- 封面简介 feature：获取条目详情并展示封面+简介面板
-- 遵循 DESIGN.md 第 7.3 节：通过 run_subject_pipeline 复用通用管线
-- 含 30 分钟 TTL 的 cover_intro_cache（按标题缓存）
-- 使用 make_feature_init（无 opts，配置经 deps.opts 传递）

local mp = require("mp")

local M = {}

local deps, init = require("modules.utils.module_loader").make_feature_init(
    "cover_intro_flow",
    {
        notify = "table",
        state = "table",
        menu = "table",
        api = "table",
        cover_intro = "table",
        cards = "table",
        production_score = "table",
        name_resolver = "table",
        loading_controller = "table",
        request_registry = "table",
        search_pipeline = "table",
        get_danmaku_info = "function",
        get_current_title = "function",
        opts = "table",
        anilist = "table",
        mal = "table",
        baike = "table",
        data_cache = "table",
    }
)
M.init = init

-- ============ 内部辅助 ============

-- 默认封面缓存 TTL（30 分钟）
local DEFAULT_CACHE_TTL = 1800

local function get_cache_ttl()
    if deps.opts and deps.opts.COVER_INTRO_CACHE_TTL then
        return tonumber(deps.opts.COVER_INTRO_CACHE_TTL) or DEFAULT_CACHE_TTL
    end
    return DEFAULT_CACHE_TTL
end

-- 从 subject.url 提取服务器 origin
local function server_from_url(url)
    if type(url) ~= "string" or url == "" then return nil end
    return url:match("^(https?://[^/]+)")
end

-- 解析可用 bangumi 服务器 URL
local function resolve_server(subject)
    if deps.servers and type(deps.servers.get_active_bangumi_servers) == "function" then
        local servers = deps.servers.get_active_bangumi_servers() or {}
        if servers[1] then return servers[1] end
    end
    if subject and subject.url then
        local s = server_from_url(subject.url)
        if s then return s end
    end
    if deps.opts and deps.opts.api_base_url then
        return deps.opts.api_base_url
    end
    return "https://api.bgm.tv"
end

-- 从 subject/cached 表中提取有效标题（name_cn/name），无有效标题时返回 fallback
-- 用于 on_cached_hit / on_search_success：外层已通过 resolve_display_title 获取中文标题，
-- 此处仅需同步提取 subject 字段，无有效标题时用外层 title 兜底（避免重复异步调用）
local function extract_title_or(subject, fallback)
    if type(subject) == "table" then
        if type(subject.name_cn) == "string" and subject.name_cn ~= "" then
            return subject.name_cn
        elseif type(subject.name) == "string" and subject.name ~= "" then
            return subject.name
        end
    end
    return fallback
end

-- 拉取条目详情并展示封面简介
-- subject: 搜索得到的条目（含 id/url）
-- title: 展示标题
-- entry_path: 进入时路径
-- v1.6: 支持多数据源（bangumi/anilist/mal/baike）的详情接口适配
local function fetch_detail_and_show(subject, title, entry_path)
    if deps.state.search_state.current_path ~= entry_path then return end
    if not subject or not subject.id then
        if deps.notify then deps.notify.error("条目信息无效") end
        deps.loading_controller.finish()
        return
    end

    -- 根据 subject 来源选择数据接口
    -- v1.6: 支持多数据源（anilist/mal/baike）的兼容接口
    local source = subject._source or "bangumi"
    local fetch_fn, fetch_arg

    if source == "anilist" and deps.anilist
       and type(deps.anilist.get_subject_detail_compatible) == "function" then
        fetch_fn = deps.anilist.get_subject_detail_compatible
        fetch_arg = subject.id
    elseif source == "mal" and deps.mal
       and type(deps.mal.get_subject_detail_compatible) == "function" then
        fetch_fn = deps.mal.get_subject_detail_compatible
        fetch_arg = subject.id
    elseif source == "baike" and deps.baike
       and type(deps.baike.get_subject_detail_compatible) == "function" then
        fetch_fn = deps.baike.get_subject_detail_compatible
        fetch_arg = subject.id
    else
        local server_url = resolve_server(subject)
        fetch_fn = function(id, cb)
            deps.api.get_subject_detail(id, server_url, cb)
        end
        fetch_arg = subject.id
    end

    fetch_fn(fetch_arg, function(success, detail, err_info)
        if deps.state.search_state.current_path ~= entry_path then return end
        if not success or not detail then
            -- v1.6: 透传具体错误原因（网络超时/404/空数据等），便于用户诊断
            local err_msg = "获取条目详情失败"
            if type(err_info) == "table" and err_info.msg and err_info.msg ~= "" then
                err_msg = "获取条目详情失败：" .. err_info.msg
            end
            if deps.notify then deps.notify.error(err_msg) end
            deps.loading_controller.finish()
            return
        end

        -- 加载来源提示：根据 source 显示数据来源
        if deps.notify and type(deps.notify.show_click_hint) == "function" then
            local source_label = "Bangumi"
            if source == "anilist" then source_label = "AniList"
            elseif source == "mal" then source_label = "MAL"
            elseif source == "baike" then source_label = "百度百科"
            end
            pcall(deps.notify.show_click_hint, "封面简介", "从 " .. source_label .. " 加载")
        end

        -- 写入 cover_intro_cache（带 _ts 时间戳）
        if title and deps.state and type(deps.state.set_cover_intro_cache) == "function" then
            pcall(deps.state.set_cover_intro_cache, title, {
                detail = detail,
                source_name = source,
                _ts = mp.get_time(),
            })
        end

        -- v1.7: 写入本地持久化缓存
        if deps.data_cache and type(deps.data_cache.save) == "function" then
            pcall(deps.data_cache.save, entry_path, "detail", {
                detail = detail,
                source_name = source,
            })
        end

        -- 结束加载并展示封面简介
        -- v1.6: cover_intro 是独立 OSD overlay（ass-events），不是 uosc menu，
        --       必须用 finish() 主动关闭 loading menu，不能用 finish_silent()。
        --       finish_silent 依赖新 uosc menu 覆盖旧 loading menu，
        --       但 cover_intro overlay 不会覆盖 uosc menu，导致两者同时显示。
        --       顺序：先 finish() 关闭 loading menu + cancel_all（此时 cover_intro
        --       的图片下载尚未注册，不受影响），再 cover_intro.show() 打开 overlay。
        deps.loading_controller.finish()
        if deps.cover_intro and type(deps.cover_intro.show) == "function" then
            deps.cover_intro.show(deps, detail, source)
        end
    end)
end

-- ============ 公共入口 ============

-- fetch: 封面简介入口
-- v1.6: 使用统一接口 resolve_display_title 获取中文标题
--       （4 级优先级 + 中文转换，与 BGM 搜索预填逻辑一致）
function M.fetch()
    if deps.notify and deps.notify.set_tag then deps.notify.set_tag("封面简介") end
    if not deps.search_pipeline or not deps.cover_intro then
        if deps.notify then deps.notify.error("模块未初始化") end
        return
    end
    if not deps.search_pipeline.resolve_display_title then
        if deps.notify then deps.notify.error("搜索管线未就绪") end
        return
    end

    -- 记录进入时路径，防止异步回调污染
    local entry_path = mp.get_property("path")

    -- 1. 异步获取中文标题（4 级优先级 + 中文转换）
    deps.search_pipeline.resolve_display_title(function(title, season_num)
        if deps.state.search_state.current_path ~= entry_path then return end

        if not title or title == "" then
            if deps.notify then deps.notify.error("无法识别标题") end
            return
        end

        -- v1.7: 本地持久化缓存优先（命中直接展示）
        if deps.data_cache then
            local cached_detail = deps.data_cache.load(entry_path, "detail")
            if cached_detail and type(cached_detail) == "table" and cached_detail.detail then
                -- 加载来源提示：本地持久化缓存命中
                if deps.notify and type(deps.notify.show_click_hint) == "function" then
                    pcall(deps.notify.show_click_hint, "封面简介", "从本地缓存加载")
                end
                if deps.cover_intro and type(deps.cover_intro.show) == "function" then
                    deps.cover_intro.show(deps, cached_detail.detail, cached_detail.source_name or "bangumi")
                end
                if deps.notify then deps.notify.debug("封面简介命中本地缓存: %s", tostring(title)) end
                return
            end
        end

        -- 2. 缓存检查（30 分钟 TTL）
        local ttl = get_cache_ttl()
        local cache = deps.state.search_state.cover_intro_cache[title]
        if type(cache) == "table" and cache._ts
           and (mp.get_time() - cache._ts) <= ttl
           and cache.detail then
            -- 缓存命中：直接展示
            -- 加载来源提示：内存缓存命中
            if deps.notify and type(deps.notify.show_click_hint) == "function" then
                pcall(deps.notify.show_click_hint, "封面简介", "从内存缓存加载")
            end
            if deps.cover_intro and type(deps.cover_intro.show) == "function" then
                deps.cover_intro.show(deps, cache.detail, cache.source_name or "bangumi")
            end
            return
        end

        -- 3. 缓存未命中：走通用管线
        local menu_type = deps.menu and deps.menu.MENU_COVER_INTRO or "cover_intro"

        deps.search_pipeline.run_subject_pipeline({
            menu_type = menu_type,
            -- 缓存命中：用缓存的 subject 拉取详情
            -- v1.6: 用 extract_title_or 同步提取标题，无有效标题时用外层 title 兜底
            on_cached_hit = function(cached, ep)
                fetch_detail_and_show(cached, extract_title_or(cached, title), ep)
            end,
            -- 搜索函数：包装 search_subject_enhanced 以匹配管线契约
            search_fn = function(t, sn, on_progress, on_done, skip_extra)
                deps.search_pipeline.search_subject_enhanced(
                    t, sn, on_done, on_progress, skip_extra)
            end,
            -- 搜索成功：拉取详情 + 展示 + 写缓存
            on_search_success = function(subject, ep)
                fetch_detail_and_show(subject, extract_title_or(subject, title), ep)
            end,
        })
    end)
end

return M
