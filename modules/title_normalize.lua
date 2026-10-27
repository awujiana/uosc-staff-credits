-- modules/title_normalize.lua
-- 标题规范化：繁体→简体 转换 + 「已是中文」判定的修正
--
-- ============================================================================
-- 为什么需要这个模块（2026-10-05 实测定位）
-- ============================================================================
--
-- 症状：播放「無職転生 III ～異世界行ったら本気だす～」时，搜索框里填的
--       就是这串**繁体日文原名**，拿去搜 Bangumi 当然搜不到中文条目。
--
-- 根因（两层，缺一不可）：
--
-- 【第一层】utils.is_chinese() 无法区分「简体中文」与「繁体/日文汉字」
--
--   原实现：str:find("[\228-\233][\128-\191]")
--   Lua 的字符类里 \228-\233 是**字节**范围（不是码点）。
--   而 UTF-8 中 E4..E9 恰好是 **全部 CJK 汉字**的首字节区间：
--
--       无(E6) 职(E8)      ← 简体
--       無(E7) 職(E8)      ← 繁体
--       進(E9) 撃(E6)      ← 日文汉字
--       評(E8) 価(E5)
--
--   ⇒ 任何中日韩汉字都命中 [E4-E9]，于是 is_chinese("無職転生") == true。
--
-- 【第二层】resolve_chinese_title() 的第一句就是 `if is_chinese(title) then return`
--
--   于是繁体标题被判定为「已经是中文」，**直接原样返回，从不送去做转换**。
--   两层叠加 = 繁体/日文标题永远不会被转成简体。
--
-- ⚠️ 关键认知：**「是中文」和「是简体中文」是两回事。**
--    原代码把前者当后者用，这个偷换概念让整条转换链路静默失效 ——
--    没有报错、没有日志，只是搜索结果为空。
--
-- ============================================================================
-- 本模块提供什么
-- ============================================================================
--
--   normalize(title)        → 规范化后的标题（繁体转简体 + 清理），并返回
--                             是否发生了转换
--   to_simplified(s)        → 纯繁体→简体转换
--   has_traditional(s)      → 是否含繁体字（用于决定是否值得去转换）
--   is_simplified_chinese(s)→ 是否**已经是**简体中文（替代原 is_chinese 的误用）
--
-- 字典复用 uosc_danmaku/dicts/t2s_chars.lua（4113 条单字映射，经实测验证），
-- 不重复造轮子。若该文件不可达则本模块优雅降级为「不做转换」。

local mp = require("mp")
local msg = require("mp.msg")

local M = {}

-- ============================================================================
-- 加载 t2s 字典
-- ============================================================================
-- 路径说明：uosc_staff_credits 与 uosc_danmaku 是 scripts/ 下的兄弟目录。
-- 用 expand-path 拿绝对路径后再拼，避免依赖 cwd。
-- 注意：mp.command_native 的首元素直接是命令名（不加 "command" 包装），
--       加包装会返回 nil —— 这个坑本项目已经踩过 3 次，勿重蹈。

local t2s = nil
local t2s_loaded = false

local function load_t2s()
    if t2s_loaded then return t2s end
    t2s_loaded = true

    local ok, base = pcall(mp.command_native, { "expand-path", "~~/scripts" })
    if not ok or type(base) ~= "string" or base == "" then
        msg.warn("[title_normalize] 无法解析 ~~/scripts，繁体转换已禁用")
        return nil
    end

    local path = base .. "/uosc_danmaku/dicts/t2s_chars.lua"
    local ok2, dict = pcall(dofile, path)
    if not ok2 or type(dict) ~= "table" then
        msg.warn("[title_normalize] 载入 t2s 字典失败，繁体转换已禁用: " .. tostring(path))
        return nil
    end

    t2s = dict
    msg.verbose("[title_normalize] t2s 字典已载入")
    return t2s
end

-- 预留：测试时可注入字典
function M._set_dict(dict)
    t2s = dict
    t2s_loaded = true
end

-- ============================================================================
-- ⚠️ 第三次踩同一个坑：Lua 字符类对多字节字符是「字节集」语义
-- ============================================================================
--
-- 曾用 KANA = "[ぁ-ゖァ-ヺーｦ-ﾟ]" 判「含日文假名」。
-- 看起来对，**实测全错**：这个类会匹配**任何一个汉字**。
--
--   原因：`ぁ`=E3 81 81、`ゖ`=E3 82 96。Lua 把区间展开为「逐字节比较首字节」，
--         于是首字节 ≥ E3 的都被算进去 —— E3..E9 全部中招，
--         而 E4..E9 正是**全部 CJK 汉字**的首字节区间。
--
--   实测：find(KANA) 对 进/无/间/鬼/巨/人 全部返回 true。
--   ⇒ is_simplified_chinese("进击的巨人") == false（明明是简体！）
--   ⇒ resolve_chinese_title 第 2 步的「已是简体就早退」永远不成立，
--     每次搜索都白跑一轮网络请求。
--
-- 结论（本项目第 3 次栽在同一件事上，见 guess.lua / strip_subtitle）：
--   **凡是非 ASCII 的 Lua 字符类，一律不可信。**
--   必须先把字符串解码成码点，再按码点区间判断。
--
-- 下面实现一个最小的 UTF-8 解码器：单趟扫描，产出 (codepoint) 并用
-- 位运算取真实码点，再与 U+3040..U+30FF（假名区）比较。
-- ============================================================================

-- UTF-8 解码：把字符串转成码点数组（非法序列按 U+FFFD 处理，不崩）
local function utf8_codepoints(s)
    local cps, i, n = {}, 1, #s
    while i <= n do
        local b = s:byte(i)
        local cp, size
        if b < 0x80 then
            cp, size = b, 1
        elseif b >= 0xC2 and b <= 0xDF then
            local b2 = s:byte(i + 1)
            if b2 and b2 >= 0x80 and b2 <= 0xBF then
                cp, size = (b - 0xC0) * 0x40 + (b2 - 0x80), 2
            end
        elseif b >= 0xE0 and b <= 0xEF then
            local b2, b3 = s:byte(i + 1), s:byte(i + 2)
            if b2 and b3 and b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF then
                cp, size = (b - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80), 3
            end
        elseif b >= 0xF0 and b <= 0xF4 then
            local b2, b3, b4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
            if b2 and b3 and b4
               and b2 >= 0x80 and b2 <= 0xBF
               and b3 >= 0x80 and b3 <= 0xBF
               and b4 >= 0x80 and b4 <= 0xBF then
                cp, size = (b - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000
                          + (b3 - 0x80) * 0x40 + (b4 - 0x80), 4
            end
        end
        if not cp then cp, size = 0xFFFD, 1 end
        cps[#cps + 1] = cp
        i = i + size
    end
    return cps
end
M._codepoints = utf8_codepoints  -- 导出便于测试

-- CJK 统一表意文字（含扩展 A）：U+3400..U+9FFF
local function is_han_cp(cp)
    return (cp >= 0x3400 and cp <= 0x4DBF)
        or (cp >= 0x4E00 and cp <= 0x9FFF)
        or (cp >= 0xF900 and cp <= 0xFAFF)
end

-- 日文假名：平假名 U+3040..U+309F、片假名 U+30A0..U+30FF、半角片假名 U+FF66..U+FF9F
local function is_kana_cp(cp)
    return (cp >= 0x3040 and cp <= 0x309F)
        or (cp >= 0x30A0 and cp <= 0x30FF)
        or (cp >= 0xFF66 and cp <= 0xFF9F)
end

-- has_kana: 是否含日文假名（码点判定，绝不误伤汉字）
local function has_kana(s)
    for _, cp in ipairs(utf8_codepoints(s)) do
        if is_kana_cp(cp) then return true end
    end
    return false
end
M.has_kana = has_kana

-- has_han: 是否含汉字（码点判定）
local function has_han(s)
    for _, cp in ipairs(utf8_codepoints(s)) do
        if is_han_cp(cp) then return true end
    end
    return false
end
M.has_han = has_han

-- ============================================================================
-- 逐字符转换
-- ============================================================================
-- 按 UTF-8 序列切分后逐字查表，未命中则原样保留。
-- 这样比逐字节处理安全：不会把多字节字符切坏。
local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"

function M.to_simplified(s)
    if type(s) ~= "string" or s == "" then return s end
    local dict = load_t2s()
    if not dict then return s end
    return (s:gsub(UTF8_CHAR, function(c)
        return dict[c] or c
    end))
end

-- has_traditional: 判断字符串中是否存在「会被转换」的字符
-- 用途：决定是否有必要去做网络转换 —— 不含繁体字就不必白跑一趟
function M.has_traditional(s)
    if type(s) ~= "string" or s == "" then return false end
    local dict = load_t2s()
    if not dict then return false end
    for c in s:gmatch(UTF8_CHAR) do
        if dict[c] then return true end
    end
    return false
end

-- ============================================================================
-- is_simplified_chinese: 修正版「是否已是简体中文」
-- ============================================================================
-- 语义与原来的 is_chinese 不同，这是有意的：
--   is_chinese            → 「含汉字」（简繁日都算）→ 会导致转换被跳过
--   is_simplified_chinese → 「含汉字 **且** 不含待转繁体字」→ 才真的不用转
--
-- 同时排除日文假名：含假名说明是日文标题，即便汉字部分是简体，
-- 也该送去搜索（服务端更懂日文原名 → 中文译名的映射）。
--
-- ⚠️ 三项判定全部走码点（utf8_codepoints），不用 Lua 字符类：
--    · has_kana   —— 旧 KANA 字节类会误匹配所有汉字，见上文
--    · has_han    —— 旧 [\228-\233][\128-\191] 同样是字节语义
--    · has_traditional —— 字典查表本就按完整 UTF-8 序列，安全

function M.is_simplified_chinese(s)
    if type(s) ~= "string" or s == "" then return false end
    -- 含日文假名 → 不是中文标题，需要处理
    if M.has_kana(s) then return false end
    -- 含汉字？
    if not M.has_han(s) then return false end
    -- 含繁体 → 仍需转换
    if M.has_traditional(s) then return false end
    return true
end

-- ============================================================================
-- normalize: 一站式规范化
-- ============================================================================
-- 返回：normalized, changed
--   normalized — 规范化后的标题
--   changed    — 是否发生了实际变化
function M.normalize(title)
    if type(title) ~= "string" or title == "" then
        return title, false
    end

    local converted = M.to_simplified(title)

    -- 去掉转换后可能出现的多余空格
    converted = converted:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")

    return converted, converted ~= title
end

-- ============================================================================
-- to_standard_name: 把弹幕 API 的 animeTitle 清洗成「可搜索的标准名」
-- ============================================================================
-- 背景（2026-10-06）：
--   弹幕 API 返回的 animeTitle 带了一堆检索用的装饰后缀，例如
--     无职转生Ⅲ ～到了异世界就拿出真本事～(2026)【TV动画】from dandan
--     无职转生Ⅱ ～到了异世界就拿出真本事～ 第2部分(2024)【TV动画】from dandan
--   直接拿这串去 Bangumi 搜是搜不到的（噪声词会稀释匹配），
--   必须清洗成
--     无职转生Ⅲ ～到了异世界就拿出真本事～
--     无职转生Ⅱ ～到了异世界就拿出真本事～ 第2部分
--
-- 剥离三类尾部噪声（反复剥离，因为可能叠加）：
--   1. `from xxx`      —— 数据来源标记（ASCII，正则安全）
--   2. `【...】`       —— 类型标记，如【TV动画】（⚠️ 见下）
--   3. `(1999)`        —— 4 位年份（ASCII，正则安全）
--
-- ⚠️ 为什么【...】不能直接用 `【[^】]*】`：
--   又是「Lua 字符类是字节集」这个坑（本项目已踩 4 次）。
--   `】` = E3 80 91，于是 `[^】]` 是**字节集**取反 {E3, 80, 91}，
--   任何含续接字节 80 或 91 的汉字（如「一」= E4 B8 80）都会被中途截断。
--   本用例里【TV动画】恰好不含这些字节才侥幸能用 —— 但这是运气，不是正确。
--   ⇒ 统一改用「按 UTF-8 字符回扫」的写法。

-- 复用模块顶部的 utf8_codepoints 同级思路，这里需要的是「字符串」而非码点
local UTF8_UNIT = "[%z\1-\127\194-\244][\128-\191]*"

local function utf8_units(s)
    local t = {}
    for u in s:gmatch(UTF8_UNIT) do t[#t + 1] = u end
    return t
end

-- 剥掉尾部成对的「左括号…右括号」（按整字符比较，绝不切坏多字节字符）
-- s: 输入串；l, r: 左/右括号字符（如 "【" "】"）
-- digits_only: 为 true 时，仅当括号内容全为数字才剥离（避免误伤「（第一部）」）
local function strip_trailing_pair(s, l, r, digits_only)
    local u = utf8_units(s)
    -- 先吃掉尾部空白
    while #u > 0 and u[#u]:match("^%s$") do u[#u] = nil end
    if #u == 0 or u[#u] ~= r then return s end
    -- 从右往左找配对的左括号
    local i = #u - 1
    while i >= 1 and u[i] ~= l do i = i - 1 end
    if i < 1 then return s end
    -- 内容校验（可选）
    if digits_only then
        local has = false
        for k = i + 1, #u - 1 do
            local c = u[k]
            if c:match("^%d$") then
                has = true
            elseif not c:match("^%s$") then
                return s   -- 含非数字非空白 → 不剥
            end
        end
        if not has then return s end
    end
    -- 丢弃 i..#u 整段（含括号）
    local out = {}
    for k = 1, i - 1 do out[#out + 1] = u[k] end
    local res = table.concat(out)
    return (res:gsub("%s+$", ""))
end

-- 剥掉尾部的 "from <来源>" 标记
--
-- ⚠️ 两个实测坑（2026-10-06）：
--   1. 真实返回是 `【TV动画】from dandan` —— `】` 与 `from` **之间没有空格**，
--      所以 `%s+from` 这种写法**永远不匹配**（我第一版就栽在这）。
--   2. 若放宽成 `from%s+%w+$`，会把正片名 `Escape from Tarkov` 误剥成 `Escape`。
--
-- ⇒ 判据：只有**紧跟在 】 / ) / ）之后**（或位于串首）的 `from` 才认定为来源标记。
--   这一约束既覆盖了实际格式，又不会误伤正常片名。
local function strip_trailing_from(s)
    local u = utf8_units(s)
    -- 从尾部跳过空白，收集结尾的 word 段
    local n = #u
    while n >= 1 and u[n]:match("^%s$") do n = n - 1 end
    local e = n
    while n >= 1 and u[n]:match("^[%w_%.%-]$") do n = n - 1 end
    if n >= e then return s end            -- 尾部没有 word 段
    -- 跳过 word 段前的空白，期望读到 "from"
    local k = n
    while k >= 1 and u[k]:match("^%s$") do k = k - 1 end
    if k < 4 then return s end
    if not (u[k] == "m" and u[k - 1] == "o" and u[k - 2] == "r" and u[k - 3] == "f") then
        return s
    end
    local before = k - 4                    -- from 前面那个字符的下标
    if before >= 1 then
        local b = u[before]
        -- 只认噪声分隔符后的 from，避免误伤 "Escape from Tarkov"
        if b ~= "】" and b ~= ")" and b ~= "）" then return s end
    end
    local out = {}
    for i = 1, before do out[#out + 1] = u[i] end
    local res = table.concat(out)
    return (res:gsub("%s+$", ""))
end

-- to_standard_name: 返回清洗后的标准名；无法清洗时原样返回
function M.to_standard_name(s)
    if type(s) ~= "string" or s == "" then return s end

    local t = s
    local prev
    repeat
        prev = t
        -- 1. 尾部 "from <来源>"（要求前面是 】 / ) / ））
        t = strip_trailing_from(t)
        -- 2. 尾部 "【...】"（类型标记）—— UTF-8 安全
        t = strip_trailing_pair(t, "【", "】")
        -- 3. 尾部 "(1999)" 年份
        t = t:gsub("%s*%(%d%d%d%d%)%s*$", "")
        -- 4. 尾部 "（1999）" 全角括号年份（仅当括号内是数字才剥）
        t = strip_trailing_pair(t, "（", "）", true)
        -- 5. 收尾空白
        t = t:gsub("%s+$", "")
    until t == prev

    -- 全部剥光说明原串本来就是纯噪声，此时回退原串更安全
    if t == "" then return s end
    return t
end

return M
