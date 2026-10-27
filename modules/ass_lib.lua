-- modules/ass_lib.lua
-- ASS 渲染辅助库
-- 提供 OSD 尺寸获取、坐标转换、颜色转换、文本转义、矩形/文本绘制等功能
-- 遵循 UI.md 2.2 节的 draw_rect 实现规范（\an7\pos(0,0) 绝对坐标模式）

local mp = require("mp")
local assdraw = require("mp.assdraw")

local M = {}

-- get_osd_size: 读取 osd-width/osd-height
-- 当属性为 0 或 nil 时返回默认值 1280×720
-- 返回 osd_w, osd_h
function M.get_osd_size()
    local w = mp.get_property_native("osd-width")
    local h = mp.get_property_native("osd-height")
    if not w or w == 0 then w = 1280 end
    if not h or h == 0 then h = 720 end
    return w, h
end

-- get_video_display_rect: 获取视频在 OSD 中的显示区域
-- 返回 { osd_w, osd_h, disp_x, disp_y, disp_w, disp_h, video_w, video_h }
function M.get_video_display_rect()
    local osd_w, osd_h = M.get_osd_size()
    local disp_w = mp.get_property_native("display-width") or osd_w
    local disp_h = mp.get_property_native("display-height") or osd_h
    local video_w = mp.get_property_native("width") or 0
    local video_h = mp.get_property_native("height") or 0
    local disp_x = 0
    local disp_y = 0

    -- 计算视频在 OSD 中的居中显示区域（保持宽高比）
    if video_w > 0 and video_h > 0 and disp_w > 0 and disp_h > 0 then
        local video_aspect = video_w / video_h
        local disp_aspect = disp_w / disp_h
        if video_aspect > disp_aspect then
            -- 视频更宽，按宽度缩放，垂直居中
            local scaled_h = disp_w / video_aspect
            disp_x = 0
            disp_y = math.floor((disp_h - scaled_h) / 2)
            disp_h = math.floor(scaled_h)
        else
            -- 视频更高，按高度缩放，水平居中
            local scaled_w = disp_h * video_aspect
            disp_x = math.floor((disp_w - scaled_w) / 2)
            disp_y = 0
            disp_w = math.floor(scaled_w)
        end
    end

    return {
        osd_w = osd_w,
        osd_h = osd_h,
        disp_x = disp_x,
        disp_y = disp_y,
        disp_w = disp_w,
        disp_h = disp_h,
        video_w = video_w,
        video_h = video_h,
    }
end

-- osd_to_video_coords: OSD 坐标转视频像素坐标
-- osd_x, osd_y: OSD 逻辑坐标
-- rect: 可选，预计算的 get_video_display_rect 结果
-- 返回 video_x, video_y
function M.osd_to_video_coords(osd_x, osd_y, rect)
    rect = rect or M.get_video_display_rect()
    if rect.disp_w <= 0 or rect.disp_h <= 0 then
        return 0, 0
    end
    -- 相对 OSD 显示区域的偏移
    local rel_x = osd_x - rect.disp_x
    local rel_y = osd_y - rect.disp_y
    -- 转换到视频像素坐标
    local video_x = math.floor(rel_x * (rect.video_w / rect.disp_w))
    local video_y = math.floor(rel_y * (rect.video_h / rect.disp_h))
    return video_x, video_y
end

-- hex_to_ass: RRGGBB -> BBGGRR 颜色转换
-- ASS 颜色格式为 &HBBGGRR
-- 无效输入返回 FFFFFF（白色）
function M.hex_to_ass(hex)
    if type(hex) ~= "string" then return "FFFFFF" end
    -- 去除前缀 #
    hex = hex:gsub("^#", "")
    -- 必须是 6 位十六进制
    if not hex:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
        return "FFFFFF"
    end
    local r = hex:sub(1, 2)
    local g = hex:sub(3, 4)
    local b = hex:sub(5, 6)
    return b .. g .. r
end

-- 内部：alpha 转换为 ASS 2 位十六进制
-- 接受数字（0-255）、字符串（2 位十六进制如 "80" 或数字字符串）
-- ASS alpha: 00 = 不透明, FF = 完全透明
local function alpha_to_ass(alpha)
    if alpha == nil then return "00" end
    if type(alpha) == "string" then
        -- 已经是 2 位十六进制字符串
        if alpha:match("^[0-9a-fA-F][0-9a-fA-F]$") then
            return alpha:upper()
        end
        -- 尝试转为数字
        local n = tonumber(alpha)
        if n then
            if n < 0 then n = 0 end
            if n > 255 then n = 255 end
            return string.format("%02X", math.floor(n))
        end
        return "00"
    end
    if type(alpha) == "number" then
        local n = alpha
        if n < 0 then n = 0 end
        if n > 255 then n = 255 end
        return string.format("%02X", math.floor(n))
    end
    return "00"
end

-- ass_escape: ASS 文本转义
-- 转义字符: \ { } \n \r \t \0
-- 顺序很重要：先转义反斜杠，再转义花括号
function M.ass_escape(text)
    if text == nil then return "" end
    text = tostring(text)
    -- 先转义反斜杠（避免后续转义被二次处理）
    text = text:gsub("\\", "\\\\")
    -- 转义花括号
    text = text:gsub("{", "\\{")
    text = text:gsub("}", "\\}")
    -- 换行符 -> ASS 硬换行 \N
    text = text:gsub("\n", "\\N")
    -- 回车符 -> 移除（避免空行）
    text = text:gsub("\r", "")
    -- 制表符 -> ASS 硬空格 \h
    text = text:gsub("\t", "\\h")
    -- 空字节 -> 移除
    text = text:gsub("\0", "")
    return text
end

-- 内部：将坐标转为整数（用于 string.format %d）
local function to_int(v)
    if v == nil then return 0 end
    local n = tonumber(v)
    if not n then return 0 end
    return math.floor(n)
end

-- draw_rect: 矩形绘制（填充 + 描边）
-- 使用 \an7\pos(0,0) 绝对坐标模式（V4-P3 统一）
-- x, y, w, h: 矩形位置和尺寸
-- fill_color: 填充颜色（RRGGBB 字符串），nil 表示不填充
-- border_color: 边框颜色（RRGGBB 字符串），nil 表示无边框
-- border_w: 边框宽度（像素）
-- fill_alpha: 填充透明度（0-255 数字或 2 位十六进制字符串），nil 表示不透明
-- border_alpha: 边框透明度，同上
-- 边框实现：4 条矩形边（顶/底/左/右），向外扩展 bs = max(1, floor(border_w)) 像素
function M.draw_rect(x, y, w, h, fill_color, border_color, border_w, fill_alpha, border_alpha)
    if not x or not y or not w or not h then return "" end
    x = to_int(x)
    y = to_int(y)
    w = to_int(w)
    h = to_int(h)
    local parts = {}
    local x2 = x + w
    local y2 = y + h

    -- 填充矩形
    if fill_color ~= nil then
        local bbggrr = M.hex_to_ass(fill_color)
        local alpha = alpha_to_ass(fill_alpha)
        table.insert(parts, string.format(
            "{\\fs1\\1c&H%s&\\1a&H%s&\\bord0\\shad0\\an7\\p1\\pos(0,0)}m %d %d l %d %d l %d %d l %d %d{\\p0}\n",
            bbggrr, alpha,
            x, y, x2, y, x2, y2, x, y2
        ))
    end

    -- 边框：4 条矩形边
    if border_color ~= nil and border_w ~= nil and tonumber(border_w) and tonumber(border_w) > 0 then
        local bbggrr = M.hex_to_ass(border_color)
        local balpha = alpha_to_ass(border_alpha)
        local bs = math.max(1, math.floor(tonumber(border_w)))
        -- 顶边
        table.insert(parts, string.format(
            "{\\fs1\\1c&H%s&\\1a&H%s&\\bord0\\shad0\\an7\\p1\\pos(0,0)}m %d %d l %d %d l %d %d l %d %d{\\p0}\n",
            bbggrr, balpha,
            x - bs, y - bs, x2 + bs, y - bs, x2 + bs, y, x - bs, y
        ))
        -- 底边
        table.insert(parts, string.format(
            "{\\fs1\\1c&H%s&\\1a&H%s&\\bord0\\shad0\\an7\\p1\\pos(0,0)}m %d %d l %d %d l %d %d l %d %d{\\p0}\n",
            bbggrr, balpha,
            x - bs, y2, x2 + bs, y2, x2 + bs, y2 + bs, x - bs, y2 + bs
        ))
        -- 左边
        table.insert(parts, string.format(
            "{\\fs1\\1c&H%s&\\1a&H%s&\\bord0\\shad0\\an7\\p1\\pos(0,0)}m %d %d l %d %d l %d %d l %d %d{\\p0}\n",
            bbggrr, balpha,
            x - bs, y, x, y, x, y2, x - bs, y2
        ))
        -- 右边
        table.insert(parts, string.format(
            "{\\fs1\\1c&H%s&\\1a&H%s&\\bord0\\shad0\\an7\\p1\\pos(0,0)}m %d %d l %d %d l %d %d l %d %d{\\p0}\n",
            bbggrr, balpha,
            x2, y, x2 + bs, y, x2 + bs, y2, x2, y2
        ))
    end

    return table.concat(parts)
end

-- draw_round_rect: draw a rounded rectangle with mpv's assdraw path API.
-- This follows the event/path lifecycle used by mp.assdraw (new_event,
-- draw_start, round_rect_cw, draw_stop) instead of hand-building \p1 data.
-- Coordinates and color/alpha arguments match draw_rect.
function M.draw_round_rect(x, y, w, h, fill_color, border_color, border_w, fill_alpha, border_alpha, radius)
    if not x or not y or not w or not h then return "" end
    x = to_int(x)
    y = to_int(y)
    w = to_int(w)
    h = to_int(h)
    if w <= 0 or h <= 0 then return "" end

    local corner_radius = math.max(0, to_int(radius or 8))
    corner_radius = math.min(corner_radius, math.floor(math.min(w, h) / 2))

    local border_width = tonumber(border_w) or 0
    if not border_color or border_width <= 0 then
        border_width = 0
    else
        border_width = math.max(1, math.floor(border_width))
    end

    local fill_bbggrr = M.hex_to_ass(fill_color or "FFFFFF")
    local border_bbggrr = M.hex_to_ass(border_color or fill_color or "FFFFFF")
    local fill_alpha_ass = fill_color and alpha_to_ass(fill_alpha) or "FF"
    local border_alpha_ass = border_color and alpha_to_ass(border_alpha) or "00"

    local ass = assdraw.ass_new()
    ass:new_event()
    ass:pos(0, 0)
    ass:append(string.format(
        "{\\blur0\\shad0\\an7\\1c&H%s&\\1a&H%s&\\3c&H%s&\\3a&H%s&\\bord%d}",
        fill_bbggrr, fill_alpha_ass, border_bbggrr, border_alpha_ass, border_width
    ))
    ass:draw_start()
    ass:round_rect_cw(x, y, x + w, y + h, corner_radius)
    ass:draw_stop()
    return ass.text
end

-- draw_text: 单行文本绘制
-- x, y: 文本左上角坐标（\an7 对齐）
-- text: 文本内容（会自动 ass_escape）
-- style: 可选样式字符串，直接拼接到 {} 中（如 "\\fs22\\b1\\c&HFFFBFF&"）
function M.draw_text(x, y, text, style)
    if text == nil then return "" end
    text = tostring(text)
    x = to_int(x)
    y = to_int(y)
    local style_str = style or ""
    if style_str ~= "" and style_str:sub(1, 1) ~= "\\" then
        style_str = "\\" .. style_str
    end
    return string.format(
        "{\\an7\\pos(%d,%d)%s}%s\n",
        x, y, style_str, M.ass_escape(text)
    )
end

-- render_empty_state: 渲染居中的空状态提示
-- overlay: mp.create_osd_overlay('ass-events') 创建的 overlay 对象
-- msg: 主消息文本
-- hint: 可选提示文本（显示在主消息下方）
-- 所有字号和偏移基于 ui_scale = osd_w / 1920 动态缩放，与三个面板模块保持一致
function M.render_empty_state(overlay, msg, hint)
    if not overlay then return end
    local osd_w, osd_h = M.get_osd_size()
    local ui_scale = osd_w / 1920
    local parts = {}
    local center_x = math.floor(osd_w / 2)
    local center_y = math.floor(osd_h / 2)

    -- 半透明背景矩形（居中，占屏幕中间 1/2 × 1/3）
    local bg_x = math.floor(osd_w / 4)
    local bg_y = math.floor(osd_h / 3)
    local bg_w = math.floor(osd_w / 2)
    local bg_h = math.floor(osd_h / 3)
    table.insert(parts, M.draw_rect(
        bg_x, bg_y, bg_w, bg_h,
        "121018", nil, 0, "80", "00"
    ))

    -- 主消息（居中，\an5 对齐）
    local msg_fs = math.floor(28 * ui_scale)
    local msg_offset = math.floor(10 * ui_scale)
    table.insert(parts, string.format(
        "{\\an5\\pos(%d,%d)\\fs%d\\c&HFFFBFF&\\b1}%s\n",
        center_x, center_y - msg_offset, msg_fs, M.ass_escape(msg or "")
    ))

    -- 提示文本（可选，居中，\an5 对齐）
    if hint and hint ~= "" then
        local hint_fs = math.floor(16 * ui_scale)
        local hint_offset = math.floor(30 * ui_scale)
        table.insert(parts, string.format(
            "{\\an5\\pos(%d,%d)\\fs%d\\c&HA0A0A0&}%s\n",
            center_x, center_y + hint_offset, hint_fs, M.ass_escape(hint)
        ))
    end

    -- 更新 overlay
    overlay.res_x = osd_w
    overlay.res_y = osd_h
    overlay.data = table.concat(parts)
    overlay:update()
end

return M
