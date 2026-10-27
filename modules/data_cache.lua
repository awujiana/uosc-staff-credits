-- modules/data_cache.lua
-- 本地持久化数据缓存模块
-- 缓存所有 API 响应数据到 ~~/staff-credits-data-cache.json
-- 含 LRU 淘汰（200→180）与 TTL 过期（data_cache_days）机制
-- 遵循 ADR-10 统一 init(opts, deps) 接口；持久化采用 200ms 防抖 + 临时文件原子替换

local mp = require("mp")
local msg = require("mp.msg")
local utils = require("mp.utils")

local M = {}

local opts, deps, init = require("modules.utils.module_loader").make_init(
    "data_cache",
    { notify = "table" }
)
M.init = init

-- 缓存文件路径
local CACHE_FILE = "~~/staff-credits-data-cache.json"

-- 内存缓存表
local cache_data = {}

-- 防抖定时器
local persist_timer = nil

-- 所有数据类型（用于 remove_path 批量删除）
local DATA_TYPES = { "characters", "persons", "detail", "production_score", "subject" }

-- 计算 path_hash: DJB2 变种，取低 16 位（4 位十六进制）
local function compute_path_hash(path)
    if type(path) ~= "string" or path == "" then return "" end
    local hash = 5381
    for i = 1, #path do
        hash = (hash * 33 + path:byte(i)) % 65536
    end
    return string.format("%04X", hash)
end

-- 从磁盘加载缓存到内存表
local function load_from_disk()
    cache_data = {}
    local path = mp.command_native({"expand-path", CACHE_FILE})
    if not path or path == "" then return end
    local f = io.open(path, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return end
    local ok, data = pcall(utils.parse_json, content)
    if ok and type(data) == "table" then
        cache_data = data
    else
        msg.warn("[data_cache] failed to parse cache file: " .. tostring(path))
    end
end

-- 实际写入逻辑（无防抖，供 persist 与 clear_all 复用）
-- v1.7.1: format_json 包 pcall 保护，避免任何 JSON 序列化异常导致脚本进程崩溃
local function do_persist()
    local path = mp.command_native({"expand-path", CACHE_FILE})
    if not path or path == "" then return end
    local tmp_path = path .. ".tmp"
    -- v1.7.1: pcall 保护 format_json（数字键/循环引用/不可序列化类型都会抛错）
    local ok_fmt, json_str = pcall(utils.format_json, cache_data)
    if not ok_fmt or not json_str or json_str == "" then
        msg.warn("[data_cache] format_json failed, skip persist: " .. tostring(json_str))
        return
    end
    local f = io.open(tmp_path, "w")
    if not f then return end
    f:write(json_str)
    f:close()
    os.remove(path)
    local ok = os.rename(tmp_path, path)
    if not ok then
        pcall(function() os.remove(tmp_path) end)
    end
end

-- 持久化（200ms 防抖）
local function persist()
    if persist_timer then
        pcall(function() mp.cancel_timer(persist_timer) end)
    end
    persist_timer = mp.add_timeout(0.2, function()
        persist_timer = nil
        do_persist()
    end)
end

-- LRU 淘汰：超过 200 条时按时间戳删除最旧条目，删到 180 条
local function enforce_lru()
    local count = 0
    for _ in pairs(cache_data) do count = count + 1 end
    if count <= 200 then return end
    local entries = {}
    for k, v in pairs(cache_data) do
        if type(v) == "table" then
            table.insert(entries, {key = k, ts = v._ts or 0})
        end
    end
    table.sort(entries, function(a, b) return a.ts < b.ts end)
    local to_remove = count - 180
    for i = 1, to_remove do
        if entries[i] then
            cache_data[entries[i].key] = nil
        end
    end
    msg.debug(string.format("[data_cache] LRU evicted %d entries (had %d, target 180)",
        to_remove, count))
end

-- save: 写入缓存
-- path: 视频路径; data_type: "characters"/"persons"/"detail"/"production_score"/"subject"
-- data: 要缓存的数据（table）
-- v1.7.1: 修复 utils.format_json 遇数字键崩溃 BUG
--   原因: persons/characters 数据是数组 [{id=1,...}, ...]，浅拷贝后 entry 含数字键，
--         utils.format_json 要求所有键必须是字符串，遇数字键抛 "key must be a string"，
--         导致整个 uosc_staff_credits 脚本进程被 mpv 销毁。
--   修复: 统一用 { items = data, _ts = ... } 包装，确保顶层只有字符串键。
function M.save(path, data_type, data)
    if not opts or opts.enable_data_cache == false then return nil end
    if type(data) ~= "table" then return nil end
    local path_hash = compute_path_hash(path)
    if path_hash == "" then return nil end
    local key = path_hash .. "_" .. tostring(data_type or "")
    -- v1.7.1: 用 items 包装避免数字键污染顶层（format_json 要求字符串键）
    local entry = {
        items = data,
        _ts = mp.get_time(),
    }
    cache_data[key] = entry
    enforce_lru()
    persist()
    return true
end

-- load: 读取缓存
-- 返回缓存数据（table）或 nil；超过 TTL 返回 nil
-- v1.7.1: 还原 items 包装，兼容旧格式（直接 entry 含数字键的情况）
function M.load(path, data_type)
    if not opts or opts.enable_data_cache == false then return nil end
    local path_hash = compute_path_hash(path)
    if path_hash == "" then return nil end
    local key = path_hash .. "_" .. tostring(data_type or "")
    local entry = cache_data[key]
    if type(entry) ~= "table" then return nil end
    -- TTL 检查：data_cache_days <= 0 表示永不过期
    local days = opts.data_cache_days or 7
    if days > 0 then
        local age = mp.get_time() - (entry._ts or 0)
        if age > days * 86400 then return nil end
    end
    -- v1.7.1: 优先返回 items 字段（新格式）；兼容旧格式直接返回剥离 _ts 的 entry
    if entry.items ~= nil then
        return entry.items
    end
    -- 旧格式兼容：剥离 _ts，返回剩余字段
    local result = {}
    for k, v in pairs(entry) do
        if k ~= "_ts" then result[k] = v end
    end
    return result
end

-- remove_path: 删除指定路径的所有缓存（5 种 data_type）
function M.remove_path(path)
    local path_hash = compute_path_hash(path)
    if path_hash == "" then return end
    local changed = false
    for _, dt in ipairs(DATA_TYPES) do
        local key = path_hash .. "_" .. dt
        if cache_data[key] ~= nil then
            cache_data[key] = nil
            changed = true
        end
    end
    if changed then persist() end
end

-- clear_all: 清空所有缓存并立即持久化
function M.clear_all()
    cache_data = {}
    do_persist()
end

-- has_cache: 检查缓存是否存在（不检查 TTL，仅检查键存在）
function M.has_cache(path, data_type)
    local path_hash = compute_path_hash(path)
    if path_hash == "" then return false end
    local key = path_hash .. "_" .. tostring(data_type or "")
    return cache_data[key] ~= nil
end

-- 覆盖 init：先调用 base_init 注入 opts/deps，再从磁盘加载缓存
local base_init = init
function M.init(new_opts, new_deps)
    base_init(new_opts, new_deps)
    load_from_disk()
end

return M
