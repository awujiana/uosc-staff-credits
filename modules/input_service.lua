-- modules/input_service.lua
-- 鼠标输入服务 - 统一 mouse-pos 观察者，惰性初始化
-- 遵循 UI.md 13 节：单一 mp.observe_property("mouse-pos", ...) 监听器
-- 首个订阅者时注册，无订阅者时释放，避免多模块各自管理鼠标输入
-- 模块工厂模式：init(opts, deps) 仅标记初始化

local mp = require("mp")
local msg = require("mp.msg")

local M = {}

-- 模块本地状态
local initialized = false
local subscribers = {}      -- 订阅者回调列表（函数列表）
local observer_active = false  -- 当前 observer 是否已注册

-- 内部：mouse-pos 属性变化回调
-- mpv 的 mouse-pos 返回 { x, y, hover } 表
-- 提取 x, y 后分发给所有订阅者
local function on_mouse_pos(_name, value)
    if type(value) ~= "table" then return end
    local mx = value.x
    local my = value.y
    if type(mx) ~= "number" then mx = 0 end
    if type(my) ~= "number" then my = 0 end
    -- 遍历副本，避免订阅中 unsubscribe 导致索引错乱
    local snapshot = {}
    for i = 1, #subscribers do
        snapshot[i] = subscribers[i]
    end
    for i = 1, #snapshot do
        local cb = snapshot[i]
        if type(cb) == "function" then
            local ok = pcall(cb, mx, my)
            if not ok then
                msg.warn("[input_service] subscriber callback error")
            end
        end
    end
end

-- 内部：确保 observer 已注册
-- 修复：先 pcall 注册，成功后再设标志，避免注册失败导致服务永久失效
local function ensure_observer()
    if observer_active then return end
    local ok = pcall(mp.observe_property, "mouse-pos", "native", on_mouse_pos)
    if ok then
        observer_active = true
    else
        msg.warn("[input_service] failed to observe mouse-pos")
    end
end

-- 内部：当无订阅者时释放 observer
local function maybe_release_observer()
    if not observer_active then return end
    if #subscribers > 0 then return end
    observer_active = false
    pcall(mp.unobserve_property, on_mouse_pos)
end

-- init: 工厂初始化，仅标记已初始化
-- 遵循 ADR-10 统一 init(opts, deps) 接口
function M.init(new_opts, new_deps)
    initialized = true
end

-- subscribe: 注册鼠标位置变化回调
-- callback 签名: function(mouse_x, mouse_y)
-- 首次订阅时惰性初始化 observer
function M.subscribe(callback)
    if type(callback) ~= "function" then return false end
    -- 避免重复注册同一回调
    for i = 1, #subscribers do
        if subscribers[i] == callback then
            return true
        end
    end
    table.insert(subscribers, callback)
    ensure_observer()
    return true
end

-- unsubscribe: 移除鼠标位置变化回调
-- 当无订阅者时自动释放 observer
function M.unsubscribe(callback)
    if type(callback) ~= "function" then return false end
    for i = #subscribers, 1, -1 do
        if subscribers[i] == callback then
            table.remove(subscribers, i)
            break
        end
    end
    maybe_release_observer()
    return true
end

return M
