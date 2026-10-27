-- features/subject_select.lua
-- 条目选择编排：手动搜索 + 结果展示 + 选中后缓存
-- 遵循 ADR-09：dispatcher 仅路由，业务下沉 features
-- 用于自动搜索失败时让用户手动选择条目，选中后写入缓存供其他 feature 复用
-- 使用 make_feature_init（无 opts）

local mp = require("mp")

local M = {}

local deps, init = require("modules.utils.module_loader").make_feature_init(
    "subject_select",
    {
        notify = "table",
        state = "table",
        menu = "table",
        api = "table",
        name_resolver = "table",
        loading_controller = "table",
        request_registry = "table",
        search_pipeline = "table",
        history = "table",
        get_danmaku_info = "function",
        get_current_title = "function",
    }
)
M.init = init

-- 引用基础设施
local path_mod = require("modules.utils.path")

-- ============ 内部辅助 ============

-- 获取可用 bangumi 服务器 URL 列表
local function get_bangumi_servers()
    if deps.servers and type(deps.servers.get_active_bangumi_servers) == "function" then
        return deps.servers.get_active_bangumi_servers() or {}
    end
    return {}
end

-- 从 subject.url 提取服务器 origin
local function server_from_url(url)
    if type(url) ~= "string" or url == "" then return nil end
    return url:match("^(https?://[^/]+)")
end

-- 构造可缓存的条目信息
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

-- 将选中的条目写入历史 + 状态缓存
-- subject: 条目表（含 id/name/name_cn/url）
local function cache_selected_subject(subject)
    local info = build_subject_info(subject)
    if not info then return false end

    local path = mp.get_property("path")
    -- 写入 state（按路径）
    if path and deps.state and type(deps.state.set_last_subject) == "function" then
        pcall(deps.state.set_last_subject, path, info)
    end
    -- 写入 history（按目录）
    if path and not path_mod.is_protocol(path) then
        local ok, dir = pcall(path_mod.get_parent_directory, path)
        if ok and dir and deps.history
           and type(deps.history.save) == "function" then
            pcall(deps.history.save, dir, info)
        end
    end
    return true
end

-- ============ 公共接口 ============

-- show_bgm_search_panel: 展示搜索输入面板
-- suggestion: 预填的搜索建议（通常为当前标题），可为 nil
-- source: 数据源标识
-- 流程：
--   1. 获取原始 suggestion（调用统一接口 resolve_title_sync，4 级优先级）
--   2. **本地**做一次繁→简转换，把转换结果作为预填（零延迟、零网络）
--   3. 立即显示面板
--   4. 仍非简体时异步走网络转换，成功后 update_menu 更新
-- v1.6: 复用 search_pipeline.resolve_title_sync 统一标题获取逻辑
--       （独立于 uosc_danmaku，未暴露时也能通过文件名解析 + 中文转换获取中文标题）
--
-- 2026-10-05 修正：原来直接拿原始标题预填，导致搜索框里显示的是
--   「無職転生 III」这种**繁体日文原名**（用户截图所见）。
--   现在第 2 步先用 title_normalize 本地转换 —— 这一步是纯查表，没有 IO，
--   可以同步做，从而彻底消除「先显示错标题再刷新」的闪烁。
function M.show_bgm_search_panel(suggestion, source)
    if deps.notify and deps.notify.set_tag then deps.notify.set_tag("BGM 搜索") end
    if not deps.menu or type(deps.menu.show_search_panel) ~= "function" then
        if deps.notify then deps.notify.error("菜单模块未就绪") end
        return
    end
    -- 若未提供 suggestion，调用统一接口获取基础标题（4 级优先级）
    if (not suggestion or suggestion == "")
       and deps.search_pipeline
       and type(deps.search_pipeline.resolve_title_sync) == "function" then
        suggestion = deps.search_pipeline.resolve_title_sync()
    end

    -- 2. 本地繁→简（同步、零网络），让预填内容立刻就是简体
    local local_title = suggestion
    if local_title and local_title ~= "" then
        local ok, tn = pcall(require, "modules.title_normalize")
        if ok and tn and type(tn.to_simplified) == "function" then
            local converted = tn.to_simplified(local_title)
            if converted and converted ~= "" then
                local_title = converted
            end
        end
    end

    -- 3. 立即显示面板（预填已简体化）
    deps.menu.show_search_panel(local_title, source)

    -- 4. 仍非简体（含日文假名 / 字典未覆盖的繁体）时，异步走网络转换
    local need_online = true
    if local_title and local_title ~= "" then
        local ok, tn = pcall(require, "modules.title_normalize")
        if ok and tn and type(tn.is_simplified_chinese) == "function" then
            need_online = not tn.is_simplified_chinese(local_title)
        end
    end
    if need_online
       and suggestion and suggestion ~= ""
       and deps.search_pipeline
       and type(deps.search_pipeline.resolve_chinese_title) == "function" then
        deps.search_pipeline.resolve_chinese_title(suggestion, function(chinese_title)
            -- 转换成功且与当前预填不同，更新面板
            if chinese_title and chinese_title ~= ""
               and chinese_title ~= local_title then
                -- 同类型菜单用 update-menu 避免闪烁（menu.show_search_panel 内部自动选择）
                deps.menu.show_search_panel(chinese_title, source)
            end
        end)
    end
end

-- search_subject: 执行搜索并展示结果
-- query: 搜索关键词
-- source: 数据源标识（用于结果回调路由）
-- subject_type: 可选，Bangumi 类别过滤（来自 `名称|ds/dy/dm` 后缀）
--               1=TV/动画 2=电视剧 3=剧场版；nil = 不过滤
function M.search_subject(query, source, subject_type)
    if not query or query == "" then
        if deps.notify then deps.notify.warn("搜索关键词为空") end
        return
    end

    deps.state.set_last_search_query(query)

    local servers = get_bangumi_servers()
    if #servers == 0 then
        if deps.notify then deps.notify.error("未配置可用的 Bangumi 服务器") end
        return
    end

    if deps.notify then deps.notify.info("正在搜索: " .. query) end
    -- 加载来源提示：搜索中
    if deps.notify and type(deps.notify.show_click_hint) == "function" then
        pcall(deps.notify.show_click_hint, "BGM 搜索", "搜索中...")
    end

    deps.api.search_subject_parallel(query, servers, function(success, results, err_info)
        if not success then
            local msg_str = "搜索失败"
            if err_info and err_info.msg then msg_str = err_info.msg end
            if deps.notify then deps.notify.error(msg_str) end
            return
        end
        -- 类别过滤（`名称|ds/dy/dm` 后缀）
        if subject_type and type(results) == "table" then
            local filtered = {}
            for _, r in ipairs(results) do
                -- Bangumi 搜索结果里类别字段名可能是 type / subject_type
                local t = (type(r) == "table") and (r.type or r.subject_type) or nil
                if t == nil or tonumber(t) == subject_type then
                    filtered[#filtered + 1] = r
                end
            end
            -- 过滤后为空则回退到全集（避免把用户搜成 0 结果）
            if #filtered > 0 then results = filtered end
        end
        -- 加载来源提示：搜索完成
        if deps.notify and type(deps.notify.show_click_hint) == "function" then
            local count = (type(results) == "table") and #results or 0
            pcall(deps.notify.show_click_hint, "BGM 搜索", "从 Bangumi 加载 " .. count .. " 条结果")
        end
        M.show_search_results(results, source)
    end)
end

-- show_search_results: 展示搜索结果列表
-- results: 搜索结果数组
-- source: 数据源标识
function M.show_search_results(results, source)
    if not results or #results == 0 then
        if deps.notify then deps.notify.warn("未找到匹配结果") end
        return
    end
    if not deps.menu or type(deps.menu.show_search_results) ~= "function" then
        if deps.notify then deps.notify.error("菜单模块未就绪") end
        return
    end
    deps.menu.show_search_results(results, source)
end

-- handle_bgm_select: 处理从搜索结果中选中条目
-- id: 选中的条目 id
-- source: 数据源标识
function M.handle_bgm_select(id, source)
    if not id then
        if deps.notify then deps.notify.warn("未提供条目 id") end
        return
    end

    local servers = get_bangumi_servers()
    if #servers == 0 then
        if deps.notify then deps.notify.error("未配置可用的 Bangumi 服务器") end
        return
    end
    local server_url = servers[1]

    if deps.notify then deps.notify.info("正在获取条目详情...") end
    -- 加载来源提示：获取详情中
    if deps.notify and type(deps.notify.show_click_hint) == "function" then
        pcall(deps.notify.show_click_hint, "BGM 搜索", "加载详情中...")
    end

    deps.api.get_subject_detail(id, server_url, function(success, detail, err_info)
        if not success or not detail then
            local msg_str = "获取条目详情失败"
            if err_info and err_info.msg then msg_str = err_info.msg end
            if deps.notify then deps.notify.error(msg_str) end
            return
        end

        -- 加载来源提示：详情加载完成
        if deps.notify and type(deps.notify.show_click_hint) == "function" then
            pcall(deps.notify.show_click_hint, "BGM 搜索", "从 Bangumi 加载详情")
        end

        -- 写入缓存
        if cache_selected_subject(detail) then
            local name = deps.name_resolver.resolve(detail)
            if deps.notify then deps.notify.info("已选择: " .. name) end
        else
            if deps.notify then deps.notify.warn("条目缓存失败") end
        end
    end)
end

-- handle_staff_select: 备选选中处理（直接使用已有 subject 信息，无需再次请求详情）
-- subject: 已有的条目表（含 id/name/name_cn/url）
-- source: 数据源标识
function M.handle_staff_select(subject, source)
    if type(subject) ~= "table" or not subject.id then
        if deps.notify then deps.notify.warn("条目信息无效") end
        return
    end
    if cache_selected_subject(subject) then
        local name = deps.name_resolver.resolve(subject)
        if deps.notify then deps.notify.info("已选择: " .. name) end
    else
        if deps.notify then deps.notify.warn("条目缓存失败") end
    end
end

return M
