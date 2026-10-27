-- Title parsing and display-name regression test for mpv.
-- Run this directory together with the uosc_staff_credits package directory.
--
-- 覆盖两件容易悄悄坏掉的事：
--   1. guess.parse_title 的季 / 集识别（互斥模式改可叠加模式后必须保住）
--   2. title_normalize.format_subject_title 的季集后缀拼接与去重

local mp = require("mp")

local script_dir = mp.get_script_directory()
package.path = script_dir .. "/../../?.lua;" .. script_dir .. "/../../?/init.lua;" .. package.path

local failures = 0

local function assert_equal(actual, expected, message)
    if actual == expected then return end
    failures = failures + 1
    mp.msg.error(string.format("[title_parse_flow] FAIL %s: got %q, want %q",
        message or "", tostring(actual), tostring(expected)))
end

local function assert_true(value, message)
    if value then return end
    failures = failures + 1
    mp.msg.error("[title_parse_flow] FAIL " .. tostring(message or "assertion failed"))
end

local function run()
    local guess = require("modules.guess")
    local title_normalize = require("modules.title_normalize")

    -- ---- 1. 季 / 集识别 ----
    -- 每项：文件名, 期望标题, 期望季, 期望集
    local parse_cases = {
        { "無職転生 III ～異世界行ったら本気だす～ - 09 [Baha][WEB-DL][1080p]",
          "無職転生 III", "3", "09" },
        { "进击的巨人 第三季 第05集", "进击的巨人", "3", "05" },
        { "[Lilith-Raws] 无职转生 第二部 EP12 [Baha][WEB-DL][1080p]",
          "无职转生", "2", "12" },
        { "Sword Art Online II - 05", "Sword Art Online II", "2", "05" },
        { "Steins;Gate.S01E22.1080p", "Steins;Gate", "01", "22" },
        { "Re:Zero 2nd Season - 26", "Re:Zero", "2", "26" },
        { "鬼灭の刃 第26話", "鬼灭の刃", nil, "26" },
        { "青春期猪头少年不会梦到兔女郎学姐 - 03",
          "青春期猪头少年不会梦到兔女郎学姐", nil, "03" },
        { "药屋少女的呢喃 S2 - 14", "药屋少女的呢喃", "2", "14" },
        { "MOVIE 剧场版 1080p", "MOVIE 剧场版 1080p", nil, nil },
    }

    for _, case in ipairs(parse_cases) do
        local title, season, episode = guess.parse_title("D:/anime/" .. case[1] .. ".mkv")
        assert_equal(title, case[2], "title of " .. case[1])
        assert_equal(season, case[3], "season of " .. case[1])
        assert_equal(episode, case[4], "episode of " .. case[1])
    end

    -- 字节字符类陷阱：「阶」(E9 98 B6) 首字节命中 [话集回] 的字节集，不能被当成集数单位
    local trap_title, trap_season, trap_episode =
        guess.parse_title("D:/anime/无职转生 第3阶 阶段测试.mkv")
    assert_equal(trap_episode, nil, "第3阶 must not be parsed as an episode")
    assert_equal(trap_season, nil, "第3阶 must not be parsed as a season")
    assert_true(trap_title ~= nil and trap_title ~= "", "第3阶 still yields a title")

    -- ---- 2. 展示名优先级 + 季集后缀 ----
    -- 不依赖繁简字典：用本身已是简体的名字，只测优先级与后缀
    assert_equal(
        title_normalize.format_subject_title({ name_cn = "进击的巨人 第三季", name = "進撃の巨人" }, nil, 3, nil),
        "进击的巨人 第三季",
        "已含「第三季」时不再追加后缀")
    assert_equal(
        title_normalize.format_subject_title({ name = "药屋少女的呢喃" }, nil, nil, 14),
        "药屋少女的呢喃 第14集",
        "集数后缀")
    assert_equal(
        title_normalize.format_subject_title({}, "无职转生", 2, 12),
        "无职转生 第二季 第12集",
        "name_cn 缺失时回退 fallback，并追加季集")
    assert_equal(
        title_normalize.format_subject_title({}, nil, nil, nil),
        "未知条目",
        "兜底标题")

    -- 罗马数字去重：中文译名常把季数嵌进名字，不能拼成「…Ⅲ … 第 3 季」
    local roman_title = title_normalize.format_subject_title(
        { name_cn = "无职转生Ⅲ ～到了异世界就拿出真本事～" }, nil, 3, 5)
    assert_equal(roman_title:find("第3季", 1, true), nil, "全角 Ⅲ 已表达季数，不应追加 第3季")
    assert_equal(roman_title:find("第三季", 1, true), nil, "全角 Ⅲ 已表达季数，不应追加 第三季")
    assert_true(roman_title:find("第5集", 1, true) ~= nil, "集数后缀仍需追加")

    -- 罗马数字必须独立成词：Isekai 里的 I 不算季数 1，所以仍要追加后缀
    -- （季数 1~10 用中文数字，与 Bangumi 的「第三季」写法保持一致）
    assert_equal(
        title_normalize.format_subject_title({ name_cn = "Isekai Quartet" }, nil, 1, nil),
        "Isekai Quartet 第一季",
        "Isekai 里的 I 不是季数标记，应当追加 第一季")

    -- ---- 3. 集数文本提取 ----
    assert_equal(title_normalize.extract_episode_number("第12话 起始"), 12, "extract 第12话")
    assert_equal(title_normalize.extract_episode_number("第 3 集"), 3, "extract 第3集")
    assert_equal(title_normalize.extract_episode_number("第3阶 阶段"), nil, "extract 第3阶 must be nil")
    assert_equal(title_normalize.extract_episode_number(""), nil, "extract empty must be nil")

    -- ---- 4. 职员名优先级 ----
    -- 不断言具体字形：字典是否可用取决于运行环境（非 mpv 下会优雅降级），
    -- 这里只锁死「日文原名优先于罗马字」这条规则本身。
    local name_resolver = require("modules.name_resolver")
    local person_name = name_resolver.resolve_person({ name = "宮崎駿", name_en = "Hayao Miyazaki" })
    assert_true(person_name ~= "" and person_name ~= "Hayao Miyazaki",
        "无中文译名时日文原名优先于罗马字，实际得到 " .. tostring(person_name))
    assert_equal(
        name_resolver.resolve_person({ name = "宮崎駿", name_cn = "宫崎骏" }),
        "宫崎骏",
        "有中文译名时取中文译名")

    if failures > 0 then
        mp.msg.error(string.format("[title_parse_flow] FAIL: %d assertion(s) failed", failures))
    else
        mp.msg.info("[title_parse_flow] PASS: season/episode parsing, display titles, person names")
    end
    mp.commandv("quit")
end

mp.add_timeout(0.2, function()
    local ok, err = pcall(run)
    if not ok then
        mp.msg.error("[title_parse_flow] ERROR: " .. tostring(err))
        mp.commandv("quit")
    end
end)
