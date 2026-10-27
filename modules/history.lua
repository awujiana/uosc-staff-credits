-- modules/history.lua
-- 搜索历史缓存模块
-- 按视频目录保存成功的搜索结果，LRU 淘汰策略
-- 持久化到 opts.history_path（默认 ~~/staff-credits-history.json）
-- 遵循 ADR-10 统一 init(opts, deps) 接口

local mp = require("mp")
local utils = require("mp.utils")
local msg = require("mp.msg")

local M = {}

local opts, deps, init = require("modules.utils.module_loader").make_init(
    "history",
    {}
)
M.init = init

-- 引用基础设施
local utils_mod = require("modules.utils")
local io_mod = require("modules.utils.io")

-- LRU 配置（来自 defaults.lua）
local MAX_ENTRIES = 5000
local EVICT_TARGET_RATIO = 0.9  -- 淘汰到 90%（4500 条）

-- 缓存解析后的历史表，避免每次都读文件
local cache = nil
local cache_dirty = false

-- 获取历史文件路径（展开 ~~ 等）
local function history_path()
    if not opts.history_path or opts.history_path == "" then
        return mp.command_native({"expand-path", "~~/staff-credits-history.json"})
    end
    return mp.command_native({"expand-path", opts.history_path})
end

-- 从磁盘加载历史表
local function load_from_disk()
    local path = history_path()
    if not path or not io_mod.file_exists(path) then
        return {}
    end
    local content = io_mod.read_file(path)
    if not content or content == "" then
        return {}
    end
    local data = utils.parse_json(content)
    if type(data) ~= "table" then
        msg.warn("[history] failed to parse history file: " .. tostring(path))
        return {}
    end
    return data
end

-- 内部：确保 cache 已加载
local function ensure_cache()
    if cache == nil then
        cache = load_from_disk()
    end
    return cache
end

-- 内部：标记 cache 已修改，待写回
local function mark_dirty()
    cache_dirty = true
end

-- 内部：将 cache 写回磁盘
local function flush_to_disk()
    if not cache_dirty then return true end
    if cache == nil then return true end
    local path = history_path()
    if not path then return false end
    local ok = io_mod.write_json_file(path, cache)
    if ok then
        cache_dirty = false
    else
        msg.warn("[history] failed to write history file: " .. tostring(path))
    end
    return ok
end

-- 内部：LRU 淘汰
-- 当记录数超过 MAX_ENTRIES，按 _ts 时间戳排序，删除最旧的直到 <= 目标值
local function enforce_lru()
    if cache == nil then return end
    -- 仅统计数据记录（排除 _schema_version 等元字段）
    local entries = {}
    for key, val in pairs(cache) do
        if type(val) == "table" and key ~= "_schema_version" then
            table.insert(entries, {key = key, ts = val._ts or 0})
        end
    end
    if #entries <= MAX_ENTRIES then return end

    local target = math.floor(MAX_ENTRIES * EVICT_TARGET_RATIO)
    -- 升序排序（最旧在前）
    table.sort(entries, function(a, b) return a.ts < b.ts end)
    local to_remove = #entries - target
    for i = 1, to_remove do
        cache[entries[i].key] = nil
    end
    mark_dirty()
    msg.debug(string.format("[history] LRU evicted %d entries (had %d, target %d)",
        to_remove, #entries, target))
end

-- get: 读取指定目录的历史记录
-- dir: 视频所在目录路径（由调用方通过 utils.get_parent_directory 获取）
-- 返回 record table 或 nil
function M.get(dir)
    if not dir then return nil end
    ensure_cache()
    local rec = cache[dir]
    if type(rec) ~= "table" then return nil end
    return rec
end

-- save: 保存或更新一条历史记录
-- dir: 目录路径作为 key
-- data: 记录内容（table），将原样保存；自动追加 _ts 时间戳
function M.save(dir, data)
    if not dir or type(data) ~= "table" then return false end
    ensure_cache()
    -- 复制以避免外部修改影响 cache
    local rec = {}
    for k, v in pairs(data) do
        rec[k] = v
    end
    rec._ts = mp.get_time()
    cache[dir] = rec
    enforce_lru()
    mark_dirty()
    return flush_to_disk()
end

-- remove: 删除指定目录的历史记录
-- 返回 true 若删除了记录，false 若不存在
function M.remove(dir)
    if not dir then return false end
    ensure_cache()
    if cache[dir] == nil then return false end
    cache[dir] = nil
    mark_dirty()
    return flush_to_disk()
end

-- clear_all: 清空所有历史记录
function M.clear_all()
    cache = {}
    mark_dirty()
    return flush_to_disk()
end

-- get_all: 返回完整历史表（只读副本）
function M.get_all()
    ensure_cache()
    -- 返回浅拷贝避免外部修改污染 cache
    local copy = {}
    for k, v in pairs(cache) do
        copy[k] = v
    end
    return copy
end

-- flush: 强制写回磁盘（用于路径切换等关键时机）
function M.flush()
    return flush_to_disk()
end

return M
