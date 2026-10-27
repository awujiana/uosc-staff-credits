-- features/progress_sync.lua
-- 观看进度同步 —— 把当前这一集标记到你的 Bangumi 收藏（需要 bangumi_token）
--
-- ============================================================================
-- 它解决什么问题
-- ============================================================================
-- 看番时不用再切到网页去点「看过」。菜单里点一下即可。
--
-- ============================================================================
-- 三个前置条件（缺一不可，缺了就明确告诉用户缺哪个）
-- ============================================================================
--   1. 配了 bangumi_token（script-opts/uosc_staff_credits.conf）
--   2. 当前视频已经识别出 Bangumi 条目（即执行过一次搜索，state 里按 path 缓存了 id）
--   3. 能从文件名推断出集数（modules/guess.get_episode_number）
--
-- 为什么必须有第 2 条：标记「看过」用的是 Bangumi 的 **episode_id**，
-- 而 episode_id 只能由 subject_id + 集数 推出来（见 apis/bangumi_user.resolve_episode_id）。
-- 没有 subject_id 就无从下手，硬猜只会标错条目 —— 宁可不动。
--
-- ============================================================================
-- progress_sync_mode 的三档语义
-- ============================================================================
--   off    （默认）只在手动点菜单时联网。打开视频**不产生任何网络请求**。
--   notify 打开视频后读一次收藏状态并提示「在看 · 已看 N/M 集」。
--   auto   notify 的基础上，播放进度达到 progress_sync_threshold%（默认 80）
--          后自动把本集标为看过。每个视频只自动标一次。
--
-- 为什么 auto 要卡进度阈值：一打开文件就标记会把「点错、看了 30 秒就关掉」
-- 也算成看过，把用户的收藏记录弄脏。阈值让「真的看完了」才记。
--
-- ============================================================================
-- 安全
-- ============================================================================
-- token 只在 apis/bangumi_user 里拼进 Authorization 头，本模块**碰不到** token，
-- 也不打印任何请求细节，避免把凭证带进日志。

local mp = require("mp")

local M = {}

local deps, init = require("modules.utils.module_loader").make_feature_init(
    "progress_sync",
    {
        notify = "table",
        state = "table",
        guess = "table",
        bangumi_user = "table",
        opts = "table",
        script_name = "string",
    }
)
M.init = init

-- ============================================================================
-- 模块状态
-- ============================================================================
local auto_timer = nil          -- auto 模式的周期检查定时器
local auto_marked = {}          -- path -> true，防止同一视频重复自动标记
local AUTO_TICK_SECONDS = 10    -- auto 模式的检查周期

local function log(fmt, ...)
    if deps.notify and type(deps.notify.debug) == "function" then
        pcall(deps.notify.debug, "[progress_sync] " .. string.format(fmt, ...))
    end
end

local function info(text)
    if deps.notify and type(deps.notify.info) == "function" then
        pcall(deps.notify.info, text)
    end
end

local function warn(text)
    if deps.notify and type(deps.notify.warn) == "function" then
        pcall(deps.notify.warn, text)
    end
end

-- ============================================================================
-- 上下文读取
-- ============================================================================

-- current_path: 当前视频路径（优先用 state 里的单一真相来源）
local function current_path()
    if deps.state and deps.state.search_state then
        local p = deps.state.search_state.current_path
        if p and p ~= "" then return p end
    end
    return mp.get_property("path")
end

-- current_subject_id: 当前路径已缓存的 Bangumi 条目 id
local function current_subject_id()
    local p = current_path()
    if not p or not deps.state or type(deps.state.get_last_subject) ~= "function" then
        return nil
    end
    local ok, cached = pcall(deps.state.get_last_subject, p)
    if not ok or type(cached) ~= "table" or not cached.id then return nil end
    return tonumber(cached.id)
end

-- current_episode_number: 从当前文件名推断集数
local function current_episode_number()
    local p = current_path()
    if not p or p == "" then return nil end
    if not deps.guess or type(deps.guess.get_episode_number) ~= "function" then
        return nil
    end
    local _, fname = mp.utils.split_path(p)
    if not fname or fname == "" then return nil end
    fname = fname:gsub("%.[%w]+$", "")      -- 去掉扩展名
    local ok, n = pcall(deps.guess.get_episode_number, fname, nil)
    if not ok or type(n) ~= "number" then return nil end
    return n
end

-- is_enabled: 是否配了 token 且开关打开
function M.is_enabled()
    return deps.bangumi_user ~= nil
        and type(deps.bangumi_user.is_enabled) == "function"
        and deps.bangumi_user.is_enabled() == true
end

-- available: 是否具备标记条件
-- 返回 (ok, reason)
function M.available()
    if not M.is_enabled() then
        return false, "未配置 bangumi_token"
    end
    if not current_subject_id() then
        return false, "尚未识别出 Bangumi 条目（先执行一次搜索）"
    end
    if not current_episode_number() then
        return false, "无法从文件名识别集数"
    end
    return true, nil
end

-- describe_current: 给菜单 hint 用的一行描述
function M.describe_current()
    local sid = current_subject_id()
    local ep = current_episode_number()
    if sid and ep then
        return string.format("条目 %s · 第 %s 集", tostring(sid), tostring(ep))
    end
    return nil
end

-- ============================================================================
-- 主菜单条目
-- ============================================================================
-- 未配 token 时返回空表 —— 功能不可用时不该在主菜单里留一条死项，
-- 那只会让用户反复点、反复困惑。配了 token 但暂时不可用（没搜索过 / 认不出集数）
-- 则显示为置灰项 + 说明原因，这样用户知道**为什么**点不了。
function M.build_menu_items()
    if not M.is_enabled() then return {} end

    local script_name = deps.script_name or ""
    local ok, reason = M.available()
    local items = {}

    if ok then
        items[#items + 1] = {
            title = "标记本集为看过",
            icon = "check_circle",
            hint = M.describe_current() .. " · 写入 Bangumi 收藏",
            value = "script-message-to " .. script_name .. " staff-credits-mark-watched",
            keep_open = false,
        }
        items[#items + 1] = {
            title = "查看观看进度",
            icon = "timeline",
            hint = M.describe_current() .. " · 读取收藏状态",
            value = "script-message-to " .. script_name .. " staff-credits-show-progress",
            keep_open = false,
        }
    else
        items[#items + 1] = {
            title = "标记本集为看过",
            icon = "check_circle",
            hint = "暂不可用：" .. tostring(reason),
            italic = true,
            unselectable = true,
            keep_open = true,
        }
    end

    return items
end

-- ============================================================================
-- 读取进度
-- ============================================================================
-- read_progress: 读当前条目的收藏状态与已看集数
-- callback(success, text, err_info)；text 是给人看的一行摘要
function M.read_progress(callback)
    local sid = current_subject_id()
    if not sid then
        if callback then callback(false, nil, "尚未识别出 Bangumi 条目") end
        return
    end
    deps.bangumi_user.get_collection(sid, function(ok, coll, err)
        if not ok then
            if callback then callback(false, nil, err and err.msg or "读取失败") end
            return
        end
        local ctype = coll and coll.type
        if not ctype or tonumber(ctype) == 0 then
            if callback then callback(true, "尚未收藏该条目", coll) end
            return
        end
        local text = deps.bangumi_user.describe_collection_type(ctype)
        if coll.ep_status then
            text = text .. " · 已看 " .. tostring(coll.ep_status) .. " 集"
        end
        if callback then callback(true, text, coll) end
    end)
end

-- show_progress: 读并提示
function M.show_progress()
    if not M.is_enabled() then
        warn("未配置 bangumi_token，无法读取观看进度")
        return
    end
    M.read_progress(function(ok, text, err)
        if ok then
            info("Bangumi 进度：" .. tostring(text))
        else
            warn("读取观看进度失败：" .. tostring(err))
        end
    end)
end

-- ============================================================================
-- 标记本集为看过
-- ============================================================================
-- mark_current_episode: 完整编排
-- callback(success, info_table, err_text)
function M.mark_current_episode(callback)
    local ok_avail, reason = M.available()
    if not ok_avail then
        warn("无法标记：" .. tostring(reason))
        if callback then callback(false, nil, reason) end
        return
    end

    local sid = current_subject_id()
    local ep = current_episode_number()

    -- 集数 → episode_id（内部会拉取并缓存剧集列表）
    deps.bangumi_user.resolve_episode_id(sid, ep, function(ok, episode_id, err)
        if not ok then
            warn("标记失败：" .. tostring(err and err.msg or "解析集数失败"))
            if callback then callback(false, nil, err and err.msg) end
            return
        end
        -- 先确保条目本身已收藏，再标集（mark_episode_watched 内部会处理）
        deps.bangumi_user.mark_episode_watched(sid, episode_id, function(ok2, info2, err2)
            if not ok2 then
                warn("标记失败：" .. tostring(err2 and err2.msg or "写入失败"))
                if callback then callback(false, nil, err2 and err2.msg) end
                return
            end
            info(string.format("已标记为看过：条目 %s 第 %s 集", tostring(sid), tostring(ep)))
            if callback then
                callback(true, {
                    subject_id = sid,
                    episode_id = episode_id,
                    episode_number = ep,
                }, nil)
            end
        end)
    end)
end

-- ============================================================================
-- 自动模式（file-loaded 之后调用）
-- ============================================================================

local function stop_auto_timer()
    if auto_timer then
        pcall(function() auto_timer:kill() end)
        auto_timer = nil
    end
end

-- auto_tick: 检查播放进度是否达到阈值
local function auto_tick()
    local p = current_path()
    if not p or auto_marked[p] then
        stop_auto_timer()
        return
    end
    local threshold = tonumber(deps.opts and deps.opts.progress_sync_threshold) or 80
    local pos = mp.get_property_number("percent-pos", 0) or 0
    if pos < threshold then return end
    auto_marked[p] = true
    stop_auto_timer()
    log("播放进度 %.1f%% ≥ %d%%，自动标记", pos, threshold)
    M.mark_current_episode(nil)
end

-- on_file_loaded: 由 dispatcher 在文件加载后调用
-- path: 当前视频路径（nil 表示无文件）
--
-- ⚠️ 为什么不「等固定 3 秒再读」：条目 id 是**搜索**出来的，而搜索要多久取决于
--    网络与数据源。写死延时要么太短（还没搜到就问 Bangumi，白跑一趟）、
--    要么太长（用户已经切走了）。改为**轮询等待**条目出现，有上限、可中断。
local READY_POLL_SECONDS = 2
local READY_POLL_MAX = 8          -- 最多等 16 秒

function M.on_file_loaded(path)
    stop_auto_timer()
    if not M.is_enabled() then return end
    if not path or path == "" then return end

    local mode = deps.opts and deps.opts.progress_sync_mode or "off"
    if mode == "off" then
        -- 默认档：打开视频**不产生任何网络请求**
        return
    end

    local tries = 0
    local waiter = nil

    local function wait_ready()
        tries = tries + 1
        -- 期间换台了 → 放弃
        if current_path() ~= path then
            if waiter then pcall(function() waiter:kill() end) end
            return
        end
        if not current_subject_id() and tries < READY_POLL_MAX then
            return                       -- 还没搜到条目，下一拍再看
        end
        if waiter then pcall(function() waiter:kill() end) end
        waiter = nil

        if not current_subject_id() then
            log("等不到条目识别结果，跳过进度同步")
            return
        end

        M.read_progress(function(ok, text, err)
            if not ok then
                log("读进度失败: %s", tostring(err))
                return
            end
            info("Bangumi 进度：" .. tostring(text))
        end)

        if mode == "auto" and not auto_marked[path] then
            auto_timer = mp.add_periodic_timer(AUTO_TICK_SECONDS, auto_tick)
        end
    end

    waiter = mp.add_periodic_timer(READY_POLL_SECONDS, wait_ready)
end

-- ============================================================================
-- 清理（供「清除所有缓存」调用）
-- ============================================================================
function M.clear_cache()
    auto_marked = {}
    stop_auto_timer()
    if deps.bangumi_user and type(deps.bangumi_user.clear_episode_cache) == "function" then
        pcall(deps.bangumi_user.clear_episode_cache)
    end
end

-- 仅供测试观察
M._current_subject_id = current_subject_id
M._current_episode_number = current_episode_number

return M
