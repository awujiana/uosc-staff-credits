-- app/state.lua
-- 应用状态表（纯数据模块）
-- 遵循 DESIGN.md 第 5 节：loading_state / search_state 关注点分离（ADR-03）
-- 所有权规则（FF-4 单写者）：
--   loading_state.*         唯一写者 loading_controller
--   search_state.current_path 唯一写者 dispatcher（path observer）
--   last_subject_by_path    features 通过 setter
--   cover_intro_cache       features 通过 setter
-- 本模块为纯数据 + setter，不持有任何业务逻辑，无需 init

local mp = require("mp")
local msg = require("mp.msg")

local M = {}

-- ============ 三大状态结构 ============

-- 加载流程状态（唯一写者：loading_controller）
M.loading_state = {
    loading = false,           -- 是否正在加载
    loading_timer = nil,       -- mp.add_periodic_timer 句柄
    loading_start_time = 0,    -- 计算剩余时间的起点
    loading_menu_type = nil,   -- 当前加载菜单类型
}

-- 搜索流程状态（current_path 唯一写者：dispatcher）
M.search_state = {
    current_path = nil,        -- 当前视频路径
    last_search_query = nil,   -- 最近一次搜索关键词
    last_subject_by_path = {}, -- 按 path 隔离的条目缓存
    cover_intro_cache = {},    -- 封面缓存（TTL 30 分钟）
}

-- ============ 6 个 setter 方法 ============
-- 设计原则：setter 仅做简单赋值，读取操作仍直接访问字段

-- set_current_path: 设置当前视频路径（dispatcher path observer 调用）
function M.set_current_path(path)
    M.search_state.current_path = path
end

-- set_last_search_query: 记录最近一次搜索关键词
function M.set_last_search_query(query)
    M.search_state.last_search_query = query
end

-- set_last_subject: 缓存指定路径的条目信息
-- path: 视频路径作为 key
-- info: 条目信息表 {id, name, name_cn, url, _ts, ...}
function M.set_last_subject(path, info)
    if not path then return end
    M.search_state.last_subject_by_path[path] = info
end

-- clear_search_state: 清除指定路径的条目缓存
function M.clear_search_state(path)
    if not path then return end
    M.search_state.last_subject_by_path[path] = nil
end

-- set_cover_intro_cache: 缓存指定标题的封面简介
-- key: 通常为标题字符串
-- cache: 缓存内容表，应包含 _ts 时间戳
function M.set_cover_intro_cache(key, cache)
    if not key then return end
    M.search_state.cover_intro_cache[key] = cache
end

-- clear_cover_intro_cache: 清除指定 key 的封面缓存
function M.clear_cover_intro_cache(key)
    if not key then return end
    M.search_state.cover_intro_cache[key] = nil
end

-- ============ 读取方法 ============

-- get_last_subject: 读取指定路径的缓存条目，不存在返回 nil
function M.get_last_subject(path)
    if not path then return nil end
    return M.search_state.last_subject_by_path[path]
end

-- ============ 缓存清理函数 ============
-- 由 dispatcher 的 path observer 触发

-- cleanup_search_cache: 超阈值清空 last_subject_by_path，仅保留当前路径条目
-- current_path: 当前视频路径（其缓存将被保留）
-- max_entries: 上限阈值，默认 50
function M.cleanup_search_cache(current_path, max_entries)
    max_entries = tonumber(max_entries) or 50
    local cache = M.search_state.last_subject_by_path
    -- 统计条目数
    local count = 0
    for _ in pairs(cache) do
        count = count + 1
    end
    if count <= max_entries then return end
    -- 超阈值：清空所有，仅保留当前路径条目
    local keep = cache[current_path]
    M.search_state.last_subject_by_path = {}
    if keep ~= nil then
        M.search_state.last_subject_by_path[current_path] = keep
    end
    msg.debug(string.format("[state] cleanup_search_cache: purged %d entries, kept current_path=%s",
        count, tostring(current_path)))
end

-- cleanup_cover_intro_cache: 删除过期的封面缓存
-- 每个缓存条目应含 _ts 时间戳；超过 ttl_seconds 视为过期
-- ttl_seconds: 默认 1800（30 分钟）
function M.cleanup_cover_intro_cache(ttl_seconds)
    ttl_seconds = tonumber(ttl_seconds) or 1800
    local cache = M.search_state.cover_intro_cache
    local now = mp.get_time()
    local removed = 0
    for key, entry in pairs(cache) do
        if type(entry) == "table" then
            local ts = entry._ts or 0
            if (now - ts) > ttl_seconds then
                cache[key] = nil
                removed = removed + 1
            end
        else
            -- 非表结构视为无效，直接清除
            cache[key] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then
        msg.debug(string.format("[state] cleanup_cover_intro_cache: removed %d expired entries", removed))
    end
end

return M
