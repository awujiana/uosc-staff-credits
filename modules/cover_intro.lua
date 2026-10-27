-- modules/cover_intro.lua
-- 封面简介面板 - 展示番剧封面、名称、评分、标签、制作信息、简介
-- 遵循 UI.md 1.2 节（封面简介面板）布局规范
-- 遵循 UI.md 7.2 节（按键绑定）、12.2 节（底部提示栏）
-- 遵循 UI.md 5.2 节（强制中文字体 Noto Sans CJK SC 的 gsub 注入，ISSUE-013 修复）
-- 使用 DESIGN.md 3 节 make_panel_module 工厂注入公共方法
-- overlay id 分配：0（单张封面，固定）

local mp = require("mp")

-- v1.7: 通用 overlay 管理组件（统一分配 id + 文件验证 + 批量清理）
local overlay_manager = require("modules.overlay_manager")

local M = {}

-- ====== 模块工厂初始化（make_init）======
local opts, deps, init = require("modules.utils.module_loader").make_init(
    "cover_intro",
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

-- ====== 面板尺寸常量（UI.md 1.2.1）======
-- v1.6: 增大面板尺寸，避免内容溢出（960×580 → 1200×720）
local PANEL_BASE_W = 1200
local PANEL_BASE_H = 720

-- ====== 模块本地状态 ======
local state = {
    visible = false,
    detail = nil,         -- 条目详情数据（bangumi/anilist/mal/baike 格式）
    source_name = "",     -- "bangumi" / "anilist" / "mal" / "baike" / "未知"
    overlay = nil,        -- mp.create_osd_overlay('ass-events') 句柄
    -- v1.7: cover_overlay_id 改由 overlay_manager.alloc_id 动态分配
    cover_overlay_id = nil,       -- 当前使用的 overlay id（alloc_id 成功时为分配值，失败时降级为 62）
    cover_overlay_id_range = nil, -- overlay_manager.alloc_id 返回的区间（nil 表示降级模式，使用旧逻辑）
    render_version = 0,   -- 旧回调失效标记
    cover_loaded = false, -- 封面是否已加载并添加 overlay
    in_flight_downloads = {},  -- 封面下载取消函数列表（修复：面板关闭时取消未完成下载）
    close_btn = nil,     -- v1.7.2: 右上角关闭按钮区域 {x, y, size}
}

-- ====== 内部辅助：防御性类型处理 ======

-- truncate_text: 防御性截断文本（V4-P3 修复）
-- 修复：使用 UTF8 字符数而非字节数，避免多字节字符被截断导致乱码
-- 超过 max_len 时截取前 max_len-1 个字符并追加 "…"（单字符省略号）
local function truncate_text(text, max_len)
    if text == nil then return "" end
    if type(text) ~= "string" then
        text = tostring(text)
    end
    max_len = tonumber(max_len) or 0
    if max_len <= 0 then return "" end
    if max_len == 1 then return "…" end

    -- 计算 UTF8 字符数（而非字节数）
    local char_count = 0
    for _ in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        char_count = char_count + 1
    end

    if char_count <= max_len then return text end

    -- 按字符数截取
    local chars = {}
    local idx = 0
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        idx = idx + 1
        if idx > max_len - 1 then break end
        table.insert(chars, char)
    end
    return table.concat(chars) .. "…"
end

-- 防御性字符串转换
local function to_str(v)
    if v == nil then return "" end
    if type(v) == "string" then return v end
    if type(v) == "number" then return tostring(v) end
    return tostring(v)
end

-- ====== 内部辅助：从 detail 提取统一字段 ======
-- 兼容 bangumi（rating/infobox/tags 对象数组）和 anilist/mal/baike 格式

-- 提取番剧中文名
local function get_name_cn(detail, source_name)
    if type(detail) ~= "table" then return "" end
    if source_name == "anilist" then
        -- AniList title.native 是日文原名，name_cn 字段已由 parse_media 填充
        return to_str(detail.name_cn)
    elseif source_name == "mal" then
        -- MAL alternative_titles.ja 是日文原名，name_cn 已由 parse_anime 填充
        return to_str(detail.name_cn)
    elseif source_name == "baike" then
        -- 百度百科 title 即中文标题
        return to_str(detail.name_cn or detail.name)
    end
    return to_str(detail.name_cn)
end

-- 提取封面图 URL（优先 large，回退 common/medium）
local function get_cover_url(detail, source_name)
    if type(detail) ~= "table" then return nil end
    if source_name == "anilist" or source_name == "mal" then
        -- AniList/MAL 返回 images: {large, medium, common}
        local images = detail.images
        if type(images) == "table" then
            local url = images.large or images.common or images.medium
            if type(url) == "string" and url ~= "" then return url end
        end
        return nil
    elseif source_name == "baike" then
        -- 百度百科 API 不返回图片
        return nil
    end
    local images = detail.images
    if type(images) == "table" then
        local url = images.large or images.common or images.medium
        if type(url) == "string" and url ~= "" then return url end
    end
    return nil
end

-- 提取别名列表：返回数组 { {label="日文名", value=...}, {label="英文名", value=...}, {label="罗马音", value=...} }
local function get_aliases(detail, source_name)
    local aliases = {}
    if type(detail) ~= "table" then return aliases end

    -- bangumi: 从 infobox 别名项提取
    local infobox = detail.infobox
    if type(infobox) == "table" then
        for _, item in ipairs(infobox) do
            if type(item) == "table" and item.key == "别名" then
                local val = item.value
                if type(val) == "table" then
                    for _, sub in ipairs(val) do
                        if type(sub) == "table" and sub.k and sub.v then
                            local k = to_str(sub.k)
                            local label
                            if k:find("日文") then label = "日文名"
                            elseif k:find("英文") or k:lower():find("english") then label = "英文名"
                            elseif k:find("罗马") or k:lower():find("romaji") or k:lower():find("hepburn") then label = "罗马音"
                            end
                            if label then
                                table.insert(aliases, {label = label, value = to_str(sub.v)})
                            end
                        end
                    end
                end
            end
        end
    end
    -- 补充原始名作为日文名
    if #aliases == 0 and detail.name and detail.name ~= "" then
        table.insert(aliases, {label = "日文名", value = to_str(detail.name)})
    end
    return aliases
end

-- 提取评分列表：返回数组 { {platform=..., score=..., votes=...} }
local function get_ratings(detail, source_name)
    local ratings = {}
    if type(detail) ~= "table" then return ratings end

    if source_name == "anilist" then
        -- AniList: averageScore (0-100) / meanScore (0-100)
        if detail.score then
            table.insert(ratings, {
                platform = "AniList",
                score = tonumber(detail.score) or 0,
                votes = 0,  -- AniList 不返回投票数
            })
        end
        return ratings
    elseif source_name == "mal" then
        -- MAL: mean (0-10) / scoring_users
        if detail.score then
            table.insert(ratings, {
                platform = "MAL",
                score = tonumber(detail.score) or 0,
                votes = (detail._raw and detail._raw.scoring_users) or 0,
            })
        end
        return ratings
    elseif source_name == "baike" then
        -- 百度百科: 无评分
        return ratings
    end

    -- bangumi: 单平台
    local rating = detail.rating
    if type(rating) == "table" and rating.score then
        table.insert(ratings, {
            platform = "Bangumi",
            score = tonumber(rating.score) or 0,
            votes = tonumber(rating.total) or 0,
        })
    end
    return ratings
end

-- 提取元数据：返回数组 { {label=..., value=...} }
local function get_metadata(detail, source_name)
    local meta = {}
    if type(detail) ~= "table" then return meta end

    -- 类型
    local type_str = to_str(detail.platform)
    if type_str ~= "" then
        table.insert(meta, {label = "类型", value = type_str})
    end

    -- 首播日期
    local date_str = to_str(detail.date)
    if date_str ~= "" then
        table.insert(meta, {label = "首播", value = date_str})
    end

    -- 集数
    local eps = detail.eps or detail.eps_count or detail.total_episodes
    if eps and eps ~= 0 then
        table.insert(meta, {label = "集数", value = to_str(eps)})
    end

    return meta
end

-- 提取制作信息：返回数组 { {label=..., value=...} }
-- v1.6: 字段调整为 动漫监督/原作者/原作类型/制作/改编
--   - "导演" → "动漫监督"
--   - "原作" → "原作者"
--   - 新增 "原作类型"（bangumi infobox "原作载体" 字段，如 漫画/轻小说/游戏）
--   - "连载杂志"/"连载" 归为 "改编"
local function get_production_info(detail, source_name)
    local info = {}
    if type(detail) ~= "table" then return info end

    -- v1.6: anilist/mal staff 已由 parse_staff 转换为 {name, relation} 格式
    -- relation 为英文职位名（如 "Original Creator"/"Director"）
    if source_name == "anilist" or source_name == "mal" then
        local staff = detail.staff
        if type(staff) == "table" then
            for _, s in ipairs(staff) do
                if type(s) == "table" and s.name and s.relation then
                    local rel = to_str(s.relation)
                    local label = nil
                    -- 英文职位名匹配
                    if rel:lower():find("director") or rel:find("監督") or rel:find("监督") then
                        label = "动漫监督"
                    elseif rel:lower():find("original") or rel:lower():find("creator")
                        or rel:find("原作") then
                        label = "原作者"
                    elseif rel:lower():find("studio") or rel:lower():find("animation")
                        or rel:find("动画制作") or rel:find("制作") then
                        label = "制作"
                    elseif rel:lower():find("script") or rel:lower():find("series composition")
                        or rel:find("脚本") or rel:find("シリーズ構成") then
                        label = "脚本"
                    elseif rel:lower():find("music") or rel:find("音楽") or rel:find("音乐") then
                        label = "音乐"
                    elseif rel:lower():find("character design") or rel:find("キャラクターデザイン")
                        or rel:find("人物设定") then
                        label = "人物设定"
                    end
                    if label then
                        -- 合并同职位人员
                        local found = false
                        for _, e in ipairs(info) do
                            if e.label == label then
                                e.value = e.value .. ", " .. to_str(s.name)
                                found = true
                                break
                            end
                        end
                        if not found then
                            table.insert(info, {label = label, value = to_str(s.name)})
                        end
                    end
                end
            end
        end
        -- 补充 infobox 中的原作类型（anilist/mal 的 infobox 已由 detail 查询构造）
        if type(detail.infobox) == "table" then
            for _, item in ipairs(detail.infobox) do
                if type(item) == "table" and item.key then
                    local k = to_str(item.key)
                    if k:find("原作类型") then
                        table.insert(info, {label = "原作类型", value = to_str(item.value)})
                        break
                    end
                end
            end
        end
        return info
    end

    -- baike: staff 已由 parse_card 转换为 {name, positions} 格式（中文职位名）
    if source_name == "baike" then
        local staff = detail.staff
        if type(staff) == "table" then
            for _, s in ipairs(staff) do
                if type(s) == "table" and s.name and type(s.positions) == "table" then
                    for _, pos in ipairs(s.positions) do
                        local pos_str = to_str(pos)
                        local label
                        if pos_str:find("导演") or pos_str:find("監督") then label = "动漫监督"
                        elseif pos_str:find("原作") and not pos_str:find("载体") then label = "原作者"
                        elseif pos_str:find("原作载体") then label = "原作类型"
                        elseif pos_str:find("动画制作") or pos_str:find("制作") then label = "制作"
                        elseif pos_str:find("脚本") then label = "脚本"
                        elseif pos_str:find("音乐") or pos_str:find("音楽") then label = "音乐"
                        end
                        if label then
                            local found = false
                            for _, e in ipairs(info) do
                                if e.label == label then
                                    e.value = e.value .. ", " .. to_str(s.name)
                                    found = true
                                    break
                                end
                            end
                            if not found then
                                table.insert(info, {label = label, value = to_str(s.name)})
                            end
                        end
                    end
                end
            end
        end
        return info
    end

    -- bangumi: 从 infobox 提取
    local infobox = detail.infobox
    if type(infobox) == "table" then
        for _, item in ipairs(infobox) do
            if type(item) == "table" and item.key and item.value then
                local k = to_str(item.key)
                local label
                -- v1.6: 字段映射调整
                if k:find("导演") or k:find("監督") or k:lower():find("director") then label = "动漫监督"
                elseif k:find("原作载体") then label = "原作类型"
                elseif k:find("原作") and not k:find("载体") then label = "原作者"
                elseif (k:find("动画制作") or k:find("制作")) and not k:find("製作年") then label = "制作"
                elseif k:find("连载杂志") or k:find("连载") then label = "改编"
                end
                if label then
                    local val_str
                    if type(item.value) == "table" then
                        local parts = {}
                        for _, sub in ipairs(item.value) do
                            if type(sub) == "table" and sub.v then
                                table.insert(parts, to_str(sub.v))
                            end
                        end
                        val_str = table.concat(parts, ", ")
                    else
                        val_str = to_str(item.value)
                    end
                    table.insert(info, {label = label, value = val_str})
                end
            end
        end
    end
    return info
end

-- 提取标签列表：返回字符串数组
local function get_tags(detail, source_name)
    local tags = {}
    if type(detail) ~= "table" then return tags end

    local raw_tags = detail.tags
    if type(raw_tags) ~= "table" then return tags end

    for _, t in ipairs(raw_tags) do
        if type(t) == "string" then
            table.insert(tags, t)
        elseif type(t) == "table" and t.name then
            table.insert(tags, to_str(t.name))
        end
    end
    return tags
end

-- 提取简介文本：summary → synopsis → description → intro → "暂无简介信息"
local function get_summary(detail, source_name)
    if type(detail) ~= "table" then return "暂无简介信息" end

    local candidates = {detail.summary, detail.synopsis, detail.description, detail.intro}

    for _, v in ipairs(candidates) do
        if type(v) == "string" and v ~= "" then
            return v
        end
    end
    return "暂无简介信息"
end

-- ====== 软换行算法（简介正文）======
-- 中文 1em（1 字符宽度 = 1 字号）
-- 英文 0.55em（1 字符宽度 ≈ 0.55 字号）
-- 遍历字符逐字累加宽度，超过 max_width 时插入 \N
local function soft_wrap(text, max_width, font_size)
    if type(text) ~= "string" or text == "" then return "" end
    max_width = tonumber(max_width) or 0
    font_size = tonumber(font_size) or 1
    if max_width <= 0 then return text end

    local lines = {}
    local current_line = {}
    local current_width = 0

    -- UTF8 字符模式
    local utf8_pattern = "[%z\1-\127\194-\244][\128-\191]*"

    for char in text:gmatch(utf8_pattern) do
        -- 跳过空字节
        if char == "\0" then
            -- ignore
        elseif char == "\n" then
            -- 硬换行：结束当前行
            table.insert(lines, table.concat(current_line))
            current_line = {}
            current_width = 0
        elseif char == "\r" then
            -- 回车符忽略
        else
            -- 计算字符宽度：CJK 字符 1em，其它 0.55em
            local byte = string.byte(char)
            local char_width
            if byte >= 0xE0 then
                -- 3/4 字节 UTF8（中文/日文/韩文/emoji 等）
                char_width = font_size
            elseif byte >= 0x80 then
                -- 2 字节 UTF8（拉丁扩展等）
                char_width = font_size * 0.55
            else
                -- ASCII
                char_width = font_size * 0.55
            end

            -- 超宽则换行（当前行非空时）
            if current_width + char_width > max_width and #current_line > 0 then
                table.insert(lines, table.concat(current_line))
                current_line = {}
                current_width = 0
            end

            table.insert(current_line, char)
            current_width = current_width + char_width
        end
    end

    -- 最后一行
    if #current_line > 0 then
        table.insert(lines, table.concat(current_line))
    end

    return table.concat(lines, "\\N")
end

-- ====== compute_layout（UI.md 1.2.1 / 1.2.2）======
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

    -- 内边距与各区域高度
    local pad = s(24)
    local title_h = s(36)
    local separator_h = s(1)
    local hint_h = s(24)

    -- 内容区起点
    local content_y = panel_y + title_h + separator_h + s(12)

    -- 左右分栏
    local left_w = s(280)
    local cover_w = left_w - s(20)
    local cover_h = math.floor(cover_w * 1.5)

    -- 右侧内容区宽度（最小 s(300)，最大不超过面板右边界）
    local right_x = panel_x + pad + left_w + s(20)
    local right_w = panel_w - pad * 2 - left_w - s(20)
    local min_right_w = s(300)
    if right_w < min_right_w then right_w = min_right_w end
    -- 防止右侧内容溢出面板右边界
    local max_right_w = panel_w - (right_x - panel_x) - pad
    if right_w > max_right_w then right_w = max_right_w end

    -- 右侧内容区起点
    local right_y = content_y

    -- 左侧封面区起点
    local left_x = panel_x + pad + s(10)
    local left_y = content_y + s(10)

    -- 底部提示栏位置（OSD 底部，UI.md 12.2）
    local hint_y = osd_h - math.floor(40 * ui_scale)

    return {
        osd_w = osd_w,
        osd_h = osd_h,
        ui_scale = ui_scale,
        s = s,
        panel_x = panel_x,
        panel_y = panel_y,
        panel_w = panel_w,
        panel_h = panel_h,
        pad = pad,
        title_h = title_h,
        separator_h = separator_h,
        hint_h = hint_h,
        content_y = content_y,
        left_x = left_x,
        left_y = left_y,
        left_w = left_w,
        cover_w = cover_w,
        cover_h = cover_h,
        right_x = right_x,
        right_y = right_y,
        right_w = right_w,
        hint_y = hint_y,
    }
end

-- ====== 封面图下载与 overlay ======

-- download_cover_image: 下载封面图并添加 overlay
local function download_cover_image(layout)
    if not state.visible then return end
    if not layout then return end
    if not deps.ui_base or type(deps.ui_base.download_image_with_cache) ~= "function" then
        return
    end

    local url = get_cover_url(state.detail, state.source_name)
    if not url then
        mp.msg.debug("[cover_intro] download_cover_image: no cover URL")
        return
    end

    local target_w = layout.cover_w
    local target_h = layout.cover_h
    if target_w <= 0 or target_h <= 0 then
        mp.msg.debug("[cover_intro] download_cover_image: invalid target size: " .. target_w .. "x" .. target_h)
        return
    end

    -- 封面 overlay 位置（OSD 坐标，因使用 osd-cover flag）
    local cover_x = layout.left_x
    local cover_y = layout.left_y
    -- 记录当前下载的版本，用于回调失效（面板关闭时 render_version 会递增）
    local download_version = state.render_version

    mp.msg.debug("[cover_intro] download_cover_image: url=" .. tostring(url) .. " size=" .. target_w .. "x" .. target_h .. " pos=" .. cover_x .. "," .. cover_y)

    local dl_opts = {
        prefix = "cover_",
        cache_days = tonumber(opts.image_cache_days) or 30,
        timeout = tonumber(opts.timeout) or 10,
        mpv_path = opts.mpv_path or "",
        max_concurrent = 4,
        user_agent = opts.user_agent,
        proxy = opts.proxy,
        in_flight_list = state.in_flight_downloads,  -- 修复：传入共享列表实现去重与并发控制
        -- v1.6: 防盗链支持，用 URL 的 origin 作为 Referer（绕过基于域名的防盗链）
        referer = url:match("^https?://[^/]+") or url,
        -- v1.6: SSL/TLS 选项（修复 Windows curl exit code 35）
        ssl_no_revoke = opts.ssl_no_revoke == true,
        cacert_path = opts.cacert_path or "",
        insecure = opts.insecure == true,
    }

    pcall(deps.ui_base.download_image_with_cache, url, target_w, target_h, dl_opts,
        function(success, bgra_path, w, h)
            mp.msg.debug("[cover_intro] download callback: success=" .. tostring(success) .. " path=" .. tostring(bgra_path) .. " size=" .. w .. "x" .. h)
            -- 旧回调丢弃：版本不匹配或面板已关闭
            if download_version ~= state.render_version then
                mp.msg.debug("[cover_intro] download callback: version mismatch, discarding")
                return
            end
            if not state.visible then
                mp.msg.debug("[cover_intro] download callback: panel closed, discarding")
                return
            end
            if not success or not bgra_path then
                mp.msg.debug("[cover_intro] download callback: failed")
                -- 渲染占位文字"封面加载失败"
                state.cover_loaded = false
                if state.visible then
                    -- 触发重新渲染（仅占位文字）
                    local cur_overlay = state.overlay
                    if cur_overlay then
                        -- 直接在 overlay 上追加失败提示
                        pcall(function()
                            local ass_lib = deps.ass_lib
                            if ass_lib then
                                local osd_w, osd_h = ass_lib.get_osd_size()
                                local fail_fs = math.floor(18 * layout.ui_scale)
                                local fail_str = string.format(
                                    "{\\an5\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
                                    math.floor(layout.left_x + layout.cover_w / 2),
                                    math.floor(layout.left_y + layout.cover_h / 2),
                                    fail_fs,
                                    ass_lib.hex_to_ass("FF6B6B"),
                                    ass_lib.ass_escape("封面加载失败")
                                )
                                -- 追加到现有 data
                                cur_overlay.data = (cur_overlay.data or "") .. fail_str
                                cur_overlay.res_x = osd_w
                                cur_overlay.res_y = osd_h
                                pcall(function() cur_overlay:update() end)
                            end
                        end)
                    end
                end
                return
            end
            if w <= 0 or h <= 0 then
                mp.msg.debug("[cover_intro] download callback: invalid size " .. w .. "x" .. h)
                return
            end

            -- v1.7: 添加封面 overlay（优先使用 overlay_manager.add，降级时回退旧逻辑）
            if state.cover_overlay_id_range then
                -- overlay_manager 模式：overlay_manager.add 内部完成文件验证 + pcall 包裹
                mp.msg.debug("[cover_intro] overlay-add: id=" .. state.cover_overlay_id ..
                    " pos=" .. cover_x .. "," .. cover_y ..
                    " size=" .. w .. "x" .. h ..
                    " path=" .. tostring(bgra_path))
                local ok = overlay_manager.add(state.cover_overlay_id, cover_x, cover_y, bgra_path, w, h)
                if ok then
                    state.cover_loaded = true
                    mp.msg.debug("[cover_intro] overlay-add: success via overlay_manager")
                    -- 触发重新渲染以显示图片
                    if state.visible then
                        local cur_overlay = state.overlay
                        if cur_overlay then
                            pcall(function() cur_overlay:update() end)
                        end
                    end
                else
                    mp.msg.debug("[cover_intro] overlay-add: overlay_manager.add failed")
                end
            else
                -- 降级模式：旧逻辑（直接 mp.commandv + 手动文件验证）
                local utils = require("mp.utils")
                local file_info = utils.file_info(bgra_path)
                if not file_info or not file_info.is_file then
                    mp.msg.debug("[cover_intro] overlay-add: bgra file not found: " .. tostring(bgra_path))
                    return
                end
                local file_size = file_info.size or 0
                local expected_size = 4 * w * h
                mp.msg.debug("[cover_intro] overlay-add: id=" .. state.cover_overlay_id ..
                    " pos=" .. cover_x .. "," .. cover_y ..
                    " size=" .. w .. "x" .. h ..
                    " path=" .. tostring(bgra_path) ..
                    " file_size=" .. file_size ..
                    " expected_size=" .. expected_size)
                if file_size ~= expected_size then
                    mp.msg.debug("[cover_intro] overlay-add: file size mismatch! expected " .. expected_size .. " got " .. file_size)
                    return
                end
                local ok, err = pcall(mp.commandv, "overlay-add",
                    state.cover_overlay_id, cover_x, cover_y, bgra_path, 0,
                    "bgra", w, h, 4 * w)
                if ok then
                    state.cover_loaded = true
                    mp.msg.debug("[cover_intro] overlay-add: success via direct commandv")
                    if state.visible then
                        local cur_overlay = state.overlay
                        if cur_overlay then
                            pcall(function() cur_overlay:update() end)
                        end
                    end
                else
                    mp.msg.debug("[cover_intro] overlay-add: failed - " .. tostring(err))
                end
            end
        end)
end

-- ====== 鼠标支持 ======

-- v1.7.2: 鼠标左键点击关闭按钮检测
-- v1.8: MBTN_LEFT 按键绑定不传递坐标参数，必须主动获取 mouse-pos
local function on_mouse_click()
    if not state.visible then return end
    if not state.close_btn then return end
    -- 主动获取鼠标坐标（MBTN_LEFT 回调无参数）
    local mouse = mp.get_property_native("mouse-pos")
    if type(mouse) ~= "table" then return end
    local mx = mouse.x
    local my = mouse.y
    if type(mx) ~= "number" or type(my) ~= "number" then return end
    local cb = state.close_btn
    if mx >= cb.x and mx < cb.x + cb.size
       and my >= cb.y and my < cb.y + cb.size then
        M.close()
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
    local layout = compute_layout(osd_w, osd_h)
    local ui_scale = layout.ui_scale

    local detail = state.detail or {}
    local source_name = state.source_name or "未知"

    local parts = {}

    -- 1. 面板背景（draw_rect, fill=121018, alpha=80）
    table.insert(parts, ass_lib.draw_rect(
        layout.panel_x, layout.panel_y, layout.panel_w, layout.panel_h,
        "121018", nil, 0, "80", "00"
    ))

    -- 2. 顶部装饰线（draw_rect, fill=88C0FC, alpha=00）
    table.insert(parts, ass_lib.draw_rect(
        layout.panel_x, layout.panel_y,
        layout.panel_w, layout.separator_h,
        "88C0FC", nil, 0, "00", "00"
    ))

    -- 3. 面板标题（fs=32*ui_scale, bold, F0F0F0, \an5 居中 panel_x+panel_w/2）
    -- v1.6: 标题改为动漫中文标题（优先 name_cn），无中文名时回退到 "封面简介"
    local title_fs = math.floor(32 * ui_scale)
    local title_center_y = layout.panel_y + math.floor(layout.title_h / 2)
    local panel_title = get_name_cn(detail, source_name)
    if panel_title == "" then
        panel_title = to_str(detail.name) ~= "" and to_str(detail.name) or "封面简介"
    end
    panel_title = truncate_text(panel_title, 30)
    table.insert(parts, string.format(
        "{\\an5\\pos(%d,%d)\\fs%d\\b1\\c&H%s&}%s\n",
        math.floor(layout.panel_x + layout.panel_w / 2),
        title_center_y,
        title_fs,
        ass_lib.hex_to_ass("F0F0F0"),
        ass_lib.ass_escape(panel_title)
    ))

    -- 3b. 右上角关闭按钮（v1.7.2: 供鼠标使用）
    local close_size = math.floor(28 * ui_scale)
    local close_x = layout.panel_x + layout.panel_w - close_size - math.floor(8 * ui_scale)
    local close_y = layout.panel_y + math.floor(8 * ui_scale)
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

    -- 4. 左侧封面区背景（draw_rect, fill=2A2930, alpha=C0）
    table.insert(parts, ass_lib.draw_rect(
        layout.left_x, layout.left_y,
        layout.cover_w, layout.cover_h,
        "2A2930", nil, 0, "C0", "00"
    ))

    -- 5. 左侧封面占位（封面未加载时）
    if not state.cover_loaded then
        local placeholder_fs = math.floor(18 * ui_scale)
        table.insert(parts, string.format(
            "{\\an5\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
            math.floor(layout.left_x + layout.cover_w / 2),
            math.floor(layout.left_y + layout.cover_h / 2),
            placeholder_fs,
            ass_lib.hex_to_ass("A0A0A0"),
            ass_lib.ass_escape("封面加载中...")
        ))
    end

    -- 5.2 左侧封面下方标签区（v1.6: 标签从右侧移到封面下方，带方框）
    -- 布局：封面下方留间距后开始，标签流式排列，宽度受 left_w 限制
    -- v1.6.1: 添加底部边界检查，防止标签超出面板
    local tags = get_tags(detail, source_name)
    if #tags > 0 then
        local tag_title_fs = math.floor(13 * ui_scale)
        local tag_fs = math.floor(12 * ui_scale)
        local tag_h = math.floor(22 * ui_scale)
        local tag_gap_x = math.floor(5 * ui_scale)   -- 水平间距
        local tag_gap_y = math.floor(5 * ui_scale)   -- 垂直间距
        local tag_pad = math.floor(8 * ui_scale)     -- 文字左右内边距
        local max_tags = 12

        -- 截断标签数量
        if #tags > max_tags then
            local trimmed = {}
            for i = 1, max_tags do
                table.insert(trimmed, tags[i])
            end
            tags = trimmed
        end

        -- 标签区起点：封面下方 + 间距
        local tags_y = layout.left_y + layout.cover_h + math.floor(12 * ui_scale)
        local tags_x_start = layout.left_x
        local tags_w_limit = layout.left_w  -- 标签区宽度上限

        -- 计算可用高度（面板底部 - 标签起点 - 底部边距）
        local panel_bottom = layout.panel_y + layout.panel_h
        local tags_max_y = panel_bottom - math.floor(20 * ui_scale)  -- 预留底部边距

        -- 标签标题（检查是否超出底部）
        if tags_y < tags_max_y then
            table.insert(parts, string.format(
                "{\\an4\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
                tags_x_start, tags_y, tag_title_fs,
                ass_lib.hex_to_ass("808080"),
                ass_lib.ass_escape("标签:")
            ))
        else
            -- 标签标题已超出底部，不渲染任何标签
            tags = {}  -- 清空标签列表，跳过后续渲染
        end
        local tag_y = tags_y + tag_title_fs + math.floor(4 * ui_scale)
        local tag_x = tags_x_start

        for _, t in ipairs(tags) do
            local t_str = truncate_text(t, 10)
            -- 估算标签宽度：字符数 * fs * 0.8 + 两侧内边距
            local char_count = 0
            for _ in t_str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                char_count = char_count + 1
            end
            local tag_w = math.floor(char_count * tag_fs * 0.8) + 2 * tag_pad

            -- 超宽则换行
            if tag_x + tag_w > tags_x_start + tags_w_limit then
                tag_x = tags_x_start
                tag_y = tag_y + tag_h + tag_gap_y
            end

            -- 检查是否超出底部边界
            if tag_y + tag_h > tags_max_y then
                break  -- 超出则停止渲染更多标签
            end

            -- 标签方框背景（深蓝半透明 + 浅蓝边框）
            table.insert(parts, ass_lib.draw_rect(
                tag_x, tag_y, tag_w, tag_h,
                "2A4A6A", "4A6A8A", 1, "80", "00"
            ))
            -- 标签文字（居中）
            table.insert(parts, string.format(
                "{\\an5\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
                math.floor(tag_x + tag_w / 2),
                math.floor(tag_y + tag_h / 2),
                tag_fs,
                ass_lib.hex_to_ass("A8D4F7"),
                ass_lib.ass_escape(t_str)
            ))
            tag_x = tag_x + tag_w + tag_gap_x
        end
    end

    -- 6. 右侧内容区
    local rx = layout.right_x
    local ry = layout.right_y
    local rw = layout.right_w

    -- 6.1 番剧中文名（fs=22*ui_scale, bold, F0F0F0, \an4 左对齐，truncate 40 字符）
    local name_cn = truncate_text(get_name_cn(detail, source_name), 40)
    local name_fs = math.floor(22 * ui_scale)
    table.insert(parts, string.format(
        "{\\an4\\pos(%d,%d)\\fs%d\\b1\\c&H%s&}%s\n",
        rx, ry, name_fs,
        ass_lib.hex_to_ass("F0F0F0"),
        ass_lib.ass_escape(name_cn)
    ))
    ry = ry + name_fs + math.floor(6 * ui_scale)

    -- 6.2 别名行（fs=14*ui_scale，标签 88C0FC，值 B0B0B0，truncate 44 字符）
    local aliases = get_aliases(detail, source_name)
    if #aliases > 0 then
        local alias_fs = math.floor(14 * ui_scale)
        local alias_parts = {}
        for _, a in ipairs(aliases) do
            local val = truncate_text(a.value, 44)
            table.insert(alias_parts, string.format(
                "{\\c&H%s&}%s{\\c&H%s&} %s",
                ass_lib.hex_to_ass("88C0FC"),
                ass_lib.ass_escape(a.label .. ":"),
                ass_lib.hex_to_ass("B0B0B0"),
                ass_lib.ass_escape(val)
            ))
        end
        -- 使用 \h 分隔多个别名
        local alias_text = table.concat(alias_parts, "\\h\\h")
        table.insert(parts, string.format(
            "{\\an4\\pos(%d,%d)\\fs%d}%s\n",
            rx, ry, alias_fs, alias_text
        ))
        ry = ry + alias_fs + math.floor(6 * ui_scale)
    end

    -- 6.3 评分方框（v1.6: 多网站评分，每站一个方框，站点名上+评分下，方框遮罩）
    -- 横向排列，超出 right_w 则换行；最多 2 行
    local ratings = get_ratings(detail, source_name)
    if #ratings > 0 then
        local rating_box_w = math.floor(90 * ui_scale)   -- 单个方框宽
        local rating_box_h = math.floor(48 * ui_scale)   -- 单个方框高
        local rating_gap = math.floor(8 * ui_scale)      -- 方框间距
        local site_fs = math.floor(12 * ui_scale)        -- 站点名字号
        local score_fs = math.floor(18 * ui_scale)       -- 评分字号（大）
        local votes_fs = math.floor(10 * ui_scale)       -- 投票数字号
        local max_rows = 2                               -- 最多 2 行
        local per_row = math.max(1, math.floor((rw + rating_gap) / (rating_box_w + rating_gap)))

        -- 评分标题
        local rating_title_fs = math.floor(14 * ui_scale)
        table.insert(parts, string.format(
            "{\\an4\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
            rx, ry, rating_title_fs,
            ass_lib.hex_to_ass("808080"),
            ass_lib.ass_escape("评分:")
        ))
        ry = ry + rating_title_fs + math.floor(4 * ui_scale)

        local box_x = rx
        local box_y = ry
        local row_count = 1
        local placed_in_row = 0

        for idx, r in ipairs(ratings) do
            if placed_in_row >= per_row then
                -- 换行
                box_x = rx
                box_y = box_y + rating_box_h + rating_gap
                placed_in_row = 0
                row_count = row_count + 1
                if row_count > max_rows then break end
            end

            -- 评分分数颜色：>=8 绿色，>=6 金色，>=4 橙色，<4 红色
            local score_color = "FF6B6B"
            if r.score >= 8 then score_color = "7FE07F"
            elseif r.score >= 6 then score_color = "FFD700"
            elseif r.score >= 4 then score_color = "FFA040"
            end

            -- 方框背景（半透明深色 + 边框高亮）
            table.insert(parts, ass_lib.draw_rect(
                box_x, box_y, rating_box_w, rating_box_h,
                "2A2930", "4A6A8A", 1, "C0", "00"
            ))

            -- 站点名（上方居中，浅蓝）
            local site_name = truncate_text(r.platform, 8)
            table.insert(parts, string.format(
                "{\\an5\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
                math.floor(box_x + rating_box_w / 2),
                math.floor(box_y + site_fs + math.floor(2 * ui_scale)),
                site_fs,
                ass_lib.hex_to_ass("88C0FC"),
                ass_lib.ass_escape(site_name)
            ))

            -- 评分值（中间居中，大字号，按分数着色）
            local score_str = string.format("%.1f", r.score)
            table.insert(parts, string.format(
                "{\\an5\\pos(%d,%d)\\fs%d\\b1\\c&H%s&}%s\n",
                math.floor(box_x + rating_box_w / 2),
                math.floor(box_y + site_fs + score_fs + math.floor(6 * ui_scale)),
                score_fs,
                ass_lib.hex_to_ass(score_color),
                ass_lib.ass_escape(score_str)
            ))

            -- 投票数（底部居中，小字号，灰色，仅 votes>0 时显示）
            if r.votes and r.votes > 0 then
                local votes_str = r.votes >= 1000 and
                    string.format("%.1fk", r.votes / 1000) or tostring(r.votes)
                table.insert(parts, string.format(
                    "{\\an5\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
                    math.floor(box_x + rating_box_w / 2),
                    math.floor(box_y + rating_box_h - math.floor(2 * ui_scale)),
                    votes_fs,
                    ass_lib.hex_to_ass("808080"),
                    ass_lib.ass_escape(votes_str .. " 票")
                ))
            end

            box_x = box_x + rating_box_w + rating_gap
            placed_in_row = placed_in_row + 1
        end
        ry = box_y + rating_box_h + math.floor(8 * ui_scale)
    end

    -- 6.4 元数据行（fs=14*ui_scale，标签 808080，值 D0D0D0）
    local meta = get_metadata(detail, source_name)
    if #meta > 0 then
        local meta_fs = math.floor(14 * ui_scale)
        local meta_parts = {}
        for _, m in ipairs(meta) do
            table.insert(meta_parts, string.format(
                "{\\c&H%s&}%s{\\c&H%s&} %s",
                ass_lib.hex_to_ass("808080"),
                ass_lib.ass_escape(m.label .. ":"),
                ass_lib.hex_to_ass("D0D0D0"),
                ass_lib.ass_escape(m.value)
            ))
        end
        local meta_text = table.concat(meta_parts, "\\h\\h")
        table.insert(parts, string.format(
            "{\\an4\\pos(%d,%d)\\fs%d}%s\n",
            rx, ry, meta_fs, meta_text
        ))
        ry = ry + meta_fs + math.floor(6 * ui_scale)
    end

    -- 6.5 制作信息（fs=14*ui_scale，标题 808080，值 C8C8C8，truncate 14-16 字符）
    local prod = get_production_info(detail, source_name)
    if #prod > 0 then
        local prod_fs = math.floor(14 * ui_scale)
        for _, p in ipairs(prod) do
            -- truncate 14-16 字符
            local val = truncate_text(p.value, 16)
            table.insert(parts, string.format(
                "{\\an4\\pos(%d,%d)\\fs%d}{\\c&H%s&}%s{\\c&H%s&} %s\n",
                rx, ry, prod_fs,
                ass_lib.hex_to_ass("808080"),
                ass_lib.ass_escape(p.label .. ":"),
                ass_lib.hex_to_ass("C8C8C8"),
                ass_lib.ass_escape(val)
            ))
            ry = ry + prod_fs + math.floor(2 * ui_scale)
        end
        ry = ry + math.floor(4 * ui_scale)
    end

    -- 6.6 标签已移至左侧封面下方（见 5.2 标签区），此处不再渲染

    -- 6.7 简介标题（fs=20*ui_scale, bold, 88C0FC）
    local summary_title_fs = math.floor(20 * ui_scale)
    table.insert(parts, string.format(
        "{\\an4\\pos(%d,%d)\\fs%d\\b1\\c&H%s&}%s\n",
        rx, ry, summary_title_fs,
        ass_lib.hex_to_ass("88C0FC"),
        ass_lib.ass_escape("简介")
    ))
    ry = ry + summary_title_fs + math.floor(6 * ui_scale)

    -- 6.8 简介正文（fs=18*ui_scale, E8E8E8, 行高 26*ui_scale，软换行算法）
    -- 先 ASS 转义原始文本，再软换行（避免简介含 { } \ 破坏 ASS 渲染）
    local summary_raw = get_summary(detail, source_name)
    local summary = ass_lib.ass_escape(summary_raw)
    local summary_fs = math.floor(18 * ui_scale)
    local line_h = math.floor(26 * ui_scale)
    -- 简介可用高度：从当前 ry 到 hint_y - 8
    local summary_max_h = layout.hint_y - math.floor(8 * ui_scale) - ry
    if summary_max_h < line_h then summary_max_h = line_h end
    -- 软换行（在已转义文本上插入 \\N）
    local wrapped = soft_wrap(summary, rw, summary_fs)
    -- 按 \N 分割行
    local summary_lines = {}
    for line in (wrapped .. "\\N"):gmatch("([^\\]*)\\N") do
        -- 跳过空行
        if line ~= "" then
            table.insert(summary_lines, line)
        end
    end
    -- 限制行数（基于可用高度）
    local max_lines = math.floor(summary_max_h / line_h)
    if max_lines < 1 then max_lines = 1 end
    local show_lines = #summary_lines
    if show_lines > max_lines then
        show_lines = max_lines
        -- 最后一行加省略号
        summary_lines[show_lines] = summary_lines[show_lines] .. "…"
    end

    -- 渲染简介行
    for i = 1, show_lines do
        table.insert(parts, string.format(
            "{\\an4\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
            rx, ry + (i - 1) * line_h, summary_fs,
            ass_lib.hex_to_ass("E8E8E8"),
            summary_lines[i]
        ))
    end

    -- 7. 底部提示栏（fs=16*ui_scale, A0A0A0, \an5 居中 panel_x+panel_w/2）
    local hint_fs = math.floor(16 * ui_scale)
    local source_display
    if source_name == "bangumi" then
        source_display = "Bangumi"
    elseif source_name == "anilist" then
        source_display = "AniList"
    elseif source_name == "mal" then
        source_display = "MAL"
    elseif source_name == "baike" then
        source_display = "百度百科"
    else
        source_display = "未知"
    end
    local hint_text = "ESC/Ctrl+右键 关闭 · 点击右上角✕ · 数据来源: " .. source_display
    table.insert(parts, string.format(
        "{\\an5\\pos(%d,%d)\\fs%d\\c&H%s&}%s\n",
        math.floor(layout.panel_x + layout.panel_w / 2),
        layout.hint_y,
        hint_fs,
        ass_lib.hex_to_ass("A0A0A0"),
        ass_lib.ass_escape(hint_text)
    ))

    -- 8. 强制中文字体 gsub 注入（UI.md 5.2，ISSUE-013 修复）
    -- 对所有样式块 {…} 注入 \fnNoto Sans CJK SC，排除绘图块（含 \p1）
    -- 修复：原模式 {\\fs(%d+)...} 只匹配 { 后紧跟 \fs 的块（仅绘图块），
    --        文本块格式为 {\\an4\\pos(...)\\fs%d...}，{ 后是 \an4 不匹配。
    --        改为匹配所有 {…} 块，在块内查找 \fs 后插入 \fn
    local ass_str = table.concat(parts)
    ass_str = ass_str:gsub("{([^}]*)}", function(block_content)
        -- 绘图块保持原样
        if block_content:find("\\p1") then
            return "{" .. block_content .. "}"
        end
        -- 在 \fsN 后插入 \fnNoto Sans CJK SC（若尚未包含 \fn）
        if not block_content:find("\\fn") then
            local new_content = block_content:gsub("(\\fs%d+)", "%1\\fnNoto Sans CJK SC")
            -- 若块中无 \fs，则在块尾追加 \fn
            if new_content == block_content then
                new_content = block_content .. "\\fnNoto Sans CJK SC"
            end
            return "{" .. new_content .. "}"
        end
        return "{" .. block_content .. "}"
    end)

    -- 9. 更新 overlay（res_x/res_y 必须等于 osd_w/osd_h，V4-P3 修复）
    state.overlay.res_x = osd_w
    state.overlay.res_y = osd_h
    state.overlay.data = ass_str
    pcall(function() state.overlay:update() end)

    -- 10. 异步下载封面图
    if not state.cover_loaded then
        download_cover_image(layout)
    end
end

-- ====== 公共方法 ======

function M.is_visible()
    return state.visible
end

-- show: 入口
-- new_deps: 调用方传入的 deps（模块使用闭包注入的 deps，此参数仅做签名兼容）
-- detail: 条目详情数据（bangumi / anilist / mal / baike 格式）
-- source_name: "bangumi" / "anilist" / "mal" / "baike" / "未知"
function M.show(new_deps, detail, source_name)
    -- 校验 detail 非空
    if type(detail) ~= "table" then
        if deps.notify then pcall(deps.notify.warn, "条目详情为空") end
        return
    end

    -- 关闭其他面板 + 禁用 uosc
    if deps.ui_base then
        pcall(deps.ui_base.close_other_panels, "cover_intro")
        pcall(deps.ui_base.disable_uosc)
    end

    -- v1.9.5: 核选项强制关闭所有残留 uosc 菜单
    if deps.loading_controller and type(deps.loading_controller.nuclear_menu_dismiss) == "function" then
        pcall(deps.loading_controller.nuclear_menu_dismiss)
    end

    -- 重置状态
    state.detail = detail
    state.source_name = source_name or "未知"
    state.render_version = state.render_version + 1
    state.cover_loaded = false

    -- v1.7: 通过 overlay_manager 统一分配封面 overlay id（1 个）
    --       返回 nil（id 不足）时降级使用固定 id 62（旧逻辑），确保功能不中断
    local id_range = overlay_manager.alloc_id("cover_intro", 1)
    if id_range then
        state.cover_overlay_id_range = id_range
        state.cover_overlay_id = id_range.start_id
    else
        mp.msg.warn("[cover_intro] overlay_manager.alloc_id 失败，降级使用固定 id 62")
        state.cover_overlay_id_range = nil
        state.cover_overlay_id = 62
    end

    -- 创建 overlay（若未创建）
    if not state.overlay then
        state.overlay = mp.create_osd_overlay('ass-events')
    end

    state.visible = true
    M.visible = true

    -- 首次渲染
    render()

    -- 注册按键（register_keys 内部先 unregister 旧绑定）
    M.register_keys({
        {key="ESC",             name="cover-intro-close",  fn=M.close, forced=true},
        {key="Ctrl+MBTN_RIGHT", name="cover-intro-close-m", fn=M.close, forced=true},
        {key="MBTN_LEFT",       name="cover-intro-click",  fn=on_mouse_click, forced=true},
    })

    -- 注册 OSD observer（osd-width/osd-height 变化时重新 render，仅在 visible 时）
    -- 先 unregister 防止重复注册
    M.unregister_osd()
    M.register_osd_observers(function()
        if state.visible then render() end
    end, {"osd-width", "osd-height"}, 100, M.is_visible)
end

-- ====== init 覆盖（make_panel_module 工厂使用模式，DESIGN.md 3.3）======

local base_init = init
function M.init(new_opts, new_deps)
    base_init(new_opts, new_deps)
    deps.ui_base.make_panel_module("cover_intro", M)

    M.set_cleanup(function()
        state.visible = false
        M.visible = false
        -- 递增版本使所有在途下载回调失效
        state.render_version = state.render_version + 1
        -- 清空在途下载列表（允许后续新下载请求，不被旧的 in_flight 阻止）
        state.in_flight_downloads = {}
        -- v1.7: 移除封面 overlay（overlay_manager 模式用 remove_all，降级模式用旧逻辑）
        if state.cover_overlay_id_range then
            overlay_manager.remove_all()
        elseif state.cover_overlay_id ~= nil then
            pcall(mp.commandv, "overlay-remove", state.cover_overlay_id)
        end
        state.cover_loaded = false
        -- 移除 ASS overlay
        if state.overlay then
            pcall(function() state.overlay:remove() end)
            state.overlay = nil
        end
        state.detail = nil
        state.source_name = ""
        state.close_btn = nil  -- v1.7.2: 清理关闭按钮区域
    end)

    M.init_panel(deps, {is_visible = M.is_visible, close = M.close})
end

return M
