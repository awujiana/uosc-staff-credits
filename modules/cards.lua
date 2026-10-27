-- modules/cards.lua
-- 角色介绍面板 - 卡片化展示角色与声优信息
-- 遵循 UI.md 1.1 节（角色介绍面板）布局规范
-- 遵循 UI.md 7.1 节（按键绑定）、12.1/12.4 节（底部提示栏/翻页反馈）
-- 使用 DESIGN.md 3 节 make_panel_module 工厂注入公共方法
-- overlay id 分配：0-31 角色图片，32-47 CV 头像

local mp = require("mp")
local msg = require("mp.msg")

-- v1.7: 通用组件（pagination / overlay_manager / mouse_interaction）
local pagination = require("modules.pagination")
local overlay_manager = require("modules.overlay_manager")
local mouse_interaction = require("modules.mouse_interaction")

local M = {}

-- ====== 模块工厂初始化（make_init）======
local opts, deps, init = require("modules.utils.module_loader").make_init(
    "cards",
    {
        ui_base = "table",
        panel_registry = "table",
        input_service = "table",
        ass_lib = "table",
        notify = "table",
        request_registry = "table",
        utils = "table",
    }
)
M.init = init

-- ====== LAYOUT 常量表（UI.md 1.1.1）======
local LAYOUT = {
    title_h = 40,
    separator_h = 8,
    hint_h = 30,
    margin = 40,
    no_image_line_h = 24,
    no_image_max_lines = 3,
    no_image_per_line = 6,
    no_image_padding = 28,
    visible_rows = 2,
    card_spacing = 12,
    card_w = 200,
    min_card_h = 220,
    max_card_h = 420,
    cv_line_h = 24,
    min_per_row = 2,
    max_per_row = 5,
    img_padding = 6,
    img_h_ratio = 0.70,
    text_area_h = 0.30,
    title_start_offset = 10,
    -- v1.7: btn_* 常量已移除，改由 modules/pagination.lua 统一管理
}

-- ====== 模块本地状态 ======
local state = {
    visible = false,
    characters = {},         -- 原始角色列表
    with_images = {},        -- 有图角色列表（卡片网格分页用）
    without_images = {},     -- 无图角色列表（底部文字区）
    title = "",
    offset = 0,              -- 翻页偏移（以 with_images 为准）
    layout = nil,            -- compute_layout 结果
    overlay = nil,           -- mp.create_osd_overlay('ass-events') 句柄
    page_feedback = nil,     -- "up" / "down" / nil
    page_feedback_timer = nil,
    render_version = 0,      -- 旧回调失效标记
    hover_index = 0,         -- 鼠标悬停的卡片索引（1-indexed，0 表示无悬停）
    hover_button = nil,      -- 鼠标悬停的按钮："prev" / "next" / nil（保留供 render 使用）
    -- v1.7: 通用组件状态（替代 mouse_subscribed/mouse_callback/image_overlays）
    pagination_layout = nil, -- pagination.compute_layout 结果
    overlay_id_range = nil,  -- overlay_manager.alloc_id 返回的 id 区间（nil 表示降级模式）
    in_flight_downloads = {},-- 进行中下载条目列表
    pending_retry = {},      -- 重试定时器列表
    cv_avatars = {},         -- CV 头像缓存（预留）
    close_btn = nil,         -- v1.7.2: 右上角关闭按钮区域 {x, y, size}
}

-- ====== 内部辅助：角色数据提取 ======

-- 解析角色名称：优先简体中文 name_cn，回退 name
-- v1.6: 角色介绍要求使用简体中文显示角色名
local function resolve_character_name(char)
    if type(char) ~= "table" then return "未知角色" end
    if type(char.name_cn) == "string" and char.name_cn ~= "" then
        return char.name_cn
    end
    if type(char.name) == "string" and char.name ~= "" then
        return char.name
    end
    return "未知角色"
end

-- 解析 CV 名称：优先简体中文 name_cn，回退 name
-- v1.6: 角色介绍要求 CV 名字使用简体中文
local function resolve_cv_name(actor)
    if type(actor) ~= "table" then return nil end
    if type(actor.name_cn) == "string" and actor.name_cn ~= "" then
        return actor.name_cn
    end
    if type(actor.name) == "string" and actor.name ~= "" then
        return actor.name
    end
    return nil
end

-- 检查角色是否有可用图片
local function has_character_image(char)
    if type(char) ~= "table" then return false end
    -- v1.6: 多数据源图片字段适配
    -- bangumi: images.medium（主要）/ images.large / images.small
    -- anilist/mal: images.large / images.medium
    local images = char.images
    if type(images) == "string" and images ~= "" then return true end
    if type(images) == "table" then
        local url = images.medium or images.large or images.common or images.url
        if type(url) == "string" and url ~= "" then return true end
    end
    return false
end

-- 获取角色图片 URL
local function get_character_image_url(char)
    if type(char) ~= "table" then return nil end
    -- v1.6: 多数据源图片字段适配
    local images = char.images
    -- bangumi/anilist/mal: images 可能是字符串 URL 或对象
    if type(images) == "string" and images ~= "" then return images end
    if type(images) == "table" then
        local url = images.medium or images.large or images.common or images.url
        if type(url) == "string" and url ~= "" then return url end
    end
    return nil
end

-- 获取角色 actors 列表（声优）
local function get_cv_list(char)
    if type(char) ~= "table" then return {} end
    local actors = char.actors
    if type(actors) ~= "table" then return {} end
    return actors
end

-- 获取首个 CV 名字（优先简体中文）
local function get_first_cv_name(char)
    local actors = get_cv_list(char)
    if #actors == 0 then return nil end
    local first = actors[1]
    if type(first) ~= "table" then return nil end
    -- v1.6: 优先使用简体中文 CV 名
    return resolve_cv_name(first)
end

-- 获取首个 CV 头像 URL
-- bangumi: actor.images.medium（主要）/ large / small
local function get_first_cv_avatar_url(char)
    local actors = get_cv_list(char)
    if #actors == 0 then return nil end
    local first = actors[1]
    if type(first) ~= "table" then return nil end
    -- bangumi/anilist/mal: images 对象或字符串
    if type(first.images) == "string" and first.images ~= "" then
        return first.images
    end
    if type(first.images) == "table" then
        local u = first.images.medium or first.images.large or first.images.url
        if type(u) == "string" and u ~= "" then return u end
    end
    return nil
end

-- 拆分角色为有图/无图两组
local function split_characters(chars)
    local with_img = {}
    local without_img = {}
    for _, c in ipairs(chars) do
        if has_character_image(c) then
            table.insert(with_img, c)
        else
            table.insert(without_img, c)
        end
    end
    return with_img, without_img
end

-- v1.6: 构造角色卡片第二行文本: "关系 CV cv_name"
-- 关系缺失时仅显示 "CV cv_name"
-- 例: "主角 CV 内田雄馬" / "CV 未知"
local function build_relation_cv_line(char)
    local rel = char.relation
    local has_rel = type(rel) == "string" and rel ~= ""
    local cv_name = get_first_cv_name(char)
    local cv_display = cv_name or "未知"

    if has_rel then
        return rel .. " CV " .. cv_display
    end
    return "CV " .. cv_display
end

-- ====== compute_layout（UI.md 1.1.2）======
-- 全屏自适应布局计算
local function compute_layout(osd_w, osd_h, with_images_count, without_images_count)
    -- 防御：osd 尺寸异常时回退到默认值（避免负数/0/NaN 导致 layout 崩溃）
    if type(osd_w) ~= "number" or osd_w <= 0 then osd_w = 1280 end
    if type(osd_h) ~= "number" or osd_h <= 0 then osd_h = 720 end
    local ui_scale = osd_w / 1920
    if ui_scale <= 0 then ui_scale = 1280 / 1920 end
    local function s(v) return math.floor(v * ui_scale) end

    -- 可用宽度
    local avail_w = osd_w - 2 * s(LAYOUT.margin)

    -- 列数计算（限制 [min_per_row, max_per_row]）
    local spacing = s(LAYOUT.card_spacing)
    local base_card_w = s(LAYOUT.card_w)
    local per_row = math.floor((avail_w + spacing) / (base_card_w + spacing))
    if per_row < LAYOUT.min_per_row then per_row = LAYOUT.min_per_row end
    if per_row > LAYOUT.max_per_row then per_row = LAYOUT.max_per_row end

    -- 动态扩大卡片：当 per_row 达到 max_per_row 后仍有空间，扩大 card_w 填满，最大 s(240)
    local card_w = base_card_w
    if per_row >= LAYOUT.max_per_row then
        local total_with_base = per_row * base_card_w + (per_row - 1) * spacing
        local extra_space = avail_w - total_with_base
        if extra_space > 0 then
            local max_card_w = s(240)
            card_w = base_card_w + math.floor(extra_space / per_row)
            if card_w > max_card_w then card_w = max_card_w end
        end
    end

    -- 无图区域高度
    local no_image_count = without_images_count or 0
    local no_image_line_h = s(LAYOUT.no_image_line_h)
    local no_image_area_h = 0
    if no_image_count > 0 then
        local lines_needed = math.ceil(no_image_count / LAYOUT.no_image_per_line)
        if lines_needed > LAYOUT.no_image_max_lines then
            lines_needed = LAYOUT.no_image_max_lines
        end
        no_image_area_h = lines_needed * no_image_line_h
    end

    -- 可用高度（卡片网格可用）
    local no_image_padding = s(LAYOUT.no_image_padding)
    local avail_h = osd_h
        - s(LAYOUT.margin) * 2
        - s(LAYOUT.title_h)
        - s(LAYOUT.separator_h)
        - s(LAYOUT.hint_h)
        - no_image_padding * 2
        - no_image_area_h
    if avail_h < 0 then avail_h = 0 end

    -- 卡片高度
    local cv_line_h = s(LAYOUT.cv_line_h)
    local card_h = math.floor((avail_h - s(LAYOUT.card_spacing) * (LAYOUT.visible_rows - 1)) / LAYOUT.visible_rows) + cv_line_h
    local min_card_h = s(LAYOUT.min_card_h)
    local max_card_h = s(LAYOUT.max_card_h)
    if card_h < min_card_h then card_h = min_card_h end
    if card_h > max_card_h then card_h = max_card_h end

    -- 水平居中
    local total_w = per_row * card_w + (per_row - 1) * spacing
    local start_x = math.floor((osd_w - total_w) / 2)
    if start_x < s(LAYOUT.margin) then start_x = s(LAYOUT.margin) end

    -- 垂直布局
    local title_y = s(LAYOUT.margin)
    local separator_y = title_y + s(LAYOUT.title_h)
    local cards_y = separator_y + s(LAYOUT.separator_h) + s(LAYOUT.title_start_offset) + no_image_padding
    local cards_h = LAYOUT.visible_rows * card_h + (LAYOUT.visible_rows - 1) * spacing
    local no_image_y = cards_y + cards_h + no_image_padding
    local hint_y = osd_h - math.floor(40 * ui_scale)

    -- 图片与文字区域尺寸
    local img_padding_scaled = s(LAYOUT.img_padding)
    local img_h = math.floor(card_h * LAYOUT.img_h_ratio)
    local text_area_h = card_h - img_h
    if text_area_h < 0 then text_area_h = 0 end

    -- v1.7: btn_* 坐标计算已移至 modules/pagination.lua（compute_layout 内部处理）
    return {
        osd_w = osd_w,
        osd_h = osd_h,
        ui_scale = ui_scale,
        s = s,
        per_row = per_row,
        card_w = card_w,
        card_h = card_h,
        visible_rows = LAYOUT.visible_rows,
        visible_count = per_row * LAYOUT.visible_rows,
        spacing = spacing,
        start_x = start_x,
        total_w = total_w,
        title_y = title_y,
        separator_y = separator_y,
        cards_y = cards_y,
        cards_h = cards_h,
        no_image_y = no_image_y,
        no_image_area_h = no_image_area_h,
        no_image_line_h = no_image_line_h,
        no_image_padding = no_image_padding,
        hint_y = hint_y,
        cv_line_h = cv_line_h,
        img_padding = img_padding_scaled,
        img_h = img_h,
        text_area_h = text_area_h,
        -- v1.7: 翻页位置配置（供 pagination 组件读取）
        pagination_position = (opts and opts.pagination_position) or "bottom",
    }
end

-- ====== 图片下载与 overlay 管理 ======

-- v1.7: 清除所有已添加的图片 overlay（改用 overlay_manager 统一管理）
local function clear_image_overlays()
    overlay_manager.remove_all()
end

-- 取消所有进行中的下载
-- 杀掉 pending_retry 定时器 + 调用 in_flight 条目的 abort_fn
local function abort_in_flight_downloads()
    for i = #state.pending_retry, 1, -1 do
        local timer = state.pending_retry[i]
        if timer then
            pcall(function() mp.cancel_timer(timer) end)
        end
        table.remove(state.pending_retry, i)
    end
    for i = #state.in_flight_downloads, 1, -1 do
        local entry = state.in_flight_downloads[i]
        if type(entry) == "table" and type(entry.abort_fn) == "function" then
            pcall(entry.abort_fn)
        end
        table.remove(state.in_flight_downloads, i)
    end
end

-- 内部：构造下载 opts（共享 in_flight_list / pending_retry_list）
-- v1.6: url 参数用于提取 origin 作为 Referer（防盗链绕过）
local function make_download_opts(url)
    local referer = nil
    if type(url) == "string" and url ~= "" then
        referer = url:match("^https?://[^/]+") or url
    end
    return {
        prefix = "staff_credits_",
        cache_days = tonumber(opts.image_cache_days) or 30,
        timeout = tonumber(opts.timeout) or 10,
        mpv_path = opts.mpv_path or "",
        max_concurrent = 4,
        in_flight_list = state.in_flight_downloads,
        pending_retry_list = state.pending_retry,
        user_agent = opts.user_agent,
        proxy = opts.proxy,
        referer = referer,  -- v1.6: 防盗链支持
        -- v1.6: SSL/TLS 选项（修复 Windows curl exit code 35）
        ssl_no_revoke = opts.ssl_no_revoke == true,
        cacert_path = opts.cacert_path or "",
        insecure = opts.insecure == true,
    }
end

-- v1.7: record_overlay_id 已移除（overlay_manager.add 内部维护 active_ids）

-- 下载角色卡片图片（当前页可见角色）
-- overlay id：由 overlay_manager 分配，无分配时降级 0-31
local function download_card_images()
    if not state.layout then return end
    if not deps.ui_base or type(deps.ui_base.download_image_with_cache) ~= "function" then
        msg.debug("[cards] download_card_images: ui_base.download_image_with_cache not available")
        return
    end
    local layout = state.layout
    local cards = state.with_images
    if #cards == 0 then
        msg.debug("[cards] download_card_images: no cards with images")
        return
    end

    local end_idx = math.min(state.offset + layout.visible_count, #cards)
    local capture_version = state.render_version
    -- v1.7: overlay id 由 overlay_manager 分配；无分配时降级使用固定 0..31
    local id_range = state.overlay_id_range
    local id_base = (id_range and id_range.start_id) or 0

    for i = state.offset + 1, end_idx do
        local char = cards[i]
        if not char then break end

        local url = get_character_image_url(char)
        if url then
            msg.debug("[cards] download_card_images: downloading for slot %d: %s", i - state.offset - 1, url)
            local slot = i - state.offset - 1  -- 0-indexed
            local row = math.floor(slot / layout.per_row)
            local col = slot % layout.per_row
            local card_x = layout.start_x + col * (layout.card_w + layout.spacing)
            local card_y = layout.cards_y + row * (layout.card_h + layout.spacing)
            local img_x = card_x + layout.img_padding
            local img_y = card_y + layout.img_padding
            local target_w = layout.card_w - 2 * layout.img_padding
            local target_h = layout.img_h
            local overlay_id = id_base + slot  -- v1.7: 基于 alloc_id 起点 + slot

            if target_w > 0 and target_h > 0 and slot < 32 then
                local dl_opts = make_download_opts(url)
                pcall(deps.ui_base.download_image_with_cache, url, target_w, target_h, dl_opts,
                    function(success, bgra_path, w, h)
                        -- 旧回调丢弃：版本不匹配或面板已关闭
                        if capture_version ~= state.render_version then return end
                        if not state.visible then return end
                        if not success or not bgra_path then
                            msg.debug("[cards] download_card_images: callback failed for slot %d", slot)
                            return
                        end
                        if w <= 0 or h <= 0 then return end
                        msg.debug("[cards] download_card_images: overlay-add id=%d pos=%d,%d size=%dx%d",
                            overlay_id, img_x, img_y, w, h)
                        -- v1.7: 改用 overlay_manager.add（含文件验证 + pcall 包裹）
                        local ok = overlay_manager.add(overlay_id, img_x, img_y, bgra_path, w, h)
                        if not ok then
                            msg.debug("[cards] download_card_images: overlay-add failed for slot %d", slot)
                        end
                    end)
            end
        else
            msg.debug("[cards] download_card_images: no URL for slot %d, char name=%s",
                i - state.offset - 1, char.name or "?")
        end
    end
end

-- 下载 CV 头像（当前页可见角色的首个 CV 头像）
-- overlay id：由 overlay_manager 分配，无分配时降级 32..47
local function download_cv_avatars()
    if not state.layout then return end
    if not deps.ui_base or type(deps.ui_base.download_image_with_cache) ~= "function" then
        return
    end
    local layout = state.layout
    local cards = state.with_images
    if #cards == 0 then return end

    local end_idx = math.min(state.offset + layout.visible_count, #cards)
    local capture_version = state.render_version
    local avatar_size = layout.cv_line_h
    if avatar_size < 16 then avatar_size = 16 end
    -- v1.7: overlay id 基点（alloc_id 起点 + 32 偏移到 CV 头像区）
    local id_range = state.overlay_id_range
    local cv_id_base = (id_range and id_range.start_id or 0) + 32

    for i = state.offset + 1, end_idx do
        local char = cards[i]
        if not char then break end

        local cv_url = get_first_cv_avatar_url(char)
        if cv_url then
            local slot = i - state.offset - 1
            local row = math.floor(slot / layout.per_row)
            local col = slot % layout.per_row
            local card_x = layout.start_x + col * (layout.card_w + layout.spacing)
            local card_y = layout.cards_y + row * (layout.card_h + layout.spacing)
            -- CV 头像位于文字区域底部左侧
            local text_y = card_y + layout.img_h
            local avatar_x = card_x + layout.img_padding
            local avatar_y = text_y + layout.text_area_h - layout.cv_line_h - 2
            local overlay_id = cv_id_base + slot  -- v1.7: 基于 alloc_id 起点 + 32 + slot

            if slot < 16 then
                local dl_opts = make_download_opts(cv_url)
                pcall(deps.ui_base.download_image_with_cache, cv_url, avatar_size, avatar_size, dl_opts,
                    function(success, bgra_path, w, h)
                        if capture_version ~= state.render_version then return end
                        if not state.visible then return end
                        if not success or not bgra_path then return end
                        if w <= 0 or h <= 0 then return end
                        -- v1.7: 改用 overlay_manager.add（含文件验证 + pcall 包裹）
                        overlay_manager.add(overlay_id, avatar_x, avatar_y, bgra_path, w, h)
                    end)
            end
        end
    end
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
    local with_imgs = state.with_images or {}
    local without_imgs = state.without_images or {}

    local layout = compute_layout(osd_w, osd_h, #with_imgs, #without_imgs)
    state.layout = layout

    -- v1.7: 计算翻页按钮布局（使用通用组件，替代内联 btn_* 计算）
    state.pagination_layout = pagination.compute_layout(layout, state.offset, #with_imgs, layout.visible_count)

    local parts = {}

    -- 1. 标题（居中，fs=28*ui_scale，bold，FFFBFF）
    local title_fs = math.floor(28 * layout.ui_scale)
    local title_center_y = layout.title_y + math.floor(layout.s(LAYOUT.title_h) / 2)
    table.insert(parts, string.format(
        "{\\an5\\pos(%d,%d)\\fs%d\\b1\\c&H%s&}%s\n",
        math.floor(osd_w / 2),
        title_center_y,
        title_fs,
        ass_lib.hex_to_ass("FFFBFF"),
        ass_lib.ass_escape(state.title or "")
    ))

    -- 1b. 右上角关闭按钮（v1.7.2: 供鼠标使用）
    local close_size = layout.s(28)
    local close_x = layout.start_x + layout.total_w + layout.s(12) - close_size
    local close_y = layout.title_y
    state.close_btn = {x = close_x, y = close_y, size = close_size}
    table.insert(parts, ass_lib.draw_rect(
        close_x, close_y, close_size, close_size,
        "2A2930", nil, 0, "60", "00"
    ))
    local close_fs = math.floor(close_size * 0.6)
    table.insert(parts, string.format(
        "{\\an5\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
        math.floor(close_x + close_size / 2),
        math.floor(close_y + close_size / 2),
        close_fs,
        ass_lib.hex_to_ass("A0A0A0"),
        ass_lib.ass_escape("✕")
    ))

    -- 2. 分隔线（draw_rect, fill=88C0FC, alpha=00）
    table.insert(parts, ass_lib.draw_rect(
        layout.start_x, layout.separator_y,
        layout.total_w, layout.s(LAYOUT.separator_h),
        "88C0FC", nil, 0, "00", "00"
    ))

    -- 3. 卡片网格
    local visible_count = layout.visible_count
    local end_idx = math.min(state.offset + visible_count, #with_imgs)

    for i = state.offset + 1, end_idx do
        local char = with_imgs[i]
        if not char then break end

        local slot = i - state.offset - 1
        local row = math.floor(slot / layout.per_row)
        local col = slot % layout.per_row
        local card_x = layout.start_x + col * (layout.card_w + layout.spacing)
        local card_y = layout.cards_y + row * (layout.card_h + layout.spacing)

        -- hover_index 1-indexed，slot 0-indexed
        local is_hover = (slot + 1 == state.hover_index)

        -- 背景矩形（hover 时高亮 + 边框 88C0FC 2px）
        if is_hover then
            table.insert(parts, ass_lib.draw_rect(
                card_x, card_y, layout.card_w, layout.card_h,
                "3A3940", "88C0FC", 2, "D0", "00"
            ))
        else
            table.insert(parts, ass_lib.draw_rect(
                card_x, card_y, layout.card_w, layout.card_h,
                "2A2930", nil, 0, "C0", "00"
            ))
        end

        -- 图片区域底色（占位，实际图片用 overlay-add）
        local img_x = card_x + layout.img_padding
        local img_y = card_y + layout.img_padding
        local img_w = layout.card_w - 2 * layout.img_padding
        local img_h = layout.img_h
        if img_w > 0 and img_h > 0 then
            table.insert(parts, ass_lib.draw_rect(
                img_x, img_y, img_w, img_h,
                "1A1A20", nil, 0, "80", "00"
            ))
        end

        -- 文字区域底色（draw_rect, fill=000000, alpha=90）
        local text_y = card_y + layout.img_h
        local text_h = layout.text_area_h
        table.insert(parts, ass_lib.draw_rect(
            card_x, text_y, layout.card_w, text_h,
            "000000", nil, 0, "90", "00"
        ))

        -- v1.6: 角色卡片采用两行布局
        -- 第一行: 角色名（fs=22*ui_scale, bold, FFFBFF, 居中）
        -- 第二行: "关系 CV cv_name"（fs=14*ui_scale, 多色, 居中）
        local name_fs = math.floor(22 * layout.ui_scale)
        local name_y = text_y + math.floor(text_h * 0.30)
        table.insert(parts, string.format(
            "{\\an5\\pos(%d,%d)\\fs%d\\b1\\c&H%s&}%s\n",
            math.floor(card_x + layout.card_w / 2),
            name_y,
            name_fs,
            ass_lib.hex_to_ass("FFFBFF"),
            ass_lib.ass_escape(resolve_character_name(char))
        ))

        -- 第二行: "关系 CV cv_name"
        -- 有头像时偏右 16px 给头像留位
        local rel_cv_fs = math.floor(14 * layout.ui_scale)
        local rel_cv_y = text_y + math.floor(text_h * 0.75)
        local has_avatar = get_first_cv_avatar_url(char) ~= nil
        local rel_cv_x = math.floor(card_x + layout.card_w / 2)
        if has_avatar then
            rel_cv_x = rel_cv_x + math.floor(16 * layout.ui_scale)
        end
        local rel_cv_text = build_relation_cv_line(char)
        table.insert(parts, string.format(
            "{\\an5\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
            rel_cv_x, rel_cv_y, rel_cv_fs,
            ass_lib.hex_to_ass("A8D4F7"),
            ass_lib.ass_escape(rel_cv_text)
        ))
    end

    -- 4. 无图角色区（底部文字横排，最多 no_image_max_lines × no_image_per_line）
    -- v1.6: 显示格式 "角色名 关系 CV cv_name"（与卡片第二行一致）
    if #without_imgs > 0 then
        local no_img_fs = math.floor(15 * layout.ui_scale)
        local per_line = LAYOUT.no_image_per_line
        local max_lines = LAYOUT.no_image_max_lines
        local total_shown = math.min(#without_imgs, per_line * max_lines)
        local col_w = math.floor(layout.total_w / per_line)

        for idx = 1, total_shown do
            local char = without_imgs[idx]
            if not char then break end
            local line = math.floor((idx - 1) / per_line)
            local col = (idx - 1) % per_line
            local cx = layout.start_x + col * col_w
            local cy = layout.no_image_y + line * layout.no_image_line_h

            -- v1.6: 新格式 "角色名 关系 CV cv_name"
            local char_name = resolve_character_name(char)
            local rel_cv = build_relation_cv_line(char)
            local text = char_name .. " " .. rel_cv

            table.insert(parts, string.format(
                "{\\an7\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
                cx, cy, no_img_fs,
                ass_lib.hex_to_ass("88C0FC"),
                ass_lib.ass_escape(text)
            ))
        end

        -- 溢出提示
        if #without_imgs > total_shown then
            local more_y = layout.no_image_y + max_lines * layout.no_image_line_h
            table.insert(parts, string.format(
                "{\\an7\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
                layout.start_x, more_y, no_img_fs,
                ass_lib.hex_to_ass("808080"),
                ass_lib.ass_escape("...共 " .. #without_imgs .. " 个无图角色")
            ))
        end
    end

    -- 5. 翻页按钮（v1.7: 使用通用 pagination.render 替代内联渲染）
    pagination.render(parts, state.pagination_layout, state, ass_lib)

    -- 6. 底部提示栏（fs=14*ui_scale, A0A0A0, \an5 居中）
    local hint_fs = math.floor(14 * layout.ui_scale)
    local page_num = math.floor(state.offset / visible_count) + 1
    local total_pages = math.max(1, math.ceil((#with_imgs > 0 and #with_imgs or 1) / visible_count))
    local hint_text = string.format(
        "ESC/Ctrl+右键 关闭 · ←→ 翻页 · 点击右上角✕ · 第 %d/%d 页 · 有图 %d + 无图 %d = 共 %d 角色",
        page_num, total_pages,
        #with_imgs, #without_imgs, #state.characters
    )
    table.insert(parts, string.format(
        "{\\an5\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
        math.floor(osd_w / 2), layout.hint_y, hint_fs,
        ass_lib.hex_to_ass("A0A0A0"),
        ass_lib.ass_escape(hint_text)
    ))

    -- 7. 翻页反馈箭头（page_feedback 存在时）
    if state.page_feedback == "down" or state.page_feedback == "up" then
        local fb_fs = math.floor(32 * layout.ui_scale)
        local fb_y
        local arrow
        if state.page_feedback == "down" then
            fb_y = osd_h - math.floor(60 * layout.ui_scale)
            arrow = "↓"
        else
            fb_y = math.floor(60 * layout.ui_scale)
            arrow = "↑"
        end
        table.insert(parts, string.format(
            "{\\an5\\pos(%d,%d)\\fs%d\\b1\\c&H%s&}%s\n",
            math.floor(osd_w / 2), fb_y, fb_fs,
            ass_lib.hex_to_ass("88C0FC"),
            arrow
        ))
    end

    -- 更新 overlay（res_x/res_y 必须等于 osd_w/osd_h，V4-P3 修复）
    state.overlay.res_x = osd_w
    state.overlay.res_y = osd_h
    state.overlay.data = table.concat(parts)
    pcall(function() state.overlay:update() end)

    -- 异步下载图片与 CV 头像
    download_card_images()
    download_cv_avatars()
end

-- ====== 翻页 ======

-- 设置翻页反馈定时器（200ms 后清除并重新 render）
-- 连续翻页时复用定时器（先 kill 旧的再创建新的）
local function set_page_feedback_timer()
    if state.page_feedback_timer then
        pcall(function() state.page_feedback_timer:kill() end)
    end
    state.page_feedback_timer = mp.add_timeout(0.2, function()
        state.page_feedback = nil
        if state.visible then render() end
    end)
end

-- 向后翻页（RIGHT / WHEEL_DOWN / 下一页按钮）
local function page_right()
    if not state.visible then return end
    local layout = state.layout
    if not layout then return end
    local visible_count = layout.visible_count
    local total = #(state.with_images or {})
    if total == 0 then return end
    local max_offset = math.max(0, math.ceil(total / visible_count) - 1) * visible_count
    local new_offset = state.offset + visible_count
    if new_offset > max_offset then new_offset = max_offset end
    if new_offset == state.offset then return end

    abort_in_flight_downloads()
    clear_image_overlays()
    state.offset = new_offset
    state.hover_index = 0
    state.hover_button = nil
    state.page_feedback = "down"
    set_page_feedback_timer()
    render()
end

-- 向前翻页（LEFT / WHEEL_UP / 上一页按钮）
local function page_left()
    if not state.visible then return end
    local layout = state.layout
    if not layout then return end
    local visible_count = layout.visible_count
    local new_offset = state.offset - visible_count
    if new_offset < 0 then new_offset = 0 end
    if new_offset == state.offset then return end

    abort_in_flight_downloads()
    clear_image_overlays()
    state.offset = new_offset
    state.hover_index = 0
    state.hover_button = nil
    state.page_feedback = "up"
    set_page_feedback_timer()
    render()
end

-- ====== 鼠标交互（v1.7: 改用 mouse_interaction 通用组件）======

-- v1.7: hit_test_buttons 已移除（改用 pagination.hit_test）
-- v1.7: update_hover_highlight 已移除（改由 mouse_interaction.on_hover_change 回调驱动）

-- 鼠标左键点击回调（由 MBTN_LEFT 按键绑定调用）
-- v1.7: 改用 pagination.on_click 替代内联 hit_test_buttons + 翻页分发
-- v1.8: MBTN_LEFT 按键绑定不传递坐标参数，必须主动获取 mouse-pos
local function on_mouse_click()
    if not state.visible then return end
    if not state.layout then return end
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
    -- 翻页按钮命中检测 + 翻页分发（统一交给 pagination 组件）
    pagination.on_click(mx, my, state.pagination_layout, page_left, page_right)
end

-- ====== 公共方法 ======

function M.is_visible()
    return state.visible
end

-- show: 入口
-- new_deps: 调用方传入的 deps（模块使用闭包注入的 deps，此参数仅做签名兼容）
-- characters: 角色列表
-- title: 展示标题
function M.show(new_deps, characters, title)
    if type(characters) ~= "table" or #characters == 0 then
        if deps.notify then pcall(deps.notify.warn, "未找到角色信息") end
        return
    end

    -- 关闭其他面板 + 禁用 uosc
    if deps.ui_base then
        pcall(deps.ui_base.close_other_panels, "cards")
        pcall(deps.ui_base.disable_uosc)
    end

    -- v1.9.5: 核选项强制关闭所有残留 uosc 菜单（替代 v1.9.3/v1.9.4 的 force_close）
    --       uosc close-menu 是异步命令，在高速竞态下不可靠（已验证 5 个版本）。
    --       nuclear_menu_dismiss() 同时尝试：
    --       A. 所有已知 menu_type 的 close-menu  B. 无参 close-menu
    --       C. blur 命令  D. 延迟 ESC 键模拟  E. 100ms 二次重试
    if deps.loading_controller and type(deps.loading_controller.nuclear_menu_dismiss) == "function" then
        pcall(deps.loading_controller.nuclear_menu_dismiss)
    end

    -- 重置状态
    state.characters = characters
    state.with_images, state.without_images = split_characters(characters)
    state.title = title or ""
    state.offset = 0
    state.hover_index = 0
    state.hover_button = nil
    state.render_version = state.render_version + 1
    state.in_flight_downloads = {}
    state.pending_retry = {}
    state.cv_avatars = {}
    state.page_feedback = nil

    -- v1.7: 通过 overlay_manager 统一分配 overlay id（最多 48 个：32 角色 + 16 CV 头像）
    --       返回 nil（id 不足）时降级使用固定 id 0..47（由 download_* 函数内 id_base=0 兜底）
    state.overlay_id_range = overlay_manager.alloc_id("cards", 48)

    -- 创建 overlay（若未创建）
    if not state.overlay then
        state.overlay = mp.create_osd_overlay('ass-events')
    end

    state.visible = true
    M.visible = true

    -- 首次渲染
    render()

    -- 注册按键（register_keys 内部先 unregister 旧绑定）
    -- v1.6: LEFT/RIGHT 改为 forced=true，强制覆盖 mpv 默认的快退/快进，避免翻页冲突
    --       面板关闭时 unregister_keys 会自动释放，不影响正常播放
    -- v1.8: 翻页快捷键只用 LEFT/RIGHT（用户要求），移除 WHEEL_UP/WHEEL_DOWN
    M.register_keys({
        {key="RIGHT",           name="cards-right",        fn=page_right,      forced=true},
        {key="LEFT",            name="cards-left",         fn=page_left,       forced=true},
        {key="ESC",             name="cards-close",        fn=M.close,         forced=true},
        {key="Ctrl+MBTN_RIGHT", name="cards-close-m",      fn=M.close,         forced=false},
        {key="MBTN_LEFT",       name="cards-mouse-click",  fn=on_mouse_click,  forced=true},
    })

    -- 注册 OSD observer（osd-width/osd-height 变化时重新 render，仅在 visible 时）
    -- 先 unregister 防止重复注册（M.show 重复调用场景）
    M.unregister_osd()
    M.register_osd_observers(function()
        if state.visible then render() end
    end, {"osd-width", "osd-height"}, 100, M.is_visible)

    -- v1.7: 订阅鼠标输入（改用 mouse_interaction 通用组件，替代内联 mouse_subscribed/mouse_callback）
    if deps.input_service then
        mouse_interaction.enable(deps.input_service, {
            hit_test = function(mx, my)
                -- 优先检查翻页按钮（使用通用 pagination.hit_test）
                local btn = pagination.hit_test(mx, my, state.pagination_layout)
                if btn then return btn end
                -- 然后检查卡片悬停
                if not state.layout then return nil end
                local layout = state.layout
                local with_imgs = state.with_images
                if #with_imgs == 0 then return nil end
                local end_idx = math.min(state.offset + layout.visible_count, #with_imgs)
                for i = state.offset + 1, end_idx do
                    local slot = i - state.offset - 1
                    local row = math.floor(slot / layout.per_row)
                    local col = slot % layout.per_row
                    local card_x = layout.start_x + col * (layout.card_w + layout.spacing)
                    local card_y = layout.cards_y + row * (layout.card_h + layout.spacing)
                    if mx >= card_x and mx < card_x + layout.card_w
                       and my >= card_y and my < card_y + layout.card_h then
                        return slot + 1  -- 1-indexed
                    end
                end
                return nil
            end,
            on_hover_change = function(old_hover, new_hover)
                -- 区分按钮悬停和卡片悬停（与 staff_grid.lua 一致）
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
    deps.ui_base.make_panel_module("cards", M)

    M.set_cleanup(function()
        state.visible = false
        M.visible = false
        state.render_version = state.render_version + 1
        abort_in_flight_downloads()
        -- v1.7: overlay 清理由 overlay_manager.remove_all 统一处理（clear_image_overlays 内部调用）
        clear_image_overlays()
        if state.overlay then
            pcall(function() state.overlay:remove() end)
            state.overlay = nil
        end
        if state.page_feedback_timer then
            pcall(function() state.page_feedback_timer:kill() end)
            state.page_feedback_timer = nil
        end
        -- v1.7: 关闭鼠标订阅（改用 mouse_interaction.disable 统一管理）
        mouse_interaction.disable()
        state.layout = nil
        state.pagination_layout = nil
        state.page_feedback = nil
        state.hover_index = 0
        state.hover_button = nil
        state.close_btn = nil  -- v1.7.2: 清理关闭按钮区域
    end)

    M.init_panel(deps, {is_visible = M.is_visible, close = M.close})
end

return M
