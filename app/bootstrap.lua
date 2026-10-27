-- app/bootstrap.lua
-- 启动组合根（Composition Root）
-- 遵循 DESIGN.md 第 2 节：唯一的装配点，完成配置/模块加载/DI/事件注册
-- ADR-11：从 main.lua 迁移所有装配逻辑
--
-- 核心流程：
--   1. load_options() 合并 defaults + script-opts
--   2. safe_require 按依赖顺序加载所有模块
--   3. init_module 依次初始化（pcall 保护，关键模块失败 return false）
--   4. 注入闭包函数（format_error_message / debug_log / get_current_title / ...）
--   5. dispatcher.register_all() 注册事件
--   6. 5s 后清理过期图片缓存

local mp = require("mp")
local msg = require("mp.msg")

local M = {}

-- ============ 内部辅助 ============

-- init_module: 对普通模块调用 mod.init(opts, deps)
-- pcall 保护，关键模块失败返回 false，可选模块失败仅 warn
-- 无 init 函数的模块（如 state/panel_registry/ass_lib 等）直接跳过
local function init_module(mod, init_opts, init_deps, name, critical)
    if not mod then
        if critical then
            msg.error("[bootstrap] critical module '" .. tostring(name) .. "' not loaded")
            return false
        end
        return true
    end
    if type(mod.init) ~= "function" then
        return true
    end
    local ok, err = pcall(mod.init, init_opts, init_deps)
    if not ok then
        if critical then
            msg.error("[bootstrap] critical module '" .. tostring(name) ..
                "' init failed: " .. tostring(err))
            return false
        else
            msg.warn("[bootstrap] optional module '" .. tostring(name) ..
                "' init failed: " .. tostring(err))
        end
    end
    return true
end

-- init_feature: 对 features 层模块调用 mod.init(deps)（无 opts）
-- features 使用 make_feature_init，init 只接收 deps
local function init_feature(mod, feature_deps, name)
    if not mod then return true end
    if type(mod.init) ~= "function" then return true end
    local ok, err = pcall(mod.init, feature_deps)
    if not ok then
        msg.warn("[bootstrap] feature '" .. tostring(name) ..
            "' init failed: " .. tostring(err))
    end
    return true
end

-- ============ 主入口 ============

-- M.run: 启动组合根
-- 返回 boolean：true 表示启动成功，false 表示失败
function M.run()
    -- ====== 1. 加载配置 ======
    local defaults_mod = require("modules.defaults")
    local opts = defaults_mod.load_options()
    if not opts then
        msg.error("[bootstrap] load_options failed")
        return false
    end

    -- ====== 1.5 合并持久化的运行时配置（必须在这里，且早于任何模块 init）======
    -- 优先级：runtime_config > opts(script-opts) > defaults
    --
    -- ⚠️ 为什么非要在这一步、而不能等 runtime_config.init（步骤 18.7）：
    --   module_loader.make_init 会把 opts **浅拷贝**进每个模块自己的一张表
    --   （shallow_merge）。模块一旦 init 过，它的副本就固定了 —— 之后再改这张
    --   共享 opts 也传导不到它。所以持久化值必须在**第一次 init 之前**并进来。
    --
    --   历史缺陷（2026-10-07 修）：此前只在 runtime_config.load() 里合并它自己的
    --   私有副本，而 data_cache / cards / cover_intro 读的都是各自的副本 ——
    --   于是「改了设置、菜单显示新值、重启却回退」，与文档承诺相反。
    --   详见 docs/REVIEW_AND_MERGE.md §11.11。
    --
    -- 本步同时也让 runtime_config 的 runtime_data 就位（供菜单显示当前值）。
    do
        local ok_rc, rc = pcall(require, "modules.runtime_config")
        if ok_rc and rc and type(rc.apply_persisted) == "function" then
            local applied = rc.apply_persisted(opts)
            local n = 0
            if type(applied) == "table" then
                for _ in pairs(applied) do n = n + 1 end
            end
            if n > 0 then
                msg.verbose("[bootstrap] 已合并运行时配置项 " .. n .. " 个")
            end
        else
            -- 非致命：持久化配置读不到时照常以 script-opts/defaults 启动
            msg.warn("[bootstrap] runtime_config 不可用，跳过持久化配置合并: "
                .. tostring(rc))
        end
    end

    -- ====== 2. 获取 script_name ======
    local script_name = mp.get_script_name() or "uosc_staff_credits"

    -- ====== 3. 缓存常量 ======
    local COVER_INTRO_CACHE_TTL = defaults_mod.DEFAULT_COVER_INTRO_CACHE_TTL or 1800
    local MAX_LAST_SUBJECT_ENTRIES = defaults_mod.DEFAULT_MAX_LAST_SUBJECT_ENTRIES or 50

    -- ====== 4. 按依赖顺序加载所有模块 ======
    local module_loader = require("modules.utils.module_loader")
    local mods = {}

    -- 关键模块加载失败标志
    local critical_failed = false

    -- 辅助：safe_require 并存入 mods 表
    -- critical=true 时失败设 critical_failed=true
    local function load_mod(name, critical)
        local mod = module_loader.safe_require(name, not critical)
        mods[name] = mod
        if not mod and critical then
            msg.error("[bootstrap] critical module '" .. name .. "' failed to load")
            critical_failed = true
        end
        return mod
    end

    -- 4.1 基础设施层
    load_mod("modules.utils.path", false)
    load_mod("modules.utils.url", false)
    load_mod("modules.utils.io", false)
    load_mod("modules.utils.net", false)
    load_mod("modules.utils.image", false)
    load_mod("modules.utils.module_loader", false)
    load_mod("modules.utils", false)
    load_mod("modules.types", false)
    load_mod("modules.notify", false)
    load_mod("modules.ass_lib", false)
    load_mod("modules.defaults", false)

    -- 4.2 UI 基础
    load_mod("modules.input_service", false)
    load_mod("modules.panel_registry", false)
    load_mod("modules.ui_base", false)

    -- 4.3 数据层
    load_mod("modules.guess", false)
    load_mod("modules.name_resolver", false)
    load_mod("modules.history", false)
    load_mod("modules.servers", false)
    load_mod("modules.api", false)
    load_mod("apis.dandanplay", false)
    load_mod("apis.extra", false)
    load_mod("apis.anilist", false)
    load_mod("apis.mal", false)
    load_mod("apis.baike", false)
    load_mod("apis.bangumi_user", false)   -- v2.0: Bangumi 用户端点（需 token）
    load_mod("modules.danmaku_link", false)

    -- 4.4 业务层
    load_mod("app.state", true)             -- 关键
    load_mod("app.request_registry", true)  -- 关键
    load_mod("app.loading_controller", true)  -- 关键
    load_mod("app.search_pipeline", true)   -- 关键
    load_mod("features.shared", false)
    load_mod("features.staff_credits", false)
    load_mod("features.character_cards", false)
    load_mod("features.cover_intro_flow", false)
    load_mod("features.production_score_flow", false)
    load_mod("features.subject_select", false)
    load_mod("features.progress_sync", false)   -- v2.0: 观看进度同步（需 token）

    -- 4.5 表示层
    load_mod("modules.menu", true)          -- 关键
    load_mod("modules.cards", false)
    load_mod("modules.cover_intro", false)
    load_mod("modules.production_score", false)
    load_mod("modules.staff_grid", false)
    load_mod("modules.data_cache", false)
    load_mod("modules.runtime_config", false)  -- v1.7: 运行时配置（200ms 防抖 + 原子写入）
    load_mod("app.dispatcher", true)        -- 关键

    -- 关键模块加载失败则中止
    if critical_failed then
        msg.error("[bootstrap] critical module loading failed, aborting")
        return false
    end

    -- ====== 5. 定义闭包函数（捕获 mods 上下文）======

    -- format_error_message: 错误码转中文提示（DESIGN.md 10.4）
    local function format_error_message(err_info, default_msg)
        err_info = err_info or {}
        local code = err_info.code or ""
        if code == "ERR_NETWORK" then
            return "网络错误，请检查连接（超时或 DNS 失败）"
        elseif code == "ERR_HTTP" then
            return "服务器错误：" .. (err_info.msg or "HTTP 错误")
        elseif code == "ERR_PARSE" then
            return "响应解析失败（服务器返回非 JSON 数据）"
        elseif code == "ERR_EMPTY" then
            return err_info.msg or default_msg or "未找到匹配结果"
        end
        return err_info.msg or default_msg or "未知错误"
    end

    -- debug_log: 受 opts.debug 门控（DESIGN.md 2.4）
    local function debug_log(...)
        if not opts or not opts.debug then return end
        local nargs = select("#", ...)
        if nargs > 0 then
            local ok, formatted = pcall(string.format, ...)
            if ok then
                mp.msg.debug("[staff-credits] " .. formatted)
            else
                mp.msg.debug("[staff-credits] " .. tostring((...)))
            end
        else
            mp.msg.debug("[staff-credits] ")
        end
    end

    -- get_current_title: 调用 guess.parse_title(mp.get_property("path"))
    local function get_current_title()
        local path = mp.get_property("path")
        if not path then return nil end
        local guess_mod = mods["modules.guess"]
        if not guess_mod or type(guess_mod.parse_title) ~= "function" then
            return nil
        end
        local title, season_num = guess_mod.parse_title(path)
        return title, season_num
    end

    -- get_danmaku_info: 调用 danmaku_link.get_info()
    local function get_danmaku_info()
        local danmaku_link_mod = mods["modules.danmaku_link"]
        if not danmaku_link_mod then return nil end
        if type(danmaku_link_mod.get_info) ~= "function" then return nil end
        return danmaku_link_mod.get_info()
    end

    -- fallback_to_subject_list_search: 搜索失败回退到条目列表搜索
    local function fallback_to_subject_list_search(title, source, _danmaku_info)
        local feature_subject_select = mods["features.subject_select"]
        if not feature_subject_select then return end
        if type(feature_subject_select.show_bgm_search_panel) == "function" then
            pcall(feature_subject_select.show_bgm_search_panel, title, source)
        end
    end

    -- ====== 6. 按顺序初始化模块 ======

    -- 模块引用简写（提升可读性）
    local notify_mod = mods["modules.notify"]
    local ass_lib_mod = mods["modules.ass_lib"]
    local ui_base_mod = mods["modules.ui_base"]
    local panel_registry_mod = mods["modules.panel_registry"]
    local input_service_mod = mods["modules.input_service"]
    local utils_mod = mods["modules.utils"]
    local guess_mod = mods["modules.guess"]
    local name_resolver_mod = mods["modules.name_resolver"]
    local history_mod = mods["modules.history"]
    local servers_mod = mods["modules.servers"]
    local api_mod = mods["modules.api"]
    local dandanplay_mod = mods["apis.dandanplay"]
    local extra_mod = mods["apis.extra"]
    local anilist_mod = mods["apis.anilist"]
    local mal_mod = mods["apis.mal"]
    local baike_mod = mods["apis.baike"]
    local bangumi_user_mod = mods["apis.bangumi_user"]
    local danmaku_link_mod = mods["modules.danmaku_link"]
    local state_mod = mods["app.state"]
    local request_registry_mod = mods["app.request_registry"]
    local loading_controller_mod = mods["app.loading_controller"]
    local search_pipeline_mod = mods["app.search_pipeline"]
    local menu_mod = mods["modules.menu"]
    local cards_mod = mods["modules.cards"]
    local cover_intro_mod = mods["modules.cover_intro"]
    local production_score_mod = mods["modules.production_score"]
    local staff_grid_mod = mods["modules.staff_grid"]
    local data_cache_mod = mods["modules.data_cache"]
    local runtime_config_mod = mods["modules.runtime_config"]  -- v1.7
    local dispatcher_mod = mods["app.dispatcher"]

    -- 步骤 1: notify.init(opts)
    if not init_module(notify_mod, opts, nil, "notify", false) then return false end

    -- 步骤 2: ass_lib.init(opts)（无 deps 时传 {}；ass_lib 无 init 则跳过）
    if not init_module(ass_lib_mod, opts, {}, "ass_lib", false) then return false end

    -- 步骤 3: ui_base.init(opts, {panel_registry, ass_lib, input_service, notify})
    -- ui_base 无 init 函数，跳过（模块已 require 即可用）
    if not init_module(ui_base_mod, opts, {
        panel_registry = panel_registry_mod,
        ass_lib = ass_lib_mod,
        input_service = input_service_mod,
        notify = notify_mod,
    }, "ui_base", false) then return false end

    -- 步骤 4: guess.init(opts, {})
    if not init_module(guess_mod, opts, {}, "guess", false) then return false end

    -- 步骤 5: history.init(opts, {notify})
    if not init_module(history_mod, opts, {
        notify = notify_mod,
    }, "history", false) then return false end

    -- 步骤 6: servers.init(opts, {notify})
    if not init_module(servers_mod, opts, {
        notify = notify_mod,
    }, "servers", false) then return false end

    -- 步骤 7: api.init(opts, {request_registry, guess, notify, servers})
    if not init_module(api_mod, opts, {
        request_registry = request_registry_mod,
        guess = guess_mod,
        notify = notify_mod,
        servers = servers_mod,
    }, "api", false) then return false end

    -- 步骤 8: apis.dandanplay.init(opts, {notify, request_registry})
    if not init_module(dandanplay_mod, opts, {
        notify = notify_mod,
        request_registry = request_registry_mod,
    }, "dandanplay", false) then return false end

    -- 步骤 9: apis.extra.init(opts, {notify, request_registry})
    if not init_module(extra_mod, opts, {
        notify = notify_mod,
        request_registry = request_registry_mod,
    }, "extra", false) then return false end

    -- 步骤 10.1: apis.anilist.init(opts, {notify, request_registry})
    -- v1.6: AniList GraphQL API，无需认证，作为第三数据源
    if not init_module(anilist_mod, opts, {
        notify = notify_mod,
        request_registry = request_registry_mod,
    }, "anilist", false) then return false end

    -- 步骤 10.2: apis.mal.init(opts, {notify, request_registry})
    -- v1.6: MAL API v2，需配置 mal_client_id，未配置时模块不可用但不报错
    if not init_module(mal_mod, opts, {
        notify = notify_mod,
        request_registry = request_registry_mod,
    }, "mal", false) then return false end

    -- 步骤 10.3: apis.baike.init(opts, {notify, request_registry})
    -- v1.6: 百度百科 OpenAPI，作为中文标题与简介兜底数据源
    if not init_module(baike_mod, opts, {
        notify = notify_mod,
        request_registry = request_registry_mod,
    }, "baike", false) then return false end

    -- 步骤 10.4: apis.bangumi_user.init(opts, {notify, request_registry})
    -- v2.0: Bangumi 用户端点（读写收藏/观看进度）。需要 bangumi_token，
    --       未配置时模块加载成功但 is_enabled() 为 false，不产生任何网络请求。
    if not init_module(bangumi_user_mod, opts, {
        notify = notify_mod,
        request_registry = request_registry_mod,
    }, "bangumi_user", false) then return false end

    -- 步骤 11: danmaku_link.init(opts, {notify})
    if not init_module(danmaku_link_mod, opts, {
        notify = notify_mod,
    }, "danmaku_link", false) then return false end

    -- 步骤 12: loading_controller.init(opts, {menu, ui_base, notify, request_registry, state, script_name})
    -- menu 在步骤 15 才 init，但模块表已 require，引用有效（运行时调用时 init 已完成）
    if not init_module(loading_controller_mod, opts, {
        menu = menu_mod,
        ui_base = ui_base_mod,
        notify = notify_mod,
        request_registry = request_registry_mod,
        state = state_mod,
        script_name = script_name,
    }, "loading_controller", true) then return false end

    -- 步骤 13: search_pipeline.init(opts, 完整 deps)
    if not init_module(search_pipeline_mod, opts, {
        api = api_mod,
        dandanplay = dandanplay_mod,
        extra = extra_mod,
        anilist = anilist_mod,
        mal = mal_mod,
        baike = baike_mod,
        guess = guess_mod,
        notify = notify_mod,
        servers = servers_mod,
        state = state_mod,
        request_registry = request_registry_mod,
        menu = menu_mod,
        history = history_mod,
        name_resolver = name_resolver_mod,
        loading_controller = loading_controller_mod,
        get_danmaku_info = get_danmaku_info,
        get_current_title = get_current_title,
        debug_log = debug_log,
    }, "search_pipeline", true) then return false end

    -- 步骤 14: features.*.init(deps)
    -- 构造综合 deps 表，各 feature 按需取用
    local feature_deps = {
        notify = notify_mod,
        state = state_mod,
        menu = menu_mod,
        api = api_mod,
        name_resolver = name_resolver_mod,
        loading_controller = loading_controller_mod,
        history = history_mod,
        request_registry = request_registry_mod,
        search_pipeline = search_pipeline_mod,
        servers = servers_mod,
        anilist = anilist_mod,
        mal = mal_mod,
        baike = baike_mod,
        bangumi_user = bangumi_user_mod,
        cards = cards_mod,
        cover_intro = cover_intro_mod,
        production_score = production_score_mod,
        staff_grid = staff_grid_mod,
        data_cache = data_cache_mod,
        opts = opts,
        script_name = script_name,
        get_danmaku_info = get_danmaku_info,
        get_current_title = get_current_title,
        fallback_to_subject_list_search = fallback_to_subject_list_search,
        debug_log = debug_log,
        runtime_config = runtime_config_mod,  -- v1.7
    }

    init_feature(mods["features.shared"], feature_deps, "shared")
    init_feature(mods["features.staff_credits"], feature_deps, "staff_credits")
    init_feature(mods["features.character_cards"], feature_deps, "character_cards")
    init_feature(mods["features.cover_intro_flow"], feature_deps, "cover_intro_flow")
    init_feature(mods["features.production_score_flow"], feature_deps, "production_score_flow")
    init_feature(mods["features.subject_select"], feature_deps, "subject_select")
    init_feature(mods["features.progress_sync"], feature_deps, "progress_sync")

    -- 步骤 15: menu.init(opts, {servers, script_name=script_name, state, opts, runtime_config, progress_sync})
    -- v1.7: 新增 opts 与 runtime_config 依赖，供 show_settings_menu 读写运行时配置
    -- v2.0: 新增 progress_sync，主菜单据此插入观看进度条目（未配 token 时返回空表）
    if not init_module(menu_mod, opts, {
        servers = servers_mod,
        script_name = script_name,
        state = state_mod,
        opts = opts,                          -- v1.7
        runtime_config = runtime_config_mod,  -- v1.7
        progress_sync = mods["features.progress_sync"],  -- v2.0
    }, "menu", true) then return false end

    -- 步骤 16: cards.init(opts, {ui_base, panel_registry, input_service, ass_lib, notify, request_registry, utils})
    if not init_module(cards_mod, opts, {
        ui_base = ui_base_mod,
        panel_registry = panel_registry_mod,
        input_service = input_service_mod,
        ass_lib = ass_lib_mod,
        notify = notify_mod,
        request_registry = request_registry_mod,
        utils = utils_mod,
    }, "cards", false) then return false end

    -- 步骤 17: cover_intro.init(opts, {ui_base, panel_registry, input_service, ass_lib, notify, utils})
    if not init_module(cover_intro_mod, opts, {
        ui_base = ui_base_mod,
        panel_registry = panel_registry_mod,
        input_service = input_service_mod,
        ass_lib = ass_lib_mod,
        notify = notify_mod,
        utils = utils_mod,
    }, "cover_intro", false) then return false end

    -- 步骤 18: production_score.init(opts, {ui_base, panel_registry, input_service, ass_lib, notify, request_registry, api, utils})
    if not init_module(production_score_mod, opts, {
        ui_base = ui_base_mod,
        panel_registry = panel_registry_mod,
        input_service = input_service_mod,
        ass_lib = ass_lib_mod,
        notify = notify_mod,
        request_registry = request_registry_mod,
        api = api_mod,
        utils = utils_mod,
    }, "production_score", false) then return false end

    -- 步骤 18.5: staff_grid.init(opts, {ui_base, panel_registry, input_service, ass_lib, notify, utils})
    if not init_module(staff_grid_mod, opts, {
        ui_base = ui_base_mod,
        panel_registry = panel_registry_mod,
        input_service = input_service_mod,
        ass_lib = ass_lib_mod,
        notify = notify_mod,
        utils = utils_mod,
    }, "staff_grid", false) then return false end

    -- 步骤 18.6: data_cache.init(opts, {notify})
    if not init_module(data_cache_mod, opts, {
        notify = notify_mod,
    }, "data_cache", false) then return false end

    -- 步骤 18.7: runtime_config.init(opts, {notify})
    -- v1.7: 运行时配置（读取 ~~/staff-credits-runtime-config.json，200ms 防抖写入）
    if not init_module(runtime_config_mod, opts, {
        notify = notify_mod,
    }, "runtime_config", false) then return false end

    -- 步骤 19: dispatcher.init(opts, 完整模块表 + 闭包)
    if not init_module(dispatcher_mod, opts, {
        opts = opts,
        ui_base = ui_base_mod,
        notify = notify_mod,
        menu = menu_mod,
        state = state_mod,
        loading_controller = loading_controller_mod,
        request_registry = request_registry_mod,
        search_pipeline = search_pipeline_mod,
        danmaku_link = danmaku_link_mod,
        history = history_mod,
        servers = servers_mod,
        api = api_mod,  -- v1.7: 静默预加载深度需要 api.get_subject_characters/persons/detail
        panel_registry = panel_registry_mod,
        cards = cards_mod,
        cover_intro = cover_intro_mod,
        production_score = production_score_mod,
        staff_grid = staff_grid_mod,
        data_cache = data_cache_mod,
        runtime_config = runtime_config_mod,  -- v1.7
        feature_staff_credits = mods["features.staff_credits"],
        feature_character_cards = mods["features.character_cards"],
        feature_cover_intro_flow = mods["features.cover_intro_flow"],
        feature_production_score_flow = mods["features.production_score_flow"],
        feature_subject_select = mods["features.subject_select"],
        feature_progress_sync = mods["features.progress_sync"],   -- v2.0
        bangumi_user = bangumi_user_mod,                          -- v2.0
        script_name = script_name,
        get_danmaku_info = get_danmaku_info,
        get_current_title = get_current_title,
        debug_log = debug_log,
        COVER_INTRO_CACHE_TTL = COVER_INTRO_CACHE_TTL,
        MAX_LAST_SUBJECT_ENTRIES = MAX_LAST_SUBJECT_ENTRIES,
    }, "dispatcher", true) then return false end

    -- 步骤 20: dispatcher.register_all()
    if dispatcher_mod and type(dispatcher_mod.register_all) == "function" then
        local ok, err = pcall(dispatcher_mod.register_all)
        if not ok then
            msg.error("[bootstrap] dispatcher.register_all failed: " .. tostring(err))
            return false
        end
    else
        msg.error("[bootstrap] dispatcher or register_all not available")
        return false
    end

    -- ====== 7. 启动 5s 后清理过期图片缓存 ======
    mp.add_timeout(5, function()
        local temp_dir = os.getenv("TEMP") or "/tmp"
        if ui_base_mod and type(ui_base_mod.cleanup_expired_cache) == "function" then
            local ok, count = pcall(ui_base_mod.cleanup_expired_cache,
                temp_dir, {"staff_credits_", "cover_"}, opts.image_cache_days, 2000)
            if ok then
                msg.debug("[bootstrap] cleanup_expired_cache: removed " .. tostring(count) .. " files")
            end
        end
    end)

    -- 暴露内部状态供调试
    M._mods = mods
    M._opts = opts
    M._script_name = script_name

    return true
end

return M
