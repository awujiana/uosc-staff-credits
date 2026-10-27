-- modules/runtime_config.lua
-- 运行时配置持久化模块
-- 持久化到 ~~/staff-credits-runtime-config.json，合并优先级: runtime_config > opts > defaults
-- 遵循 ADR-10 统一 init(opts, deps) 接口；持久化采用 200ms 防抖 + 临时文件原子替换

local mp = require("mp")
local msg = require("mp.msg")
local utils = require("mp.utils")

local M = {}

local opts, deps, init = require("modules.utils.module_loader").make_init(
    "runtime_config",
    { notify = "table" }
)
M.init = init

local CONFIG_FILE = "~~/staff-credits-runtime-config.json"
local runtime_data = {}
local persist_timer = nil
-- 共享 opts 表的引用（由 apply_persisted 记下）。save() 同步写它，
-- 使读 deps.opts 的模块（features 层）**当场**生效。
local shared_opts = nil
local persisted_loaded = false

-- read_persisted: 读并解析持久化文件。文件缺失/为空/解析失败一律返回空表。
local function read_persisted()
    local path = mp.command_native({"expand-path", CONFIG_FILE})
    if not path or path == "" then return {} end
    local f = io.open(path, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return {} end
    local ok, data = pcall(utils.parse_json, content)
    if ok and type(data) == "table" then return data end
    return {}
end

-- 持久化（200ms 防抖，临时文件 + rename 原子写入）
local function persist()
    if persist_timer then
        pcall(function() mp.cancel_timer(persist_timer) end)
    end
    persist_timer = mp.add_timeout(0.2, function()
        persist_timer = nil
        -- 2026-10-05 修正：原写法 {"command", "expand-path", ...} 是错的。
        --   mp.command_native 要求**命令名直接作为第一个元素**，
        --   多包一层 "command" 会返回 nil（mpv 会报 "Command 'command' not found"）。
        --   后果：path 恒为 nil → 下一行的守卫直接 return → 配置持久化**静默失效**。
        --   已在真机验证：错误写法返回 nil，正确写法返回展开后的路径字符串。
        local path = mp.command_native({"expand-path", CONFIG_FILE})
        if not path or path == "" then return end
        local tmp_path = path .. ".tmp"
        local json_str = utils.format_json(runtime_data)
        local f = io.open(tmp_path, "w")
        if not f then return end
        f:write(json_str)
        f:close()
        os.remove(path)
        local ok = os.rename(tmp_path, path)
        if not ok then
            pcall(function() os.remove(tmp_path) end)
        end
    end)
end

-- 覆盖 init：先调用 base_init 注入 opts/deps，再触发 load
local base_init = init
function M.init(new_opts, new_deps)
    base_init(new_opts, new_deps)
    M.load()
end

-- apply_persisted: 读持久化文件，并把它**并入调用方给的那张表**。
--
-- ⚠️ 为什么必须由 bootstrap 在**任何模块 init 之前**调用：
--   module_loader.make_init 做的是 `shallow_merge(opts, new_opts)` ——
--   它把调用方的 opts **浅拷贝**进模块自己的一张表。一旦某模块 init 过，
--   它的副本就固定了；之后再改那张共享 opts 都传导不到它。
--   所以持久化值必须在**第一次 init 之前**并进共享 opts。
--
--   （此前只在 M.load() 里合并 runtime_config **自己的私有副本**，
--     对 data_cache / cards / cover_intro 等模块完全无效 —— 见 §11.11。）
--
-- target: 要并入的表（bootstrap 的共享 opts）。返回实际读到的持久化表。
function M.apply_persisted(target)
    if not persisted_loaded then
        runtime_data = read_persisted()
        persisted_loaded = true
    end
    if type(target) == "table" then
        shared_opts = target
        for k, v in pairs(runtime_data) do
            target[k] = v
        end
    end
    return runtime_data
end

-- load: 模块自身 init 时调用（保持向后兼容）。
-- 走同一条 apply_persisted 路径；若 bootstrap 已提前并入，则不重复读文件。
function M.load()
    M.apply_persisted(opts)
end

-- save: 更新单个配置项并持久化（200ms 防抖）；同时更新 opts 运行时值
-- key: string；value: string/number/boolean
--
-- 写三处：
--   1. runtime_data        —— 让 get() 立刻返回新值（设置菜单据此显示）
--   2. 本模块私有 opts      —— 本模块内可见
--   3. shared_opts（共享表）—— 读 deps.opts 的 features 层**当场**生效
--      （例如 progress_sync 读 deps.opts.progress_sync_mode）
-- 注意：读**自己私有副本**的模块（data_cache / cards / cover_intro）
--   本次会话内不会变，要**重启**才生效 —— 这正是文档承诺的「下次启动仍然生效」。
function M.save(key, value)
    if type(key) ~= "string" or key == "" then return end
    runtime_data[key] = value
    if type(opts) == "table" then
        opts[key] = value
    end
    if type(shared_opts) == "table" then
        shared_opts[key] = value
    end
    persist()
end

-- get: 获取配置项（合并优先级: runtime_config > opts > defaults），无则 nil
function M.get(key)
    if runtime_data[key] ~= nil then
        return runtime_data[key]
    end
    if type(opts) == "table" then
        return opts[key]
    end
    return nil
end

-- get_all: 获取所有运行时配置（返回 runtime_data 表的浅拷贝）
function M.get_all()
    local copy = {}
    for k, v in pairs(runtime_data) do
        copy[k] = v
    end
    return copy
end

return M
