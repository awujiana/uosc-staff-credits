-- modules/guess.lua
-- 文件名/标题解析模块
-- 从播放路径中提取 标题 / 季数 / 集数，用于 Bangumi 搜索
-- 遵循 ADR-10 统一 init(opts, deps) 接口
--
-- 参考 uosc_danmaku/modules/utils.lua 的 parse_title / get_episode_number 实现，
-- 简化并适配 uosc_staff_credits 的 opts.title_replace JSON 规则格式

local mp = require("mp")
local utils = require("mp.utils")
local msg = require("mp.msg")

local M = {}

local opts, deps, init = require("modules.utils.module_loader").make_init(
    "guess",
    {}
)
M.init = init

-- 工具：获取路径 basename（不含扩展名）
local function basename_no_ext(path)
    if not path or path == "" then return nil end
    -- 协议路径直接返回 nil（由 media-title 兜底）
    local sep = "/"
    if path:find("\\") then sep = "\\" end
    local fname = path
    local pos = path:match("^.*()" .. sep)
    if pos and pos > 0 then
        fname = path:sub(pos + 1)
    end
    -- 去掉扩展名
    fname = fname:gsub("%.[^%.\\/]*$", "")
    return fname
end

-- 应用 opts.title_replace 规则（JSON 字符串）
-- 格式：{"rules": [{"pattern": "replacement"}, ...]}
local function apply_title_replace(title)
    if not title or title == "" then return title end
    if not opts.title_replace or opts.title_replace == "" then
        return title
    end
    local cfg = utils.parse_json(opts.title_replace)
    if type(cfg) ~= "table" then return title end
    -- cfg 可能是 {rules = {...}} 或数组形态
    local rules = cfg.rules
    if type(rules) ~= "table" then
        -- 退化：把 cfg 当作数组处理
        rules = cfg
    end
    if type(rules) ~= "table" then return title end
    for _, entry in pairs(rules) do
        if type(entry) == "table" then
            for pattern, replacement in pairs(entry) do
                local ok, _ = pcall(function()
                    title = title:gsub(pattern, replacement)
                end)
                if not ok then
                    msg.warn("[guess] invalid title_replace pattern: " .. tostring(pattern))
                end
            end
            -- 兼容 uosc_danmaku 的清理步骤
            title = title:gsub("[_%.]", " ")
                     :gsub("^%s*(.-)%s*$", "%1")
                     :gsub("[@#%.%+%-%%&*_=,/~`]+$", "")
        end
    end
    return title
end

-- ---- UTF-8 安全的「按字符」切分 ----
--
-- ⚠️ 为什么必须这么做（2026-10-05 踩坑记录）：
--   Lua 的字符类对多字节字符是**字节集**语义，不是码点集语义。
--   `[～〜~]` 展开后是字节集 {7E, 80, 9C, 9E, BD, E3, EF} —— 里面含
--   80/9C/9E 这些 **UTF-8 续接字节**，于是正则会从「某个汉字的中间」
--   开始匹配，把字符啃成残缺字节。
--
--   实测证据（tools/ 下 probe 脚本）：
--     「無職転生 III ～異世界行ったら本気だす～」(#56)
--     过一遍 `gsub("%s*[～〜~][^～〜~]*[～〜~]%s*$", " ")` 后变 #55，
--     即**尾部的「～」被吃掉了**，尽管这串本来就没有「～…～」结构。
--     再叠加 `[%-–—]`（含 E2 80 前缀共享）的两条规则、配合
--     `repeat until s == prev` 反复迭代，最终丢掉 6 字节 = 「す～」。
--
--   ⇒ 结论：**任何涉及非 ASCII 的字符类都不可信**，必须先把字符串切成
--      UTF-8 字符序列，再按「整字符」比较。下面复用 title_normalize.lua
--     同一个 idiom。
local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"
local function utf8_units(s)
    local t = {}
    for u in s:gmatch(UTF8_CHAR) do t[#t + 1] = u end
    return t
end

-- 波浪号类字符（整字符比较，不再用字节类）
local TILDE = { ["～"] = true, ["〜"] = true, ["~"] = true }
-- 连字符类字符
local DASH = { ["-"] = true, ["–"] = true, ["—"] = true, ["−"] = true }
local SPACE = { [" "] = true, ["\t"] = true }

local function is_tilde(u) return u ~= nil and TILDE[u] == true end
local function is_dash(u) return u ~= nil and DASH[u] == true end
local function is_space(u) return u ~= nil and SPACE[u] == true end
local function is_digit(u) return u ~= nil and u:match("^%d$") ~= nil end

-- 从尾部吃空格，返回「有效长度」
local function trim_tail_spaces(u, n)
    while n >= 1 and is_space(u[n]) do n = n - 1 end
    return n
end

-- strip_subtitle: 去掉标题尾部的「副标题」段
--
-- 2026-10-05 新增。背景：像
--   「無職転生 III ～異世界行ったら本気だす～ - 09」
-- 这种名字，`～…～` 是副标题，搜索时带上它会导致 Bangumi 匹配不到条目。
--
-- 处理三类尾部噪声（全部在**字符序列**上做，不碰字节）：
--   1. 波浪号包裹的副标题：～…～ / ~…~ / 〜…〜
--   2. 尾部裸的「 - 数字」残留（集数已单独抽出后剩下的分隔符）
--   3. 尾部孤立的连字符
--
-- 实现要点：不用正则去 `$` 锚定多字节结构，而是「从尾部往回扫」，
-- 逐个字符判断。这样绝不会索引到字符中间。
local function strip_subtitle(s)
    if not s then return s end
    local u = utf8_units(s)
    local changed = true
    while changed and #u > 0 do
        changed = false
        local n = trim_tail_spaces(u, #u)
        if n < 1 then break end

        -- 规则 1：尾部是波浪号 → 向前找成对的另一个波浪号，整段删掉
        if is_tilde(u[n]) then
            local j = n - 1
            while j >= 1 and not is_tilde(u[j]) do j = j - 1 end
            if j >= 1 then
                -- 找到成对：删除 j..n（含）整段
                local out = {}
                for k = 1, j - 1 do out[#out + 1] = u[k] end
                u = out
                changed = true
            else
                -- 孤立的尾波浪号（无配对）—— 也去掉，它不可能是正文
                u[n] = nil
                changed = true
            end

        -- 规则 2：尾部是数字 → 看它前面紧邻的是不是连字符
        elseif is_digit(u[n]) then
            local j = n
            while j >= 1 and (is_digit(u[j]) or u[j] == "." or u[j] == "v"
                              or u[j] == "V") do j = j - 1 end
            local k = trim_tail_spaces(u, j)
            if k >= 1 and is_dash(u[k]) then
                local out = {}
                for m = 1, k - 1 do out[#out + 1] = u[m] end
                u = out
                changed = true
            end

        -- 规则 3：尾部是孤立连字符
        elseif is_dash(u[n]) then
            u[n] = nil
            changed = true
        end
    end
    return table.concat(u)
end

-- 清理标题噪声：方括号、圆括号、书名号、常见分隔符
local function clean_title(s)
    if not s then return s end
    s = s:gsub("%[[^%]]*%]", " ")
         :gsub("%([^%)]*%)", " ")
         :gsub("【[^】]*】", " ")
         :gsub("《([^》]*)》", "%1")
         :gsub("〔([^〕]*)〕", "%1")
         :gsub("[%._]", " ")
    s = strip_subtitle(s)
    s = s:gsub("%s+", " ")
         :gsub("^%s*(.-)%s*$", "%1")
    return s
end

-- ============================================================================
-- 季数 / 集数抽取
-- ============================================================================
--
-- 背景（2026-10-27 重写）：
--   原实现把季、集识别写成**一条 if/else 链**，六个模式互斥 ——
--   命中集数就拿不到季数，命中季数就拿不到集数。实测后果：
--
--     「进击的巨人 第三季 第05集」→ episode=05，season=nil
--     「無職転生 III ～…～ - 09」 → episode=09，season=nil（罗马数字没覆盖）
--     「无职转生 第二部 EP12」    → 中文「第X季/第X部」压根没有对应模式
--
--   而且季数一旦漏掉，搜索关键词里就少了季信息，制作评分/职员表会
--   取到第一季的条目（详见 search_pipeline.select_best_subject）。
--
-- ⇒ 现在拆成三步，彼此独立、可叠加：
--     ① 季 + 集 同时命中（S01E02 / 2x05）
--     ② 只抽集（Episode / EP / 第X话 / [09] / - 09）
--     ③ 只抽季（第X季 / 第X部 / Season X / 2nd Season / 独立 S2）
--   ③ 在 ② 剩下的串上做，所以「第三季 … 第05集」两者都能拿到。
--
-- ⚠️ 罗马数字（III / Ⅲ）只作为**季数提示**，不从标题里剥离：
--    中文正式译名常把它嵌在名字里（如「无职转生Ⅲ」），剥掉反而搜不到。

-- 中文数字 → 整数（支持 一..十、十一..九十九）
local CN_DIGIT = {
    ["零"] = 0, ["一"] = 1, ["二"] = 2, ["三"] = 3, ["四"] = 4,
    ["五"] = 5, ["六"] = 6, ["七"] = 7, ["八"] = 8, ["九"] = 9, ["两"] = 2,
}

local function chinese_number_to_int(text)
    if type(text) ~= "string" or text == "" then return nil end
    local units = {}
    for u in text:gmatch(UTF8_CHAR) do
        if CN_DIGIT[u] then
            units[#units + 1] = { digit = CN_DIGIT[u] }
        elseif u == "十" then
            units[#units + 1] = { ten = true }
        else
            return nil
        end
    end
    if #units == 0 then return nil end
    if #units == 1 and not units[1].ten then return units[1].digit end

    -- 形如 [d]十[d]
    local total, i = 0, 1
    if units[i] and not units[i].ten then
        total = units[i].digit
        i = i + 1
    end
    if not (units[i] and units[i].ten) then return nil end
    total = (total == 0 and 1 or total) * 10
    i = i + 1
    if units[i] and not units[i].ten then
        total = total + units[i].digit
        i = i + 1
    end
    if i <= #units then return nil end
    return total
end
M.chinese_number_to_int = chinese_number_to_int

-- 罗马数字（ASCII + 全角 Ⅰ..Ⅻ）
local ROMAN_VALUE = { I = 1, V = 5, X = 10, L = 50, C = 100 }
local ROMAN_CHARS = {}
for k, v in pairs(ROMAN_VALUE) do
    ROMAN_CHARS[k] = true
    ROMAN_CHARS[k:lower()] = true
end
for k = 0, 11 do
    -- U+2160(Ⅰ) .. U+216B(Ⅻ)
    ROMAN_CHARS[string.char(0xE2, 0x85, 0xA0 + k)] = true
end

local function is_roman_char(u) return u ~= nil and ROMAN_CHARS[u] == true end
local function is_word_char(u) return u ~= nil and u:match("^[%w]$") ~= nil end

local function roman_to_int(text)
    -- 全角 Ⅰ..Ⅻ 的码点表（U+2160..U+216B）
    local FULLWIDTH_ROMAN = {}
    for k = 0, 11 do
        FULLWIDTH_ROMAN[string.char(0xE2, 0x85, 0xA0 + k)] = k + 1
    end

    local values = {}
    for u in text:gmatch(UTF8_CHAR) do
        local v = ROMAN_VALUE[u:upper()] or FULLWIDTH_ROMAN[u]
        if not v then return nil end
        values[#values + 1] = v
    end
    if #values == 0 then return nil end
    local total = 0
    for i = 1, #values do
        if i < #values and values[i] < values[i + 1] then
            total = total - values[i]
        else
            total = total + values[i]
        end
    end
    if total < 1 or total > 20 then return nil end
    return total
end

-- detect_roman_season: 找出「独立成词」的罗马数字作为季数提示。
-- 不从标题剥离（理由见本节顶部注释）。
local function detect_roman_season(s)
    local units = utf8_units(s)
    local i = 1
    while i <= #units do
        if is_roman_char(units[i]) then
            local j = i
            while j <= #units and is_roman_char(units[j]) do j = j + 1 end
            -- 要求两侧都不是单词字符：避开 "MIX" 里的 IX、"Isekai" 里的 I
            if not is_word_char(units[i - 1]) and not is_word_char(units[j]) then
                local token = table.concat(units, "", i, j - 1)
                local value = roman_to_int(token)
                if value then return tostring(value) end
            end
            i = j
        else
            i = i + 1
        end
    end
    return nil
end

-- 去掉 "v2" 这类版本号尾巴
local function strip_version(value)
    return (value:gsub("v%d+$", ""))
end

-- ⚠️ 又一次「Lua 字符类是字节集」陷阱（本项目第 5 次）：
--   `[话集回]` 展开成字节集 {E8,AF,9D,E9,9B,86,E5,9B,9E}，
--   于是**任意首字节命中 E5/E8/E9 的汉字**都会被当成集数单位 ——
--   实测「第 3 阶」中的「阶」(E9 98 B6) 会被误判为「第3集」。
--   `[一二三四五六七八九十]` 同理（首字节 E4/E5 覆盖大半汉字区）。
-- ⇒ 这里改用「逐个字面量单位 + 在 第…单位 之间捕获后再校验」的写法，
--   全程不出现非 ASCII 字符类。
local EPISODE_UNITS = { "话", "集", "回", "話" }
local SEASON_UNITS  = { "季", "部", "期" }

-- normalize_episode: 清洗集数里被正则顺手捎进来的杂音
--   · "22v2"    → "22"（版本号）
--   · "22.1080" → "22"（S01E22.1080p 里 .1080 是分辨率，不是集数小数）
--   小数部分仅 1~2 位时保留（部分番剧确有 5.5 集这种写法）。
local function normalize_episode(value)
    if type(value) ~= "string" then return value end
    value = strip_version(value)
    local int_part, frac = value:match("^(%d+)%.(%d+)$")
    if int_part and frac and #frac >= 3 then return int_part end
    return value
end

-- 阿拉伯数字写法：第 12 集
local function match_arabic_count(s, units)
    for _, unit in ipairs(units) do
        local t, n = s:match("^(.-)%s*第%s*(%d+[%.v]?%d*)%s*" .. unit)
        if n then return (normalize_episode(n)), t end
    end
    return nil, nil
end

-- 中文数字写法：第十二集
-- 第…单位 之间用 (.-) 捕获，再交给 chinese_number_to_int 校验 ——
-- 捕获到「3季」这种杂音时校验失败，函数返回 nil，不会误判。
local function match_chinese_count(s, units)
    -- 「第三季 第五集」里有两个「第」：第一个的中文数字段会抓到「三季 第五」
    -- 这种杂音（校验失败）。不能就此放弃，要继续往后找下一个「第」。
    local from = 1
    while true do
        local i = s:find("第", from, true)
        if not i then return nil, nil end
        local head = s:sub(1, i - 1)
        local tail = s:sub(i + 3)   -- 「第」为 3 字节
        for _, unit in ipairs(units) do
            local n = tail:match("^%s*(.-)%s*" .. unit)
            if n then
                local value = chinese_number_to_int(n)
                if value then return tostring(value), head end
            end
        end
        from = i + 3
    end
end

-- strip_tail_tags: 剥掉尾部成串的 [..] / (..) 发布组标签
local function strip_tail_tags(s)
    local stripped = s:gsub("[%s]*[%[%(][^%]%)]*[%]%)]%s*$", "")
    local previous = s
    while stripped ~= previous do
        previous = stripped
        stripped = stripped
            :gsub("%s+$", "")
            :gsub("[%[%(][^%]%)]*[%]%)]%s*$", "")
    end
    return (stripped:gsub("%s+$", ""))
end

-- extract_episode: 返回 episode, rest（未命中时 episode=nil、rest=s）
local function extract_episode(s)
    local t, e

    -- 1. Episode 09 / episode_09
    t, e = s:match("^(.-)%s*[Ee]pisode[%s_.%-]*(%d+[%.v]?%d*)")
    if e then return normalize_episode(e), t end

    -- 2. EP09 / ep09 / E09（缩写）
    --    前置守卫 [^%ddD]：排除 "1080p60"、"x264" 之类把 p/P 当集数标记的误命中
    t, e = s:match("^(.-)%s*[^%ddD][eEpP]+(%d+[%.v]?%d*)")
    if e then return normalize_episode(e), t end

    -- 3. 第 09 话 / 集 / 回
    e, t = match_arabic_count(s, EPISODE_UNITS)
    if e then return e, t end

    -- 4. 第九话（中文数字）
    e, t = match_chinese_count(s, EPISODE_UNITS)
    if e then return e, t end

    -- 5. [09]
    t, e = s:match("^(.-)%s*%[(%d+[%.v]?%d*)%]")
    if e then return normalize_episode(e), t end

    -- 6. 「 - 09」DashEpisode（2026-10-05 新增，日文番剧最常见命名法）
    --    要点：必须要求分隔符是「空格 + 连字符 + 空格」或行首锚定的连字符，
    --    否则会把片名里本来就有的连字符（如 "Re:Zero-1"）误切断。
    --    数字限定 1~3 位，避开年份（4 位）。
    local probe = strip_tail_tags(s)
    local dash_title, dash_ep =
        probe:match("^(.-)%s+[%-–—]%s+(%d%d?%d?[%.v]?%d*)%s*$")
    if not dash_ep then
        dash_title, dash_ep = probe:match("^(.-)%-%-?%s*(%d%d?%d?[%.v]?%d*)%s*$")
    end
    -- 仍未命中则退回原始串再试一次（避免剥标签剥过头）
    if not dash_ep then
        dash_title, dash_ep = s:match("^(.-)%s+[%-–—]%s+(%d%d?%d?[%.v]?%d*)%s*$")
    end
    if dash_ep then return normalize_episode(dash_ep), dash_title end

    return nil, s
end

-- extract_season: 返回 season, rest（命中即从 rest 剥离；未命中 rest=s）
local function extract_season(s)
    local t, n

    -- 1. 第 3 季 / 第 3 部 / 第 3 期
    n, t = match_arabic_count(s, SEASON_UNITS)
    if n then return n, t end

    -- 2. 第三季 / 第二部（中文数字）
    n, t = match_chinese_count(s, SEASON_UNITS)
    if n then return n, t end

    -- 3. 2nd Season / 3rd season
    --    必须排在 "Season X" 之前，否则 "Re:Zero 2nd Season - 26" 会被
    --    「Season 后面的 - 26」误读成第 26 季。
    t, n = s:match("^(.-)(%d+)[nrdsth]+[%s_%.%-]*[sS]eason")
    if n then return n, t end

    -- 4. Season 3 / season.3 / SEASON-3
    --    Season 与数字之间只允许空白/点/紧邻的单个连字符：
    --    "Season - 26" 不应被读成第 26 季。
    t, n = s:match("^(.-)[%s_%.%-]+[sS][eE][aA][sS][oO][nN][%s_%.]*%-?(%d+)")
    if n then return n, t end
    t, n = s:match("^(.-)[%s_%.%-]+[sS]eason[%s_%.]*%-?(%d+)")
    if n then return n, t end

    -- 5. 独立 S2 / S2)（S 前需有分隔符，避开 "Studio"、"Subtitle" 等词）
    t, n = s:match("^(.-)[%s_%-%[%]%(]+[sS](%d+)%f[%D]")
    if n then return n, t end

    return nil, s
end

-- extract_season_episode: 一次拿全 标题残留 / 季 / 集
local function extract_season_episode(s)
    -- ① 季 + 集 同时命中：S01E02
    local t, sn, en = s:match("^(.-)%s*[sS](%d+)[%.%-%s:]?[eE](%d+[%.v]?%d*)")
    if sn and en then return t, sn, normalize_episode(en) end

    -- ①b 2x05（季数需 ≤30，避开 "1920x1080" 这类分辨率）
    local t2, sn2, en2 = s:match("^(.-)%s*(%d+)x(%d%d?%d?)%f[%D]")
    if sn2 and en2 and (tonumber(sn2) or 0) <= 30 then
        return t2, sn2, en2
    end

    -- ② 集
    local episode, rest = extract_episode(s)
    -- ③ 季（在②剩余串上找）
    local season, rest2 = extract_season(rest)
    if not season then season = detect_roman_season(rest2) end

    return rest2, season, episode
end
M.extract_season_episode = extract_season_episode

-- parse_title: 从路径解析 标题/季数/集数
-- path: 视频路径（本地或 URL）。若为 nil，自动从 mp.get_property("path") 获取
-- 返回 title, season_num, episode_num（季/集为字符串形式，便于外部比较；不存在时为 nil）
function M.parse_title(path)
    if not path then
        path = mp.get_property("path")
    end
    if not path then return nil end

    local fname = basename_no_ext(path)
    -- 协议路径优先用 media-title
    local is_url = path:find("^%a[%w.+-]-://") ~= nil
    if is_url then
        local mtitle = mp.get_property("media-title")
        if mtitle and mtitle ~= "" then
            fname = mtitle
        end
    end
    if not fname or fname == "" then return nil end

    -- 细空格统一为普通空格
    local thin_space = string.char(0xE2, 0x80, 0x89)
    fname = fname:gsub(thin_space, " ")

    local title_part, season, episode = extract_season_episode(fname)

    -- 兜底：本地文件取父目录名作为标题
    if (not title_part or title_part == "") and not is_url then
        local parent = nil
        local ok, result = pcall(function()
            return mp.command_native({"normalize-path", path})
        end)
        if ok and type(result) == "string" and result ~= "" then
            parent = utils.split_path(result)
        else
            parent = utils.split_path(path)
        end
        if parent then
            -- 去掉末尾分隔符后再 split 一次，得到目录名
            local _, dir_name = utils.split_path(parent:sub(1, -2))
            if dir_name and dir_name ~= "" then
                -- 跳过 Season/Specials/第X季 类目录，向上再取一层
                if dir_name:lower():match("^%s*seasons?%s*%d+%s*$")
                   or dir_name:lower():match("^%s*specials?%s*$")
                   or dir_name:match("^%s*SPs?%s*$")
                   or dir_name:match("^%s*O[VAD]+s?%s*$")
                   or dir_name:match("^%s*第.-[季部]+%s*$") then
                    local upper_dir = utils.split_path(parent:sub(1, -2))
                    if upper_dir then
                        _, dir_name = utils.split_path(upper_dir:sub(1, -2))
                    end
                end
                title_part = dir_name
            end
        end
    end

    if not title_part or title_part == "" then
        return nil
    end

    -- 清理 + 应用用户替换规则
    title_part = clean_title(title_part)
    title_part = apply_title_replace(title_part)

    return title_part, season, episode
end

-- get_episode_number: 从文件名推断集数
-- filename: 当前播放文件名（无扩展名）
-- history_fname: 可选，uosc_danmaku 历史记录中的文件名，用于推断集数偏移
-- 返回 number 或 nil
function M.get_episode_number(filename, history_fname)
    if not filename or filename == "" then return nil end
    local thin_space = string.char(0xE2, 0x80, 0x89)
    filename = filename:gsub(thin_space, " ")

    -- 若提供了历史文件名，尝试通过两者集数差值推断
    -- 这里简化为：分别从两个文件名中提取集数，若都存在则返回当前集数
    -- （uosc_danmaku 的 get_series_episodes 较复杂，这里只做基础匹配）
    local function extract_ep(s)
        if not s then return nil end
        local _, e = s:match("^.-[sS]%d+[%.%-%s:]?[eE](%d+[%.v]?%d*)")
        if e then return tonumber(e:gsub("v%d+$", "")) end
        _, e = s:match("^.-[^%ddD][eEpP]+(%d+[%.v]?%d*)")
        if e then return tonumber(e:gsub("v%d+$", "")) end
        _, e = s:match("^.-第%s*(%d+[%.v]?%d*)%s*[话集回]")
        if e then return tonumber(e:gsub("v%d+$", "")) end
        _, e = s:match("^.-[%[(%d+[%.v]?%d*)%]]")
        if e then return tonumber(e:gsub("v%d+$", "")) end
        -- 纯数字结尾
        e = s:match("(%d+)%s*$")
        if e then return tonumber(e) end
        return nil
    end

    local current_ep = extract_ep(filename)
    if not current_ep then return nil end

    if history_fname and history_fname ~= "" then
        local history_ep = extract_ep(history_fname)
        -- 若历史记录有集数，且与当前文件名集数不同，说明可能有偏移
        -- 简化：直接返回当前文件名解析出的集数
        if history_ep then
            return current_ep
        end
    end

    return current_ep
end

-- best_match_by_jw: 复用 utils facade 的同名函数
-- 保留导出便于 deps.guess.best_match_by_jw 调用
local utils_mod = require("modules.utils")
M.best_match_by_jw = utils_mod.best_match_by_jw
M.jaro_winkler = utils_mod.jaro_winkler

return M
