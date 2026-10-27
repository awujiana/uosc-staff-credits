-- modules/staff_grid.lua
-- 职员表网格面板 - 5列网格 OSD 展示全部职员，支持翻页
-- 替代 uosc open-menu 单列菜单，解决职员过多需要滚动的问题
-- 遵循 UI.md 7.2 节（按键绑定）、12.2 节（底部提示栏）
-- 使用 DESIGN.md 3 节 make_panel_module 工厂注入公共方法

local mp = require("mp")
local msg = require("mp.msg")

local pagination = require("modules.pagination")
local mouse_interaction = require("modules.mouse_interaction")

local M = {}

-- ====== 模块工厂初始化（make_init）======
local opts, deps, init = require("modules.utils.module_loader").make_init(
    "staff_grid",
    {
        ui_base = "table",
        panel_registry = "table",
        input_service = "table",
        ass_lib = "table",
        notify = "table",
        utils = "table",
    }
)
M.init = init

-- ====== LAYOUT 常量表 ======
local LAYOUT = {
    title_h = 40,
    separator_h = 8,
    hint_h = 30,
    margin = 40,
    cell_spacing = 10,
    cell_h = 50,
    visible_rows = 14,
    name_fs = 18,
    role_fs = 12,
    title_fs = 28,
    per_row = 5,
}

-- ====== 模块本地状态 ======
local state = {
    visible = false,
    items = {},          -- 职员列表 {name, role, kind}
    title = "",
    offset = 0,          -- 翻页偏移
    layout = nil,
    overlay = nil,
    render_version = 0,
    hover_index = 0,       -- 由 mouse_interaction 管理
    hover_button = nil,    -- 由 pagination/mouse_interaction 管理（"prev"/"next"/"close"/nil）
    close_btn = nil,       -- v1.7.2: 右上角关闭按钮区域 {x, y, size}
}

-- ====== compute_layout ======
local function compute_layout(osd_w, osd_h, items_count)
    if type(osd_w) ~= "number" or osd_w <= 0 then osd_w = 1280 end
    if type(osd_h) ~= "number" or osd_h <= 0 then osd_h = 720 end
    local ui_scale = osd_w / 1920
    if ui_scale <= 0 then ui_scale = 1280 / 1920 end
    local function s(v) return math.floor(v * ui_scale) end

    local avail_w = osd_w - 2 * s(LAYOUT.margin)
    local spacing = s(LAYOUT.cell_spacing)
    local per_row = LAYOUT.per_row
    local cell_w = math.floor((avail_w - spacing * (per_row - 1)) / per_row)

    local visible_rows = LAYOUT.visible_rows
    local cell_h = s(LAYOUT.cell_h)
    local avail_h = osd_h - 2 * s(LAYOUT.margin) - s(LAYOUT.title_h) - s(LAYOUT.separator_h) - s(LAYOUT.hint_h) - s(20)
    if avail_h > 0 then
        visible_rows = math.floor((avail_h + spacing) / (cell_h + spacing))
        if visible_rows < 3 then visible_rows = 3 end
        if visible_rows > 20 then visible_rows = 20 end
    end

    local total_w = per_row * cell_w + (per_row - 1) * spacing
    local start_x = math.floor((osd_w - total_w) / 2)
    if start_x < s(LAYOUT.margin) then start_x = s(LAYOUT.margin) end

    local title_y = s(LAYOUT.margin)
    local separator_y = title_y + s(LAYOUT.title_h)
    local cells_y = separator_y + s(LAYOUT.separator_h) + s(10)
    local cells_h = visible_rows * cell_h + (visible_rows - 1) * spacing
    local hint_y = osd_h - math.floor(40 * ui_scale)

    return {
        osd_w = osd_w, osd_h = osd_h,
        ui_scale = ui_scale, s = s,
        per_row = per_row, cell_w = cell_w, cell_h = cell_h,
        visible_rows = visible_rows,
        visible_count = per_row * visible_rows,
        spacing = spacing,
        start_x = start_x, total_w = total_w,
        title_y = title_y, separator_y = separator_y,
        cells_y = cells_y, cells_h = cells_h,
        hint_y = hint_y,
        pagination_position = (opts and opts.pagination_position) or "bottom",
    }
end

-- ====== 翻页 ======
-- ⚠️ 2026-10-06 修复：render 的**前向声明**必须放在 page_up/page_down 之前。
--    Lua 的局部量作用域从声明语句之后才开始，原来 `local function render()`
--    写在第 157 行、而 page_up/page_down 在第 106/118 行，于是它们体内的
--    `render()` 编译成了**全局读取** → 运行时 attempt to call global 'render'
--    (a nil value)。触发条件：职员表条目多到能翻页时按 LEFT/RIGHT 或点翻页箭头。
--    实测证据（tools/ 下的探针）：
--      page_down → staff_grid.lua:130: attempt to call global 'render' (a nil value)
--      page_up   → staff_grid.lua:114: attempt to call global 'render' (a nil value)
--    debug.getupvalue 亦证实 page_up/page_down 的上值里**没有** render。
--    修法即标准前向声明：先 `local render`，稍后改成 `render = function() ... end`。
local render

local function page_up()
    if not state.visible then return end
    local layout = state.layout
    if not layout then return end
    local visible_count = layout.visible_count
    if state.offset > 0 then
        state.offset = state.offset - visible_count
        if state.offset < 0 then state.offset = 0 end
        render()
    end
end

local function page_down()
    if not state.visible then return end
    local layout = state.layout
    if not layout then return end
    local visible_count = layout.visible_count
    local max_offset = 0
    if #state.items > 0 then
        max_offset = math.max(0, math.ceil(#state.items / visible_count) - 1) * visible_count
    end
    if state.offset < max_offset then
        state.offset = state.offset + visible_count
        if state.offset > max_offset then state.offset = max_offset end
        render()
    end
end

-- ====== 鼠标支持 ======
-- v1.8: MBTN_LEFT 按键绑定不传递坐标参数，必须主动获取 mouse-pos
local function on_mouse_click()
    if not state.visible or not state.layout then return end
    -- 主动获取鼠标坐标（MBTN_LEFT 回调无参数）
    local mouse = mp.get_property_native("mouse-pos")
    if type(mouse) ~= "table" then return end
    local mx = mouse.x
    local my = mouse.y
    if type(mx) ~= "number" or type(my) ~= "number" then return end
    -- v1.7.2: 优先检测关闭按钮
    if state.close_btn then
        local cb = state.close_btn
        if mx >= cb.x and mx < cb.x + cb.size
           and my >= cb.y and my < cb.y + cb.size then
            M.close()
            return
        end
    end
    pagination.on_click(mx, my, state.pagination_layout, page_up, page_down)
end

-- ====== 渲染 ======
-- 注意：这里**不能**写成 `local function render()`，否则会新建一个从本行才
-- 生效的局部量，前面 page_up/page_down 仍然读全局。必须赋值给上面 `local render`
-- 声明出来的那个局部量。
render = function()
    if not state.visible then return end
    if not state.overlay then return end
    local ass_lib = deps.ass_lib
    if not ass_lib then return end

    state.render_version = state.render_version + 1

    local osd_w, osd_h = ass_lib.get_osd_size()
    local layout = compute_layout(osd_w, osd_h, #state.items)
    state.layout = layout

    -- 计算翻页按钮布局（使用通用组件）
    state.pagination_layout = pagination.compute_layout(layout, state.offset, #state.items, layout.visible_count)

    local parts = {}

    -- 1. 面板背景
    local panel_h = layout.cells_h + layout.s(20) + layout.s(LAYOUT.title_h) + layout.s(LAYOUT.separator_h) + layout.s(10) + layout.s(10)
    table.insert(parts, ass_lib.draw_round_rect(
        layout.start_x - layout.s(20), layout.title_y - layout.s(10),
        layout.total_w + layout.s(40), panel_h,
        "121018", nil, 0, "80", "00", layout.s(14)
    ))

    -- 2. 顶部装饰线
    table.insert(parts, ass_lib.draw_rect(
        layout.start_x - layout.s(20), layout.title_y - layout.s(10),
        layout.total_w + layout.s(40), layout.s(4),
        "88C0FC", nil, 0, "00", "00"
    ))

    -- 3. 标题
    local title_fs = math.floor(LAYOUT.title_fs * layout.ui_scale)
    local title_center_y = layout.title_y + math.floor(layout.s(LAYOUT.title_h) / 2)
    table.insert(parts, string.format(
        "{\\an5\\pos(%d,%d)\\fs%d\\b1\\c&H%s&}%s\n",
        math.floor(osd_w / 2), title_center_y, title_fs,
        ass_lib.hex_to_ass("FFFBFF"),
        ass_lib.ass_escape(state.title or "")
    ))

    -- 3b. 右上角关闭按钮（v1.7.2: 供鼠标使用）
    -- v1.7.4: 增加悬停反馈（hover_button == "close" 时文字转红 E06C75）
    local close_size = layout.s(28)
    local close_x = layout.start_x + layout.total_w + layout.s(12) - close_size
    local close_y = layout.title_y
    state.close_btn = {x = close_x, y = close_y, size = close_size}
    local close_hover = (state.hover_button == "close")
    table.insert(parts, ass_lib.draw_round_rect(
        close_x, close_y, close_size, close_size,
        close_hover and "3A3940" or "2A2930",
        close_hover and "88C0FC" or nil,
        close_hover and 2 or 0, "60", "00", layout.s(6)
    ))
    local close_fs = math.floor(close_size * 0.6)
    table.insert(parts, string.format(
        "{\\an5\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
        math.floor(close_x + close_size / 2),
        math.floor(close_y + close_size / 2),
        close_fs,
        ass_lib.hex_to_ass(close_hover and "E06C75" or "A0A0A0"),
        ass_lib.ass_escape("✕")
    ))

    -- 4. 分隔线
    table.insert(parts, ass_lib.draw_rect(
        layout.start_x, layout.separator_y,
        layout.total_w, layout.s(LAYOUT.separator_h),
        "88C0FC", nil, 0, "00", "00"
    ))

    -- 5. 职员网格
    local visible_count = layout.visible_count
    local end_idx = math.min(state.offset + visible_count, #state.items)
    local name_fs = math.floor(LAYOUT.name_fs * layout.ui_scale)
    local role_fs = math.floor(LAYOUT.role_fs * layout.ui_scale)

    for i = state.offset + 1, end_idx do
        local item = state.items[i]
        if not item then break end

        local slot = i - state.offset - 1
        local row = math.floor(slot / layout.per_row)
        local col = slot % layout.per_row
        local cell_x = layout.start_x + col * (layout.cell_w + layout.spacing)
        local cell_y = layout.cells_y + row * (layout.cell_h + layout.spacing)

        local is_hover = (slot + 1 == state.hover_index)

        -- 单元格背景
        if is_hover then
            table.insert(parts, ass_lib.draw_round_rect(
                cell_x, cell_y, layout.cell_w, layout.cell_h,
                "3A3940", "88C0FC", 2, "D0", "00", layout.s(8)
            ))
        else
            table.insert(parts, ass_lib.draw_round_rect(
                cell_x, cell_y, layout.cell_w, layout.cell_h,
                "2A2930", nil, 0, "C0", "00", layout.s(8)
            ))
        end

        -- 职员名（居中上半部分）
        local name_y = cell_y + math.floor(layout.cell_h * 0.35)
        table.insert(parts, string.format(
            "{\\an5\\pos(%d,%d)\\fs%d\\b1\\c&H%s&}%s\n",
            math.floor(cell_x + layout.cell_w / 2), name_y, name_fs,
            ass_lib.hex_to_ass("FFFBFF"),
            ass_lib.ass_escape(item.name or "")
        ))

        -- 职位（居中下半部分，较小字号）
        local role_y = cell_y + math.floor(layout.cell_h * 0.72)
        table.insert(parts, string.format(
            "{\\an5\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
            math.floor(cell_x + layout.cell_w / 2), role_y, role_fs,
            ass_lib.hex_to_ass("A8D4F7"),
            ass_lib.ass_escape(item.role or "")
        ))
    end

    -- 6. 翻页按钮（使用通用组件）
    pagination.render(parts, state.pagination_layout, state, ass_lib)

    -- 7. 底部提示栏
    local hint_fs = math.floor(14 * layout.ui_scale)
    local total_pages = 0
    if #state.items > 0 then
        total_pages = math.ceil(#state.items / visible_count)
    end
    local current_page = 0
    if #state.items > 0 then
        current_page = math.floor(state.offset / visible_count) + 1
    end
    local hint_text = string.format("ESC/Ctrl+右键 关闭 · ←→ 翻页 · 点击右上角✕ · 第 %d/%d 页 · 共 %d 人",
        current_page, total_pages, #state.items)
    table.insert(parts, string.format(
        "{\\an5\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
        math.floor(osd_w / 2), layout.hint_y, hint_fs,
        ass_lib.hex_to_ass("808080"),
        ass_lib.ass_escape(hint_text)
    ))

    -- 8. 无数据提示
    if #state.items == 0 then
        local empty_fs = math.floor(20 * layout.ui_scale)
        table.insert(parts, string.format(
            "{\\an5\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
            math.floor(osd_w / 2), math.floor((layout.cells_y + layout.cells_h) / 2),
            empty_fs,
            ass_lib.hex_to_ass("808080"),
            ass_lib.ass_escape("无职员数据")
        ))
    end

    local ass_text = table.concat(parts)
    state.overlay.data = ass_text
    state.overlay.res_x = osd_w
    state.overlay.res_y = osd_h
    pcall(function() state.overlay:update() end)
end

-- ====== 公开接口 ======

-- v1.7.3: 修复 is_visible 缺失导致 panel_registry 注册失败
-- 其他面板（cards/cover_intro/production_score）均显式定义此函数
function M.is_visible()
    return state.visible
end

function M.show(items, title)
    -- v1.7.4: 移除废弃的首参 new_deps（调用方原先传 deps 但被忽略，实际使用模块级 deps）
    if type(items) ~= "table" or #items == 0 then
        if deps.notify then pcall(deps.notify.warn, "未找到职员信息") end
        return
    end

    -- 关闭其他面板 + 禁用 uosc
    if deps.ui_base then
        pcall(deps.ui_base.close_other_panels, "staff_grid")
        pcall(deps.ui_base.disable_uosc)
    end

    -- v1.9.5: 核选项强制关闭所有残留 uosc 菜单
    if deps.loading_controller and type(deps.loading_controller.nuclear_menu_dismiss) == "function" then
        pcall(deps.loading_controller.nuclear_menu_dismiss)
    end

    -- 重置状态
    state.items = items
    state.title = title or "职员表"
    state.offset = 0
    state.hover_index = 0
    state.hover_button = nil
    state.render_version = state.render_version + 1

    -- 创建 overlay（若未创建）
    if not state.overlay then
        state.overlay = mp.create_osd_overlay('ass-events')
    end

    state.visible = true
    M.visible = true

    -- 首次渲染
    render()

    -- 注册按键（register_keys 内部先 unregister 旧绑定）
    -- v1.8: 翻页快捷键只用 LEFT/RIGHT（用户要求），移除 UP/DOWN/PGUP/PGDWN/WHEEL
    M.register_keys({
        {key="RIGHT",           name="staff_grid-right",   fn=page_down,       forced=true},
        {key="LEFT",            name="staff_grid-left",    fn=page_up,         forced=true},
        {key="ESC",             name="staff_grid-close",   fn=M.close,         forced=true},
        {key="Ctrl+MBTN_RIGHT", name="staff_grid-close-m", fn=M.close,         forced=false},
        {key="MBTN_LEFT",       name="staff_grid-click",   fn=on_mouse_click,  forced=true},
    })

    -- 注册 OSD observer（osd-width/osd-height 变化时重新 render，仅在 visible 时）
    -- v1.7.4: 移至 M.init() 一次性注册，避免每次 show() 重复 observe/unobserve 抖动
    --         （is_visible 门控已保证不可见时不重绘，无需在 show 里重建）

    -- 订阅鼠标输入（使用通用组件）
    if deps.input_service then
        mouse_interaction.enable(deps.input_service, {
            hit_test = function(mx, my)
                -- 优先检查关闭按钮（v1.7.4: 纳入 hit_test，使 ✕ 具备悬停反馈）
                if state.close_btn then
                    local cb = state.close_btn
                    if mx >= cb.x and mx < cb.x + cb.size
                       and my >= cb.y and my < cb.y + cb.size then
                        return "close"
                    end
                end
                -- 然后检查翻页按钮
                local btn = pagination.hit_test(mx, my, state.pagination_layout)
                if btn then return btn end
                -- 然后检查单元格悬停
                if not state.layout then return nil end
                local layout = state.layout
                local visible_count = layout.visible_count
                local end_idx = math.min(state.offset + visible_count, #state.items)
                for i = state.offset + 1, end_idx do
                    local slot = i - state.offset - 1
                    local row = math.floor(slot / layout.per_row)
                    local col = slot % layout.per_row
                    local cell_x = layout.start_x + col * (layout.cell_w + layout.spacing)
                    local cell_y = layout.cells_y + row * (layout.cell_h + layout.spacing)
                    if mx >= cell_x and mx <= cell_x + layout.cell_w
                        and my >= cell_y and my <= cell_y + layout.cell_h then
                        return slot + 1
                    end
                end
                return nil
            end,
            on_hover_change = function(old_hover, new_hover)
                -- 区分按钮悬停和单元格悬停
                if type(new_hover) == "string" then
                    state.hover_button = new_hover
                    state.hover_index = 0
                elseif type(new_hover) == "number" then
                    state.hover_index = new_hover
                    state.hover_button = nil
                else
                    state.hover_index = 0
                    state.hover_button = nil
                end
                render()
            end,
            on_click = on_mouse_click,
        })
    end
end

-- ====== init 覆盖（make_panel_module 工厂使用模式）======

local base_init = init
function M.init(new_opts, new_deps)
    base_init(new_opts, new_deps)
    deps.ui_base.make_panel_module("staff_grid", M)

    -- v1.7.4: OSD observer 一次性注册（原在 show() 内每次重建，造成订阅抖动与防抖定时器泄漏风险）
    -- 注册后会一直存活，由 is_visible 门控（不可见时不触发 render）
    M.unregister_osd()
    M.register_osd_observers(function()
        if state.visible then render() end
    end, {"osd-width", "osd-height"}, 100, M.is_visible)

    M.set_cleanup(function()
        state.visible = false
        M.visible = false
        state.render_version = state.render_version + 1
        if state.overlay then
            pcall(function() state.overlay:remove() end)
            state.overlay = nil
        end
        -- 关闭鼠标订阅（使用通用组件）
        mouse_interaction.disable()
        state.layout = nil
        -- v1.7.1: 同步清理 pagination_layout（修复 close 后 hit_test 使用残留 layout 导致 nil 比较崩溃）
        state.pagination_layout = nil
        state.hover_index = 0
        state.hover_button = nil
        state.close_btn = nil  -- v1.7.2: 清理关闭按钮区域
    end)

    M.init_panel(deps, {is_visible = M.is_visible, close = M.close})
end

return M
