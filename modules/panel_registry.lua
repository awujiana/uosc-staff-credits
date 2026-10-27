-- modules/panel_registry.lua
-- 面板注册中心 - 管理面板可见性和互斥
-- 遵循 DESIGN.md 4 节：register/unregister/get_panel/list/close_all_except/close_all
-- V4-P3 关键修复：不使用 __mode="v" 弱值元表（避免 GC 回收面板临时表导致丢失）
-- 面板模块由 package.loaded 强引用，不会真正泄漏

local msg = require("mp.msg")

local M = {}

-- 面板表：{ [name] = { is_visible = function, close = function } }
-- 不设置弱值元表（V4-P3 修复）
local panels = {}

-- register: 注册面板
-- name: 字符串面板名
-- panel: { is_visible = function, close = function }
-- 校验 name 为字符串、panel 含 is_visible/close 函数
function M.register(name, panel)
    if type(name) ~= "string" or name == "" then
        msg.warn("[panel_registry] register: invalid name (expected non-empty string)")
        return false
    end
    if type(panel) ~= "table" then
        msg.warn("[panel_registry] register: invalid panel for '" .. name .. "' (expected table)")
        return false
    end
    if type(panel.is_visible) ~= "function" then
        msg.warn("[panel_registry] register: panel '" .. name .. "' missing is_visible function")
        return false
    end
    if type(panel.close) ~= "function" then
        msg.warn("[panel_registry] register: panel '" .. name .. "' missing close function")
        return false
    end
    panels[name] = panel
    return true
end

-- unregister: 注销面板（一般不调用）
function M.unregister(name)
    if type(name) ~= "string" then return false end
    panels[name] = nil
    return true
end

-- get_panel: 获取面板对象，不存在返回 nil
function M.get_panel(name)
    if type(name) ~= "string" then return nil end
    return panels[name]
end

-- list: 列出所有已注册名称（调试用）
-- 返回数组（1-indexed）
function M.list()
    local names = {}
    for name, _ in pairs(panels) do
        table.insert(names, name)
    end
    return names
end

-- close_all_except: 互斥核心 - 关闭除指定面板外的所有可见面板
-- except_name: 排除的面板名（可为 nil，表示关闭全部）
-- 每个 close 都用 pcall 包裹，单个面板关闭失败不中断后续
-- 修复：先收集待关闭面板列表，避免在 pairs 迭代中 close 修改 panels 表导致未定义行为
-- 返回关闭的面板数
function M.close_all_except(except_name)
    -- 第一阶段：收集需要关闭的面板名（避免在 pairs 迭代中修改表）
    local to_close = {}
    for name, panel in pairs(panels) do
        if name ~= except_name then
            local ok_visible, visible = pcall(function() return panel.is_visible() end)
            if ok_visible and visible then
                table.insert(to_close, name)
            end
        end
    end
    -- 第二阶段：逐个关闭
    local closed_count = 0
    for _, name in ipairs(to_close) do
        local panel = panels[name]
        if panel then
            local ok_close, err = pcall(panel.close)
            if ok_close then
                closed_count = closed_count + 1
            else
                msg.warn("[panel_registry] close_all_except: failed to close '" ..
                    tostring(name) .. "': " .. tostring(err))
            end
        end
    end
    return closed_count
end

-- close_all: 关闭所有可见面板
-- 委托 close_all_except(nil)
function M.close_all()
    return M.close_all_except(nil)
end

return M
