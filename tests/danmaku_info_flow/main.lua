-- danmaku-anime-info 广播协议回归测试。
--
-- 覆盖 uosc_danmaku（fork 版）→ uosc_staff_credits 的两条取数通道：
--   1. script-message 实时广播（含换片清场与 path 新鲜度校验）
--   2. user-data 持久属性（脚本加载顺序晚于 uosc_danmaku 时的兜底）
--
-- 只有在 harness 提供的 mpv_stub 下才有意义（需要能改 path / user-data /
-- 手动触发 script-message）。真实 mpv 里直接跳过，避免误报。

local mp = require("mp")

local script_dir = mp.get_script_directory()
package.path = script_dir .. "/../../?.lua;" .. script_dir .. "/../../?/init.lua;" .. package.path

local stub = rawget(_G, "mpv_stub")
if type(stub) ~= "table" then
    mp.msg.warn("[danmaku_info_flow] SKIP: 需要 harness 提供的 mpv_stub")
    mp.commandv("quit")
    return
end

local failures = 0

local function assert_equal(actual, expected, message)
    if actual == expected then return end
    failures = failures + 1
    mp.msg.error(string.format("[danmaku_info_flow] FAIL %s: got %q, want %q",
        message or "", tostring(actual), tostring(expected)))
end

local function assert_true(value, message)
    if value then return end
    failures = failures + 1
    mp.msg.error("[danmaku_info_flow] FAIL " .. tostring(message or "assertion failed"))
end

local function emit(...)
    local cb = stub.script_messages["danmaku-anime-info"]
    if not cb then
        failures = failures + 1
        mp.msg.error("[danmaku_info_flow] FAIL: 未注册 danmaku-anime-info 处理函数")
        return
    end
    cb(...)
end

local function run()
    local danmaku_link = require("modules.danmaku_link")

    -- ---- 1. 什么都没有时返回 nil ----
    stub.path = "D:/anime/[Sub] Show - 01.mkv"
    stub.user_data = {}
    assert_equal(danmaku_link.get_info(), nil, "无广播无历史时应返回 nil")

    -- ---- 2. 实时广播 ----
    emit("无职转生 ～到了异世界就拿出真本事～", "第3话", "1024", "https://api.example",
        stub.path)
    local info = danmaku_link.get_info()
    assert_true(type(info) == "table", "广播后应返回 table")
    if type(info) == "table" then
        assert_equal(info.anime, "无职转生 ～到了异世界就拿出真本事～", "广播 anime")
        assert_equal(info.episode, "第3话", "广播 episode")
        assert_equal(info.episode_id, "1024", "广播 episode_id")
        assert_equal(info.api_server, "https://api.example", "广播 api_server")
    end

    -- ---- 3. path 不匹配时丢弃（换片后的陈旧广播）----
    stub.path = "D:/anime/[Sub] Other - 01.mkv"
    assert_equal(danmaku_link.get_info(), nil, "path 不匹配时应丢弃广播缓存")

    -- ---- 4. 空广播 = 清场 ----
    stub.path = "D:/anime/[Sub] Show - 02.mkv"
    emit("-")
    assert_equal(danmaku_link.get_info(), nil, "空广播应清空缓存")

    -- ---- 5. user-data 兜底（模拟脚本加载顺序晚于 uosc_danmaku）----
    stub.user_data = {
        uosc_danmaku = {
            ["anime-title"] = "进击的巨人 最终季",
            ["anime-episode"] = "第05话",
            ["anime-episode-id"] = "2048",
            ["anime-api-server"] = "https://api.example",
        },
    }
    info = danmaku_link.get_info()
    assert_true(type(info) == "table", "user-data 兜底应返回 table")
    if type(info) == "table" then
        assert_equal(info.anime, "进击的巨人 最终季", "user-data anime")
        assert_equal(info.episode, "第05话", "user-data episode")
        assert_equal(info.episode_id, "2048", "user-data episode_id")
        assert_equal(info.api_server, "https://api.example", "user-data api_server")
    end

    -- ---- 6. 广播优先级高于 user-data ----
    emit("咒术回战", "第12话", "4096", "-", stub.path)
    info = danmaku_link.get_info()
    assert_true(type(info) == "table" and info.anime == "咒术回战",
        "广播应优先于 user-data")

    -- ---- 7. "-" 占位还原为 nil ----
    assert_equal(info.api_server, nil, "\"-\" 占位应还原为 nil")

    -- ---- 8. 历史兜底仍然可用 ----
    stub.script_messages["danmaku-anime-info"] = nil
    stub.user_data = {}
    stub.path = nil
    assert_equal(danmaku_link.get_info(), nil, "无 path 时应返回 nil")

    if failures > 0 then
        mp.msg.error(string.format("[danmaku_info_flow] FAIL: %d assertion(s) failed", failures))
    else
        mp.msg.info("[danmaku_info_flow] PASS: broadcast, user-data fallback, staleness guard")
    end
    mp.commandv("quit")
end

mp.add_timeout(0.2, function()
    local ok, err = pcall(run)
    if not ok then
        mp.msg.error("[danmaku_info_flow] ERROR: " .. tostring(err))
        mp.commandv("quit")
    end
end)
