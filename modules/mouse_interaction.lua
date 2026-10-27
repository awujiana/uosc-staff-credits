-- modules/mouse_interaction.lua
-- 通用鼠标交互 mixin - 统一鼠标订阅/取消订阅、悬停高亮、点击处理
-- 抽取自 staff_grid.lua 和 cards.lua 的公共逻辑，避免重复实现
-- 单例模式：同一时间只有一个面板可见，使用模块级内部状态即可
-- 纯逻辑组件，不依赖 mp 模块，input_service 作为参数传入

local M = {}

-- 模块内部状态
local internal_state = {
    input_service = nil,    -- 输入服务模块引用（提供 subscribe/unsubscribe）
    mouse_callback = nil,   -- 内部鼠标回调函数（供 unsubscribe 使用）
    current_hover = nil,    -- 当前悬停项标识（数字索引/字符串/nil）
}

-- enable: 订阅鼠标输入
-- 参数:
--   input_service: 输入服务模块（提供 subscribe(callback) 方法）
--   callbacks: 回调表，含:
--     hit_test(mx, my): 返回悬停项标识（数字索引或字符串或 nil）
--     on_hover_change(old_hover, new_hover): 悬停项变化时触发（可选，触发重绘）
--     on_click(mx, my): 鼠标点击处理（可选）
-- 行为: 内部维护 current_hover，调用 input_service.subscribe
-- 返回: 无
function M.enable(input_service, callbacks)
    if type(input_service) ~= "table" or type(callbacks) ~= "table" then return end
    if type(callbacks.hit_test) ~= "function" then return end

    -- 先清理可能存在的旧订阅，避免重复注册
    M.disable()

    -- 内部 mouse_callback：根据 hit_test 结果更新悬停状态
    local function mouse_callback(mx, my)
        local new_hover = callbacks.hit_test(mx, my)
        if new_hover ~= internal_state.current_hover then
            local old = internal_state.current_hover
            internal_state.current_hover = new_hover
            if type(callbacks.on_hover_change) == "function" then
                pcall(callbacks.on_hover_change, old, new_hover)
            end
        end
    end

    internal_state.input_service = input_service
    internal_state.mouse_callback = mouse_callback
    pcall(input_service.subscribe, mouse_callback)
end

-- disable: 取消订阅
-- 行为: 调用 input_service.unsubscribe(mouse_callback)，清理内部状态
-- 使用 pcall 包裹避免异常
-- 返回: 无
function M.disable()
    if internal_state.input_service and internal_state.mouse_callback then
        pcall(internal_state.input_service.unsubscribe, internal_state.mouse_callback)
    end
    internal_state.input_service = nil
    internal_state.mouse_callback = nil
    internal_state.current_hover = nil
end

-- get_current_hover: 获取当前悬停项
-- 返回: 当前悬停标识或 nil
function M.get_current_hover()
    return internal_state.current_hover
end

-- handle_click: 处理点击事件（供面板的 MBTN_LEFT 按键绑定调用）
-- 参数: 鼠标坐标 (mx, my) 和回调表（含 on_click）
-- 行为: 调用 callbacks.on_click(mx, my)（pcall 包裹）
-- 返回: 无
function M.handle_click(mx, my, callbacks)
    if type(callbacks) ~= "table" or type(callbacks.on_click) ~= "function" then
        return
    end
    pcall(callbacks.on_click, mx, my)
end

return M
