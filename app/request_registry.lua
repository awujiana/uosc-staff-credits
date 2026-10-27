-- app/request_registry.lua
-- 请求取消注册中心（纯逻辑模块）
-- 遵循 DESIGN.md 第 6 节：集中管理所有异步请求的 cancel_fn
-- ADR-02 / ADR-06：从 main.lua 抽出，独立模块
--
-- mpv 的 Lua 是单实例 require 缓存，此状态在脚本生命周期内全局共享
-- 无需 init，直接导出接口

local msg = require("mp.msg")

local M = {}

-- ============ 内部状态 ============

-- cancel_fn 列表：每个 fn 对应一个可取消的异步请求
local cancel_fns = {}

-- cancel_all 进行中标志（BUG-1.3 防御）
local cancelling = false

-- ============ 接口 ============

-- register: 注册一个 cancel_fn
-- fn: 取消函数，无参，调用后应中止对应异步请求
-- 返回 cancel_fn 本身（用作 unregister 的 token）；nil 表示参数无效或在 cancelling 期间被立即调用
--
-- BUG-1.3 修复：cancel_all 期间若被 abort 的请求回调触发新请求并 register，
-- 新 cancel_fn 立即 pcall 执行，避免用户已 ESC 后新请求继续运行
function M.register(fn)
    if type(fn) ~= "function" then
        return nil
    end
    if cancelling then
        -- cancel_all 进行中：立即调用，避免泄漏
        pcall(fn)
        return nil
    end
    table.insert(cancel_fns, fn)
    return fn  -- 返回 fn 本身作为 token
end

-- unregister: 注销单个 cancel_fn（请求正常完成时调用）
-- token: register 返回的 fn 引用
-- 避免已完成的请求留在列表中导致 cancel_fns 无限增长和 has_pending 误判
function M.unregister(token)
    if type(token) ~= "function" then return false end
    for i, f in ipairs(cancel_fns) do
        if f == token then
            table.remove(cancel_fns, i)
            return true
        end
    end
    return false
end

-- cancel_all: 取消所有已注册的请求
-- 设 cancelling=true，取出 fns 清空列表，逐个 pcall(fn)，重置 cancelling
-- 返回尝试取消的数量
function M.cancel_all()
    if cancelling then
        -- 防御：避免重入
        return 0
    end
    cancelling = true
    -- 取出当前列表并清空，避免遍历时新 register 干扰
    local fns = cancel_fns
    cancel_fns = {}
    local count = #fns
    for i = 1, count do
        local fn = fns[i]
        if type(fn) == "function" then
            local ok, err = pcall(fn)
            if not ok then
                msg.warn("[request_registry] cancel_fn failed: " .. tostring(err))
            end
        end
    end
    cancelling = false
    return count
end

-- clear: 仅清空列表不调用（请求正常完成时用）
function M.clear()
    cancel_fns = {}
end

-- has_pending: 是否有未完成的请求
function M.has_pending()
    return next(cancel_fns) ~= nil
end

-- is_cancelling: 防御性检查，cancel_all 是否进行中
function M.is_cancelling()
    return cancelling
end

-- size: 当前已注册数量（调试用）
function M.size()
    return #cancel_fns
end

return M
