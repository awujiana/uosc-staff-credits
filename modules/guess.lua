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

    local season, episode
    local title_part = fname

    -- 模式 1: S\d+E\d+ 或 s\d+e\d+
    local m_title, m_s, m_e = fname:match("^(.-)%s*[sS](%d+)[%.%-%s:]?[eE](%d+[%.v]?%d*)")
    if m_s and m_e then
        title_part = m_title
        season = m_s
        episode = m_e:gsub("v%d+$", "")
    else
        -- 模式 2: [Ee]pisode.?\d+ 或 EP?\d+（匹配完整 "Episode" 单词）
        m_title, m_e = fname:match("^(.-)%s*[Ee]pisode[%s_.%-]*(%d+[%.v]?%d*)")
        if m_e then
            title_part = m_title
            episode = m_e:gsub("v%d+$", "")
        else
            -- 模式 2b: EP?\d+ 或 ep\d+（缩写形式，不消耗前字符）
            m_title, m_e = fname:match("^(.-)%s*[eEpP]+(%d+[%.v]?%d*)")
            if m_e then
                title_part = m_title
                episode = m_e:gsub("v%d+$", "")
            else
                -- 模式 3: 第\d+话 / 第\d+集 / 第\d+回
                m_title, m_e = fname:match("^(.-)%s*第%s*(%d+[%.v]?%d*)%s*[话集回]")
                if m_e then
                    title_part = m_title
                    episode = m_e:gsub("v%d+$", "")
                else
                    -- 模式 4: [\d+] （末尾方括号集数）
                    m_title, m_e = fname:match("^(.-)%s*%[(%d+[%.v]?%d*)%]")
                    if m_e then
                        title_part = m_title
                        episode = m_e:gsub("v%d+$", "")
                    else
                        -- 模式 5: Season \d+ 形式
                        m_title, m_s = fname:match("^(.-)[%s_%-]?[sS]eason[%s_%-]*(%d+)")
                        if m_s then
                            title_part = m_title
                            season = m_s
                        else
                            -- 模式 6: 「 - 09」DashEpisode（2026-10-05 新增）
                            --
                            -- 为什么补这一条：这是**日文番剧**最常见的命名法，
                            -- 原实现完全没有覆盖，导致：
                            --   集数没抽出来（episode = nil）
                            --   **且 title_part 保持整个文件名**（含 " - 09"），
                            --   最终搜索关键词 = "無職転生 III ～異世界行ったら本気だす～ - 09"
                            --   → Bangumi 当然搜不到。
                            --
                            -- 要点：必须要求分隔符是「空格 + 连字符 + 空格」或
                            -- 行首锚定的连字符，否则会把片名里本来就有的
                            -- 连字符（如 "Re:Zero-1"）误切断。
                            -- 数字限定 1~3 位，避开年份（4 位）。
                            -- 用 .- 非贪婪 + $ 锚定，取**最后**一段
                            -- （避免 "Fate/stay night - 09" 被前面的 "-" 提前截断）。
                            -- 关键：发布组常把标签缀在集数**后面**，如
                            --   「[Lilith-Raws] 無職転生 III ～…～ - 09 [Baha][WEB-DL][1080p]」
                            -- $ 锚定的模式会因此整个失配（实测 ep=nil，标题带全名）。
                            -- 做法：先把尾部成串的 [..] / (..) 标签剥掉再匹配。
                            local tail_stripped = fname:gsub("[%s]*[%[%(][^%]%)]*[%]%)]%s*$", "")
                            -- 反复剥，处理连续多个标签
                            local prev_s = fname
                            while tail_stripped ~= prev_s do
                                prev_s = tail_stripped
                                tail_stripped = tail_stripped
                                    :gsub("%s+$", "")
                                    :gsub("[%[%(][^%]%)]*[%]%)]%s*$", "")
                            end
                            local probe = tail_stripped:gsub("%s+$", "")

                            local dash_title, dash_ep =
                                probe:match("^(.-)%s+[%-–—]%s+(%d%d?%d?[%.v]?%d*)%s*$")
                            if not dash_ep then
                                dash_title, dash_ep =
                                    probe:match("^(.-)%-%-?%s*(%d%d?%d?[%.v]?%d*)%s*$")
                            end
                            -- 仍未命中则退回原始串再试一次（避免剥标签剥过头）
                            if not dash_ep then
                                dash_title, dash_ep =
                                    fname:match("^(.-)%s+[%-–—]%s+(%d%d?%d?[%.v]?%d*)%s*$")
                            end
                            if dash_ep then
                                title_part = dash_title
                                episode = dash_ep:gsub("v%d+$", "")
                            end
                        end
                    end
                end
            end
        end
    end

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
