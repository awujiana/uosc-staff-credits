-- modules/production_score.lua
-- 制作评分面板 - 展示制作人员历史作品评分
-- 遵循 UI.md 1.3 节（制作评分面板）布局规范
-- 遵循 UI.md 7.3 节（按键绑定）、12.3 节（底部提示栏）、6.2 节（评分颜色映射）
-- 遵循 DESIGN.md 3 节（make_panel_module 使用模式）
-- 使用 \an7\pos(0,0) 绝对坐标模式（ass_lib.draw_rect / draw_text 内置）

local mp = require("mp")

local M = {}

-- ====== 模块工厂初始化（make_init）======
local opts, deps, init = require("modules.utils.module_loader").make_init(
    "production_score",
    {
        ui_base = "table",
        panel_registry = "table",
        input_service = "table",
        ass_lib = "table",
        notify = "table",
        request_registry = "table",
        api = "table",
        utils = "table",
    }
)
M.init = init

-- ====== 面板尺寸常量（UI.md 1.3.1）======
local PANEL_BASE_W = 960
local PANEL_BASE_H = 580

local LAYOUT = {
    pad = 24,
    title_h = 40,
    footer_h = 30,
    list_width = 300,
    list_gap = 16,
    row_height = 28,
    detail_pad = 20,
}

-- 9 个制作组顺序（与 production_score_flow.lua GROUP_ORDER 一致）
local GROUP_ORDER = {
    "动画制作", "系列构成", "脚本", "监督", "人物设定",
    "总作画监督", "音乐", "美术监督", "摄影监督",
}

-- ====== 模块本地状态 ======
local state = {
    visible = false,
    groups = {},              -- 9 组制作人员数据 { [组名] = {person, ...} }
    title = "",               -- 面板标题
    selected_index = 1,       -- 当前选中人员索引（扁平化后，1-based）
    flat_persons = {},        -- 扁平化后的人员列表（含 group 字段）
    overlay = nil,            -- mp.create_osd_overlay('ass-events') 句柄
    render_version = 0,       -- 旧回调失效标记
    current_fetch_id = 0,     -- 防止 stale 回调
    current_person_detail = nil, -- 当前选中人员的详情（含 works/score）
    mouse_subscribed = false,
    mouse_callback = nil,
    server_url = "https://api.bgm.tv", -- API 服务器地址
    scroll_offset = 0,        -- 列表滚动偏移（0-based，首个可见行索引）
    max_visible_rows = 1,     -- 最大可见行数（render 时计算）
    list_bounds = nil,        -- 列表区域边界（供鼠标交互）：{x, y, w, h, row_h}
    close_btn = nil,          -- 关闭按钮边界：{x, y, size}
}

-- ====== 内部辅助：防御性类型处理 ======

-- 防御性字符串转换
local function to_str(v)
    if v == nil then return "" end
    if type(v) == "string" then return v end
    if type(v) == "number" then return tostring(v) end
    return tostring(v)
end

-- 防御性截断文本（与 cover_intro.lua 一致）
local function truncate_text(text, max_len)
    if text == nil then return "" end
    if type(text) ~= "string" then
        text = tostring(text)
    end
    max_len = tonumber(max_len) or 0
    if max_len <= 0 then return "" end
    if max_len == 1 then return "…" end
    if #text <= max_len then return text end
    return text:sub(1, max_len - 1) .. "…"
end

-- ====== 评分颜色映射（UI.md 6.2）======
local function score_to_color(score)
    if score == nil then return "A0A0A0" end  -- 灰色（无评分）
    if score >= 7.5 then return "6FCF87" end  -- 绿色（优秀）
    if score >= 6.5 then return "FFD93D" end  -- 黄色（良好）
    if score >= 5.5 then return "FF9F43" end  -- 橙色（一般）
    return "FF6B6B"                            -- 红色（较差）
end

-- ====== calculate_score: 根据作品列表计算制作评分 ======
-- 与 features/production_score_flow.lua 一致：每部作品 5 分，上限 100
local function calculate_score(works)
    if type(works) ~= "table" then return 0 end
    local count = 0
    for _ in ipairs(works) do
        count = count + 1
    end
    local score = count * 5
    if score > 100 then score = 100 end
    return score
end

-- ====== 从 work 提取年份 ======
local function extract_year(date_str)
    if type(date_str) ~= "string" then return "" end
    return date_str:match("^(%d%d%d%d)") or ""
end

-- ====== 从 work 提取标题 ======
local function get_work_title(work)
    if type(work) ~= "table" then return "未知" end
    local title = work.name_cn
    if type(title) == "string" and title ~= "" then return title end
    title = work.name
    if type(title) == "string" and title ~= "" then return title end
    return "未知"
end

-- ====== compute_layout（UI.md 1.3.1 / 1.3.2）======
local function compute_layout(osd_w, osd_h)
    -- 防御：osd 尺寸异常时回退到默认值
    if type(osd_w) ~= "number" or osd_w <= 0 then osd_w = 1280 end
    if type(osd_h) ~= "number" or osd_h <= 0 then osd_h = 720 end
    local ui_scale = osd_w / 1920
    if ui_scale <= 0 then ui_scale = 1280 / 1920 end
    local function s(v) return math.floor(v * ui_scale) end

    -- 高度不足时按比例缩小
    local max_panel_h = osd_h - s(80)
    local h_scale = 1.0
    local base_panel_h = s(PANEL_BASE_H)
    if base_panel_h > max_panel_h and base_panel_h > 0 then
        h_scale = max_panel_h / base_panel_h
        if h_scale < 0.1 then h_scale = 0.1 end
    end

    local panel_w = math.floor(s(PANEL_BASE_W) * h_scale)
    local panel_h = math.floor(s(PANEL_BASE_H) * h_scale)

    -- 居中
    local panel_x = math.floor((osd_w - panel_w) / 2)
    local panel_y = math.floor((osd_h - panel_h) / 2)

    -- 内容区（UI.md 1.3.2）
    local content_y = panel_y + s(LAYOUT.title_h)
    local content_h = panel_h - s(LAYOUT.title_h) - s(LAYOUT.footer_h)

    -- 左右分栏
    local list_x = panel_x + s(LAYOUT.pad)
    local list_w = s(LAYOUT.list_width)
    local detail_x = list_x + list_w + s(LAYOUT.list_gap)
    local detail_w = panel_x + panel_w - s(LAYOUT.pad) - detail_x

    -- 底部提示栏位置（UI.md 12.3）
    local footer_y = panel_y + panel_h - math.floor(s(LAYOUT.footer_h) / 2)

    -- 关闭按钮（右上角，距边缘 s(8)，size s(28)）
    local close_size = s(28)
    local close_x = panel_x + panel_w - s(8) - close_size
    local close_y = panel_y + s(8)

    -- 列表行高与最大可见行数
    local row_h = s(LAYOUT.row_height)
    local max_visible_rows = math.floor((content_h - s(20)) / row_h)
    if max_visible_rows < 1 then max_visible_rows = 1 end

    return {
        osd_w = osd_w,
        osd_h = osd_h,
        ui_scale = ui_scale,
        s = s,
        panel_x = panel_x,
        panel_y = panel_y,
        panel_w = panel_w,
        panel_h = panel_h,
        content_y = content_y,
        content_h = content_h,
        list_x = list_x,
        list_w = list_w,
        detail_x = detail_x,
        detail_w = detail_w,
        footer_y = footer_y,
        close_x = close_x,
        close_y = close_y,
        close_size = close_size,
        row_h = row_h,
        max_visible_rows = max_visible_rows,
    }
end

-- ====== 扁平化 groups 到 flat_persons ======
-- 按 GROUP_ORDER 顺序遍历，为每个 person 添加 group 字段
local function flatten_groups(groups)
    local flat = {}
    if type(groups) ~= "table" then return flat end
    for _, gname in ipairs(GROUP_ORDER) do
        local persons = groups[gname]
        if type(persons) == "table" then
            for _, p in ipairs(persons) do
                if type(p) == "table" then
                    local copy = {}
                    for k, v in pairs(p) do
                        copy[k] = v
                    end
                    copy.group = gname
                    table.insert(flat, copy)
                end
            end
        end
    end
    return flat
end

-- ====== 调整滚动偏移，确保 selected_index 可见 ======
local function ensure_visible(index)
    local max_rows = state.max_visible_rows
    if max_rows < 1 then max_rows = 1 end
    if index < state.scroll_offset + 1 then
        state.scroll_offset = index - 1
    elseif index > state.scroll_offset + max_rows then
        state.scroll_offset = index - max_rows
    end
    if state.scroll_offset < 0 then state.scroll_offset = 0 end
end

-- ====== 渲染 ======

local function render()
    if not state.visible then return end
    if not state.overlay then return end
    local ass_lib = deps.ass_lib
    if not ass_lib then return end

    -- 递增版本号，使旧回调失效
    state.render_version = state.render_version + 1

    local osd_w, osd_h = ass_lib.get_osd_size()
    local layout = compute_layout(osd_w, osd_h)
    local ui_scale = layout.ui_scale
    local s = layout.s

    -- 更新 max_visible_rows 到 state（供滚动逻辑使用）
    state.max_visible_rows = layout.max_visible_rows

    local parts = {}

    -- 1. 面板背景（draw_rect, fill=121018, alpha=80）
    table.insert(parts, ass_lib.draw_rect(
        layout.panel_x, layout.panel_y, layout.panel_w, layout.panel_h,
        "121018", nil, 0, "80", "00"
    ))

    -- 2. 顶部装饰线（draw_rect, fill=88C0FC, alpha=00）
    table.insert(parts, ass_lib.draw_rect(
        layout.panel_x, layout.panel_y,
        layout.panel_w, s(1),
        "88C0FC", nil, 0, "00", "00"
    ))

    -- 3. 面板标题（fs=22*ui_scale, bold, color 88C0FC, \an5 居中）
    local title_fs = math.floor(22 * ui_scale)
    local title_center_y = layout.panel_y + math.floor(s(LAYOUT.title_h) / 2)
    table.insert(parts, string.format(
        "{\\an5\\pos(%d,%d)\\fs%d\\b1\\c&H%s&}%s\n",
        math.floor(layout.panel_x + layout.panel_w / 2),
        title_center_y,
        title_fs,
        ass_lib.hex_to_ass("88C0FC"),
        ass_lib.ass_escape(state.title ~= "" and state.title or "制作评分")
    ))

    -- 4. 左侧人员列表背景（fill=2A2930, alpha=C0）
    table.insert(parts, ass_lib.draw_rect(
        layout.list_x, layout.content_y, layout.list_w, layout.content_h,
        "2A2930", nil, 0, "C0", "00"
    ))

    -- 5. 左侧列表项（UI.md 1.3.3）
    local row_h = layout.row_h
    local list_inner_y = layout.content_y + s(10)
    local list_inner_h = layout.content_h - s(20)
    local max_rows = layout.max_visible_rows
    local total = #state.flat_persons

    -- 记录列表区域边界（供鼠标交互）
    state.list_bounds = {
        x = layout.list_x,
        y = list_inner_y,
        w = layout.list_w,
        h = list_inner_h,
        row_h = row_h,
    }

    local list_fs = math.floor(14 * ui_scale)
    local start_row = state.scroll_offset
    local end_row = math.min(total, start_row + max_rows)

    for i = start_row + 1, end_row do
        local person = state.flat_persons[i]
        if not person then break end
        local row_y = list_inner_y + (i - start_row - 1) * row_h
        local is_selected = (i == state.selected_index)

        -- 选中行高亮背景（fill=4A4950 alpha E0）
        if is_selected then
            table.insert(parts, ass_lib.draw_rect(
                layout.list_x, row_y, layout.list_w, row_h,
                "4A4950", nil, 0, "E0", "00"
            ))
            -- 左侧 4px 蓝色指示条（88C0FC）
            table.insert(parts, ass_lib.draw_rect(
                layout.list_x, row_y, s(4), row_h,
                "88C0FC", nil, 0, "00", "00"
            ))
        end

        -- 行内容：[组标签] 人员名
        local group_tag = truncate_text(to_str(person.group), 6)
        local person_name = truncate_text(to_str(person.name), 18)
        local text_color = is_selected and "FFFBFF" or "D0D0D0"
        local line_text = string.format(
            "{\\c&H%s&}[%s]{\\c&H%s&} %s",
            ass_lib.hex_to_ass("88C0FC"),
            ass_lib.ass_escape(group_tag),
            ass_lib.hex_to_ass(text_color),
            ass_lib.ass_escape(person_name)
        )
        table.insert(parts, string.format(
            "{\\an4\\pos(%d,%d)\\fs%d}%s\n",
            layout.list_x + s(8),
            row_y + math.floor((row_h - list_fs) / 2),
            list_fs,
            line_text
        ))
    end

    -- 6. 右侧详情区背景（fill=2A2930, alpha=C0）
    table.insert(parts, ass_lib.draw_rect(
        layout.detail_x, layout.content_y, layout.detail_w, layout.content_h,
        "2A2930", nil, 0, "C0", "00"
    ))

    -- 7. 关闭按钮（右上角）
    local close_size = layout.close_size
    local close_x = layout.close_x
    local close_y = layout.close_y
    -- 记录关闭按钮边界（供鼠标点击检测）
    state.close_btn = {x = close_x, y = close_y, size = close_size}
    -- 按钮背景
    table.insert(parts, ass_lib.draw_rect(
        close_x, close_y, close_size, close_size,
        "2A2930", nil, 0, "60", "00"
    ))
    -- X 符号（\an5 居中，color A0A0A0）
    local close_fs = math.floor(close_size * 0.6)
    table.insert(parts, string.format(
        "{\\an5\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
        math.floor(close_x + close_size / 2),
        math.floor(close_y + close_size / 2),
        close_fs,
        ass_lib.hex_to_ass("A0A0A0"),
        ass_lib.ass_escape("✕")
    ))

    -- 8. 右侧详情内容
    local detail = state.current_person_detail
    local dx = layout.detail_x + s(LAYOUT.detail_pad)
    local dy = layout.content_y + s(LAYOUT.detail_pad)
    local dw = layout.detail_w - s(LAYOUT.detail_pad) * 2

    if detail and detail.error then
        -- 错误状态
        local err_fs = math.floor(14 * ui_scale)
        table.insert(parts, string.format(
            "{\\an4\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
            dx, dy, err_fs,
            ass_lib.hex_to_ass("FF6B6B"),
            ass_lib.ass_escape("加载失败: " .. to_str(detail.error.msg or "未知错误"))
        ))
    elseif detail then
        -- 正常详情
        local person = detail.person or {}

        -- 人员名（fs=18*ui_scale, bold, FFFBFF）
        local name_fs = math.floor(18 * ui_scale)
        table.insert(parts, string.format(
            "{\\an4\\pos(%d,%d)\\fs%d\\b1\\c&H%s&}%s\n",
            dx, dy, name_fs,
            ass_lib.hex_to_ass("FFFBFF"),
            ass_lib.ass_escape(truncate_text(to_str(person.name), 30))
        ))
        dy = dy + name_fs + s(6)

        -- 大分数（fs=28*ui_scale, bold，按评分着色，右对齐 \an6）
        local score_fs = math.floor(28 * ui_scale)
        local score_val = detail.score
        local score_color = score_to_color(score_val)
        local score_text = score_val ~= nil and string.format("%.1f", score_val) or "—"
        table.insert(parts, string.format(
            "{\\an6\\pos(%d,%d)\\fs%d\\b1\\c&H%s&}%s\n",
            dx + dw, dy, score_fs,
            ass_lib.hex_to_ass(score_color),
            ass_lib.ass_escape(score_text)
        ))

        -- 有效作品数（fs=11*ui_scale, A0A0A0，紧贴大分数下方右对齐）
        local works_count = type(detail.works) == "table" and #detail.works or 0
        local count_fs = math.floor(11 * ui_scale)
        table.insert(parts, string.format(
            "{\\an6\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
            dx + dw, dy + score_fs + s(2), count_fs,
            ass_lib.hex_to_ass("A0A0A0"),
            ass_lib.ass_escape("有效作品 " .. works_count .. " 部")
        ))

        -- 担任角色（fs=13*ui_scale, 88C0FC）
        local rel_fs = math.floor(13 * ui_scale)
        table.insert(parts, string.format(
            "{\\an4\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
            dx, dy + s(4), rel_fs,
            ass_lib.hex_to_ass("88C0FC"),
            ass_lib.ass_escape("担任: " .. to_str(person.relation or person.group or "—"))
        ))
        dy = dy + score_fs + s(10)

        -- 分隔线（fill=555555, alpha=AA）
        table.insert(parts, ass_lib.draw_rect(
            dx, dy, dw, s(1),
            "555555", nil, 0, "AA", "00"
        ))
        dy = dy + s(8)

        -- 子指标（两列，fs=12*ui_scale，标签 A0A0A0）
        local sub_fs = math.floor(12 * ui_scale)
        local sub_row_h = sub_fs + s(6)
        local col_w = math.floor(dw / 2)

        -- 计算近作分（近 5 年作品数 * 5，上限 100）
        local current_year = tonumber(os.date("%Y")) or 2026
        local recent_count = 0
        if type(detail.works) == "table" then
            for _, w in ipairs(detail.works) do
                local y = tonumber(extract_year(to_str(w and w.date)))
                if y and y >= current_year - 5 then
                    recent_count = recent_count + 1
                end
            end
        end
        local recent_score = recent_count * 5
        if recent_score > 100 then recent_score = 100 end

        -- 翻车作数（无 per-work 评分数据，显示 0）
        local flop_count = 0

        local sub_metrics = {
            {label = "基础加权分", value = string.format("%.0f", score_val or 0), color = "D0D0D0"},
            {label = "近作分",     value = string.format("%.0f", recent_score),    color = "D0D0D0"},
            {label = "有效作品数", value = tostring(works_count),                   color = "D0D0D0"},
            {label = "翻车作",     value = tostring(flop_count),                    color = "FF6B6B"},
        }

        for idx, m in ipairs(sub_metrics) do
            if idx > 6 then break end
            local col = ((idx - 1) % 2)
            local row = math.floor((idx - 1) / 2)
            local mx = dx + col * col_w
            local my = dy + row * sub_row_h
            table.insert(parts, string.format(
                "{\\an4\\pos(%d,%d)\\fs%d}{\\c&H%s&}%s{\\c&H%s&} %s\n",
                mx, my, sub_fs,
                ass_lib.hex_to_ass("A0A0A0"),
                ass_lib.ass_escape(m.label .. ":"),
                ass_lib.hex_to_ass(m.color),
                ass_lib.ass_escape(m.value)
            ))
        end
        local sub_rows = math.ceil(#sub_metrics / 2)
        dy = dy + sub_rows * sub_row_h + s(6)

        -- 分隔线
        table.insert(parts, ass_lib.draw_rect(
            dx, dy, dw, s(1),
            "555555", nil, 0, "AA", "00"
        ))
        dy = dy + s(6)

        -- 历史作品列表（fs=12*ui_scale, color D0D0D0，按评分着色）
        local work_fs = math.floor(12 * ui_scale)
        local work_row_h = work_fs + s(4)
        -- 计算可用高度（留出底部边距）
        local detail_bottom = layout.content_y + layout.content_h - s(LAYOUT.detail_pad)
        local avail_h = detail_bottom - dy
        if avail_h < work_row_h then avail_h = work_row_h end
        local max_work_rows = math.floor(avail_h / work_row_h)
        if max_work_rows < 1 then max_work_rows = 1 end

        if type(detail.works) == "table" and #detail.works > 0 then
            local shown = 0
            for _, w in ipairs(detail.works) do
                if shown >= max_work_rows then break end
                local year = extract_year(to_str(w and w.date))
                local wtitle = truncate_text(get_work_title(w), 28)
                -- 无 per-work 评分，显示 "—"
                local wscore_str = "—"
                local wcolor = "A0A0A0"

                local wy = dy + shown * work_row_h
                table.insert(parts, string.format(
                    "{\\an4\\pos(%d,%d)\\fs%d}{\\c&H%s&}%s{\\c&H%s&} %s{\\c&H%s&} %s\n",
                    dx, wy, work_fs,
                    ass_lib.hex_to_ass("808080"),
                    ass_lib.ass_escape(year),
                    ass_lib.hex_to_ass("D0D0D0"),
                    ass_lib.ass_escape(wtitle),
                    ass_lib.hex_to_ass(wcolor),
                    ass_lib.ass_escape(wscore_str)
                ))
                shown = shown + 1
            end
            -- 若有更多作品未显示，显示提示
            if #detail.works > max_work_rows then
                local more_y = dy + max_work_rows * work_row_h
                if more_y < detail_bottom then
                    table.insert(parts, string.format(
                        "{\\an4\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
                        dx, more_y, work_fs,
                        ass_lib.hex_to_ass("808080"),
                        ass_lib.ass_escape("... 共 " .. #detail.works .. " 部作品")
                    ))
                end
            end
        else
            table.insert(parts, string.format(
                "{\\an4\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
                dx, dy, work_fs,
                ass_lib.hex_to_ass("A0A0A0"),
                ass_lib.ass_escape("暂无作品数据")
            ))
        end
    else
        -- 加载中占位
        local loading_fs = math.floor(16 * ui_scale)
        table.insert(parts, string.format(
            "{\\an5\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
            math.floor(layout.detail_x + layout.detail_w / 2),
            math.floor(layout.content_y + layout.content_h / 2),
            loading_fs,
            ass_lib.hex_to_ass("A0A0A0"),
            ass_lib.ass_escape("加载中...")
        ))
    end

    -- 9. 底部提示栏（fs=12*ui_scale, A0A0A0, \an5 居中 panel_x+panel_w/2）
    local hint_fs = math.floor(12 * ui_scale)
    table.insert(parts, string.format(
        "{\\an5\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
        math.floor(layout.panel_x + layout.panel_w / 2),
        layout.footer_y,
        hint_fs,
        ass_lib.hex_to_ass("A0A0A0"),
        ass_lib.ass_escape("ESC/Ctrl+右键 关闭 · ←→/↑↓ 切换人员 · 鼠标悬停选择 · 点击右上角✕")
    ))

    -- 10. 强制中文字体 gsub 注入（UI.md 5.2，ISSUE-013 修复）
    local ass_str = table.concat(parts)
    ass_str = ass_str:gsub("{\\fs(%d+)([^}]*)}", function(fs_num, rest)
        if rest and rest:find("\\p1") then
            return "{\\fs" .. fs_num .. rest .. "}"
        end
        return "{\\fs" .. fs_num .. "\\fnNoto Sans CJK SC" .. rest .. "}"
    end)

    -- 11. 更新 overlay（res_x/res_y 必须等于 osd_w/osd_h，V4-P3 修复）
    state.overlay.res_x = osd_w
    state.overlay.res_y = osd_h
    state.overlay.data = ass_str
    pcall(function() state.overlay:update() end)
end

-- ====== 前向声明 ======
local select_person

-- ====== fetch_person_score: 获取人员作品并计算评分 ======
-- person_id: 人员 ID
-- person: 人员对象（用于构建 detail）
-- 含 current_fetch_id 防止 stale 回调
local function fetch_person_score(person_id, person)
    if not deps.api or type(deps.api.get_person_works) ~= "function" then
        state.current_person_detail = {
            person = person,
            works = {},
            score = nil,
            error = {msg = "API 模块不可用"},
        }
        render()
        return
    end

    -- 递增 fetch_id，使旧回调失效
    local fetch_id = state.current_fetch_id + 1
    state.current_fetch_id = fetch_id

    local server_url = state.server_url or "https://api.bgm.tv"

    pcall(deps.api.get_person_works, person_id, server_url, function(success, works, err_info)
        -- 旧回调丢弃：fetch_id 不匹配或面板已关闭
        if fetch_id ~= state.current_fetch_id then return end
        if not state.visible then return end

        if success and type(works) == "table" then
            local score = calculate_score(works)
            state.current_person_detail = {
                person = person,
                works = works,
                score = score,
                error = nil,
            }
        else
            state.current_person_detail = {
                person = person,
                works = {},
                score = nil,
                error = err_info or {msg = "未知错误"},
            }
        end
        render()
    end)
end

-- ====== select_person: 选中指定索引的人员 ======
-- index: 1-based 扁平化索引
select_person = function(index)
    if not state.visible then return end
    if index < 1 or index > #state.flat_persons then return end

    state.selected_index = index
    state.current_person_detail = nil  -- 清空当前详情（显示"加载中..."）

    -- 调整滚动偏移
    ensure_visible(index)

    -- 先渲染一次（显示加载占位）
    render()

    -- 触发详情加载
    local person = state.flat_persons[index]
    if person and person.id ~= nil then
        fetch_person_score(person.id, person)
    else
        -- 无 id 的人员，直接显示空详情
        state.current_person_detail = {
            person = person or {},
            works = {},
            score = nil,
            error = nil,
        }
        render()
    end
end

-- ====== select_prev / select_next ======
local function select_prev()
    if not state.visible then return end
    if state.selected_index > 1 then
        select_person(state.selected_index - 1)
    end
end

local function select_next()
    if not state.visible then return end
    if state.selected_index < #state.flat_persons then
        select_person(state.selected_index + 1)
    end
end

-- ====== 鼠标交互 ======

-- mouse_callback: 鼠标悬停时选择对应行（由 input_service 订阅触发）
-- 签名: function(mouse_x, mouse_y)
local function mouse_callback(mx, my)
    if not state.visible then return end
    if not state.list_bounds then return end
    local lb = state.list_bounds
    -- 检查鼠标是否在列表区域内
    if mx < lb.x or mx >= lb.x + lb.w then return end
    if my < lb.y or my >= lb.y + lb.h then return end
    -- 计算行号（1-based，加上滚动偏移）
    local row = math.floor((my - lb.y) / lb.row_h) + 1 + state.scroll_offset
    if row >= 1 and row <= #state.flat_persons and row ~= state.selected_index then
        select_person(row)
    end
end

-- on_mouse_click: 检查是否点击关闭按钮（10px 容差）
local function on_mouse_click()
    if not state.visible then return end
    if not state.close_btn then return end
    local mouse = mp.get_property_native("mouse-pos")
    if type(mouse) ~= "table" then return end
    local mx = mouse.x
    local my = mouse.y
    if type(mx) ~= "number" or type(my) ~= "number" then return end
    local cb = state.close_btn
    local tol = 10
    if mx >= cb.x - tol and mx <= cb.x + cb.size + tol and
       my >= cb.y - tol and my <= cb.y + cb.size + tol then
        M.close()
    end
end

-- ====== 公共方法 ======

function M.is_visible()
    return state.visible
end

-- show: 入口
-- caller_deps: 调用方传入的 deps（用于解析 server_url，模块本身使用闭包注入的 deps）
-- persons_data: 9 组制作人员数据 { [组名] = {person, ...} }
-- title: 面板标题（番剧名）
function M.show(caller_deps, persons_data, title)
    -- 校验 persons_data 非空
    if type(persons_data) ~= "table" then
        if deps.notify then pcall(deps.notify.warn, "制作人员数据为空") end
        return
    end

    -- 扁平化 groups
    local flat = flatten_groups(persons_data)
    if #flat == 0 then
        if deps.notify then pcall(deps.notify.warn, "未找到制作人员") end
        return
    end

    -- 关闭其他面板 + 禁用 uosc
    if deps.ui_base then
        pcall(deps.ui_base.close_other_panels, "production_score")
        pcall(deps.ui_base.disable_uosc)
    end

    -- v1.9.5: 核选项强制关闭所有残留 uosc 菜单
    if deps.loading_controller and type(deps.loading_controller.nuclear_menu_dismiss) == "function" then
        pcall(deps.loading_controller.nuclear_menu_dismiss)
    end

    -- 解析 server_url（从 caller_deps.servers 获取，回退默认）
    local server_url = "https://api.bgm.tv"
    if caller_deps and caller_deps.servers
       and type(caller_deps.servers.get_active_bangumi_servers) == "function" then
        local ok, servers = pcall(caller_deps.servers.get_active_bangumi_servers)
        if ok and type(servers) == "table" and servers[1] then
            server_url = servers[1]
        end
    end

    -- 重置状态
    state.groups = persons_data
    state.title = to_str(title)
    state.flat_persons = flat
    state.selected_index = 1
    state.scroll_offset = 0
    state.render_version = state.render_version + 1
    state.current_fetch_id = state.current_fetch_id + 1  -- 使所有 stale 回调失效
    state.current_person_detail = nil
    state.server_url = server_url
    state.list_bounds = nil
    state.close_btn = nil

    -- 创建 overlay（若未创建）
    if not state.overlay then
        state.overlay = mp.create_osd_overlay('ass-events')
    end

    state.visible = true
    M.visible = true

    -- 首次渲染
    render()

    -- 注册按键（UI.md 7.3）
    -- v1.7.2: 统一添加 LEFT/RIGHT 翻页，与其他面板一致
    M.register_keys({
        {key="up",        name="production_score_up",        fn=select_prev,     forced=true, opts={repeatable=true}},
        {key="down",      name="production_score_down",      fn=select_next,     forced=true, opts={repeatable=true}},
        {key="LEFT",      name="production_score_left",      fn=select_prev,     forced=true, opts={repeatable=true}},
        {key="RIGHT",     name="production_score_right",     fn=select_next,     forced=true, opts={repeatable=true}},
        {key="esc",       name="production_score_close",     fn=M.close,         forced=true},
        {key="Ctrl+MBTN_RIGHT", name="production_score_close_m", fn=M.close,     forced=false},
        {key="mbtn_left", name="production_score_mbtn_left", fn=on_mouse_click,  forced=true},
    })

    -- 注册 OSD observer（osd-width/osd-height 变化时重新 render，仅在 visible 时）
    M.unregister_osd()
    M.register_osd_observers(function()
        if state.visible then render() end
    end, {"osd-width", "osd-height"}, 100, M.is_visible)

    -- 订阅鼠标输入
    if deps.input_service and not state.mouse_subscribed then
        state.mouse_callback = mouse_callback
        pcall(deps.input_service.subscribe, state.mouse_callback)
        state.mouse_subscribed = true
    end

    -- 触发首人详情加载
    select_person(state.selected_index)
end

-- ====== init 覆盖（make_panel_module 工厂使用模式，DESIGN.md 3.3）======

local base_init = init
function M.init(new_opts, new_deps)
    base_init(new_opts, new_deps)
    deps.ui_base.make_panel_module("production_score", M)

    M.set_cleanup(function()
        state.visible = false
        M.visible = false
        state.render_version = state.render_version + 1
        -- 使所有 stale 回调失效
        state.current_fetch_id = state.current_fetch_id + 1
        -- 移除 ASS overlay
        if state.overlay then
            pcall(function() state.overlay:remove() end)
            state.overlay = nil
        end
        -- 关闭鼠标订阅
        if state.mouse_subscribed and deps.input_service then
            pcall(deps.input_service.unsubscribe, state.mouse_callback)
            state.mouse_subscribed = false
            state.mouse_callback = nil
        end
        -- 清空详情状态
        state.current_person_detail = nil
        state.flat_persons = {}
        state.groups = {}
        state.title = ""
        state.selected_index = 1
        state.scroll_offset = 0
        state.list_bounds = nil
        state.close_btn = nil
    end)

    M.init_panel(deps, {is_visible = M.is_visible, close = M.close})
end

return M
