-- modules/utils/module_loader.lua
-- 模块工厂函数
-- 遵循 DESIGN.md 2.2 节，提供 4 个工厂函数：
--   make_init(name, deps_schema)         -> (opts, deps, init)
--   make_feature_init(name, deps_schema) -> (deps, init)
--   make_set_opts(initial)               -> (opts, set_opts)
--   safe_require(name, optional)         -> module or nil
-- 所有 init 函数支持单次初始化保护和 deps schema 校验（仅 warn 不阻断）

local msg = require("mp.msg")

local M = {}

-- safe_require: pcall 保护的 require
-- optional=true 时失败仅 warn 并返回 nil；optional=false/nil 时也返回 nil 但 error 级别日志
function M.safe_require(name, optional)
    local ok, mod = pcall(require, name)
    if not ok then
        if optional then
            msg.warn("[module_loader] optional module '" .. tostring(name) .. "' failed: " .. tostring(mod))
        else
            msg.error("[module_loader] required module '" .. tostring(name) .. "' failed: " .. tostring(mod))
        end
        return nil
    end
    return mod
end

-- 内部：deps schema 校验（仅 warn 不阻断）
local function validate_deps(name, deps_schema, deps)
    if not deps_schema then return end
    if type(deps) ~= "table" then return end
    for key, expected_type in pairs(deps_schema) do
        local actual = deps[key]
        if actual ~= nil and type(actual) ~= expected_type then
            msg.warn(string.format(
                "[module_loader] %s: deps.%s expected %s, got %s",
                tostring(name), tostring(key), tostring(expected_type), type(actual)
            ))
        end
    end
end

-- 内部：浅合并 src 到 dst
local function shallow_merge(dst, src)
    if type(dst) ~= "table" then dst = {} end
    if type(src) ~= "table" then return dst end
    for k, v in pairs(src) do
        dst[k] = v
    end
    return dst
end

-- make_init: 标准模块 init 工厂
-- 返回 (opts, deps, init) 三元组
-- init(new_opts, new_deps) 将参数合并到 opts/deps upvalue
-- 单次初始化保护：重复调用仅 warn
-- deps_schema 校验：类型不匹配仅 warn 不阻断
function M.make_init(name, deps_schema)
    local opts = {}
    local deps = {}
    local initialized = false

    local function init(new_opts, new_deps)
        if initialized then
            msg.warn("[module_loader] " .. tostring(name) .. " already initialized, skipping")
            return
        end
        initialized = true
        if type(new_opts) == "table" then
            shallow_merge(opts, new_opts)
        end
        if type(new_deps) == "table" then
            shallow_merge(deps, new_deps)
        end
        validate_deps(name, deps_schema, deps)
    end

    return opts, deps, init
end

-- make_feature_init: features 层 init 工厂
-- 返回 (deps, init) 二元组，不接收 opts（配置通过 state/menu 等依赖间接传递）
-- init(new_deps) 将参数合并到 deps upvalue
function M.make_feature_init(name, deps_schema)
    local deps = {}
    local initialized = false

    local function init(new_deps)
        if initialized then
            msg.warn("[module_loader] " .. tostring(name) .. " already initialized, skipping")
            return
        end
        initialized = true
        if type(new_deps) == "table" then
            shallow_merge(deps, new_deps)
        end
        validate_deps(name, deps_schema, deps)
    end

    return deps, init
end

-- make_set_opts: 旧式 set_opts 接口兼容
-- 返回 (opts, set_opts) 二元组
-- set_opts(new_opts) 将参数合并到 opts upvalue
function M.make_set_opts(initial)
    local opts = {}
    if type(initial) == "table" then
        shallow_merge(opts, initial)
    end
    local function set_opts(new_opts)
        if type(new_opts) == "table" then
            shallow_merge(opts, new_opts)
        end
    end
    return opts, set_opts
end

return M
