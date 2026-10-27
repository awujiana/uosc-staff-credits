-- modules/menu.lua
-- uosc 菜单生成模块（表示层）
-- 遵循 DESIGN.md 第 11 节：uosc 集成（工具栏按钮 / open-menu / update-menu / close-menu）
-- 遵循 UI.md 第 8 节：7 种菜单类型与各子菜单配置
-- 实现：
--   1. 7 个菜单类型常量
--   2. 菜单状态机（idle / switching）+ 影子副本 menu_visible_type
--   3. 智能选择 open-menu vs update-menu
--   4. uosc 工具栏按钮注册
--   5. 各类菜单构建函数（主菜单 / 职员表 / 搜索 / 结果 / 加载 / 设置 / 服务器 / 错误）
-- 所有 uosc 通信通过 mp.commandv("script-message-to", "uosc", cmd, json_props)

local mp = require("mp")
local msg = require("mp.msg")
local utils = require("mp.utils")

local M = {}

local opts, deps, init = require("modules.utils.module_loader").make_init(
    "menu",
    {
        servers = "table",
        script_name = "string",
        state = "table",
        opts = "table",            -- v1.7: 读取运行时配置项默认值
        runtime_config = "table",  -- v1.7: 读写 ~~/staff-credits-runtime-config.json
    }
)

-- ============ 7 个菜单类型常量（UI.md 8.1）============
M.MENU_MAIN = "staff_credits_main"
M.MENU_CHARACTERS = "staff_credits_characters"
M.MENU_SEARCH = "staff_credits_search"
M.MENU_RESULTS = "staff_credits_results"
M.MENU_LOADING = "staff_credits_loading"
M.MENU_SETTINGS = "staff_credits_settings"
M.MENU_SERVERS = "staff_credits_servers"

-- ============ 菜单状态机（FF-8 单写者，UI.md 8.10）============
-- 状态："idle" / "switching"
-- open_menu 进入 "switching"，SWITCH_RESET_DELAY 后自动复位 "idle"
-- loading_controller 只读消费 get_state()，抑制 open-menu 引发的虚假 on_close
local menu_state = "idle"
local SWITCH_RESET_DELAY = 0.1
local switch_reset_timer = nil

-- 影子副本：当前可见的菜单类型（V4-P2-26 修复，降低对 uosc user-data 的依赖）
local menu_visible_type = nil

-- ============ 内部辅助 ============

-- 智能选择命令：同类型用 update-menu 避免闪烁，否则用 open-menu
local function choose_cmd(menu_type)
    local current = menu_visible_type
    if current and tostring(current) == tostring(menu_type) then
        return "update-menu"
    end
    return "open-menu"
end

-- 发送 uosc 菜单命令
-- cmd: "open-menu" / "update-menu" / "close-menu"
-- props: 菜单属性表（已含 type 等字段）
local function send_uosc_menu(cmd, props)
    local json_str = nil
    local ok_fmt, result = pcall(utils.format_json, props)
    if ok_fmt then
        json_str = result
    end
    if not json_str or json_str == "" then
        msg.warn("[menu] format_json failed for cmd=" .. tostring(cmd))
        return false
    end
    local ok, err = pcall(mp.commandv, "script-message-to", "uosc", cmd, json_str)
    if not ok then
        msg.warn("[menu] commandv '" .. cmd .. "' failed: " .. tostring(err))
        return false
    end
    return true
end

-- 构造默认 on_close 命令字符串
local function default_on_close(menu_type)
    return string.format("script-message-to %s staff-credits-menu-closed %s",
        tostring(deps.script_name or ""), tostring(menu_type or ""))
end

-- 进入 switching 状态，SWITCH_RESET_DELAY 后复位
local function enter_switching()
    menu_state = "switching"
    if switch_reset_timer then
        pcall(function() switch_reset_timer:kill() end)
        switch_reset_timer = nil
    end
    switch_reset_timer = mp.add_timeout(SWITCH_RESET_DELAY, function()
        menu_state = "idle"
        switch_reset_timer = nil
    end)
end

-- 注册 uosc 工具栏按钮（DESIGN.md 11.1）
local function register_toolbar_button()
    local script_name = deps.script_name or ""
    local json = utils.format_json({
        icon = "menu_book",
        tooltip = "Bangumi 工具箱",
        command = {"script-message-to", script_name, "main-menu"},
    })
    if not json then
        msg.warn("[menu] failed to serialize toolbar button config")
        return
    end
    pcall(mp.commandv, "script-message-to", "uosc", "set-button", "staff_credits_main", json)
end

-- 包装 init：调用原始 init 后注册工具栏按钮
local base_init = init
local function wrapped_init(new_opts, new_deps)
    base_init(new_opts, new_deps)
    pcall(register_toolbar_button)
end
M.init = wrapped_init

-- ============ 公共接口 ============

-- get_state: 获取菜单状态机当前状态（loading_controller 只读消费）
function M.get_state()
    return menu_state
end

-- get_visible_type: 获取当前可见菜单类型
-- menu_type: 可选，若提供则仅当匹配时返回，否则返回 nil
function M.get_visible_type(menu_type)
    if menu_type == nil then
        return menu_visible_type
    end
    if menu_visible_type == menu_type then
        return menu_visible_type
    end
    return nil
end

-- is_visible: 判断指定类型菜单是否可见
function M.is_visible(menu_type)
    return menu_visible_type == menu_type
end

-- clear_visible_type: 清除影子副本（由 dispatcher 的 staff-credits-menu-closed 调用）
function M.clear_visible_type(menu_type)
    if menu_visible_type == menu_type then
        menu_visible_type = nil
    end
end

-- ============ open_menu / update_menu / close_menu ============

-- open_menu: 打开或更新菜单（智能选择 open-menu vs update-menu）
-- props: 菜单属性表，必须含 type 字段
-- 强制 on_close 显式设置（DESIGN.md 11.4 修复）
function M.open_menu(props)
    if type(props) ~= "table" then return end
    local menu_type = props.type
    if not menu_type then
        msg.warn("[menu] open_menu: missing 'type' in props")
        return
    end

    -- 显式设置 on_close（默认 staff-credits-menu-closed）
    if not props.on_close then
        props.on_close = default_on_close(menu_type)
    end

    local cmd = choose_cmd(menu_type)
    local ok = send_uosc_menu(cmd, props)
    if not ok then return end

    -- 更新影子副本与状态机（仅 open-menu 时）
    if cmd == "open-menu" then
        menu_visible_type = menu_type
        enter_switching()
    end
end

-- update_menu: 强制更新菜单（不切换状态，仅在调用方提供时更新 on_close）
function M.update_menu(props)
    if type(props) ~= "table" then return end
    local menu_type = props.type
    if not menu_type then return end

    -- update-menu 保留原菜单的 on_close（除非显式提供）
    send_uosc_menu("update-menu", props)

    -- 同步影子副本
    if menu_visible_type ~= menu_type then
        menu_visible_type = menu_type
    end
end

-- close_menu: 关闭指定类型菜单
function M.close_menu(menu_type)
    if not menu_type then return end
    -- 清除影子副本（若匹配）
    if menu_visible_type == menu_type then
        menu_visible_type = nil
    end
    send_uosc_menu("close-menu", { type = menu_type })
end

-- ============ build_loading_item / build_error_item ============

-- build_loading_item: 构造加载中菜单项（UI.md 8.8）
function M.build_loading_item(message)
    return {
        title = message or "加载中...",
        icon = "spinner",
        italic = true,
        keep_open = true,
        unselectable = true,
    }
end

-- build_error_item: 构造错误菜单项（UI.md 8.9）
function M.build_error_item(message)
    return {
        title = message or "发生错误",
        icon = "error",
        italic = true,
        keep_open = true,
        unselectable = true,
    }
end

-- ============ show_main_menu（UI.md 8.2）============

function M.show_main_menu()
    local script_name = deps.script_name or ""
    local items = {}

    -- 1. 职员表
    table.insert(items, {
        title = "职员表",
        icon = "contact_page",
        hint = "查看番剧角色和声优列表",
        value = "script-message-to " .. script_name .. " staff-credits",
        keep_open = false,
    })
    -- 2. 角色介绍
    table.insert(items, {
        title = "角色介绍",
        icon = "person",
        hint = "卡片化显示角色（含图片）",
        value = "script-message-to " .. script_name .. " character-intro",
        keep_open = false,
    })
    -- 3. 封面简介
    table.insert(items, {
        title = "封面简介",
        icon = "book",
        hint = "番剧封面+基本信息+简介梗概",
        value = "script-message-to " .. script_name .. " cover-intro",
        keep_open = false,
    })
    -- 4. BGM 搜索
    table.insert(items, {
        title = "BGM 搜索",
        icon = "search",
        hint = "手动搜索 Bangumi 条目",
        value = "script-message-to " .. script_name .. " staff-credits-search bangumi",
        keep_open = false,
    })
    -- 5. 制作评分
    table.insert(items, {
        title = "制作评分",
        icon = "sentiment_satisfied",
        hint = "分析制作人员的历史作品评分",
        value = "script-message-to " .. script_name .. " staff-credits-production-score",
        keep_open = false,
    })
    -- 6. 观看进度（v2.0，需 bangumi_token）
    --    未配 token 时 progress_sync.build_menu_items() 返回空表 → 此处自动跳过，
    --    不会在菜单里留下点不动的死项。
    if deps.progress_sync and type(deps.progress_sync.build_menu_items) == "function" then
        local ok, ps_items = pcall(deps.progress_sync.build_menu_items)
        if ok and type(ps_items) == "table" then
            for _, item in ipairs(ps_items) do
                table.insert(items, item)
            end
        end
    end
    -- 7. 在浏览器打开当前条目（2026-10-07 审计补的入口）
    --    起因：staff-credits-open-browser 这个路由自首次接入（6c538bf）起就
    --    **没有任何发送方** —— dispatcher 里的 handle_open_browser() 写得很完整
    --    （scheme 校验、跨平台、防命令注入），但菜单里没有对应条目，
    --    于是这个能力用户根本点不到，成了「写了但从未接线」的死代码。
    --
    --    条目信息取自 state.get_last_subject(当前路径)：只有该路径已经成功
    --    解析过条目时才出现，与上面第 6 项（观看进度）同样的约定 ——
    --    不可用时直接不显示，不在菜单里留一个点不动的死项。
    do
        local cur_path = mp.get_property("path")
        local info = nil
        if cur_path and deps.state and type(deps.state.get_last_subject) == "function" then
            local ok, got = pcall(deps.state.get_last_subject, cur_path)
            if ok then info = got end
        end
        if type(info) == "table" and info.id then
            local label = info.name_cn
            if not label or label == "" then label = info.name end
            table.insert(items, {
                title = "在浏览器打开",
                icon = "open_in_new",
                hint = ((label and label ~= "") and (label .. " · ") or "") .. "bgm.tv",
                value = "script-message-to " .. script_name
                    .. " staff-credits-open-browser https://bgm.tv/subject/" .. tostring(info.id),
            })
        end
    end

    -- 8. 分隔项
    table.insert(items, {
        title = "─── 设置 ───",
        italic = true,
        unselectable = true,
        keep_open = true,
    })
    -- 9. 网站优先级
    table.insert(items, {
        title = "网站优先级",
        icon = "swap_vert",
        hint = "配置首选获取的网站 · ctrl+↑↓ 排序",
        value = "script-message-to " .. script_name .. " staff-credits-servers",
        keep_open = false,
    })
    -- 10. 搜索设置
    table.insert(items, {
        title = "搜索设置",
        icon = "settings",
        hint = "清除缓存等选项",
        value = "script-message-to " .. script_name .. " staff-credits-settings",
        keep_open = false,
    })
    -- 11. 清除当前视频缓存
    table.insert(items, {
        title = "清除当前视频缓存",
        icon = "delete",
        hint = "删除当前动漫的搜索记录",
        value = "script-message-to " .. script_name .. " staff-credits-clear-cache",
        keep_open = false,
    })
    -- 12. 清除所有缓存
    table.insert(items, {
        title = "清除所有缓存",
        icon = "delete_sweep",
        hint = "删除全部搜索记录",
        value = "script-message-to " .. script_name .. " staff-credits-clear-all",
        keep_open = false,
    })

    M.open_menu({
        type = M.MENU_MAIN,
        title = "Bangumi 工具箱",
        search_style = "disabled",
        items = items,
    })
end

-- ============ show_characters（UI.md 8.3）============

-- title: 番剧名称（fallback "职员表"）
-- items: 由 features/staff_credits.lua merge_items 构造的条目列表
--   每项 {kind="character"|"staff", name, role, cv, images}
function M.show_characters(title, items)
    if type(items) ~= "table" then items = {} end
    local display_title = title or "职员表"

    local char_count = 0
    local staff_count = 0
    local menu_items = {}

    for _, it in ipairs(items) do
        if it.kind == "character" then
            char_count = char_count + 1
            local hint = ""
            if it.cv and it.cv ~= "" then
                hint = "CV: " .. it.cv
                if it.role and it.role ~= "" then
                    hint = hint .. " [" .. it.role .. "]"
                end
            elseif it.role and it.role ~= "" then
                hint = it.role
            end
            table.insert(menu_items, {
                title = it.name or "",
                icon = "person",
                hint = hint,
                italic = false,
                unselectable = false,
                keep_open = false,
            })
        elseif it.kind == "staff" then
            staff_count = staff_count + 1
            table.insert(menu_items, {
                title = it.name or "",
                icon = "badge",
                hint = it.role or "",
                italic = false,
                unselectable = false,
                keep_open = false,
            })
        end
    end

    local total = char_count + staff_count
    local footnote
    if char_count > 0 and staff_count > 0 then
        footnote = string.format("共 %d 人（角色 %d · 职员 %d） | 滚动查看全部 · 输入文字筛选",
            total, char_count, staff_count)
    elseif char_count > 0 then
        footnote = string.format("共 %d 个角色 | 滚动查看全部 · 输入文字筛选", char_count)
    elseif staff_count > 0 then
        footnote = string.format("共 %d 名职员 | 滚动查看全部 · 输入文字筛选", staff_count)
    else
        footnote = "无数据 | 输入文字筛选"
    end

    M.open_menu({
        type = M.MENU_CHARACTERS,
        title = display_title,
        width = 560,
        search_style = "on_demand",
        items = menu_items,
        footnote = footnote,
    })
end

-- ============ show_search_panel（UI.md 8.4）============

-- search_suggestion: 预填文本（通常为 parse_title 结果），可为 nil
-- source: 数据源标识（如 "bangumi"）
--
-- 2026-10-05：对齐 uosc_danmaku 的搜索面板。参考实现
--   uosc_danmaku/modules/menu.lua 的 open_input_menu_uosc()，它额外提供了：
--     · 一行 hint：  "  追加|ds或|dy或|dm可搜索电视剧|电影|国漫"
--     · 一行状态：  "已关联弹幕：<番名>-<集数>"（bold+italic，不可选中）
--   本面板此前两者皆无，用户不知道支持 `|` 后缀语法，也不知道当前是否已关联。
--   这里补齐同样的提示行；「已关联」状态行由调用方通过 status_text 传入。
function M.show_search_panel(search_suggestion, source, status_text)
    local script_name = deps.script_name or ""
    source = source or "bangumi"
    local suggestion = search_suggestion or ""

    -- 构造 items：状态行（如有）+ 语法提示行（对齐 uosc_danmaku）
    local items = {}
    if status_text and status_text ~= "" then
        table.insert(items, {
            title = status_text,
            bold = true,
            italic = true,
            keep_open = true,
            selectable = false,
        })
    end
    table.insert(items, {
        -- 与 uosc_danmaku 逐字一致的提示文案
        hint = "  追加|ds或|dy或|dm可搜索电视剧|电影|国漫",
        keep_open = true,
        selectable = false,
    })

    M.open_menu({
        type = M.MENU_SEARCH,
        title = "在此处输入番剧名称",
        search_style = "palette",
        search_debounce = "submit",
        -- 预填搜索框（用户可直接 Enter 搜索，或修改后搜索）
        search_suggestion = suggestion,
        on_search = string.format("script-message-to %s staff-credits-search %s",
            script_name, source),
        -- footnote 显示完整标题，方便用户确认（搜索框可能只显示尾部）
        footnote = suggestion ~= ""
            and "建议标题: " .. suggestion .. " · 按 Enter 直接搜索"
            or "使用enter或ctrl+enter进行搜索 · 可直接修改输入框内容",
        items = items,
    })
end

-- parse_query_class: 拆解 `名称|class` 后缀语法（对齐 uosc_danmaku）
--
-- 参考 uosc_danmaku/modules/menu.lua:
--     local name, class = query:match("^(.-)%s*|%s*(.-)%s*$")
--     if name and class then query_extra(name, class) else get_animes(query) end
--
-- 语义：用户在搜索框里写「无职转生|ds」，`|ds` 表示改搜「电视剧」这一类。
--   ds → 电视剧（tv） · dy → 电影（movie） · dm → 国漫（anime）
-- 返回：name, class（无后缀时 class = nil）
function M.parse_query_class(query)
    if type(query) ~= "string" or query == "" then return query, nil end
    local name, class = query:match("^(.-)%s*|%s*(.-)%s*$")
    if name and class and class ~= "" then
        return name, class:lower()
    end
    return query, nil
end

-- CLASS_HINTS: `|xx` 后缀 → 提示用的中文类别名
M.CLASS_HINTS = {
    ds = "电视剧",
    dy = "电影",
    dm = "国漫",
}

-- ============ show_search_results（UI.md 8.5）============

-- Bangumi 类型 → icon 映射
local SUBJECT_TYPE_ICONS = {
    [1] = "tv",            -- TV
    [2] = "video_library", -- OVA
    [3] = "theaters",      -- 剧场版
    [4] = "public",        -- WEB
    [6] = "category",      -- 其它
}

-- results: 搜索结果数组（每项含 id/name/name_cn/url/type 等）
-- source: 数据源标识
function M.show_search_results(results, source)
    local script_name = deps.script_name or ""
    source = source or "bangumi"

    if type(results) ~= "table" or #results == 0 then
        -- 空结果：显示错误项
        M.open_menu({
            type = M.MENU_RESULTS,
            title = "搜索结果 (0)",
            search_style = "on_demand",
            items = { M.build_error_item("未找到匹配的 Bangumi 条目") },
            footnote = "共 0 条结果",
        })
        return
    end

    local menu_items = {}
    -- 首项：返回搜索
    table.insert(menu_items, {
        title = "← 返回搜索",
        icon = "arrow_back",
        value = string.format("script-message-to %s staff-credits-search %s",
            script_name, source),
        italic = false,
        unselectable = false,
        keep_open = false,
    })

    for _, r in ipairs(results) do
        if type(r) == "table" and r.id ~= nil then
            local name = r.name_cn or r.name or "未知条目"
            local icon = SUBJECT_TYPE_ICONS[r.type] or "category"
            local hint = r.name or ""
            if r.name_cn and r.name and r.name_cn ~= r.name then
                hint = r.name
            end
            table.insert(menu_items, {
                title = name,
                icon = icon,
                hint = hint,
                value = string.format("script-message-to %s staff-credits-select %s %s",
                    script_name, tostring(r.id), source),
                italic = false,
                unselectable = false,
                keep_open = false,
            })
        end
    end

    M.open_menu({
        type = M.MENU_RESULTS,
        title = string.format("搜索结果 (%d)", #results),
        search_style = "on_demand",
        items = menu_items,
        footnote = string.format("共 %d 条结果 | 输入文字筛选", #results),
    })
end

-- ============ show_loading_menu（UI.md 8.8）============

-- message: 基础提示文本（如 "正在搜索... (剩余 10s)"）
-- menu_type: 菜单类型标识（默认 MENU_LOADING）
-- title: 菜单标题（默认 "查询中"）
function M.show_loading_menu(message, menu_type, title)
    menu_type = menu_type or M.MENU_LOADING
    local script_name = deps.script_name or ""

    M.open_menu({
        type = menu_type,
        title = title or "查询中",
        search_style = "disabled",
        items = { M.build_loading_item(message) },
        on_close = string.format("script-message-to %s staff-credits-loading-close",
            script_name),
    })
end

-- ============ show_error_menu（UI.md 8.9）============

-- message: 错误提示文本
-- title: 可选菜单标题（默认 "错误"）
function M.show_error_menu(message, title)
    M.open_menu({
        type = M.MENU_LOADING,
        title = title or "错误",
        search_style = "disabled",
        items = { M.build_error_item(message) },
    })
end

-- ============ show_settings_menu（UI.md 8.6）============

-- v1.7: 预定义配置项可选值（供 show_config_value_menu 使用）
local CONFIG_OPTIONS = {
    data_cache_days = {
        title = "数据缓存天数",
        options = {
            {value = "0", label = "0 - 永不过期"},
            {value = "1", label = "1 - 一天"},
            {value = "3", label = "3 - 三天"},
            {value = "7", label = "7 - 一周（默认）"},
            {value = "15", label = "15 - 半月"},
            {value = "30", label = "30 - 一个月"},
        },
    },
    image_cache_days = {
        title = "图片缓存天数",
        options = {
            {value = "0", label = "0 - 永不过期"},
            {value = "7", label = "7 - 一周"},
            {value = "30", label = "30 - 一个月（默认）"},
            {value = "90", label = "90 - 三个月"},
        },
    },
    silent_preload_depth = {
        title = "静默预加载深度",
        options = {
            {value = "subject", label = "subject - 仅条目ID"},
            {value = "characters", label = "characters - +角色"},
            {value = "persons", label = "persons - +角色+职员（默认推荐）"},
            {value = "all", label = "all - +详情（流量大）"},
        },
    },
    pagination_position = {
        title = "翻页按钮位置",
        options = {
            {value = "top", label = "top - 顶部上方"},
            {value = "middle", label = "middle - 中间右侧"},
            {value = "bottom", label = "bottom - 底部上方（默认，避开 uosc）"},
        },
    },
}

-- v1.7: show_config_menu 通用配置选择菜单
-- key: 配置项 key（如 "silent_preload_depth"）
-- title: 菜单标题（如 "静默预加载深度"）
-- options: 数组，每项 {value, label}（如 {value="persons", label="persons - 推荐"}）
-- current_value: 当前值（用于高亮选中项）
function M.show_config_menu(key, title, options, current_value)
    local script_name = deps.script_name or ""
    local items = {}
    for _, opt in ipairs(options or {}) do
        table.insert(items, {
            title = opt.label or tostring(opt.value),
            icon = (opt.value == current_value) and "check_circle" or "radio_button_unchecked",
            value = string.format("script-message-to %s staff-credits-set-config %s %s",
                script_name, tostring(key), tostring(opt.value)),
            active = (opt.value == current_value),
            keep_open = false,
        })
    end

    M.open_menu({
        type = M.MENU_SETTINGS,
        title = title or "配置",
        search_style = "disabled",
        items = items,
    })
end

-- v1.7: show_config_value_menu 处理 staff-credits-config {key} 脚本消息
-- 根据 CONFIG_OPTIONS[key] 显示可选值列表，高亮当前值
function M.show_config_value_menu(key)
    local def = CONFIG_OPTIONS[key]
    if not def then
        if deps.notify then deps.notify.warn("未知配置项: " .. tostring(key)) end
        return
    end
    -- 当前值：runtime_config.get 优先，回退到 opts[key]
    local current = nil
    if deps.runtime_config and type(deps.runtime_config.get) == "function" then
        current = deps.runtime_config.get(key)
    end
    if current == nil and type(opts) == "table" then
        current = opts[key]
    end
    -- data_cache_days/image_cache_days 在 opts 中是 number，转换为 string 比较
    local current_str = tostring(current)
    M.show_config_menu(key, def.title, def.options, current_str)
end

function M.show_settings_menu()
    local script_name = deps.script_name or ""

    -- v1.7: 获取运行时配置（合并优先级: runtime_config > opts > defaults）
    local function cfg(key)
        if deps.runtime_config and type(deps.runtime_config.get) == "function" then
            local v = deps.runtime_config.get(key)
            if v ~= nil then return v end
        end
        if type(opts) == "table" then return opts[key] end
        return nil
    end

    local function fmt_bool(v)
        if v == true then return "yes" end
        if v == false then return "no" end
        return tostring(v)
    end

    local items = {}

    -- 1. 缓存管理组
    table.insert(items, {
        title = "─── 缓存管理 ───",
        italic = true, unselectable = true, keep_open = true,
    })
    table.insert(items, {
        title = "清除当前视频缓存",
        icon = "delete",
        value = "script-message-to " .. script_name .. " staff-credits-clear-cache",
        keep_open = false,
    })
    table.insert(items, {
        title = "清除所有缓存",
        icon = "delete_sweep",
        value = "script-message-to " .. script_name .. " staff-credits-clear-all",
        keep_open = false,
    })

    -- 2. 缓存设置组
    table.insert(items, {
        title = "─── 缓存设置 ───",
        italic = true, unselectable = true, keep_open = true,
    })
    table.insert(items, {
        title = string.format("数据缓存天数: %s", tostring(cfg("data_cache_days"))),
        icon = "schedule",
        hint = "0=永不过期 · 7=默认",
        value = string.format("script-message-to %s staff-credits-config data_cache_days",
            script_name),
        keep_open = false,
    })
    table.insert(items, {
        title = string.format("数据缓存开关: %s", fmt_bool(cfg("enable_data_cache"))),
        icon = "toggle_on",
        hint = "yes/no 切换",
        value = string.format("script-message-to %s staff-credits-set-config enable_data_cache %s",
            script_name, (cfg("enable_data_cache") == false) and "yes" or "no"),
        keep_open = false,
    })
    table.insert(items, {
        title = string.format("图片缓存天数: %s", tostring(cfg("image_cache_days"))),
        icon = "image",
        hint = "0=永不过期 · 30=默认",
        value = string.format("script-message-to %s staff-credits-config image_cache_days",
            script_name),
        keep_open = false,
    })

    -- 3. 预加载组
    table.insert(items, {
        title = "─── 静默预加载 ───",
        italic = true, unselectable = true, keep_open = true,
    })
    table.insert(items, {
        title = string.format("预加载深度: %s", tostring(cfg("silent_preload_depth"))),
        icon = "layers",
        hint = "subject/characters/persons/all",
        value = string.format("script-message-to %s staff-credits-config silent_preload_depth",
            script_name),
        keep_open = false,
    })

    -- 4. UI 设置组
    table.insert(items, {
        title = "─── UI 设置 ───",
        italic = true, unselectable = true, keep_open = true,
    })
    table.insert(items, {
        title = string.format("翻页按钮位置: %s", tostring(cfg("pagination_position"))),
        icon = "swap_vert",
        hint = "top/middle/bottom",
        value = string.format("script-message-to %s staff-credits-config pagination_position",
            script_name),
        keep_open = false,
    })

    -- 5. 调试组
    table.insert(items, {
        title = "─── 调试 ───",
        italic = true, unselectable = true, keep_open = true,
    })
    table.insert(items, {
        title = string.format("调试模式: %s", fmt_bool(cfg("debug"))),
        icon = "bug_report",
        hint = "yes/no 切换",
        value = string.format("script-message-to %s staff-credits-set-config debug %s",
            script_name, (cfg("debug") == true) and "no" or "yes"),
        keep_open = false,
    })

    M.open_menu({
        type = M.MENU_SETTINGS,
        title = "搜索设置",
        search_style = "disabled",
        items = items,
    })
end

-- ============ show_servers_menu（UI.md 8.7）============

function M.show_servers_menu()
    local script_name = deps.script_name or ""
    local items = {}

    if deps.servers and type(deps.servers.build_menu_items) == "function" then
        local ok, srv_items = pcall(deps.servers.build_menu_items)
        if ok and type(srv_items) == "table" then
            for _, it in ipairs(srv_items) do
                -- 每项 value 设置为 toggle 命令
                local value = ""
                if it.value and it.value ~= "" then
                    value = string.format("script-message-to %s staff-credits-servers-toggle %s",
                        script_name, it.value)
                end
                table.insert(items, {
                    title = it.title or "",
                    icon = it.icon or "check_box",
                    hint = it.hint or "",
                    value = value,
                    active = it.active,
                    keep_open = false,
                })
            end
        end
    end

    -- 空列表时显示提示项
    if #items == 0 then
        items = {
            {
                title = "暂无配置网站",
                icon = "info",
                italic = true,
                unselectable = true,
                keep_open = true,
            },
        }
    end

    M.open_menu({
        type = M.MENU_SERVERS,
        title = "网站优先级",
        search_style = "disabled",
        items = items,
        on_move = string.format("script-message-to %s staff-credits-servers-move",
            script_name),
        footnote = "ctrl+↑↓ 调整优先级 · 点击切换启用 · ctrl+pgup/pgdn 快速移动",
    })
end

return M
