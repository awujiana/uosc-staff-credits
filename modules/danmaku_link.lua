-- modules/danmaku_link.lua
-- uosc_danmaku 集成模块（关键）
-- 读取 uosc_danmaku 的 danmaku-history.json，匹配当前播放视频的历史记录
-- 用于复用 dandanplay 已匹配的 anime/episode 信息，避免重复搜索
--
-- 所有失败（文件缺失/解析失败/无匹配）一律静默返回 nil，不记录日志
-- 因为这是"尽力而为"的优化路径，缺失不应影响主流程
--
-- 遵循 ADR-10 统一 init(opts, deps) 接口

local mp = require("mp")
local utils = require("mp.utils")

local M = {}

local opts, deps, init = require("modules.utils.module_loader").make_init(
    "danmaku_link",
    {notify = "table"}
)
M.init = init

-- 引用基础设施
local utils_mod = require("modules.utils")
local io_mod = require("modules.utils.io")
local path_mod = require("modules.utils.path")

-- uosc_danmaku 默认 history 路径
local DANMAKU_HISTORY_PATH = "~~/danmaku-history.json"

-- get_history_path: 返回 danmaku-history.json 的展开路径
function M.get_history_path()
    return mp.command_native({"expand-path", DANMAKU_HISTORY_PATH})
end

-- read_raw: 读取原始历史表（调试用）
-- 返回 table 或 nil
function M.read_raw()
    local path = M.get_history_path()
    if not path then return nil end
    if not io_mod.file_exists(path) then return nil end
    local content = io_mod.read_file(path)
    if not content or content == "" then return nil end
    local data = utils.parse_json(content)
    if type(data) ~= "table" then return nil end
    return data
end

-- 内部：从历史记录条目构造返回信息
-- 仅提取 uosc_staff_credits 需要的字段
local function build_info(record)
    if type(record) ~= "table" then return nil end
    return {
        anime = record.animeTitle,
        episode = record.episodeTitle,
        episode_number = record.episodeNumber,
        episode_id = record.episodeId,
        api_server = record.api_server,
    }
end

-- get_info: 主入口
-- 读取 danmaku-history.json 并匹配当前播放视频
-- 返回 {anime, episode, episode_number, episode_id, api_server} 或 nil
function M.get_info()
    -- 0. 优先读取 uosc_danmaku 实时设置的 user-data 属性（最准确，实时匹配结果）
    --    uosc_danmaku 在 show_loaded 和历史读取时设置 ANIME_TITLE 属性
    --    动态检测脚本名，避免硬编码
    local user_data = mp.get_property_native("user-data")
    if type(user_data) == "table" then
        for script_key, script_data in pairs(user_data) do
            if type(script_data) == "table" and type(script_data["anime-title"]) == "string"
               and script_data["anime-title"] ~= "" then
                mp.msg.info("[danmaku_link] found anime-title from " .. tostring(script_key) .. ": " .. script_data["anime-title"])
                return { anime = script_data["anime-title"] }
            end
        end
    end
    mp.msg.info("[danmaku_link] no anime-title in user-data, user_data type=" .. type(user_data))

    -- 1. 获取当前路径
    local path = mp.get_property("path")
    if not path then return nil end

    -- 2. 读取历史文件
    local history = M.read_raw()
    if not history then return nil end

    -- 3. 按路径类型匹配
    local is_url = path_mod.is_protocol(path)

    if is_url then
        -- 网络协议路径：uosc_danmaku 用 "title" 或 "title SeasonN" 作为 key
        -- 需要 parse_title 获取标题，与历史 key 匹配
        local guess_mod = require("modules.guess")
        local title, season_num, _ = guess_mod.parse_title(path)
        if not title then return nil end

        -- 尝试 "title SeasonN" 形式
        if season_num then
            local key_with_season = title .. " Season" .. season_num
            local rec = history[key_with_season]
            local info = build_info(rec)
            if info and info.anime then return info end
        end

        -- 尝试仅 "title" 形式
        local rec = history[title]
        local info = build_info(rec)
        if info and info.anime then return info end

        -- 兜底：用 remove_query(path) 直接匹配（旧版 uosc_danmaku 行为）
        local stripped = path_mod.remove_query(path)
        if stripped then
            rec = history[stripped]
            info = build_info(rec)
            if info and info.anime then return info end
        end

        return nil
    else
        -- 本地文件：uosc_danmaku 用父目录作为 key
        local dir = path_mod.get_parent_directory(path)
        if not dir then return nil end

        -- 直接用父目录匹配
        local rec = history[dir]
        local info = build_info(rec)
        if info and info.anime then return info end

        -- 兜底：尝试规范化路径（normalize-path 后再 split）
        local ok, normalized = pcall(function()
            return mp.command_native({"normalize-path", path})
        end)
        if ok and type(normalized) == "string" and normalized ~= "" then
            local dir2 = utils.split_path(normalized)
            if dir2 and dir2 ~= dir then
                rec = history[dir2]
                info = build_info(rec)
                if info and info.anime then return info end
            end
        end

        return nil
    end
end

return M
