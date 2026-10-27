-- app/loading_controller.lua
-- 加载流程控制器
-- 遵循 DESIGN.md 第 9 节：loading_state 的唯一写者（FF-4 单写者）
-- ADR-07：抽离加载流程，负责 10 秒倒计时、ESC 取消、超时处理
--
-- 三种完成方式：
--   finish()          请求完成 / ESC / 超时
--   finish_silent()   请求成功后紧接着打开同类型新菜单
--   transition_phase() fetch_production_score 搜索阶段 → persons 阶段

local mp = require("mp")
local msg = require("mp.msg")

local M = {}

local opts, deps, init = require("modules.utils.module_loader").make_init(
    "loading_controller",
    {
        menu = "table",
        ui_base = "table",
        notify = "table",
        request_registry = "table",
        state = "table",
        script_name = "string",
    }
)
M.init = init

-- ============ 模块本地状态 ============

-- ESC 绑定是否已注册（防重复注册）
local esc_binding_registered = false
-- finish_silent 的兜底定时器
local fallback_timer = nil
-- v1.9.4: zombie menu 防护标志——一旦设置，周期定时器回调立即变为 no-op
--       解决竞态条件：finish_silent 关闭菜单后，正在执行的定时器回调
--       因 menu_visible_type 已被清除而使用 open-menu 重新打开菜单
local loading_closed = false

-- ============ 内部辅助函数 ============

-- stop_loading_timer: 停止倒计时定时器并置空
local function stop_loading_timer()
    local timer = deps.state.loading_state.loading_timer
    if timer then
        pcall(function() timer:kill() end)
        deps.state.loading_state.loading_timer = nil
    end
end

-- unregister_esc: 注销 forced ESC 绑定
local function unregister_esc()
    if esc_binding_registered then
        pcall(mp.remove_key_binding, "staff_credits_loading_esc")
        esc_binding_registered = false
    end
end

-- stop_fallback_timer: 停止 finish_silent 的兜底定时器
local function stop_fallback_timer()
    if fallback_timer then
        pcall(function() fallback_timer:kill() end)
        fallback_timer = nil
    end
end

-- get_timeout: 读取超时配置，默认 10 秒
local function get_timeout()
    local t = tonumber(opts.timeout)
    if not t or t <= 0 then return 10 end
    return t
end

-- ============ 公共接口 ============

-- set_loading: 设置 loading 标志（loading_state.loading 的唯一写者之一）
function M.set_loading(flag)
    deps.state.loading_state.loading = flag and true or false
end

-- show_with_countdown: 显示带倒计时的加载菜单
-- message: 基础提示文本
-- menu_type: 菜单类型标识
-- title: 菜单标题
-- keep_timer: true 时复用已有 loading_start_time（阶段切换时使用）
function M.show_with_countdown(message, menu_type, title, keep_timer)
    local loading_state = deps.state.loading_state

    -- v1.9.4: 重置 zombie 防护标志（新 loading 开始）
    loading_closed = false

    -- 1. 重置开始时间（keep_timer=true 时保留，用于阶段切换）
    if not keep_timer then
        loading_state.loading_start_time = mp.get_time()
    end

    -- 2. 停止旧定时器
    stop_loading_timer()
    stop_fallback_timer()

    -- 3. 记录菜单类型
    loading_state.loading_menu_type = menu_type

    local timeout = get_timeout()

    -- 4. 构造消息函数
    local function build_msg()
        local elapsed = mp.get_time() - loading_state.loading_start_time
        local remaining = timeout - elapsed
        if remaining < 0 then remaining = 0 end
        return message .. " (剩余 " .. math.ceil(remaining) .. "s)"
    end

    -- 5. 首次立即显示
    if deps.menu and type(deps.menu.show_loading_menu) == "function" then
        deps.menu.show_loading_menu(build_msg(), menu_type, title)
    end

    -- 6. 注册 forced ESC 绑定（仅首次注册，防重复）
    if not esc_binding_registered then
        if deps.ui_base and type(deps.ui_base.safe_add_key) == "function" then
            deps.ui_base.safe_add_key("ESC", "staff_credits_loading_esc", function()
                pcall(mp.commandv, "script-message-to", deps.script_name,
                    "staff-credits-loading-close")
            end, true)
            esc_binding_registered = true
        end
    end

    -- 7. 启动每秒刷新定时器
    loading_state.loading_timer = mp.add_periodic_timer(1, function()
        -- v1.9.4 [首要检查]：zombie 防护——loading 已关闭则立即退出
        --       必须在 loading 检查之前，防止 finish_silent 后正在执行的回调
        --       因 menu_visible_type 已被清除而用 open-menu 重新打开菜单
        if loading_closed then
            stop_loading_timer()
            return
        end

        -- loading 已结束：停止定时器
        if not loading_state.loading then
            stop_loading_timer()
            return
        end
        local elapsed = mp.get_time() - loading_state.loading_start_time
        local remaining = timeout - elapsed
        if remaining <= 0 then
            -- 超时：停止定时器 + 取消请求 + 显示超时提示
            stop_loading_timer()
            if deps.request_registry and deps.request_registry.has_pending()
               and type(deps.request_registry.cancel_all) == "function" then
                deps.request_registry.cancel_all()
            end
            if deps.menu and type(deps.menu.show_loading_menu) == "function" then
                deps.menu.show_loading_menu(
                    "请求超时,正在等待响应(按 ESC 取消)...", menu_type, title)
            end
            return
        end
        -- 刷新倒计时
        if deps.menu and type(deps.menu.show_loading_menu) == "function" then
            deps.menu.show_loading_menu(
                message .. " (剩余 " .. math.ceil(remaining) .. "s)", menu_type, title)
        end
    end)
end

-- handle_loading_close: 处理加载菜单关闭请求（用户 ESC 或 uosc on_close）
function M.handle_loading_close()
    -- 1. 菜单处于 switching 状态时直接抑制（open-menu 引发的旧菜单 on_close）
    if deps.menu and type(deps.menu.get_state) == "function" then
        if deps.menu.get_state() == "switching" then
            return
        end
    end

    local loading_state = deps.state.loading_state

    -- 2. loading=false：加载菜单可能仍可见（0.5s 兜底窗口）
    if not loading_state.loading then
        local menu_type = loading_state.loading_menu_type
        local visible = true
        if deps.menu and type(deps.menu.is_visible) == "function" then
            visible = deps.menu.is_visible(menu_type)
        end
        if visible and menu_type and deps.menu
           and type(deps.menu.close_menu) == "function" then
            deps.menu.close_menu(menu_type)
        end
        -- 否则忽略
        return
    end

    -- 3. loading=true：用户主动取消，调用 finish
    M.finish()
end

-- finish: 完成加载流程（请求完成 / ESC / 超时）
-- 顺序：注销 ESC + 停定时器 + loading=false + cancel_all + close_menu（BUG-1.3 顺序）
-- v1.8: 添加兜底关闭定时器（0.3s 后再次 close_menu）
--       close_menu 的 close-menu 命令是异步的，uosc 可能未及时处理，
--       导致 loading 菜单和 ASS overlay 面板（如 staff_grid）同时显示。
--       兜底定时器在 0.3s 后再次发送 close-menu，确保菜单关闭。
--       若新 loading 已开始（loading=true），跳过兜底关闭避免误关新菜单。
-- v1.9.4: 最先设置 loading_closed 防护标志，防止周期定时器回调 zombie reopen
function M.finish()
    -- v1.9.4 [首要操作]：设置防护标志，阻止定时器回调重新打开菜单
    loading_closed = true

    unregister_esc()
    stop_loading_timer()
    stop_fallback_timer()

    -- v1.9.5: 隐藏 overlay loading（如果存在）
    M.hide_overlay_loading()

    deps.state.loading_state.loading = false
    if deps.request_registry and type(deps.request_registry.cancel_all) == "function" then
        deps.request_registry.cancel_all()
    end
    local menu_type = deps.state.loading_state.loading_menu_type

    -- v1.9.5: 多重关闭（不仅依赖 close_menu）
    -- A. 标准 close_menu
    if menu_type and deps.menu and type(deps.menu.close_menu) == "function" then
        deps.menu.close_menu(menu_type)
    end
    -- B. 无参 close-menu + blur（核选项子集）
    pcall(mp.commandv, "script-message-to", "uosc", "close-menu", "{}")
    pcall(mp.commandv, "script-message-to", "uosc", "blur")

    deps.state.loading_state.loading_menu_type = nil

    -- v1.8: 兜底关闭定时器
    if menu_type then
        local mt = menu_type
        fallback_timer = mp.add_timeout(0.3, function()
            fallback_timer = nil
            if deps.state.loading_state.loading then return end
            if deps.menu and type(deps.menu.close_menu) == "function" then
                deps.menu.close_menu(mt)
            end
            -- v1.9.5: 兜底也尝试无参关闭
            pcall(mp.commandv, "script-message-to", "uosc", "close-menu", "{}")
        end)
    end
end

-- finish_silent: 请求成功后紧接着打开同类型新菜单时使用
-- 停定时器 + loading=false + cancel_all + 立即关闭菜单 + 设 0.3s 兜底定时器
-- v1.9: 立即调用 close_menu（而非仅依赖兜底定时器），
--       解决 loading 菜单与新面板（cards/cover_intro/staff_grid）叠加显示的问题
-- v1.9.4: 最先设置 loading_closed 防止 zombie menu
-- v1.9.5: 增加多重关闭方法 + 隐藏 overlay loading
function M.finish_silent()
    -- v1.9.4 [首要操作]：设置防护标志，阻止定时器回调重新打开菜单
    loading_closed = true

    stop_loading_timer()
    stop_fallback_timer()

    -- v1.9.5: 隐藏 overlay loading
    M.hide_overlay_loading()

    deps.state.loading_state.loading = false
    if deps.request_registry and type(deps.request_registry.cancel_all) == "function" then
        deps.request_registry.cancel_all()
    end
    -- 立即关闭加载菜单（关键修复：避免与新面板叠加）
    local menu_type = deps.state.loading_state.loading_menu_type

    -- v1.9.5: 多重关闭
    -- A. 标准 close_menu
    if menu_type and deps.menu and type(deps.menu.close_menu) == "function" then
        deps.menu.close_menu(menu_type)
    end
    -- B. 无参 close-menu + blur
    pcall(mp.commandv, "script-message-to", "uosc", "close-menu", "{}")
    pcall(mp.commandv, "script-message-to", "uosc", "blur")

    deps.state.loading_state.loading_menu_type = nil

    -- 0.3s 兜底：若 uosc 异步处理延迟导致菜单未及时关闭
    if menu_type then
        local mt = menu_type
        fallback_timer = mp.add_timeout(0.3, function()
            fallback_timer = nil
            if deps.state.loading_state.loading then return end
            if deps.menu and type(deps.menu.close_menu) == "function" then
                deps.menu.close_menu(mt)
            end
            -- v1.9.5: 兜底也尝试无参关闭
            pcall(mp.commandv, "script-message-to", "uosc", "close-menu", "{}")
        end)
    end
end

-- transition_phase: 阶段切换（如 fetch_production_score 搜索阶段 → persons 阶段）
-- 停定时器 + cancel_all + 清菜单类型，保持 loading=true 支撑下一阶段倒计时
-- v1.7.1: 不再清除 loading_menu_type，避免 finish() 无法关闭加载菜单
function M.transition_phase()
    stop_loading_timer()
    stop_fallback_timer()
    if deps.request_registry and type(deps.request_registry.cancel_all) == "function" then
        deps.request_registry.cancel_all()
    end
    -- v1.7.1: 保留 loading_menu_type，让下一阶段 show_with_countdown 覆盖
    -- 注意：不重置 loading，保持 true 以支撑下一阶段
end

-- force_close_loading_menu: 无条件关闭当前 loading 菜单（v1.9.3 → v1.9.4 增强）
-- 用于面板渲染后的防御性清理，解决 uosc 异步 close-menu 时序竞争
--
-- v1.9.3: 关闭 loading_menu_type 记录的菜单 + 兜底 MENU_LOADING
-- v1.9.4: 多重尝试僵尸清理机制（解决 zombie menu 竞态条件）
--
-- 僵尸菜单产生原因：
--   finish_silent() 设置 loading_closed=true 并发送 close-menu，
--   但若周期定时器回调正在执行中（已通过 loading 检查），
--   可能在 close-menu 到达 uosc 之前又发送了 update-menu/open-menu，
--   导致菜单被重新打开。此时定时器已死，无人负责关闭。
--
-- 清理策略：
--   1. 立即尝试关闭所有已知 loading 菜单类型
--   2. 在 0.5s / 1.0s / 1.5s 后重试（共 3 次延迟尝试）
--   3. 每次重试前检查是否有新 loading 进行中（有则中止）
--   4. 3 次尝试后自动停止（避免无限后台定时器）
local zombie_killer_timers = {}

function M.force_close_loading_menu()
    stop_loading_timer()
    stop_fallback_timer()

    -- v1.9.4: 也设置防护标志（双重保险）
    loading_closed = true

    local loading_state = deps.state.loading_state
    local menu_to_close = loading_state.loading_menu_type

    -- 收集所有需要尝试关闭的菜单类型
    local types_to_close = {}
    if menu_to_close then
        table.insert(types_to_close, menu_to_close)
    end

    -- 兜底：始终包含常见 loading 菜单类型
    local menu_mod = package.loaded["modules.menu"]
    if not menu_mod then
        pcall(function() menu_mod = require("modules.menu") end)
    end
    if menu_mod then
        if menu_mod.MENU_LOADING then
            table.insert(types_to_close, menu_mod.MENU_LOADING)
        end
        if menu_mod.MENU_CHARACTERS then
            table.insert(types_to_close, menu_mod.MENU_CHARACTERS)
        end
    end

    -- 去重
    local seen = {}
    local unique_types = {}
    for _, t in ipairs(types_to_close) do
        if not seen[t] then
            seen[t] = true
            table.insert(unique_types, t)
        end
    end

    -- 执行关闭函数：尝试关闭所有候选类型
    local function do_close()
        if not deps.menu or type(deps.menu.close_menu) ~= "function" then return end
        for _, mt in ipairs(unique_types) do
            pcall(deps.menu.close_menu, mt)
        end
    end

    -- 立即执行第一次关闭
    do_close()

    -- 清空记录
    loading_state.loading_menu_type = nil

    -- v1.9.4: 僵尸清理 — 延迟重试（处理竞态条件下被重新打开的菜单）
    -- 清理旧定时器
    for _, t in ipairs(zombie_killer_timers) do
        pcall(function() t:kill() end)
    end
    zombie_killer_timers = {}

    local delays = {0.5, 1.0, 1.5}
    for _, delay in ipairs(delays) do
        local timer = mp.add_timeout(delay, function()
            -- 新 loading 已开始：中止清理
            if deps.state.loading_state.loading then return end
            -- 执行关闭
            do_close()
        end)
        table.insert(zombie_killer_timers, timer)
    end
end

-- v1.9.5: ASS overlay loading 指示器——替代 uosc 菜单做 transient loading 显示
--       解决 uosc close-menu 异步不可靠导致 loading 菜单卡死的问题
--       原理：使用与 cards/cover_intro 相同的 mp.create_osd_overlay('ass-events') 系统
--             面板渲染时自然覆盖 overlay，不存在 close 竞态条件
local overlay_loader = nil  -- { overlay, update_timer, refresh_fn }

-- ============ 核选项菜单关闭（v1.9.5）============
-- nuclear_menu_dismiss: 尝试所有已知方法强制关闭 uosc 菜单
-- 原因：uosc 的 close-menu 是异步消息，在高速竞态下（数据源快速返回时）
--       可能被忽略、重排、或因 keep_open item 而无效。5 个版本修复证明
--       单一 close-menu 方向不可行，必须多重手段并行。
function M.nuclear_menu_dismiss()
    -- 1. 设置防护标志（阻止定时器回调 zombie reopen）
    loading_closed = true

    -- 2. 停止所有定时器
    stop_loading_timer()
    stop_fallback_timer()
    for _, t in ipairs(zombie_killer_timers or {}) do
        pcall(function() t:kill() end)
    end
    zombie_killer_timers = {}

    -- 3. 隐藏 overlay loading（如果存在）
    M.hide_overlay_loading()

    -- 4. 清空状态
    deps.state.loading_state.loading = false
    deps.state.loading_state.loading_menu_type = nil

    -- 5. 尝试方法 A：对每种已知 menu_type 发送 close-menu
    local menu_mod = package.loaded["modules.menu"]
    if not menu_mod then pcall(function() menu_mod = require("modules.menu") end) end
    if menu_mod then
        local all_types = {
            menu_mod.MENU_LOADING,
            menu_mod.MENU_CHARACTERS,
            menu_mod.MENU_MAIN,
            menu_mod.MENU_SEARCH,
            menu_mod.MENU_RESULTS,
            menu_mod.MENU_SETTINGS,
            menu_mod.MENU_SERVERS,
        }
        if deps.menu and type(deps.menu.close_menu) == "function" then
            for _, mt in ipairs(all_types) do
                if mt then pcall(deps.menu.close_menu, mt) end
            end
        end
    end

    -- 6. 尝试方法 B：直接发送 uosc close-menu（无参数/空 JSON）
    pcall(mp.commandv, "script-message-to", "uosc", "close-menu", "{}")
    pcall(mp.commandv, "script-message-to", "uosc", "close-menu")

    -- 7. 尝试方法 C：发送 blur 命令（让 uosc 关闭当前聚焦元素）
    pcall(mp.commandv, "script-message-to", "uosc", "blur")

    -- 8. 尝试方法 D：模拟 ESC 键（用户操作级别的菜单关闭）
    --     延迟 50ms 执行，确保在当前调用栈完成后再发
    mp.add_timeout(0.05, function()
        pcall(mp.commandv, "keypress", "ESC")
    end)

    -- 9. 二次延迟重试（100ms 后再次尝试方法 A+B）
    mp.add_timeout(0.1, function()
        if deps.state.loading_state.loading then return end  -- 新 loading 已开始
        if menu_mod and deps.menu and type(deps.menu.close_menu) == "function" then
            for _, mt in ipairs({menu_mod.MENU_LOADING, menu_mod.MENU_CHARACTERS}) do
                if mt then pcall(deps.menu.close_menu, mt) end
            end
        end
        pcall(mp.commandv, "script-message-to", "uosc", "close-menu", "{}")
    end)
end

-- ============ ASS Overlay Loading（v1.9.5）============

-- show_overlay_loading: 用 ASS overlay 显示加载指示（替代 uosc 菜单）
-- message: 提示文本（如 "正在获取详情..."）
-- 返回 overlay 引用（供 hide_overlay_loading 使用）
function M.show_overlay_loading(message)
    -- 先清除旧的
    M.hide_overlay_loading()

    local w, h = 1280, 720
    if deps.ui_base and type(deps.ui_base.get_osd_size) == "function" then
        w, h = deps.ui_base.get_osd_size()
    end

    local ov = mp.create_osd_overlay("ass-events", {
        res_x = w, res_y = h,
        z = 2500,  -- 高于面板但低于 tooltip
    })

    if not ov then return nil end

    local function render(msg_text)
        local safe_msg = (msg_text or "加载中..."):gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}")
        local ass = string.format(
            [[{\\an8}\\pos(%d,%d){\\1c&H00FFFFFF&}{\\3c&H80000000&}{\\bord3}{\\shad1}{\\1a&H60&}{\\3a&H40&}{\\fs24}{\\q2}● %s]],
            w / 2, h / 2 - 50, safe_msg
        )
        ov.data = ass
        pcall(function() ov:update() end)
    end

    render(message)
    overlay_loader = {
        overlay = ov,
        message = message,
    }

    return ov
end

-- hide_overlay_loading: 隐藏 ASS overlay 加载指示
function M.hide_overlay_loading()
    if overlay_loader and overlay_loader.overlay then
        pcall(function() overlay_loader.overlay:remove() end)
    end
    overlay_loader = nil
end

-- 暴露内部辅助函数（调试/测试用）
M._stop_loading_timer = stop_loading_timer
M._unregister_esc = unregister_esc

return M
