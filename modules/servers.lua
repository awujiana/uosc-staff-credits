-- modules/servers.lua
-- 数据源优先级配置模块
-- 管理预设服务器列表，支持启用/禁用、拖动排序、schema 迁移、防抖保存
-- 持久化到 ~~/staff-credits-servers.json
-- 遵循 ADR-10 统一 init(opts, deps) 接口

local mp = require("mp")
local utils = require("mp.utils")
local msg = require("mp.msg")

local M = {}

local opts, deps, init = require("modules.utils.module_loader").make_init(
    "servers",
    {}
)
M.init = init

-- 引用基础设施
local utils_mod = require("modules.utils")
local io_mod = require("modules.utils.io")

-- 常量
local SCHEMA_VERSION = 5
local SERVERS_FILE = "~~/staff-credits-servers.json"
local DEBOUNCE_MS = 0.2  -- 200ms

-- 预设数据源池（顺序即默认优先级）
local PRESET_SERVERS = {
    {
        url = "https://api.bangumi.lol",
        note = "镜像(首选)",
        type = "bangumi",
        enabled = true,
        is_official = false,
    },
    {
        url = "https://api.bangumi.one",
        note = "镜像",
        type = "bangumi",
        enabled = true,
        is_official = false,
    },
    {
        url = "https://api.bgm.tv",
        note = "官方",
        type = "bangumi",
        enabled = true,
        is_official = true,
    },
}

-- 运行时服务器列表（已加载 + 迁移完成）
local servers = nil
-- 防抖定时器句柄
local save_timer = nil

-- 获取配置文件路径
local function servers_path()
    return mp.command_native({"expand-path", SERVERS_FILE})
end

-- 序列化：保留 _schema_version 字符串键
local function serialize_servers_config(list)
    local out = {
        _schema_version = SCHEMA_VERSION,
        servers = {},
    }
    for i, srv in ipairs(list or {}) do
        out.servers[i] = {
            url = srv.url,
            type = srv.type or "bangumi",
            enabled = srv.enabled ~= false,
            is_official = srv.is_official == true,
            note = srv.note or "",
        }
    end
    return out
end

-- ============ Schema 迁移 ============

-- v1 → v2: 补全 enabled / type / is_official 字段
local function migrate_v1_to_v2(list)
    for _, srv in ipairs(list) do
        if srv.enabled == nil then srv.enabled = true end
        if not srv.type or srv.type == "" then srv.type = "bangumi" end
        if srv.is_official == nil then
            srv.is_official = (srv.url and (
                srv.url:find("//api%.bgm%.tv") ~= nil
                or srv.url:find("//bangumi%.tv") ~= nil
                or srv.url:find("//bgm%.tv") ~= nil
            )) or false
        end
    end
    return list
end

-- v2 → v3: 补充缺失的预设数据源（历史版本曾追加 fankuhub，已于 v5 移除）
local function migrate_v2_to_v3(list)
    local existing_urls = {}
    for _, srv in ipairs(list) do
        if srv.url then existing_urls[srv.url] = true end
    end
    -- 仅追加缺失的预设，不改变现有顺序
    for _, preset in ipairs(PRESET_SERVERS) do
        if not existing_urls[preset.url] then
            local copy = {}
            for k, v in pairs(preset) do copy[k] = v end
            table.insert(list, copy)
        end
    end
    return list
end

-- v3 → v4: 在列表最前面插入 bangumi.lol 镜像（v4 schema 新增）
local function migrate_v3_to_v4(list)
    -- 检查 bangumi.lol 是否已存在（防止重复插入）
    for _, srv in ipairs(list) do
        if srv.url == "https://api.bangumi.lol" then
            return list
        end
    end
    -- 插入到最前面
    local preset_lol = {
        url = "https://api.bangumi.lol",
        note = "镜像(首选)",
        type = "bangumi",
        enabled = true,
        is_official = false,
    }
    table.insert(list, 1, preset_lol)
    return list
end

-- v4 → v5: 移除 fankuhub 数据源（2026-10-07，用户决定不再使用）
--
-- 为什么必须写迁移：老用户的 ~~/staff-credits-servers.json 里已经存在
-- type="fankuhub" 的条目（由 v2→v3 迁移追加，或首次运行用预设初始化时写入）。
-- 光删 PRESET_SERVERS 里的预设**对老用户无效** —— 文件已存在就不会再用预设。
-- 不清理的话，该条目会继续出现在「网站优先级」菜单里，并在
-- fetch_characters_from_source 的 active_sources 遍历中被尝试，
-- 拿 fankuhub 的 URL 去请求 bangumi API，白白失败一次。
local function migrate_v4_to_v5(list)
    local kept = {}
    for _, srv in ipairs(list) do
        local is_fankuhub = (srv.type == "fankuhub")
            or (type(srv.url) == "string" and srv.url:find("fankuhub%.com", 1, false) ~= nil)
        if not is_fankuhub then
            kept[#kept + 1] = srv
        end
    end
    return kept
end

-- 迁移入口：根据 from_version 选择迁移链
local function migrate_schema(list, from_version)
    if from_version < 2 then
        list = migrate_v1_to_v2(list)
    end
    if from_version < 3 then
        list = migrate_v2_to_v3(list)
    end
    if from_version < 4 then
        list = migrate_v3_to_v4(list)
    end
    if from_version < 5 then
        list = migrate_v4_to_v5(list)
    end
    return list
end

-- ============ 加载 / 保存 ============

-- 从磁盘加载配置，必要时执行 schema 迁移
local function load_servers()
    local path = servers_path()
    if not path or not io_mod.file_exists(path) then
        -- 首次运行：用预设初始化
        local fresh = {}
        for _, preset in ipairs(PRESET_SERVERS) do
            local copy = {}
            for k, v in pairs(preset) do copy[k] = v end
            table.insert(fresh, copy)
        end
        return fresh
    end

    local content = io_mod.read_file(path)
    if not content or content == "" then
        return {}
    end
    local data = utils.parse_json(content)
    if type(data) ~= "table" then
        msg.warn("[servers] failed to parse servers file, falling back to presets")
        local fresh = {}
        for _, preset in ipairs(PRESET_SERVERS) do
            local copy = {}
            for k, v in pairs(preset) do copy[k] = v end
            table.insert(fresh, copy)
        end
        return fresh
    end

    -- 兼容两种结构：{servers = [...]} 或直接 [...]
    local list
    local ver = 1
    if data._schema_version then
        ver = tonumber(data._schema_version) or 1
        list = data.servers or {}
    elseif data[1] then
        list = data
    else
        list = {}
    end

    -- 防御性：确保每条记录字段完整
    for _, srv in ipairs(list) do
        if srv.enabled == nil then srv.enabled = true end
        if not srv.type or srv.type == "" then srv.type = "bangumi" end
        if srv.is_official == nil then srv.is_official = false end
        if not srv.note then srv.note = "" end
    end

    if ver < SCHEMA_VERSION then
        list = migrate_schema(list, ver)
        msg.info(string.format("[servers] migrated schema v%d -> v%d", ver, SCHEMA_VERSION))
        -- 迁移后立即写回
        local serialized = serialize_servers_config(list)
        io_mod.write_json_file(path, serialized)
    end

    return list
end

-- 立即写回磁盘
local function save_immediate()
    if servers == nil then return false end
    local path = servers_path()
    if not path then return false end
    local serialized = serialize_servers_config(servers)
    local ok = io_mod.write_json_file(path, serialized)
    if not ok then
        msg.warn("[servers] failed to save servers file: " .. tostring(path))
    end
    return ok
end

-- ============ 公共接口 ============

-- 内部：确保已加载
local function ensure_loaded()
    if servers == nil then
        servers = load_servers()
    end
    return servers
end

-- get_all: 返回全部服务器（含禁用项）
function M.get_all()
    ensure_loaded()
    -- 返回浅拷贝列表
    local out = {}
    for i, srv in ipairs(servers) do
        local copy = {}
        for k, v in pairs(srv) do copy[k] = v end
        out[i] = copy
    end
    return out
end

-- get_active_bangumi_servers: 返回已启用的 Bangumi URL 列表（按优先级排序）
function M.get_active_bangumi_servers()
    ensure_loaded()
    local out = {}
    for _, srv in ipairs(servers) do
        if srv.enabled ~= false and srv.type == "bangumi" and srv.url then
            table.insert(out, srv.url)
        end
    end
    return out
end

-- get_active_sources: 返回已启用的数据源列表
-- 每项: {url, type, note, is_official}
function M.get_active_sources()
    ensure_loaded()
    local out = {}
    for _, srv in ipairs(servers) do
        if srv.enabled ~= false and srv.url then
            table.insert(out, {
                url = srv.url,
                type = srv.type or "bangumi",
                note = srv.note or "",
                is_official = srv.is_official == true,
            })
        end
    end
    return out
end

-- move: 拖动排序，从 from 索引移动到 to 索引（1-based）
function M.move(from, to)
    ensure_loaded()
    if type(from) ~= "number" or type(to) ~= "number" then return false end
    if from < 1 or from > #servers then return false end
    if to < 1 or to > #servers then return false end
    if from == to then return true end
    local item = table.remove(servers, from)
    table.insert(servers, to, item)
    M.save(false)
    return true
end

-- toggle: 切换某 URL 的启用状态
function M.toggle(url)
    ensure_loaded()
    if not url then return false end
    for _, srv in ipairs(servers) do
        if srv.url == url then
            srv.enabled = not srv.enabled
            M.save(false)
            return true
        end
    end
    return false
end

-- save: 持久化
-- immediate=true 立即保存；否则 200ms 防抖
function M.save(immediate)
    if immediate then
        if save_timer then
            save_timer:kill()
            save_timer = nil
        end
        return save_immediate()
    end
    -- 防抖
    if save_timer then
        save_timer:kill()
    end
    save_timer = mp.add_timeout(DEBOUNCE_MS, function()
        save_timer = nil
        save_immediate()
    end)
    return true
end

-- build_menu_items: 构建 uosc 菜单项列表
-- 每项: {icon, title=value(URL), hint=note, active=enabled}
function M.build_menu_items()
    ensure_loaded()
    local items = {}
    for _, srv in ipairs(servers) do
        local icon = srv.enabled ~= false and "check_box" or "check_box_outline_blank"
        local hint = srv.note or ""
        if srv.type and srv.type ~= "bangumi" then
            hint = hint .. " [" .. srv.type .. "]"
        end
        if srv.is_official then
            hint = hint .. " (官方)"
        end
        table.insert(items, {
            icon = icon,
            title = srv.url or "",
            value = srv.url or "",
            hint = hint,
            active = srv.enabled ~= false,
        })
    end
    return items
end

-- init 包装：调用 make_init 返回的 init 后，立即加载服务器列表
-- 供 bootstrap 在 init 后立即调用，避免首次访问时延迟加载
function M.init_and_load(new_opts, new_deps)
    init(new_opts, new_deps)
    servers = load_servers()
end

return M
