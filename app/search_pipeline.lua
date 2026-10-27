-- app/search_pipeline.lua
-- 搜索管线协调器（业务逻辑层核心）
-- 遵循 DESIGN.md 第 7 节：多源增强搜索 / 数据源优先级 / 通用管线协调
-- ADR-01：从 main.lua 抽离搜索编排逻辑
--
-- 三个公共接口：
--   search_subject_enhanced       多源增强搜索（dandanplay + extra + bangumi）
--   fetch_characters_from_source  数据源优先级获取角色（bangumi → 多源分发）
--   run_subject_pipeline          通用 7 步管线（4 个 feature 共用）

local mp = require("mp")
local msg = require("mp.msg")

local M = {}

local opts, deps, init = require("modules.utils.module_loader").make_init(
    "search_pipeline",
    {
        api = "table",
        dandanplay = "table",
        extra = "table",
        anilist = "table",
        mal = "table",
        baike = "table",
        guess = "table",
        notify = "table",
        servers = "table",
        state = "table",
        request_registry = "table",
        menu = "table",
        history = "table",
        name_resolver = "table",
        loading_controller = "table",
        get_danmaku_info = "function",
        get_current_title = "function",
        debug_log = "function",
    }
)
M.init = init

-- 引用基础设施
local utils_mod = require("modules.utils")
local path_mod = require("modules.utils.path")
-- 2026-10-05：标题规范化（繁体→简体 + 「已是简体」判定）
-- 修正「繁体/日文标题被判为已是中文 → 从不送去转换」的静默失效，详见模块头部注释
local title_normalize = require("modules.title_normalize")

-- ============ 内部辅助 ============

local function make_err(code, m)
    return { code = code or "ERR_EMPTY", msg = tostring(m or "") }
end

local function debug_log(...)
    if deps.debug_log then pcall(deps.debug_log, ...) end
end

-- ============ 中文标题转换（集成 uosc_danmaku 思路）============
-- 当标题非中文时，优先调用 dandanplay/extra 获取中文候选
-- dandanplay API 返回的 animeTitle 默认即中文译名
-- TMDB 中文译名通过 extra.search_tmdb 获取（需配置 tmdb_api_key）

-- resolve_chinese_title: 非中文/繁体标题转换为中文
-- title: 原始标题
-- callback(chinese_title): 转换完成回调，参数为中文标题（转换失败返回原标题）
--
-- 2026-10-05 修正（重要）：
--   原实现第一句是 `if utils_mod.is_chinese(title) then return title end`，
--   而 is_chinese 用字节区间 [\228-\233] 判「含汉字」—— E4..E9 恰好覆盖
--   **全部** CJK 汉字（简/繁/日文汉字都一样），于是：
--       無職転生 → is_chinese = true → 直接返回 → **永远不转换**
--   这就是「搜索框填的是繁体日文原名、搜不到中文条目」的根因。
--
--   修正分三步：
--     1. 先用 title_normalize 做**本地**繁体→简体转换（零网络开销）
--     2. 若本地转换已产出不含繁体的简体标题 → 直接用它，省掉网络往返
--     3. 否则（仍含繁体 / 是外文）再走网络多源转换，且优先用**简体化后**
--        的标题去搜（服务端对简体关键词的匹配率更高）
local function resolve_chinese_title(title, callback)
    if not title or title == "" then
        if callback then callback(title) end
        return
    end

    -- 步骤 1：本地繁体→简体
    local simplified, changed = title_normalize.normalize(title)
    if changed then
        debug_log("resolve_chinese_title: 繁→简 本地转换: %s => %s", title, simplified)
    end

    -- 步骤 2：本地转换后已是简体中文 → 无需任何网络请求
    -- 注意这里用 is_simplified_chinese 而非 is_chinese：
    -- 后者只能判「含汉字」，会把繁体也当成已是中文（这正是原 bug）
    if title_normalize.is_simplified_chinese(simplified) then
        debug_log("resolve_chinese_title: already simplified chinese, skip: %s", simplified)
        if callback then callback(simplified) end
        return
    end

    debug_log("resolve_chinese_title: need online conversion: %s", simplified)

    -- 步骤 3：仍需网络转换时，用「简体化后的标题」作为查询关键词
    local query = simplified

    -- 并发调用 dandanplay + extra，取首个中文候选
    local pending = 0
    local done = false
    local best_candidate = nil

    local function try_finish()
        if done then return end
        if pending > 0 then return end
        done = true
        if best_candidate and best_candidate ~= "" then
            debug_log("resolve_chinese_title: converted to: %s", best_candidate)
            if callback then callback(best_candidate) end
        else
            -- 网络转换失败：至少回落到本地繁体→简体结果（优于原样返回繁体）
            debug_log("resolve_chinese_title: conversion failed, fallback to: %s", query)
            if callback then callback(query) end
        end
    end

    -- 数据源 1: dandanplay（返回中文 animeTitle）
    if deps.dandanplay and type(deps.dandanplay.search) == "function" then
        pending = pending + 1
        deps.dandanplay.search(query, function(success, candidates, _err_info)
            pending = pending - 1
            if success and type(candidates) == "table" then
                for _, c in ipairs(candidates) do
                    -- 候选也可能带繁体，统一简体化后再判定
                    if type(c) == "string" and c ~= "" then
                        local cs = title_normalize.to_simplified(c)
                        if title_normalize.is_simplified_chinese(cs) then
                            if not best_candidate then best_candidate = cs end
                            break
                        end
                    end
                end
            end
            try_finish()
        end)
    end

    -- 数据源 2: extra（TMDB 中文译名 + 360kan）
    if deps.extra and type(deps.extra.search) == "function" then
        pending = pending + 1
        deps.extra.search(query, function(success, candidates, _err_info)
            pending = pending - 1
            if success and type(candidates) == "table" then
                for _, c in ipairs(candidates) do
                    if type(c) == "string" and c ~= "" then
                        local cs = title_normalize.to_simplified(c)
                        if title_normalize.is_simplified_chinese(cs) then
                            if not best_candidate then best_candidate = cs end
                            break
                        end
                    end
                end
            end
            try_finish()
        end)
    end

    -- 无可用数据源，直接返回原标题
    if pending == 0 then
        done = true
        if callback then callback(title) end
    end
end
M.resolve_chinese_title = resolve_chinese_title

-- build_subject_info: 从 subject 构造可缓存的最小条目信息
-- v1.6: 保留 _source 字段，避免缓存命中时 fetch_and_show 用错数据源的接口
local function build_subject_info(subject)
    if type(subject) ~= "table" then return nil end
    local info = {
        id = subject.id,
        name = subject.name,
        name_cn = subject.name_cn,
        url = subject.url,
        _ts = mp.get_time(),
    }
    -- 保留数据源标识（anilist/mal/baike/bangumi），缺失时默认 "bangumi"
    if type(subject._source) == "string" and subject._source ~= "" then
        info._source = subject._source
    else
        info._source = "bangumi"
    end
    return info
end

-- ============ 统一标题解析入口（v1.6）============
-- 解决各 feature 标题获取逻辑不一致问题，提供统一的 4 级优先级 + 中文转换流程
-- 即使 uosc_danmaku 未暴露，也能通过文件名解析 + 中文转换获取中文标题

-- resolve_title_sync: 同步获取基础标题（4 级优先级）
-- 1. 弹幕关联中文名（uosc_danmaku 实时属性或历史文件，未暴露时返回 nil）
-- 2. subject 缓存中文名（静默预加载或之前搜索的结果，独立于 uosc_danmaku）
-- 3. 文件名解析（guess.parse_title，从 path 提取番剧名）
-- 4. media-title 兜底（URL 等特殊情况）
-- 返回: title (string), season_num (number|nil)
function M.resolve_title_sync()
    local title = nil
    local season_num = nil

    -- 1. 弹幕关联中文名（可能因 uosc_danmaku 未暴露而返回 nil）
    --    弹幕API返回的 animeTitle 已含季数信息（如"平凡职业造就世界最强第三季"），
    --    直接用作搜索标题，无需本地季数解析
    if deps.get_danmaku_info then
        local ok, dinfo = pcall(deps.get_danmaku_info)
        if ok and type(dinfo) == "table" and dinfo.anime and dinfo.anime ~= "" then
            title = dinfo.anime
        end
    end

    -- 2. subject 缓存中文名（独立于 uosc_danmaku，静默预加载或之前搜索的结果）
    if (not title or title == "") and deps.state then
        local cur_path = mp.get_property("path")
        if cur_path then
            local cached = deps.state.get_last_subject and deps.state.get_last_subject(cur_path)
            if cached and type(cached.name_cn) == "string" and cached.name_cn ~= "" then
                title = cached.name_cn
            end
        end
    end

    -- 3. 文件名解析（确保无 uosc_danmaku 也能获取番剧名）
    if (not title or title == "") and deps.get_current_title then
        local ok, t, s = pcall(deps.get_current_title)
        if ok and t and t ~= "" then
            title = t
            season_num = s
        end
    end

    -- 4. media-title 兜底（URL 等特殊情况）
    if not title or title == "" then
        title = mp.get_property("media-title") or ""
    end

    -- 极端情况下仍无标题，使用固定占位符
    if not title or title == "" then
        title = "未知条目"
    end

    return title, season_num
end

-- resolve_display_title: 异步获取显示标题（含中文转换）
-- 流程：
--   1. 调用 resolve_title_sync 获取基础标题
--   2. 已本地转成简体中文，直接 callback
--   3. 否则调用 resolve_chinese_title 转换（dandanplay + extra 并发）
--   4. 转换失败则返回「本地简体化」的标题
-- callback(chinese_title, season_num): 转换完成回调
--
-- 2026-10-05 修正：原用 is_chinese 判「已是中文」→ 繁体标题被跳过转换。
--   改用 is_simplified_chinese（详见 title_normalize 模块注释）。
function M.resolve_display_title(callback)
    local base_title, season_num = M.resolve_title_sync()

    -- 本地先做一次繁→简，再判定是否还需要网络转换
    local simplified = title_normalize.to_simplified(base_title)

    if title_normalize.is_simplified_chinese(simplified) then
        debug_log("resolve_display_title: already simplified chinese: %s", simplified)
        if callback then callback(simplified, season_num) end
        return
    end

    -- 仍需转换的标题，交给 resolve_chinese_title（其内部会再做一次本地简体化）
    debug_log("resolve_display_title: need conversion: %s", simplified)
    resolve_chinese_title(base_title, function(chinese_title)
        local final = chinese_title or simplified
        if callback then callback(final, season_num) end
    end)
end

-- resolve_cached_title: 缓存条目标题兜底统一入口
-- 用于 on_cached_hit 场景：缓存条目可能缺少有效标题（name/name_cn 均为空），
-- 此时调用 resolve_display_title 获取中文标题作为兜底。
-- 流程：
--   1. 优先使用缓存条目的 name_cn / name 字段（若为非空字符串）
--   2. 缓存无有效标题时调用 resolve_display_title（4 级优先级 + 中文转换）
--   3. 路径校验：异步回调时检查 current_path 是否仍为 entry_path，避免污染
--   4. resolve_display_title 不可用时回退到 media-title，再兜底 "未知条目"
-- cached: 历史缓存条目（table，含 name/name_cn 字段，可能为 nil 或空字符串）
-- entry_path: 调用方进入时的 mp.get_property("path")，用于异步回调路径校验
-- callback(title): 获取到标题后的回调（title 始终为非空字符串）
function M.resolve_cached_title(cached, entry_path, callback)
    if type(callback) ~= "function" then return end

    -- 1. 优先使用缓存条目的有效标题
    local cached_title = ""
    if type(cached) == "table" then
        if type(cached.name_cn) == "string" and cached.name_cn ~= "" then
            cached_title = cached.name_cn
        elseif type(cached.name) == "string" and cached.name ~= "" then
            cached_title = cached.name
        end
    end
    if cached_title ~= "" then
        callback(cached_title)
        return
    end

    -- 2. 缓存无有效标题：调用 resolve_display_title 获取中文标题
    if type(M.resolve_display_title) == "function" then
        M.resolve_display_title(function(display_title, _season_num)
            -- 路径校验：防止异步回调污染（entry_path 为 nil 时跳过校验）
            if entry_path and deps.state and deps.state.search_state
               and deps.state.search_state.current_path ~= entry_path then
                return
            end
            -- display_title 理论上不会为空（resolve_title_sync 有 "未知条目" 兜底），但仍防御
            local final = display_title
            if not final or final == "" then final = mp.get_property("media-title") or "未知条目" end
            callback(final)
        end)
        return
    end

    -- 3. resolve_display_title 不可用：回退到 media-title，再兜底 "未知条目"
    local fallback = mp.get_property("media-title") or "未知条目"
    callback(fallback)
end

-- ============ 7.1 search_subject_enhanced ============
-- 多源增强搜索：dandanplay + extra 获取候选标题 → bangumi 并发搜索
-- 签名: search_subject_enhanced(title, season_num, callback, on_progress, skip_extra, subject_type)
-- 回调契约: callback(success, result, err_info)
--   result = {id, name, name_cn, url}
function M.search_subject_enhanced(title, season_num, callback, on_progress, skip_extra, subject_type)
    if not title or title == "" then
        if callback then callback(false, nil, make_err("ERR_EMPTY", "empty title")) end
        return
    end

    if on_progress then on_progress("searching") end

    local active_servers = {}
    if deps.servers and type(deps.servers.get_active_bangumi_servers) == "function" then
        active_servers = deps.servers.get_active_bangumi_servers() or {}
    end
    if #active_servers == 0 then
        if callback then callback(false, nil, make_err("ERR_NETWORK", "no bangumi servers configured")) end
        return
    end

    -- 决定是否跳过外部搜索
    local extra_enabled = opts.enable_extra_search ~= false
    local has_extra = (deps.dandanplay ~= nil) or (deps.extra ~= nil)
    local skip_external = (skip_extra == true) or (not extra_enabled) or (not has_extra)

    -- done 标志：防止重复回调
    local done = false
    -- 候选标题收集
    local candidates = {}
    local pending = 0

    -- select_best_subject: 从搜索结果中选择最佳匹配条目
    -- v1.8: 修复制作评分/职员表等自动搜索取 results[1] 可能选错季的问题
    --   1. 从查询标题中提取季数关键词（"第X季"/"Season X"），优先选择 name/name_cn 含该关键词的条目
    --   2. season_num 参数非空时，构造对应中文/英文季数关键词进行匹配
    --   3. 回退到 best_match_by_jw 字符串相似度
    --   4. 兜底取首个结果
    -- results: 搜索结果数组（每个元素含 id/name/name_cn/url）
    -- query_title: 实际用于搜索的标题（可能含季数信息）
    -- season_num_param: 可选季数（数字或数字字符串）
    local cn_num_map = {["一"]=1,["二"]=2,["三"]=3,["四"]=4,["五"]=5,
                        ["六"]=6,["七"]=7,["八"]=8,["九"]=9,["十"]=10}
    local cn_nums = {"一","二","三","四","五","六","七","八","九","十"}

    local function select_best_subject(results, query_title, season_num_param)
        if not results or type(results) ~= "table" or #results == 0 then return nil end
        if #results == 1 then return results[1] end

        -- 收集季数关键词（来自查询标题 + season_num 参数）
        local season_keywords = {}

        -- 1a. 从查询标题提取"第X季"（X 为中文数字或阿拉伯数字）
        if type(query_title) == "string" and query_title ~= "" then
            local m = query_title:match("第([一二三四五六七八九十]+)季")
            if m then
                table.insert(season_keywords, "第" .. m .. "季")
                -- 同时加入阿拉伯数字形式（第3季）
                local n = cn_num_map[m]
                if n then table.insert(season_keywords, "第" .. tostring(n) .. "季") end
            else
                m = query_title:match("第(%d+)季")
                if m then
                    table.insert(season_keywords, "第" .. m .. "季")
                    local n = tonumber(m)
                    if n and cn_nums[n] then
                        table.insert(season_keywords, "第" .. cn_nums[n] .. "季")
                    end
                end
            end
            -- 1b. 从查询标题提取 "Season X" / "season X"
            local sm = query_title:match("[Ss]eason%s*(%d+)")
            if sm then
                table.insert(season_keywords, "Season " .. sm)
                table.insert(season_keywords, "season " .. sm)
                local n = tonumber(sm)
                if n and cn_nums[n] then
                    table.insert(season_keywords, "第" .. cn_nums[n] .. "季")
                end
            end
        end

        -- 1c. season_num 参数构造关键词
        if season_num_param ~= nil then
            local n = tonumber(season_num_param)
            if n and n >= 1 and n <= 10 then
                table.insert(season_keywords, "第" .. tostring(n) .. "季")
                table.insert(season_keywords, "第" .. cn_nums[n] .. "季")
                table.insert(season_keywords, "Season " .. tostring(n))
            end
        end

        -- 2. 优先选择 name/name_cn 包含季数关键词的条目
        if #season_keywords > 0 then
            for _, r in ipairs(results) do
                local name_cn = type(r.name_cn) == "string" and r.name_cn or ""
                local name = type(r.name) == "string" and r.name or ""
                for _, kw in ipairs(season_keywords) do
                    if name_cn:find(kw, 1, true) or name:find(kw, 1, true) then
                        debug_log("select_best_subject: matched by season keyword %q in %q",
                            kw, name_cn ~= "" and name_cn or name)
                        return r
                    end
                end
            end
        end

        -- 3. 回退：best_match_by_jw 字符串相似度
        if deps.guess and type(deps.guess.best_match_by_jw) == "function" then
            local cand_names = {}
            for _, r in ipairs(results) do
                table.insert(cand_names, r.name_cn or r.name or "")
            end
            local matched = deps.guess.best_match_by_jw(cand_names, query_title or "", 0.6)
            if matched and matched ~= "" then
                for _, r in ipairs(results) do
                    if (r.name_cn or r.name) == matched then
                        debug_log("select_best_subject: matched by jw score: %s", matched)
                        return r
                    end
                end
            end
        end

        -- 4. 兜底：取首个结果
        debug_log("select_best_subject: fallback to results[1]")
        return results[1]
    end

    -- try_multi_source_fallback: Bangumi 全部失败时的多源顺序兜底
    -- 构造与 bangumi subject 兼容的结构 {id, name, name_cn, url, _source}
    -- v1.6: 多源顺序兜底链
    -- 2026-10-07: 更名为 try_multi_source_fallback（原名 try_fankuhub_fallback）。
    --   该函数早已是通用链，名字却停留在「只有 fankuhub」的时代 —— 误导性命名。
    --   同时移除 fankuhub 源（用户决定不再使用），链变为 anilist → mal → baike。
    local function try_multi_source_fallback(query_title)
        -- v1.6: 多源兜底链定义（顺序尝试，任一成功即停止）
        -- 各数据源返回 results 数组，取首个构造 subject
        local fallback_sources = {}

        -- 1. anilist（无需认证）
        if deps.anilist and type(deps.anilist.search) == "function" then
            table.insert(fallback_sources, {
                name = "anilist",
                search_fn = function(q, cb) deps.anilist.search(q, cb) end,
            })
        end
        -- 2. mal（需配置 client_id）
        if deps.mal and type(deps.mal.is_available) == "function"
           and deps.mal.is_available()
           and type(deps.mal.search) == "function" then
            table.insert(fallback_sources, {
                name = "mal",
                search_fn = function(q, cb) deps.mal.search(q, cb) end,
            })
        end
        -- 3. baike（中文标题与简介兜底）
        if deps.baike and type(deps.baike.search) == "function" then
            table.insert(fallback_sources, {
                name = "baike",
                search_fn = function(q, cb) deps.baike.search(q, cb) end,
            })
        end

        if #fallback_sources == 0 then
            done = true
            if callback then callback(false, nil, make_err("ERR_NETWORK", "所有数据源均不可用")) end
            return
        end

        -- 顺序尝试各数据源
        local source_idx = 1
        local function try_next_source()
            if done then return end
            if source_idx > #fallback_sources then
                -- 所有数据源均失败
                done = true
                if callback then callback(false, nil, make_err("ERR_EMPTY", "所有数据源搜索失败")) end
                return
            end

            local src = fallback_sources[source_idx]
            debug_log("search_subject_enhanced: fallback trying %s: %s", src.name, query_title)
            src.search_fn(query_title, function(success, results, err_info)
                if done then return end
                if not success or not results or #results == 0 then
                    debug_log("search_subject_enhanced: %s fallback failed: %s",
                        src.name, (err_info and err_info.msg) or "no results")
                    source_idx = source_idx + 1
                    try_next_source()
                    return
                end
                -- v1.8: 用 select_best_subject 替代 results[1]，避免选错季
                local r = select_best_subject(results, query_title, season_num)
                if not r then
                    debug_log("search_subject_enhanced: %s fallback select_best_subject nil", src.name)
                    source_idx = source_idx + 1
                    try_next_source()
                    return
                end
                local subject = {
                    id = r.id,
                    name = r.name,
                    name_cn = r.name_cn or r.name,
                    url = r.url or ("https://" .. src.name .. ".com"),
                    _source = src.name,
                }
                done = true
                if on_progress then on_progress("detail") end
                if callback then callback(true, subject, nil) end
            end)
        end

        try_next_source()
    end

    -- try_bangumi_with_candidates: 用最佳候选发起 bangumi 并发搜索
    local function try_bangumi_with_candidates(cands)
        local best = title
        if cands and #cands > 0 and deps.guess
           and type(deps.guess.best_match_by_jw) == "function" then
            local matched = deps.guess.best_match_by_jw(cands, title, 0.6)
            if matched and matched ~= "" then
                best = matched
                debug_log("search_subject_enhanced: best candidate = " .. tostring(best))
            end
        end

        deps.api.search_subject_parallel(best, active_servers, function(success, results, err_info)
            if done then return end
            if not success then
                -- Bangumi 全部失败：走多源顺序兜底
                debug_log("search_subject_enhanced: bangumi search failed, trying multi-source fallback")
                try_multi_source_fallback(best)
                return
            end
            -- v1.8: 用 select_best_subject 替代 results[1]，根据标题中的季数信息筛选
            --   优先用原始 title（含"第X季"）匹配，season_num 作为辅助
            local result = nil
            if results and #results > 0 then
                result = select_best_subject(results, title, season_num)
            end
            if not result then
                -- 无结果：走多源顺序兜底
                debug_log("search_subject_enhanced: bangumi empty results, trying multi-source fallback")
                try_multi_source_fallback(best)
                return
            end
            done = true
            if on_progress then on_progress("detail") end
            if callback then callback(true, result, nil) end
        end)
    end

    if skip_external then
        -- 直接用原始标题搜索 bangumi
        try_bangumi_with_candidates(nil)
        return
    end

    -- 并发外部搜索（dandanplay + extra），收集候选标题
    if deps.dandanplay and type(deps.dandanplay.search) == "function" then
        pending = pending + 1
        deps.dandanplay.search(title, function(success, cands, err_info)
            if done then return end
            pending = pending - 1
            if success and type(cands) == "table" then
                for _, c in ipairs(cands) do
                    if type(c) == "string" and c ~= "" then
                        table.insert(candidates, c)
                    end
                end
            end
            if pending == 0 then
                try_bangumi_with_candidates(candidates)
            end
        end)
    end

    if deps.extra and type(deps.extra.search) == "function" then
        pending = pending + 1
        deps.extra.search(title, function(success, cands, err_info)
            if done then return end
            pending = pending - 1
            if success and type(cands) == "table" then
                for _, c in ipairs(cands) do
                    if type(c) == "string" and c ~= "" then
                        table.insert(candidates, c)
                    end
                end
            end
            if pending == 0 then
                try_bangumi_with_candidates(candidates)
            end
        end)
    end

    -- 若两个外部源均未发起（理论上不会，因 has_extra 已校验），直接 bangumi
    if pending == 0 then
        try_bangumi_with_candidates(nil)
    end
end

-- ============ 7.2 fetch_characters_from_source ============
-- 数据源优先级获取角色：bangumi 优先（含图片），失败时走多源分发（anilist/mal/baike）
-- v1.9: 性能优化：
--   2. bangumi 路径中 get_subject_characters 与 get_subject_persons 并行请求（省去 2-5s）
--   3. 超时配置拆分：loading 显示超时 vs 网络请求超时
-- 2026-10-07: 移除 fankuhub 快速路径（用户决定不再使用）。原先它排在 bangumi
--   之前以省去 3-8s 的多源搜索；移除后角色获取一律先走 bangumi，
--   仅在 bangumi 不可用时才落到 anilist/mal/baike 分发链。
--
-- 签名: fetch_characters_from_source(title, season_num, on_progress, callback, skip_extra)
-- 回调契约: callback(success, characters, persons, err_info, source_name)
function M.fetch_characters_from_source(title, season_num, on_progress, callback, skip_extra)
    if not title or title == "" then
        if callback then callback(false, nil, nil, make_err("ERR_EMPTY", "empty title"), nil) end
        return
    end

    -- 路径校验基线：捕获进入时的 current_path
    local entry_path = deps.state.search_state.current_path
    local function check_path()
        return deps.state.search_state.current_path == entry_path
    end

    -- 完成成功：统一回调
    local function finish_success(chars, persons, source_name)
        if not check_path() then return end
        if callback then callback(true, chars, persons, nil, source_name) end
    end

    -- 全部失败
    local function finish_all_fail()
        if not check_path() then return end
        if callback then
            callback(false, nil, nil, make_err("ERR_EMPTY", "所有数据源均无结果"), nil)
        end
    end

    -- try_light_novel_fallback: 角色无图片时，搜索同名轻小说补图
    local function try_light_novel_fallback(chars, persons, subject, server_url, on_fail)
        if not check_path() then return end
        if not server_url or server_url == "" then
            finish_success(chars, persons, "bangumi")
            return
        end
        deps.api.search_light_novel(title, server_url, function(ln_ok, ln_results, ln_err)
            if not check_path() then return end
            if not ln_ok or not ln_results or #ln_results == 0 then
                -- 轻小说无结果：使用原始角色
                finish_success(chars, persons, "bangumi")
                return
            end
            -- 取首个轻小说条目，获取其角色图片
            local ln_subject = ln_results[1]
            deps.api.get_subject_characters(ln_subject.id, server_url, function(lc_ok, ln_chars, lc_err)
                if not check_path() then return end
                if lc_ok and ln_chars and #ln_chars > 0 then
                    -- 构建 id -> images 映射，补全原图
                    local img_map = {}
                    for _, lc in ipairs(ln_chars) do
                        if lc.id and lc.images then
                            img_map[lc.name] = lc.images
                        end
                    end
                    for _, c in ipairs(chars) do
                        if (not c.images) and img_map[c.name] then
                            c.images = img_map[c.name]
                        end
                    end
                end
                finish_success(chars, persons, "bangumi")
            end)
        end)
    end

    -- try_bangumi: bangumi 数据源获取角色
    -- v1.6: search_subject_enhanced 可能返回非 bangumi 来源的 subject
    --       （bangumi 全部失败时走了多源兜底）。此时 subject.id 不是数字 id，
    --       必须用该源自己的兼容接口，否则 bangumi API 会 404。
    local function try_bangumi(server_url, on_fail)
        if not check_path() then return end
        if not server_url or server_url == "" then
            on_fail()
            return
        end

        M.search_subject_enhanced(title, season_num, function(success, subject, err_info)
            if not check_path() then return end
            if not success or not subject then
                on_fail()
                return
            end

            -- 根据 subject 来源选择数据接口
            -- v1.6: 支持多数据源（anilist/mal/baike）的兼容接口
            -- 2026-10-07: 移除 fankuhub 分支（不再使用该数据源）
            local source = subject._source or "bangumi"
            local get_chars_fn, get_persons_fn, get_chars_arg, get_persons_arg

            if source == "anilist" and deps.anilist
               and type(deps.anilist.get_subject_characters_compatible) == "function"
               and type(deps.anilist.get_subject_persons_compatible) == "function" then
                get_chars_fn = deps.anilist.get_subject_characters_compatible
                get_persons_fn = deps.anilist.get_subject_persons_compatible
                get_chars_arg = subject.id
                get_persons_arg = subject.id
            elseif source == "mal" and deps.mal
               and type(deps.mal.get_subject_characters_compatible) == "function"
               and type(deps.mal.get_subject_persons_compatible) == "function" then
                get_chars_fn = deps.mal.get_subject_characters_compatible
                get_persons_fn = deps.mal.get_subject_persons_compatible
                get_chars_arg = subject.id
                get_persons_arg = subject.id
            elseif source == "baike" and deps.baike
               and type(deps.baike.get_subject_persons_compatible) == "function" then
                -- 百度百科 only supports persons, no characters
                get_chars_fn = function(_id, cb) cb(true, {}, nil) end
                get_persons_fn = deps.baike.get_subject_persons_compatible
                get_chars_arg = subject.id
                get_persons_arg = subject.id
            else
                -- bangumi 默认接口
                get_chars_fn = function(id, cb)
                    deps.api.get_subject_characters(id, server_url, cb)
                end
                get_persons_fn = function(id, cb)
                    deps.api.get_subject_persons(id, server_url, cb)
                end
                get_chars_arg = subject.id
                get_persons_arg = subject.id
            end

            -- v1.9: 并行获取角色列表 + 职员列表（原为串行，节省 2-5s）
            local cs_done = false
            local ps_done = false
            local cs_result = {ok=false, data=nil, err=nil}
            local ps_result = {ok=false, data=nil, err=nil}
            local function check_parallel_done()
                if not check_path() then return end
                if not cs_done or not ps_done then return end

                -- 两者都完成，合并结果
                local chars = (cs_result.ok and cs_result.data) or {}
                local persons = (ps_result.ok and ps_result.data) or {}

                if cs_result.ok and chars and #chars > 0 then
                    -- 角色有数据：直接使用（persons 可能为空但不影响展示）
                    local has_img = false
                    for _, c in ipairs(chars) do
                        if c.images then has_img = true; break end
                    end
                    if has_img then
                        finish_success(chars, persons, "bangumi")
                    else
                        try_light_novel_fallback(chars, persons, subject, server_url, on_fail)
                    end
                elseif ps_result.ok and persons and #persons > 0 then
                    -- 角色空但 persons 有数据：从 persons 解析角色（type=1）
                    local parsed = {}
                    for _, p in ipairs(persons) do
                        if p.type == deps.api.CHAR_TYPE_CHARACTER then
                            table.insert(parsed, p)
                        end
                    end
                    if #parsed == 0 then
                        on_fail()
                        return
                    end
                    local has_img = false
                    for _, c in ipairs(parsed) do
                        if c.images then has_img = true; break end
                    end
                    if has_img then
                        finish_success(parsed, persons, "bangumi")
                    else
                        try_light_novel_fallback(parsed, persons, subject, server_url, on_fail)
                    end
                else
                    -- 两者都失败
                    on_fail()
                end
            end

            -- 并行发起两个请求
            get_chars_fn(get_chars_arg, function(cs_ok, cs_data, cs_err)
                cs_done = true
                cs_result = {ok=cs_ok, data=cs_data, err=cs_err}
                check_parallel_done()
            end)
            get_persons_fn(get_persons_arg, function(ps_ok, ps_data, ps_err)
                ps_done = true
                ps_result = {ok=ps_ok, data=ps_data, err=ps_err}
                check_parallel_done()
            end)
        end, on_progress, skip_extra)
    end

    -- ============ 数据源分发 ============
    -- 2026-10-07: 移除 fankuhub 优先快速路径与 data_source 配置项（用户决定不再使用该数据源）。
    --   原先 v1.9.1 让角色获取**优先**试 fankuhub.search（一次请求返回角色+声优+图片），
    --   失败才回退到 bangumi / 多源分发。移除后一律走 dispatch_fallback：
    --   按 active_sources 顺序走 bangumi → 多源。
    local active_sources = {}
    if deps.servers and type(deps.servers.get_active_sources) == "function" then
        active_sources = deps.servers.get_active_sources() or {}
    end

    -- 数据源分发（active_sources 为空时直接走 bangumi）
    local function dispatch_fallback()
        if #active_sources == 0 then
            local servers = deps.servers.get_active_bangumi_servers() or {}
            try_bangumi(servers[1], finish_all_fail)
            return
        end

        -- 按优先级遍历数据源
        local function try_next(index)
            if not check_path() then return end
            if index > #active_sources then
                finish_all_fail()
                return
            end
            local source = active_sources[index]
            local function on_fail()
                try_next(index + 1)
            end
            -- 非 bangumi 源（含已移除的 fankuhub）统一走 bangumi 兼容路径：
            -- try_bangumi 内部会按 subject._source 选择该源自己的兼容接口
            try_bangumi(source.url, on_fail)
        end
        try_next(1)
    end

    dispatch_fallback()
end

-- ============ 7.3 run_subject_pipeline ============
-- 通用 7 步管线协调器，4 个 feature 入口共用
-- pipeline_opts:
--   menu_type              菜单类型标识
--   on_cached_hit(cached, entry_path)   缓存命中回调
--   search_fn(title, season_num, on_progress, on_done, skip_extra)  搜索函数
--   on_search_success(data, entry_path) 搜索成功回调
--   on_failure(err_info, entry_path)    可选，失败回调
--   keep_loading_after_search           true 时搜索完成用 transition_phase
--   skip_extra                          透传给 search_fn
function M.run_subject_pipeline(pipeline_opts)
    pipeline_opts = pipeline_opts or {}
    local menu_type = pipeline_opts.menu_type
    local on_cached_hit = pipeline_opts.on_cached_hit
    local search_fn = pipeline_opts.search_fn
    local on_search_success = pipeline_opts.on_search_success
    local on_failure = pipeline_opts.on_failure
    local keep_loading_after_search = pipeline_opts.keep_loading_after_search == true
    local skip_extra = pipeline_opts.skip_extra

    -- 1. 入口守卫：若 loading 已激活则先 finish 重置，然后 set_loading(true)
    if deps.state.loading_state.loading then
        deps.loading_controller.finish()
    end
    deps.loading_controller.set_loading(true)

    -- 2. 路径解析
    local path = mp.get_property("path")
    if not path or path == "" then
        if deps.menu and type(deps.menu.show_error_menu) == "function" then
            deps.menu.show_error_menu("无法获取当前播放路径", menu_type)
        elseif deps.notify then
            deps.notify.error("无法获取当前播放路径")
        end
        deps.loading_controller.finish()
        return
    end
    local entry_path = path

    -- 路径校验辅助
    local function check_path()
        return deps.state.search_state.current_path == entry_path
    end

    -- 3. 缓存查询：history.get(dir) 或 state.get_last_subject(path)
    local dir = nil
    if not path_mod.is_protocol(path) then
        local ok, d = pcall(path_mod.get_parent_directory, path)
        if ok then dir = d end
    end

    local cached = nil
    if dir and deps.history and type(deps.history.get) == "function" then
        cached = deps.history.get(dir)
    end
    if not cached then
        cached = deps.state.get_last_subject(path)
    end
    if cached then
        deps.loading_controller.finish_silent()
        if on_cached_hit then
            pcall(on_cached_hit, cached, entry_path)
        end
        return
    end

    -- 4. 标题识别（4 级优先级，与 resolve_title_sync 保持一致）
    --   1. 弹幕关联中文名（uosc_danmaku 实时属性，已含季数信息如"第三季"）
    --   2. subject 缓存中文名（静默预加载或之前搜索的结果，独立于 uosc_danmaku）
    --   3. 文件名解析（guess.parse_title）
    --   4. media-title 兜底
    local title = nil
    local season_num = nil
    if deps.get_danmaku_info then
        local ok, dinfo = pcall(deps.get_danmaku_info)
        if ok and type(dinfo) == "table" and dinfo.anime and dinfo.anime ~= "" then
            title = dinfo.anime
        end
    end
    -- v1.8: 补齐第 2 级 subject 缓存中文名（原先缺失，导致跳过缓存直接用文件名解析）
    if (not title or title == "") and deps.state then
        local cur_path = mp.get_property("path")
        if cur_path and deps.state.get_last_subject then
            local cached_subj = deps.state.get_last_subject(cur_path)
            if cached_subj and type(cached_subj.name_cn) == "string"
               and cached_subj.name_cn ~= "" then
                title = cached_subj.name_cn
            end
        end
    end
    if not title or title == "" then
        if deps.get_current_title then
            local ok, t, s = pcall(deps.get_current_title)
            if ok and t and t ~= "" then
                title = t
                season_num = s
            end
        end
    end
    if not title or title == "" then
        title = mp.get_property("media-title") or ""
    end
    if not title or title == "" then
        if deps.menu and type(deps.menu.show_error_menu) == "function" then
            deps.menu.show_error_menu("无法识别标题", menu_type)
        elseif deps.notify then
            deps.notify.error("无法识别标题")
        end
        deps.loading_controller.finish()
        return
    end

    -- 4.5 中文标题转换：非中文标题先转换为中文
    -- uosc_danmaku 历史记录中的 animeTitle 默认已是中文，无需转换
    -- 仅当从文件名解析出非中文标题时触发转换（dandanplay + TMDB）
    local function proceed_search(final_title)
        if not check_path() then return end

        -- 5. on_progress 回调
        local in_search_phase = false
        local function on_progress(message)
            if not check_path() then return end
            if message == "searching" then
                in_search_phase = true
                if deps.menu and type(deps.menu.show_loading_menu) == "function" then
                    deps.menu.show_loading_menu("正在搜索...", menu_type, final_title)
                end
            elseif message == "detail" then
                in_search_phase = false
                deps.loading_controller.show_with_countdown("正在获取详情...", menu_type, final_title, false)
            elseif in_search_phase then
                if deps.menu and type(deps.menu.show_loading_menu) == "function" then
                    deps.menu.show_loading_menu(message, menu_type, final_title)
                end
            else
                deps.loading_controller.show_with_countdown(message, menu_type, final_title, true)
            end
        end

        -- 6. on_done 回调（3 参契约: success, data, err_info）
        local function on_done(success, data, err_info)
            if not check_path() then return end

            if not success then
                -- 失败：结束加载 + 回退
                if keep_loading_after_search then
                    deps.loading_controller.transition_phase()
                else
                    deps.loading_controller.finish_silent()
                end
                if on_failure then
                    pcall(on_failure, err_info, entry_path)
                else
                    local err_msg = "搜索失败"
                    if err_info and err_info.msg and err_info.msg ~= "" then
                        err_msg = err_info.msg
                    end
                    if deps.menu and type(deps.menu.show_error_menu) == "function" then
                        deps.menu.show_error_menu(err_msg, menu_type)
                    elseif deps.notify then
                        deps.notify.error(err_msg)
                    end
                end
                return
            end

            -- 成功：选择结束方式
            if keep_loading_after_search then
                deps.loading_controller.transition_phase()
            else
                deps.loading_controller.finish_silent()
            end

            -- 写入历史 + 状态缓存（仅当 data 看起来是 subject 时）
            -- 校验：id 存在且 name/name_cn 至少一个为非空字符串（避免空标题污染缓存）
            if type(data) == "table" and data.id ~= nil then
                local has_name = (type(data.name) == "string" and data.name ~= "")
                    or (type(data.name_cn) == "string" and data.name_cn ~= "")
                if has_name then
                    local info = build_subject_info(data)
                    if info then
                        if dir and deps.history and type(deps.history.save) == "function" then
                            pcall(deps.history.save, dir, info)
                        end
                        pcall(deps.state.set_last_subject, path, info)
                    end
                end
            end

            if on_search_success then
                pcall(on_search_success, data, entry_path)
            end
        end

        -- 7. 调度搜索
        if not search_fn or type(search_fn) ~= "function" then
            deps.loading_controller.finish()
            return
        end
        search_fn(final_title, season_num, on_progress, on_done, skip_extra)
    end

    -- 触发中文标题转换，转换完成后继续搜索流程
    resolve_chinese_title(title, function(chinese_title)
        if not check_path() then return end
        if chinese_title and chinese_title ~= "" and chinese_title ~= title then
            debug_log("run_subject_pipeline: title converted %q -> %q", title, chinese_title)
            title = chinese_title
        end
        proceed_search(title)
    end)
end

return M
