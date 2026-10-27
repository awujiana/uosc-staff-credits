-- features/production_score_flow.lua
-- 制作评分 feature：两阶段流程（搜索 → 制作人员评分）
-- 遵循 DESIGN.md 第 9.4 节：transition_phase 保持 loading=true 支撑下一阶段倒计时
-- 阶段 1：run_subject_pipeline 获取 subject_id
-- 阶段 2：get_subject_persons → 分类 9 组 → 每人 get_person_works → 计算评分
-- 使用 make_feature_init（无 opts）

local mp = require("mp")

local M = {}

local deps, init = require("modules.utils.module_loader").make_feature_init(
    "production_score_flow",
    {
        notify = "table",
        state = "table",
        menu = "table",
        api = "table",
        production_score = "table",
        name_resolver = "table",
        loading_controller = "table",
        request_registry = "table",
        search_pipeline = "table",
        anilist = "table",
        mal = "table",
        baike = "table",
        data_cache = "table",
    }
)
M.init = init

-- ============ 9 个制作组定义 ============

-- 组名 → 关键词列表（用于匹配 Bangumi person.relation）
local GROUP_DEFS = {
    { name = "动画制作",     keys = { "动画制作", "アニメーション制作", "Animation Work" } },
    { name = "系列构成",     keys = { "系列构成", "シリーズ構成" } },
    { name = "脚本",         keys = { "脚本", "脚本协力" } },
    { name = "监督",         keys = { "监督", "总监督", "シリーズ監督", "監督" } },
    { name = "人物设定",     keys = { "人物设定", "キャラクターデザイン", "角色设计" } },
    { name = "总作画监督",   keys = { "总作画监督", "チーフアニメーター", "総作画監督" } },
    { name = "音乐",         keys = { "音乐", "音楽" } },
    { name = "美术监督",     keys = { "美术监督", "美術監督" } },
    { name = "摄影监督",     keys = { "摄影监督", "撮影監督" } },
}

-- 组顺序（用于展示）
local GROUP_ORDER = {
    "动画制作", "系列构成", "脚本", "监督", "人物设定",
    "总作画监督", "音乐", "美术监督", "摄影监督",
}

-- ============ 内部辅助 ============

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
    return "https://api.bgm.tv"
end

-- classify_persons: 将 persons 按 relation 分类到 9 组
-- 返回 { [组名] = {person, ...} }
local function classify_persons(persons)
    local groups = {}
    for _, gname in ipairs(GROUP_ORDER) do
        groups[gname] = {}
    end
    if type(persons) ~= "table" then return groups end

    for _, p in ipairs(persons) do
        if type(p) == "table" and p.type ~= deps.api.CHAR_TYPE_CHARACTER then
            local rel = p.relation or ""
            for _, gdef in ipairs(GROUP_DEFS) do
                local matched = false
                for _, kw in ipairs(gdef.keys) do
                    if rel == kw or rel:find(kw, 1, true) then
                        matched = true
                        break
                    end
                end
                if matched then
                    table.insert(groups[gdef.name], p)
                    break
                end
            end
        end
    end
    return groups
end

-- calculate_score: 根据作品列表计算制作评分
-- 简化策略：作品数加权（上限 100），作品数越多评分越高
local function calculate_score(works)
    if type(works) ~= "table" then return 0 end
    local count = 0
    for _ in ipairs(works) do
        count = count + 1
    end
    -- 每部作品贡献 5 分，上限 100
    local score = count * 5
    if score > 100 then score = 100 end
    return score
end

-- run_persons_phase: 第二阶段 - 获取制作人员 + 作品 + 评分
-- subject: 搜索得到的条目
-- title: 展示标题（已过中文转换，避免缓存无有效标题时显示 "未知条目"）
-- entry_path: 进入时路径
-- menu_type: 菜单类型
local function run_persons_phase(subject, title, entry_path, menu_type)
    if deps.state.search_state.current_path ~= entry_path then return end
    if not subject or not subject.id then
        if deps.notify then deps.notify.error("条目信息无效") end
        deps.loading_controller.finish()
        return
    end

    -- 标题兜底：若传入的 title 为空，则尝试 subject 字段，最后用 "未知条目"
    local display_title = title
    if not display_title or display_title == "" then
        if type(subject.name_cn) == "string" and subject.name_cn ~= "" then
            display_title = subject.name_cn
        elseif type(subject.name) == "string" and subject.name ~= "" then
            display_title = subject.name
        else
            display_title = "未知条目"
        end
    end

    -- v1.7: 本地持久化缓存优先（命中跳过 persons + 每人 works 拉取）
    if deps.data_cache then
        local cached_score = deps.data_cache.load(entry_path, "production_score")
        if cached_score and type(cached_score) == "table" and cached_score.groups then
            -- 加载来源提示：本地缓存命中
            if deps.notify and type(deps.notify.show_click_hint) == "function" then
                pcall(deps.notify.show_click_hint, "制作评分", "从本地缓存加载")
            end
            deps.loading_controller.finish_silent()
            if deps.production_score and type(deps.production_score.show) == "function" then
                deps.production_score.show(deps, cached_score.groups, display_title)
            end
            if deps.notify then deps.notify.debug("制作评分命中本地缓存: %s", tostring(display_title)) end
            return
        end
    end

    local server_url = resolve_server(subject)

    -- 进入 persons 阶段：开启新的倒计时
    deps.loading_controller.set_loading(true)
    deps.loading_controller.show_with_countdown("正在获取制作人员...", menu_type, display_title, false)

    -- v1.6: 支持多数据源（anilist/mal/baike）的兼容接口
    -- subject._source 非 bangumi 时用对应数据源的 compatible 接口，避免 id 类型不匹配
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
        fetch_fn = function(id, cb)
            deps.api.get_subject_persons(id, server_url, cb)
        end
        fetch_arg = subject.id
    end

    fetch_fn(fetch_arg, function(success, persons, err_info)
        if deps.state.search_state.current_path ~= entry_path then return end
        if not success or not persons then
            if deps.notify then deps.notify.error("获取制作人员失败") end
            deps.loading_controller.finish()
            return
        end

        -- 分类到 9 组
        local groups = classify_persons(persons)

        -- 收集所有需查询作品的人员
        local all_persons = {}
        for _, gname in ipairs(GROUP_ORDER) do
            for _, p in ipairs(groups[gname] or {}) do
                p.group = gname
                table.insert(all_persons, p)
            end
        end

        if #all_persons == 0 then
            if deps.notify then deps.notify.warn("未找到制作人员") end
            deps.loading_controller.finish()
            return
        end

        -- 并发获取每人作品列表
        local pending = #all_persons
        for _, p in ipairs(all_persons) do
            deps.api.get_person_works(p.id, server_url, function(wok, works, werr)
                if deps.state.search_state.current_path ~= entry_path then return end
                pending = pending - 1
                if wok and type(works) == "table" then
                    p.works = works
                    p.score = calculate_score(works)
                else
                    p.works = {}
                    p.score = 0
                end
                if pending == 0 then
                    if deps.state.search_state.current_path ~= entry_path then return end
                    -- v1.7: 写入本地持久化缓存
                    if deps.data_cache and type(deps.data_cache.save) == "function" then
                        pcall(deps.data_cache.save, entry_path, "production_score", {
                            groups = groups,
                            title = display_title,
                        })
                    end
                    -- 加载来源提示：根据 source 显示数据来源
                    if deps.notify and type(deps.notify.show_click_hint) == "function" then
                        local source_label = "Bangumi"
                        if source == "anilist" then source_label = "AniList"
                        elseif source == "mal" then source_label = "MAL"
                        elseif source == "baike" then source_label = "百度百科"
                        end
                        pcall(deps.notify.show_click_hint, "制作评分", "从 " .. source_label .. " 加载")
                    end
                    deps.loading_controller.finish_silent()
                    if deps.production_score
                       and type(deps.production_score.show) == "function" then
                        deps.production_score.show(deps, groups, display_title)
                    end
                end
            end)
        end
    end)
end

-- ============ 公共入口 ============

-- fetch: 制作评分入口（两阶段）
-- v1.6: 缓存无有效标题时通过 resolve_cached_title 统一兜底
--       捕获搜索使用的标题供 on_search_success 复用
function M.fetch()
    if deps.notify and deps.notify.set_tag then deps.notify.set_tag("制作评分") end
    if not deps.search_pipeline or not deps.production_score then
        if deps.notify then deps.notify.error("模块未初始化") end
        return
    end

    local menu_type = deps.menu and deps.menu.MENU_PRODUCTION_SCORE or "production_score"

    -- 捕获搜索使用的标题（已过中文转换），供 on_search_success 复用
    local search_title_used = nil

    deps.search_pipeline.run_subject_pipeline({
        menu_type = menu_type,
        -- 搜索完成后保持 loading 进入 persons 阶段
        keep_loading_after_search = true,
        -- 缓存命中：直接进入 persons 阶段
        -- v1.6: 缓存无有效标题时通过 resolve_cached_title 统一兜底
        --       （4 级优先级 + 中文转换，与 BGM 搜索预填逻辑一致）
        on_cached_hit = function(cached, entry_path)
            deps.search_pipeline.resolve_cached_title(cached, entry_path, function(title)
                if deps.state.search_state.current_path ~= entry_path then return end
                run_persons_phase(cached, title, entry_path, menu_type)
            end)
        end,
        -- 搜索函数：包装 search_subject_enhanced
        search_fn = function(title, season_num, on_progress, on_done, skip_extra)
            search_title_used = title  -- 捕获已过中文转换的标题
            deps.search_pipeline.search_subject_enhanced(
                title, season_num, on_done, on_progress, skip_extra)
        end,
        -- 搜索成功：transition_phase 已由管线调用，进入 persons 阶段
        on_search_success = function(subject, entry_path)
            -- 标题优先级：subject.name_cn → subject.name → search_title_used → 兜底
            local title = nil
            if type(subject) == "table" then
                if type(subject.name_cn) == "string" and subject.name_cn ~= "" then
                    title = subject.name_cn
                elseif type(subject.name) == "string" and subject.name ~= "" then
                    title = subject.name
                end
            end
            if not title or title == "" then title = search_title_used end
            run_persons_phase(subject, title or "", entry_path, menu_type)
        end,
    })
end

return M
