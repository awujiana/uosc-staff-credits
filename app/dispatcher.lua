-- app/dispatcher.lua
-- 事件分发器（表示层 → 业务层路由）
-- 遵循 ADR-09：dispatcher 仅路由，业务下沉 features
-- 遵循 DESIGN.md 第 1 节：脚本消息/按键/observer 注册集中点
-- 职责：
--   1. register_all() 注册所有脚本消息与 path observer
--   2. 路由脚本消息到对应 feature/menu 入口
--   3. path_observer 处理路径切换：清理状态 + 触发静默加载（Task 36）
--   4. 静默加载：autoplay_with_danmaku 时后台预取条目信息

local mp = require("mp")
local msg = require("mp.msg")

local M = {}

local opts, deps, init = require("modules.utils.module_loader").make_init(
    "dispatcher",
    {
        opts = "table",
        ui_base = "table",
        notify = "table",
        menu = "table",
        state = "table",
        loading_controller = "table",
        request_registry = "table",
        search_pipeline = "table",
        danmaku_link = "table",
        history = "table",
        servers = "table",
        api = "table",  -- v1.7: 静默预加载深度需要 api.get_subject_characters/persons/detail
        panel_registry = "table",
        cards = "table",
        cover_intro = "table",
        production_score = "table",
        data_cache = "table",
        runtime_config = "table",  -- v1.7: 运行时配置模块
        feature_staff_credits = "table",
        feature_character_cards = "table",
        feature_cover_intro_flow = "table",
        feature_production_score_flow = "table",
        feature_subject_select = "table",
        script_name = "string",
        get_danmaku_info = "function",
        get_current_title = "function",
        debug_log = "function",
        COVER_INTRO_CACHE_TTL = "number",
        MAX_LAST_SUBJECT_ENTRIES = "number",
    }
)
M.init = init

-- 引用基础设施
local path_mod = require("modules.utils.path")

-- ============ 内部辅助 ============

local function debug_log(...)
    if deps.debug_log then pcall(deps.debug_log, ...) end
end

-- 构造可缓存的条目信息（与 shared.lua build_subject_info 一致）
local function build_subject_info(subject)
    if type(subject) ~= "table" then return nil end
    return {
        id = subject.id,
        name = subject.name,
        name_cn = subject.name_cn,
        url = subject.url,
        _ts = mp.get_time(),
    }
end

-- ============ 静默加载（Task 36）============

-- trigger_silent_load: 路径切换后静默预取条目信息
-- 条件：
--   1. opts.autoload_with_danmaku == true
--   2. state.loading_state.loading == false（用户未主动操作）
--   3. state.search_state.last_subject_by_path[path] == nil（缓存未命中）
-- 流程：
--   - 调用统一接口 resolve_title_sync 获取基础标题（4 级优先级）
--   - 调用 resolve_chinese_title 异步转换为中文标题
--   - 调用 search_pipeline.search_subject_enhanced（skip_extra=true, subject_type=2）
--   - on_progress 为空函数（不显示任何 loading 菜单、不弹 OSD）
--   - 成功 → state.set_last_subject(path, info)，仅 notify.debug
--   - 失败 → notify.debug，完全静默
--   - 注册 cancel_fn 到 request_registry（路径切换时自动取消）
-- v1.6: 复用 search_pipeline.resolve_title_sync + resolve_chinese_title 统一标题流程
--       （独立于 uosc_danmaku，未暴露时也能通过文件名解析 + 中文转换获取中文标题）
local function trigger_silent_load(path)
    if not path or path == "" then return end

    -- 1. 条件检查
    if not opts or opts.autoload_with_danmaku ~= true then return end
    if deps.state.loading_state.loading then return end
    if deps.state.search_state.last_subject_by_path[path] ~= nil then return end

    -- 2. 调用统一接口获取基础标题（4 级优先级）
    --    独立于 uosc_danmaku：弹幕关联 → subject 缓存 → 文件名解析 → media-title 兜底
    if not deps.search_pipeline
       or type(deps.search_pipeline.resolve_title_sync) ~= "function"
       or type(deps.search_pipeline.resolve_chinese_title) ~= "function" then
        return
    end

    local base_title, season_num = deps.search_pipeline.resolve_title_sync()
    if not base_title or base_title == "" then return end

    -- 3. 取消标志（路径切换时由 request_registry.cancel_all 触发）
    local cancelled = false
    local cancel_fn = function()
        cancelled = true
    end
    if deps.request_registry and type(deps.request_registry.register) == "function" then
        deps.request_registry.register(cancel_fn)
    end

    -- 4. on_progress：空函数（静默，不显示 loading 菜单）
    local function on_progress(_message) end

    -- 5. on_done：成功写入缓存，失败仅 debug 日志
    local function on_done(success, subject, _err_info)
        if cancelled then return end
        -- 路径校验：防止快速切换时旧回调污染新状态
        if deps.state.search_state.current_path ~= path then return end
        if success and subject then
            local info = build_subject_info(subject)
            if info then
                pcall(deps.state.set_last_subject, path, info)
                -- v1.7: 写入 data_cache 缓存
                if deps.data_cache and type(deps.data_cache.save) == "function" then
                    pcall(deps.data_cache.save, path, "subject", info)
                end
                -- v1.7: 根据 silent_preload_depth 扩展预取
                -- depth: subject(默认,仅条目) / characters(+角色) / persons(+角色+职员) / all(+详情)
                local depth = (opts and opts.silent_preload_depth) or "subject"
                if depth ~= "subject" and subject.id then
                    pcall(function()
                        -- characters/persons/all 都需要 characters
                        if depth == "characters" or depth == "persons" or depth == "all" then
                            -- 仅 bangumi 源支持预取；anilist/mal/baike 接口逻辑复杂，留给用户主动点击时拉取
                            local source = subject._source or "bangumi"
                            if source == "bangumi" then
                                local server_url = (subject.url and subject.url:match("^(https?://[^/]+)")) or "https://api.bgm.tv"
                                if deps.api and type(deps.api.get_subject_characters) == "function" then
                                    pcall(deps.api.get_subject_characters, subject.id, server_url, function(cs_ok, cs_data)
                                        if cancelled then return end
                                        if deps.state.search_state.current_path ~= path then return end
                                        if cs_ok and cs_data and deps.data_cache
                                           and type(deps.data_cache.save) == "function" then
                                            pcall(deps.data_cache.save, path, "characters", cs_data)
                                        end
                                        -- depth=persons/all：继续预取 persons
                                        if (depth == "persons" or depth == "all") and cs_ok then
                                            if deps.api and type(deps.api.get_subject_persons) == "function" then
                                                pcall(deps.api.get_subject_persons, subject.id, server_url, function(ps_ok, ps_data)
                                                    if cancelled then return end
                                                    if deps.state.search_state.current_path ~= path then return end
                                                    if ps_ok and ps_data and deps.data_cache
                                                       and type(deps.data_cache.save) == "function" then
                                                        pcall(deps.data_cache.save, path, "persons", ps_data)
                                                    end
                                                    -- depth=all：继续预取 detail（流量较大）
                                                    if depth == "all" and ps_ok then
                                                        if deps.api and type(deps.api.get_subject_detail) == "function" then
                                                            pcall(deps.api.get_subject_detail, subject.id, server_url, function(ds_ok, ds_data)
                                                                if cancelled then return end
                                                                if deps.state.search_state.current_path ~= path then return end
                                                                if ds_ok and ds_data and deps.data_cache
                                                                   and type(deps.data_cache.save) == "function" then
                                                                    pcall(deps.data_cache.save, path, "detail", ds_data)
                                                                end
                                                            end)
                                                        end
                                                    end
                                                end)
                                            end
                                        end
                                    end)
                                end
                            end
                        end
                    end)
                end
                if deps.notify then
                    deps.notify.debug("静默加载成功: %s", tostring(base_title))
                end
            end
        else
            if deps.notify then
                deps.notify.debug("静默加载失败: %s", tostring(base_title))
            end
        end
    end

    -- 6. 异步转换为中文标题，转换完成后调用搜索管线
    --    uosc_danmaku 历史记录中的 animeTitle 默认已是中文，转换函数会跳过
    --    仅当从文件名解析出非中文标题时触发转换（dandanplay + TMDB）
    deps.search_pipeline.resolve_chinese_title(base_title, function(chinese_title)
        if cancelled then return end
        if deps.state.search_state.current_path ~= path then return end

        local final_title = chinese_title or base_title
        if not final_title or final_title == "" then return end

        -- 7. 调用搜索管线（skip_extra=true, subject_type=2 表示动画）
        if type(deps.search_pipeline.search_subject_enhanced) == "function" then
            pcall(deps.search_pipeline.search_subject_enhanced,
                final_title, season_num, on_done, on_progress, true, 2)
        end
    end)
end

-- ============ path_observer ============

-- path_observer: 路径切换处理（FF-4 单写者 current_path）
-- 顺序：
--   1. loading_controller.finish()
--   2. state.set_current_path(path)
--   3. panel_registry.close_all()
--   4. request_registry.cancel_all()
--   5. state.cleanup_search_cache(path, MAX_LAST_SUBJECT_ENTRIES)
--   6. state.cleanup_cover_intro_cache(COVER_INTRO_CACHE_TTL)
--   7. 触发静默加载
local function path_observer(_name, path)
    -- 1. 完成加载流程（取消进行中的请求）
    if deps.loading_controller and type(deps.loading_controller.finish) == "function" then
        pcall(deps.loading_controller.finish)
    end

    -- 2. 设置当前路径
    if deps.state and type(deps.state.set_current_path) == "function" then
        pcall(deps.state.set_current_path, path)
    end

    -- 3. 关闭所有面板
    if deps.panel_registry and type(deps.panel_registry.close_all) == "function" then
        pcall(deps.panel_registry.close_all)
    end

    -- 4. 取消所有进行中的请求
    if deps.request_registry and type(deps.request_registry.cancel_all) == "function" then
        pcall(deps.request_registry.cancel_all)
    end

    -- 5. 清理搜索缓存（超阈值时仅保留当前路径）
    if deps.state and type(deps.state.cleanup_search_cache) == "function" then
        local max_entries = deps.MAX_LAST_SUBJECT_ENTRIES or 50
        pcall(deps.state.cleanup_search_cache, path, max_entries)
    end

    -- 6. 清理过期封面缓存
    if deps.state and type(deps.state.cleanup_cover_intro_cache) == "function" then
        local ttl = deps.COVER_INTRO_CACHE_TTL or 1800
        pcall(deps.state.cleanup_cover_intro_cache, ttl)
    end

    -- 7. 触发静默加载
    pcall(trigger_silent_load, path)

    -- 8. 观看进度同步（v2.0）
    --    未配 token、或 progress_sync_mode=off（默认）时，内部直接返回，
    --    不产生任何网络请求。只有显式开了 notify/auto 才会去读进度。
    if deps.feature_progress_sync
       and type(deps.feature_progress_sync.on_file_loaded) == "function" then
        pcall(deps.feature_progress_sync.on_file_loaded, path)
    end
end

-- ============ 脚本消息处理函数 ============

-- main-menu → menu.show_main_menu()
local function handle_main_menu()
    if deps.menu and type(deps.menu.show_main_menu) == "function" then
        pcall(deps.menu.show_main_menu)
    end
end

-- staff-credits → feature_staff_credits.fetch()
local function handle_staff_credits()
    if deps.notify and type(deps.notify.show_click_hint) == "function" then
        pcall(deps.notify.show_click_hint, "职员表", "加载中...")
    end
    if deps.feature_staff_credits and type(deps.feature_staff_credits.fetch) == "function" then
        pcall(deps.feature_staff_credits.fetch)
    end
end

-- character-intro → feature_character_cards.fetch()
local function handle_character_intro()
    if deps.notify and type(deps.notify.show_click_hint) == "function" then
        pcall(deps.notify.show_click_hint, "角色介绍", "加载中...")
    end
    if deps.feature_character_cards and type(deps.feature_character_cards.fetch) == "function" then
        pcall(deps.feature_character_cards.fetch)
    end
end

-- cover-intro → feature_cover_intro_flow.fetch()
local function handle_cover_intro()
    if deps.notify and type(deps.notify.show_click_hint) == "function" then
        pcall(deps.notify.show_click_hint, "封面简介", "加载中...")
    end
    if deps.feature_cover_intro_flow and type(deps.feature_cover_intro_flow.fetch) == "function" then
        pcall(deps.feature_cover_intro_flow.fetch)
    end
end

-- staff-credits-production-score → feature_production_score_flow.fetch()
local function handle_production_score()
    if deps.notify and type(deps.notify.show_click_hint) == "function" then
        pcall(deps.notify.show_click_hint, "制作评分", "加载中...")
    end
    if deps.feature_production_score_flow and type(deps.feature_production_score_flow.fetch) == "function" then
        pcall(deps.feature_production_score_flow.fetch)
    end
end

-- staff-credits-search {source} [query]
-- 从 uosc menu 的 on_search 透传 query；query 为空时打开搜索面板
-- 按 source 分发：
--   "bangumi" → feature_subject_select
--
-- 2026-10-05：支持 `名称|class` 后缀语法（对齐 uosc_danmaku）。
--   用户在搜索框里写「无职转生|ds」表示按「电视剧」检索。
--   参考 uosc_danmaku/modules/menu.lua 的 search-anime-event 处理：
--     local name, class = query:match("^(.-)%s*|%s*(.-)%s*$")
--     if name and class then query_extra(name, class) else get_animes(query) end
--   本项目的 class → 类别过滤的映射见 CLASS_TO_SUBJECT_TYPE。
local CLASS_TO_SUBJECT_TYPE = {
    ds = 2,  -- 电视剧 → Bangumi type 2 (TV)
    dy = 3,  -- 电影   → Bangumi type 3 (剧场版)
    dm = 1,  -- 国漫   → Bangumi type 1 (TV/动画)
}
deps.CLASS_TO_SUBJECT_TYPE = CLASS_TO_SUBJECT_TYPE

local function handle_search(source, query)
    local hint_name = "BGM 搜索"
    if deps.notify and type(deps.notify.show_click_hint) == "function" then
        pcall(deps.notify.show_click_hint, hint_name, "加载中...")
    end
    source = source or "bangumi"

    -- 解析 `名称|class` 后缀（对齐 uosc_danmaku）
    local query_class = nil
    if query and query ~= "" then
        if deps.menu and type(deps.menu.parse_query_class) == "function" then
            query, query_class = deps.menu.parse_query_class(query)
        end
        if query_class and query_class ~= "" then
            -- 注意：必须用本模块的 debug_log 包装，不要判 type(deps.debug_log)。
            -- deps.debug_log 在 init contract 里声明为字符串 "function"
            -- （那是契约声明，不是真实函数），type() 永远是 "string"。
            debug_log("handle_search: query_class=%s name=%q", query_class, query)
        end
    end
    -- 解析出的类别 → Bangumi subject type（仅 bangumi 路径使用）
    local subject_type = query_class and CLASS_TO_SUBJECT_TYPE[query_class] or nil

    -- Bangumi 搜索路径
    if not deps.feature_subject_select then return end
    if not query or query == "" then
        -- 返回搜索按钮或手动触发：打开搜索面板
        if type(deps.feature_subject_select.show_bgm_search_panel) == "function" then
            pcall(deps.feature_subject_select.show_bgm_search_panel, nil, source)
        end
    else
        if type(deps.feature_subject_select.search_subject) == "function" then
            -- subject_type 为 nil 时行为与原先一致（不按类别过滤）
            local ok = pcall(deps.feature_subject_select.search_subject,
                query, source, subject_type)
            if not ok then
                -- 兼容旧签名（只接受两个参数）
                pcall(deps.feature_subject_select.search_subject, query, source)
            end
        end
    end
end

-- staff-credits-select {id} {source}
-- 按 source 分发：
--   "bangumi" → feature_subject_select.handle_bgm_select
local function handle_select(id_str, source)
    source = source or "bangumi"

    -- Bangumi 路径：id 需转换为 number
    if not deps.feature_subject_select then return end
    local id = tonumber(id_str)
    if not id then
        if deps.notify then deps.notify.warn("无效的条目 id: " .. tostring(id_str)) end
        return
    end
    if type(deps.feature_subject_select.handle_bgm_select) == "function" then
        pcall(deps.feature_subject_select.handle_bgm_select, id, source)
    end
end

-- staff-credits-loading-close
local function handle_loading_close()
    if deps.loading_controller and type(deps.loading_controller.handle_loading_close) == "function" then
        pcall(deps.loading_controller.handle_loading_close)
    end
end

-- staff-credits-menu-closed {menu_type}
local function handle_menu_closed(menu_type)
    if deps.menu and type(deps.menu.clear_visible_type) == "function" then
        pcall(deps.menu.clear_visible_type, menu_type)
    end
end

-- staff-credits-close
local function handle_close()
    if deps.panel_registry and type(deps.panel_registry.close_all) == "function" then
        pcall(deps.panel_registry.close_all)
    end
end

-- staff-credits-open-browser {url}
-- 打开外部浏览器访问 URL（仅支持 http/https）
local function handle_open_browser(url)
    if not url or url == "" then return end
    -- 严格校验 URL scheme，防止 file:// / ftp:// 等非预期协议
    if not url:match("^https?://") then
        if deps.notify then pcall(deps.notify.warn, "无效的 URL（仅支持 http/https）") end
        return
    end
    -- 平台检测：Windows / macOS / Linux 分别使用不同打开方式
    -- mp.commandv 使用 argv 传递，不走 shell，避免命令注入
    local sys = package.config:sub(1, 1)  -- "\\" 为 Windows，"/" 为类 Unix
    if sys == "\\" then
        pcall(mp.commandv, "run", "cmd", "/c", "start", "", url)
    else
        -- macOS 检测（mpv 提供的 platform 属性）
        local platform = mp.get_property("platform") or ""
        if platform == "darwin" or os.execute("uname 2>/dev/null") == "Darwin" then
            pcall(mp.commandv, "run", "open", url)
        else
            pcall(mp.commandv, "run", "xdg-open", url)
        end
    end
end

-- staff-credits-clear-cache
-- 清除当前 path 缓存：state.clear_search_state(path) + history.remove(dir)
local function handle_clear_cache()
    local path = mp.get_property("path")
    if not path then
        if deps.notify then deps.notify.warn("无当前播放路径") end
        return
    end

    -- 清除 state 缓存
    if deps.state and type(deps.state.clear_search_state) == "function" then
        pcall(deps.state.clear_search_state, path)
    end

    -- 清除 history 缓存（按目录）
    if not path_mod.is_protocol(path) then
        local ok, dir = pcall(path_mod.get_parent_directory, path)
        if ok and dir and deps.history and type(deps.history.remove) == "function" then
            pcall(deps.history.remove, dir)
        end
    end

    if deps.notify then deps.notify.info("已清除当前视频缓存") end
end

-- staff-credits-clear-all
-- state 清空 + history.clear_all()
local function handle_clear_all()
    -- 清空 state 搜索缓存
    if deps.state then
        deps.state.search_state.last_subject_by_path = {}
        deps.state.search_state.cover_intro_cache = {}
    end

    -- 清空 history
    if deps.history and type(deps.history.clear_all) == "function" then
        pcall(deps.history.clear_all)
    end

    -- 清空观看进度同步的缓存（剧集列表 + 已自动标记记录）
    if deps.feature_progress_sync
       and type(deps.feature_progress_sync.clear_cache) == "function" then
        pcall(deps.feature_progress_sync.clear_cache)
    end

    if deps.notify then deps.notify.info("已清除所有缓存") end
end

-- staff-credits-settings → menu.show_settings_menu()
local function handle_settings()
    if deps.menu and type(deps.menu.show_settings_menu) == "function" then
        pcall(deps.menu.show_settings_menu)
    end
end

-- ============ 观看进度同步（v2.0，需 bangumi_token）============

-- staff-credits-mark-watched → 把当前这一集标记为看过
local function handle_mark_watched()
    local ps = deps.feature_progress_sync
    if not ps or type(ps.mark_current_episode) ~= "function" then
        if deps.notify then deps.notify.warn("观看进度同步模块不可用") end
        return
    end
    -- 模块内部会把「缺 token / 没识别条目 / 认不出集数」分别讲清楚
    pcall(ps.mark_current_episode, nil)
end

-- staff-credits-show-progress → 读取并提示当前条目的收藏状态
local function handle_show_progress()
    local ps = deps.feature_progress_sync
    if not ps or type(ps.show_progress) ~= "function" then
        if deps.notify then deps.notify.warn("观看进度同步模块不可用") end
        return
    end
    pcall(ps.show_progress)
end

-- staff-credits-servers → menu.show_servers_menu()
local function handle_servers()
    if deps.menu and type(deps.menu.show_servers_menu) == "function" then
        pcall(deps.menu.show_servers_menu)
    end
end

-- staff-credits-servers-move {from} {to}
local function handle_servers_move(from_str, to_str)
    local from_idx = tonumber(from_str)
    local to_idx = tonumber(to_str)
    if not from_idx or not to_idx then return end
    if deps.servers and type(deps.servers.move) == "function" then
        pcall(deps.servers.move, from_idx, to_idx)
    end
    -- 刷新菜单
    if deps.menu and type(deps.menu.show_servers_menu) == "function" then
        pcall(deps.menu.show_servers_menu)
    end
end

-- staff-credits-servers-toggle {url}
local function handle_servers_toggle(url)
    if not url then return end
    if deps.servers and type(deps.servers.toggle) == "function" then
        pcall(deps.servers.toggle, url)
    end
    -- 刷新菜单
    if deps.menu and type(deps.menu.show_servers_menu) == "function" then
        pcall(deps.menu.show_servers_menu)
    end
end

-- v1.7: staff-credits-set-config {key} {value}
-- 接收两个字符串参数，根据 key 类型转换 value
-- 调用 runtime_config.save(key, value) 持久化（200ms 防抖 + 原子写入）
-- 同步更新 opts 运行时值，显示 OSD 提示并重新打开设置菜单
local function handle_set_config(key, value)
    if not key or key == "" then return end
    if not deps.runtime_config or type(deps.runtime_config.save) ~= "function" then
        if deps.notify then deps.notify.warn("运行时配置模块未就绪") end
        return
    end

    -- 根据已知 key 转换 value 类型
    local converted = value
    if key == "data_cache_days" or key == "image_cache_days" then
        converted = tonumber(value)
        if not converted then
            if deps.notify then deps.notify.warn("无效数值: " .. tostring(value)) end
            return
        end
    elseif key == "enable_data_cache" or key == "debug" then
        converted = (value == "yes" or value == "true" or value == "1")
    elseif key == "silent_preload_depth" then
        local valid = { subject = true, characters = true, persons = true, all = true }
        if not valid[value] then
            if deps.notify then deps.notify.warn("无效的预加载深度: " .. tostring(value)) end
            return
        end
        converted = value
    elseif key == "pagination_position" then
        local valid = { top = true, middle = true, bottom = true }
        if not valid[value] then
            if deps.notify then deps.notify.warn("无效的翻页位置: " .. tostring(value)) end
            return
        end
        converted = value
    end

    pcall(deps.runtime_config.save, key, converted)
    -- 同步更新 opts 运行时值（runtime_config.save 已处理持久化，但 opts 引用需手动同步）
    if type(opts) == "table" then
        opts[key] = converted
    end

    -- OSD 提示
    -- 2026-10-05 修正：notify.* 的签名是 (text, tag, duration)，**不是 printf**。
    --   原写法把 string.format 的风格直接套上去：
    --     deps.notify.info("已更新: %s = %s", tostring(key), tostring(converted))
    --   实际效果是 text=%s 模板（从未被格式化）、tag=key、duration=converted(字符串)。
    --   duration 收到字符串后，mp.osd_message 内部对其做算术 →
    --     Lua error: mp.defaults:559: attempt to perform arithmetic on local 'duration' (a string value)
    --   即：**每次保存设置都会抛错**，且 %s 原样显示。
    --   已用最小复现实测确认（字符串 duration → 报错；数字/nil → 正常）。
    --   修正：先 string.format 出最终文本，只传 text（tag/duration 走默认）。
    if deps.notify then
        deps.notify.info(string.format("已更新: %s = %s", tostring(key), tostring(converted)))
    end

    -- 重新打开设置菜单
    if deps.menu and type(deps.menu.show_settings_menu) == "function" then
        pcall(deps.menu.show_settings_menu)
    end
end

-- v1.7: staff-credits-config {key}
-- 显示指定配置项的可选值列表（委托给 menu.show_config_value_menu）
local function handle_config(key)
    if deps.menu and type(deps.menu.show_config_value_menu) == "function" then
        pcall(deps.menu.show_config_value_menu, key)
    end
end

-- ============ register_all ============

-- register_all: 注册所有脚本消息与 path observer
-- 由 bootstrap 在所有模块初始化完成后调用
function M.register_all()
    local script_name = deps.script_name or ""

    -- 1. uosc 工具栏按钮（由 menu 模块在 init 时注册）

    -- 2. 脚本消息注册（ADR-09：仅路由，业务下沉 features）
    mp.register_script_message("main-menu", handle_main_menu)
    mp.register_script_message("staff-credits", handle_staff_credits)
    mp.register_script_message("character-intro", handle_character_intro)
    mp.register_script_message("cover-intro", handle_cover_intro)
    mp.register_script_message("staff-credits-production-score", handle_production_score)
    mp.register_script_message("staff-credits-search", handle_search)
    mp.register_script_message("staff-credits-select", handle_select)
    mp.register_script_message("staff-credits-loading-close", handle_loading_close)
    mp.register_script_message("staff-credits-menu-closed", handle_menu_closed)
    mp.register_script_message("staff-credits-close", handle_close)
    mp.register_script_message("staff-credits-open-browser", handle_open_browser)
    mp.register_script_message("staff-credits-clear-cache", handle_clear_cache)
    mp.register_script_message("staff-credits-clear-all", handle_clear_all)
    mp.register_script_message("staff-credits-settings", handle_settings)
    mp.register_script_message("staff-credits-servers", handle_servers)
    mp.register_script_message("staff-credits-servers-move", handle_servers_move)
    mp.register_script_message("staff-credits-servers-toggle", handle_servers_toggle)
    -- v1.7: 运行时配置（持久化到 ~~/staff-credits-runtime-config.json）
    mp.register_script_message("staff-credits-set-config", handle_set_config)
    mp.register_script_message("staff-credits-config", handle_config)
    -- v2.0: 观看进度同步（需 bangumi_token）
    mp.register_script_message("staff-credits-mark-watched", handle_mark_watched)
    mp.register_script_message("staff-credits-show-progress", handle_show_progress)

    -- 3. path observer：路径切换处理
    mp.observe_property("path", "native", path_observer)

    msg.info("[dispatcher] registered all script messages and path observer (script_name=" .. script_name .. ")")
end

-- 暴露 path_observer 供测试用
M._path_observer = path_observer
M._trigger_silent_load = trigger_silent_load

return M
