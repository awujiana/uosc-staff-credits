-- features/staff_credits.lua
-- 职员表 feature：获取条目职员列表并展示（仅工作职员，不含角色）
-- 角色展示由 character_cards feature 负责
-- 遵循 DESIGN.md 第 7.3 节：通过 run_subject_pipeline 复用通用管线
-- 使用 make_feature_init（无 opts，配置经 deps 间接传递）

local mp = require("mp")

local M = {}

local deps, init = require("modules.utils.module_loader").make_feature_init(
    "staff_credits",
    {
        notify = "table",
        state = "table",
        menu = "table",
        api = "table",
        name_resolver = "table",
        loading_controller = "table",
        history = "table",
        request_registry = "table",
        search_pipeline = "table",
        anilist = "table",
        mal = "table",
        baike = "table",
        staff_grid = "table",
        data_cache = "table",
    }
)
M.init = init

-- ============ 内部辅助 ============

-- 从 subject.url 提取服务器 origin（如 https://api.bgm.tv）
local function server_from_url(url)
    if type(url) ~= "string" or url == "" then return nil end
    local origin = url:match("^(https?://[^/]+)")
    return origin
end

-- 获取可用的 bangumi 服务器 URL
-- 优先使用 deps.servers（若注入），否则从 subject.url 推导，最后用默认值
local function resolve_server(subject)
    if deps.servers and type(deps.servers.get_active_bangumi_servers) == "function" then
        local servers = deps.servers.get_active_bangumi_servers() or {}
        if servers[1] then return servers[1] end
    end
    if subject and subject.url then
        local s = server_from_url(subject.url)
        if s then return s end
    end
    return "https://api.bgm.tv"
end

-- 构造职员菜单展示项（仅职员，不含角色）
-- persons: get_subject_persons 返回的职员列表
local function build_staff_items(persons)
    local items = {}
    if type(persons) ~= "table" then return items end
    for _, p in ipairs(persons) do
        -- 仅纳入 type=2（职员）的项，跳过 type=1（角色）避免与角色介绍重复
        if p.type ~= deps.api.CHAR_TYPE_CHARACTER then
            local name = deps.name_resolver.resolve_person(p)
            table.insert(items, {
                kind = "staff",
                name = name,
                role = p.relation or "",
                cv = "",
                images = p.images,
            })
        end
    end
    return items
end

-- 拉取职员并展示菜单（仅职员，不拉取角色以减少请求量）
-- subject: 条目（含 id / url）
-- title: 展示标题
-- entry_path: 进入时路径（用于回调路径校验）
-- menu_type: 菜单类型标识（用于 show_with_countdown）
-- v1.6: subject._source 为其他数据源时走对应的兼容接口，避免用其 id 查 bangumi API
-- v1.7: 修复 on_progress("detail") 与 callback 同步调用导致倒计时定时器被立即杀死的 BUG
--       学习 production_score_flow 模式：keep_loading_after_search + 重新 show_with_countdown
local function fetch_and_show(subject, title, entry_path, menu_type)
    if deps.state.search_state.current_path ~= entry_path then return end
    if not subject or not subject.id then
        if deps.notify then deps.notify.error("条目信息无效") end
        deps.loading_controller.finish()
        return
    end

    -- v1.7: 本地持久化缓存优先（命中跳过网络请求）
    local cached_persons = deps.data_cache and deps.data_cache.load(entry_path, "persons")
    if cached_persons and type(cached_persons) == "table" and #cached_persons > 0 then
        local items = build_staff_items(cached_persons)
        if #items > 0 then
            -- 加载来源提示：本地缓存命中
            if deps.notify and type(deps.notify.show_click_hint) == "function" then
                pcall(deps.notify.show_click_hint, "职员表", "从本地缓存加载")
            end
            deps.loading_controller.finish_silent()
            if deps.staff_grid and type(deps.staff_grid.show) == "function" then
                deps.staff_grid.show(items, title)
            elseif deps.menu and type(deps.menu.show_characters) == "function" then
                deps.menu.show_characters(title, items)
            end
            if deps.notify then deps.notify.debug("职员表命中本地缓存: %s", tostring(title)) end
            return
        end
    end

    -- 根据 subject 来源选择数据接口
    -- v1.6: 支持多数据源（anilist/mal/baike）的兼容接口
    -- anilist/mal/baike 的 subject.id 是字符串，不能调用 bangumi 的 persons 接口
    local source = subject._source or "bangumi"
    local fetch_fn, fetch_arg

    if source == "anilist" and deps.anilist
       and type(deps.anilist.get_subject_persons_compatible) == "function" then
        fetch_fn = deps.anilist.get_subject_persons_compatible
        fetch_arg = subject.id
    elseif source == "mal" and deps.mal
       and type(deps.mal.get_subject_persons_compatible) == "function" then
        fetch_fn = deps.mal.get_subject_persons_compatible
        fetch_arg = subject.id
    elseif source == "baike" and deps.baike
       and type(deps.baike.get_subject_persons_compatible) == "function" then
        fetch_fn = deps.baike.get_subject_persons_compatible
        fetch_arg = subject.id
    else
        -- bangumi 来源（默认）→ 直接走 bangumi /persons 端点
        local server_url = resolve_server(subject)
        fetch_fn = function(id, cb)
            deps.api.get_subject_persons(id, server_url, cb)
        end
        fetch_arg = subject.id
    end

    -- v1.7: 进入职员获取阶段，开启新的倒计时（修复倒计时定时器被立即杀死的 BUG）
    -- on_done 的 transition_phase 会停止旧定时器，此处重新启动新倒计时保护 persons 请求
    deps.loading_controller.set_loading(true)
    deps.loading_controller.show_with_countdown("正在获取职员...", menu_type, title, false)

    fetch_fn(fetch_arg, function(ok, data, err)
        if deps.state.search_state.current_path ~= entry_path then return end
        if not ok then
            if deps.notify then deps.notify.error("获取职员失败") end
            deps.loading_controller.finish()
            return
        end
        -- v1.7: 拉取成功后写入本地持久化缓存
        if deps.data_cache and type(deps.data_cache.save) == "function" then
            pcall(deps.data_cache.save, entry_path, "persons", data or {})
        end
        local items = build_staff_items(data or {})
        if #items == 0 then
            if deps.notify then deps.notify.warn("未找到职员信息") end
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
            pcall(deps.notify.show_click_hint, "职员表", "从 " .. source_label .. " 加载")
        end
        -- v1.7.1: 改用 finish() 而非 finish_silent()
        -- 原因: finish_silent 不关闭 uosc 加载菜单，导致加载菜单和职员表面板同时显示
        --       finish() 会主动关闭加载菜单，再显示职员表面板
        --       persons 请求已完成，cancel_all 无副作用
        deps.loading_controller.finish()
        -- 使用 staff_grid 5列网格面板展示（替代 uosc 单列菜单）
        if deps.staff_grid and type(deps.staff_grid.show) == "function" then
            deps.staff_grid.show(items, title)
        elseif deps.menu and type(deps.menu.show_characters) == "function" then
            deps.menu.show_characters(title, items)
        end
    end)
end

-- ============ 公共入口 ============

-- fetch: 职员表入口
function M.fetch()
    if deps.notify and deps.notify.set_tag then deps.notify.set_tag("职员表") end
    if not deps.search_pipeline or not deps.menu then
        if deps.notify then deps.notify.error("模块未初始化") end
        return
    end

    local menu_type = deps.menu.MENU_CHARACTERS
    if not menu_type then menu_type = "characters" end

    -- 捕获搜索使用的标题（已过中文转换），供 on_search_success 复用
    local search_title_used = nil

    deps.search_pipeline.run_subject_pipeline({
        menu_type = menu_type,
        -- v1.7: 搜索完成后保持 loading 进入职员获取阶段（修复倒计时定时器被立即杀死的 BUG）
        keep_loading_after_search = true,
        -- 缓存命中：用缓存的 subject 直接拉取角色/职员
        -- v1.6: 缓存无有效标题时通过 resolve_cached_title 统一兜底
        --       （4 级优先级 + 中文转换，与 BGM 搜索预填逻辑一致）
        on_cached_hit = function(cached, entry_path)
            deps.search_pipeline.resolve_cached_title(cached, entry_path, function(title)
                if deps.state.search_state.current_path ~= entry_path then return end
                fetch_and_show(cached, title, entry_path, menu_type)
            end)
        end,
        -- 搜索函数：包装 search_subject_enhanced 以匹配管线契约
        -- (title, season_num, on_progress, on_done, skip_extra)
        search_fn = function(title, season_num, on_progress, on_done, skip_extra)
            search_title_used = title  -- 捕获已过中文转换的标题
            deps.search_pipeline.search_subject_enhanced(
                title, season_num, on_done, on_progress, skip_extra)
        end,
        -- 搜索成功：subject 已写入缓存，拉取角色/职员
        on_search_success = function(subject, entry_path)
            -- 标题优先级：subject.name_cn → search_title_used（已过中文转换，必为中文）
            --              → subject.name → media-title → "未知条目"
            -- v1.6: name_cn 为空时优先用 search_title_used（中文），避免回退到 subject.name（可能是日文）
            local title = nil
            if type(subject) == "table" then
                if type(subject.name_cn) == "string" and subject.name_cn ~= "" then
                    title = subject.name_cn
                end
            end
            if not title or title == "" then title = search_title_used end
            if not title or title == "" then
                if type(subject) == "table" and type(subject.name) == "string" and subject.name ~= "" then
                    title = subject.name
                end
            end
            if not title or title == "" then
                title = mp.get_property("media-title") or "未知条目"
            end
            fetch_and_show(subject, title, entry_path, menu_type)
        end,
    })
end

return M
