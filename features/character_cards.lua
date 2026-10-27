-- features/character_cards.lua
-- 角色卡片 feature：通过数据源优先级获取角色并渲染为卡片面板
-- 遵循 DESIGN.md 第 7.2/7.3 节：search_fn = fetch_characters_from_source
-- 使用 make_feature_init（无 opts）

local mp = require("mp")

local M = {}

local deps, init = require("modules.utils.module_loader").make_feature_init(
    "character_cards",
    {
        notify = "table",
        state = "table",
        menu = "table",
        search_pipeline = "table",
        cards = "table",
        name_resolver = "table",
        loading_controller = "table",
        request_registry = "table",
        data_cache = "table",
    }
)
M.init = init

-- ============ 内部辅助 ============

-- 展示角色卡片
-- characters: 角色列表
-- title: 展示标题
local function show_cards(characters, title)
    if not characters or #characters == 0 then
        if deps.notify then deps.notify.warn("未找到角色信息") end
        return
    end
    if not deps.cards or type(deps.cards.show) ~= "function" then
        if deps.notify then deps.notify.error("卡片模块未就绪") end
        return
    end
    -- cards.show 需要 cards 自身的 deps；优先用 deps.cards_deps，缺失时回退到本 feature deps
    local cards_deps = deps.cards_deps or deps
    deps.cards.show(cards_deps, characters, title)
end

-- 用缓存的条目名重新拉取角色并展示（缓存命中路径）
-- cached: 历史缓存的条目（含 name/name_cn）
-- entry_path: 进入时路径
-- v1.6: 缓存条目无有效标题时通过 resolve_cached_title 统一兜底
--       （4 级优先级 + 中文转换，与 BGM 搜索预先填入的中文标题一致流程）
local function fetch_and_show_from_cache(cached, entry_path)
    if deps.state.search_state.current_path ~= entry_path then return end

    -- 用条目名重新拉取角色并展示
    local function proceed_with_title(title)
        if deps.state.search_state.current_path ~= entry_path then return end

        -- v1.7: 本地持久化缓存优先（命中跳过网络请求）
        local cached_chars = deps.data_cache and deps.data_cache.load(entry_path, "characters")
        if cached_chars and type(cached_chars) == "table" and #cached_chars > 0 then
            -- 加载来源提示：本地缓存命中
            if deps.notify and type(deps.notify.show_click_hint) == "function" then
                pcall(deps.notify.show_click_hint, "角色介绍", "从本地缓存加载")
            end
            show_cards(cached_chars, title)
            if deps.notify then deps.notify.debug("角色介绍命中本地缓存: %s", tostring(title)) end
            return
        end

        deps.search_pipeline.fetch_characters_from_source(
            title, nil,
            function(_) end,  -- 缓存路径下不再驱动 loading UI
            function(success, characters, persons, err_info, source_name)
                if deps.state.search_state.current_path ~= entry_path then return end
                if not success then
                    if deps.notify then deps.notify.error("获取角色卡片失败") end
                    return
                end
                -- v1.7: 拉取成功后写入本地缓存
                if deps.data_cache and type(deps.data_cache.save) == "function" then
                    pcall(deps.data_cache.save, entry_path, "characters", characters or {})
                end
                -- 加载来源提示：根据 source_name 显示数据来源
                if deps.notify and type(deps.notify.show_click_hint) == "function" then
                    local src = source_name or "bangumi"
                    local source_label = "Bangumi"
                    if src == "anilist" then source_label = "AniList"
                    elseif src == "mal" then source_label = "MAL"
                    elseif src == "baike" then source_label = "百度百科"
                    end
                    pcall(deps.notify.show_click_hint, "角色介绍", "从 " .. source_label .. " 加载")
                end
                show_cards(characters, title)
            end,
            nil)
    end

    -- 缓存标题兜底统一入口：cached.name_cn → cached.name → resolve_display_title → media-title
    deps.search_pipeline.resolve_cached_title(cached, entry_path, function(title)
        if deps.state.search_state.current_path ~= entry_path then return end
        proceed_with_title(title)
    end)
end

-- ============ 公共入口 ============

-- fetch: 角色卡片入口
function M.fetch()
    if deps.notify and deps.notify.set_tag then deps.notify.set_tag("角色介绍") end
    if not deps.search_pipeline or not deps.cards then
        if deps.notify then deps.notify.error("模块未初始化") end
        return
    end

    local menu_type = deps.menu and deps.menu.MENU_CHARACTERS or "characters"

    -- 捕获搜索使用的标题（已过中文转换），供 on_search_success 复用
    -- 避免搜索成功后再次丢失标题（data 中无 subject 字段）
    local search_title_used = nil

    deps.search_pipeline.run_subject_pipeline({
        menu_type = menu_type,
        -- 缓存命中：用条目名重新拉取角色
        on_cached_hit = function(cached, entry_path)
            fetch_and_show_from_cache(cached, entry_path)
        end,
        -- 搜索函数：fetch_characters_from_source 已匹配管线契约
        -- (title, season_num, on_progress, callback, skip_extra)
        -- 需将其 5 参回调适配为 on_done 的 3 参契约
        search_fn = function(title, season_num, on_progress, on_done, skip_extra)
            search_title_used = title  -- 捕获已过中文转换的标题
            deps.search_pipeline.fetch_characters_from_source(
                title, season_num, on_progress,
                function(success, characters, persons, err_info, source_name)
                    local data = nil
                    if success then
                        data = {
                            characters = characters,
                            persons = persons,
                            source_name = source_name,
                            -- 携带搜索使用的标题，供 on_search_success 使用
                            title = title,
                        }
                    end
                    on_done(success, data, err_info)
                end,
                skip_extra)
        end,
        -- 搜索成功：展示角色卡片
        on_search_success = function(data, entry_path)
            if deps.state.search_state.current_path ~= entry_path then return end
            if type(data) ~= "table" then return end
            -- 标题优先级：data.title（搜索时传入，已过中文转换）
            --            → search_title_used（闭包捕获）
            --            → media-title 兜底
            local title = data.title or search_title_used
            if not title or title == "" then
                title = mp.get_property("media-title") or "未知条目"
            end
            show_cards(data.characters, title)
        end,
    })
end

return M
