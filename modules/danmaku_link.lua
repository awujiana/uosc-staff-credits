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

-- 实时广播缓存（uosc_danmaku fork 版主动推送）
local live = nil

-- 广播协议用 "-" 占位空字段，这里还原成 nil
local function dash_to_nil(value)
    if type(value) ~= "string" or value == "" or value == "-" then return nil end
    return value
end

-- on_anime_info: 接收 uosc_danmaku 的 danmaku-anime-info 广播
-- 参数：anime, episode, episode_id, api_server, path（空值用 "-" 占位）
function M.on_anime_info(anime, episode, episode_id, api_server, path)
    anime = dash_to_nil(anime)
    if not anime then
        -- 空广播 = uosc_danmaku 换片清场
        live = nil
        return
    end
    live = {
        anime = anime,
        episode = dash_to_nil(episode),
        episode_id = dash_to_nil(episode_id),
        api_server = dash_to_nil(api_server),
        path = dash_to_nil(path),
    }
    mp.msg.verbose("[danmaku_link] anime-info: " .. anime ..
        " / " .. tostring(live.episode) ..
        " / id=" .. tostring(live.episode_id))
end

mp.register_script_message("danmaku-anime-info", M.on_anime_info)

-- info_from_user_data: 读取 uosc_danmaku 写入的 user-data 属性
-- 动态遍历脚本名，不硬编码 "uosc_danmaku"
local function info_from_user_data()
    local user_data = mp.get_property_native("user-data")
    if type(user_data) ~= "table" then return nil end
    for _, script_data in pairs(user_data) do
        if type(script_data) == "table" then
            local anime = script_data["anime-title"]
            if type(anime) == "string" and anime ~= "" then
                return {
                    anime = anime,
                    episode = dash_to_nil(script_data["anime-episode"]),
                    episode_id = dash_to_nil(script_data["anime-episode-id"]),
                    api_server = dash_to_nil(script_data["anime-api-server"]),
                }
            end
        end
    end
    return nil
end

-- get_info: 主入口
-- 返回 {anime, episode, episode_number, episode_id, api_server} 或 nil
--
-- 取数优先级（从最准到最猜）：
--   0. uosc_danmaku 主动广播的实时结果（fork 版，见 docs/UOSC_DANMAKU_API.md）
--   1. uosc_danmaku 写入的 user-data 持久属性（脚本加载顺序无关）
--   2. danmaku-history.json 按路径匹配（上游原版唯一可用的方式）
function M.get_info()
    local cur_path = mp.get_property("path")

    -- 0. 实时广播缓存。带上 path 校验：换片后即使没收到新消息，
    --    旧结果也不会被当成当前视频的匹配。
    if live and (not live.path or live.path == cur_path) then
        return {
            anime = live.anime,
            episode = live.episode,
            episode_number = live.episode_number,
            episode_id = live.episode_id,
            api_server = live.api_server,
        }
    end

    -- 1. user-data 持久属性
    local from_user_data = info_from_user_data()
    if from_user_data then return from_user_data end

    -- 2. 获取当前路径
    local path = cur_path
    if not path then return nil end

    -- 3. 读取历史文件
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
