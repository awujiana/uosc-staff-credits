-- modules/pagination.lua
-- 通用翻页按钮组件 - 供 staff_grid.lua 和 cards.lua 复用
-- 纯函数组件，无 mp 依赖，ass_lib 作为参数传入
-- 提供布局计算、渲染、命中检测、点击处理四个接口
-- 按钮位置上移 40px 避开 uosc 控制条（原为 4px）

local M = {}

-- compute_layout: 计算翻页按钮位置
-- parent_layout: 父面板布局表（含 hint_y, start_x, total_w, ui_scale, s 等）
-- offset: 当前翻页偏移
-- total: 总条目数
-- visible_count: 每页可见条目数
-- 返回: 翻页按钮布局表（btn_w, btn_h, btn_y, prev_btn_x, next_btn_x, is_first_page, is_last_page, max_offset, ui_scale）
function M.compute_layout(parent_layout, offset, total, visible_count)
    local ui_scale = parent_layout.ui_scale or 1
    local s = parent_layout.s or function(v) return math.floor(v * ui_scale) end

    -- 按钮尺寸（基础值 100×32，按 ui_scale 缩放）
    local btn_w = s(100)
    local btn_h = s(32)

    -- 按钮 Y 坐标（支持 pagination_position 配置）
    local pos = parent_layout.pagination_position or "bottom"
    local btn_y
    if pos == "top" then
        -- 网格顶部上方（兼容 cells_y / cards_y）
        local grid_top = parent_layout.cells_y or parent_layout.cards_y or 0
        btn_y = grid_top - btn_h - s(8)
        if btn_y < 0 then btn_y = 0 end
    elseif pos == "middle" then
        -- 网格垂直中间（兼容 cells_y/cards_y + cells_h/cards_h）
        local grid_top = parent_layout.cells_y or parent_layout.cards_y or 0
        local grid_h = parent_layout.cells_h or parent_layout.cards_h or 0
        btn_y = grid_top + math.floor((grid_h - btn_h) / 2)
    else
        -- 默认 bottom: 底部提示栏上方 40px（上移避开 uosc 控制条，原为 4px）
        btn_y = parent_layout.hint_y - btn_h - s(40)
    end

    -- 按钮 X 坐标
    local prev_btn_x = parent_layout.start_x
    local next_btn_x = parent_layout.start_x + parent_layout.total_w - btn_w

    -- 翻页状态计算
    local max_offset = 0
    if total > 0 and visible_count > 0 then
        max_offset = math.max(0, math.ceil(total / visible_count) - 1) * visible_count
    end
    local is_first_page = (offset == 0)
    local is_last_page = (offset >= max_offset) or (total == 0)

    return {
        btn_w = btn_w,
        btn_h = btn_h,
        btn_y = btn_y,
        prev_btn_x = prev_btn_x,
        next_btn_x = next_btn_x,
        is_first_page = is_first_page,
        is_last_page = is_last_page,
        max_offset = max_offset,
        ui_scale = ui_scale,
    }
end

-- render: 渲染翻页按钮（三态：禁用/默认/悬停）
-- ass_parts: ASS 文本片段数组（会被 table.insert）
-- layout: compute_layout 返回的布局表
-- state: 面板状态表，需含 hover_button 字段（"prev"/"next"/nil）
-- ass_lib: ASS 渲染辅助库（提供 draw_rect, hex_to_ass, ass_escape）
function M.render(ass_parts, layout, state, ass_lib)
    local btn_arrow_fs = math.floor(20 * layout.ui_scale)
    local btn_center_y = layout.btn_y + math.floor(layout.btn_h / 2)
    local hover_button = state.hover_button

    -- 渲染单个按钮（禁用/默认/悬停 三态）
    local function draw_button(btn_x, arrow, is_disabled, is_hovered)
        local fill, border, border_w, text_color, alpha = "2A2930", nil, 0, "88C0FC", "C0"
        if is_disabled then
            fill, text_color, alpha = "1A1A20", "606060", "80"
        elseif is_hovered then
            fill, border, border_w, alpha = "3A3940", "88C0FC", 2, "D0"
        end
        table.insert(ass_parts, ass_lib.draw_round_rect(
            btn_x, layout.btn_y, layout.btn_w, layout.btn_h,
            fill, border, border_w, alpha, "00", math.max(2, math.floor(6 * layout.ui_scale))
        ))
        table.insert(ass_parts, string.format(
            "{\\an5\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
            btn_x + math.floor(layout.btn_w / 2),
            btn_center_y, btn_arrow_fs,
            ass_lib.hex_to_ass(text_color),
            arrow
        ))
    end

    -- 上一页 ◀ (\226\156\160)
    draw_button(layout.prev_btn_x, "\226\156\160",
        layout.is_first_page, hover_button == "prev")
    -- 下一页 ▶ (\226\150\184)
    draw_button(layout.next_btn_x, "\226\150\184",
        layout.is_last_page, hover_button == "next")
end

-- hit_test: 鼠标命中检测
-- mx, my: 鼠标坐标
-- layout: compute_layout 返回的布局表
-- 返回: "prev" / "next" / nil
-- v1.7.1: 防御性检查所有字段（修复 close 后 pagination_layout 残留导致的 nil 比较崩溃）
function M.hit_test(mx, my, layout)
    if not layout then return nil end
    -- v1.7.1: 所有必要字段都必须是 number，任一缺失返回 nil
    if type(mx) ~= "number" or type(my) ~= "number" then return nil end
    if type(layout.btn_y) ~= "number" or type(layout.btn_h) ~= "number" then return nil end
    if type(layout.prev_btn_x) ~= "number" or type(layout.next_btn_x) ~= "number" then return nil end
    if type(layout.btn_w) ~= "number" then return nil end
    if my >= layout.btn_y and my < layout.btn_y + layout.btn_h then
        if mx >= layout.prev_btn_x and mx < layout.prev_btn_x + layout.btn_w then
            return "prev"
        elseif mx >= layout.next_btn_x and mx < layout.next_btn_x + layout.btn_w then
            return "next"
        end
    end
    return nil
end

-- on_click: 点击处理
-- mx, my: 鼠标坐标
-- layout: compute_layout 返回的布局表
-- page_up_fn: 上一页回调函数
-- page_down_fn: 下一页回调函数
function M.on_click(mx, my, layout, page_up_fn, page_down_fn)
    local hit = M.hit_test(mx, my, layout)
    if hit == "prev" then
        if page_up_fn then page_up_fn() end
    elseif hit == "next" then
        if page_down_fn then page_down_fn() end
    end
end

return M
