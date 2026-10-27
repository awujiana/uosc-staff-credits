-- modules/defaults.lua
-- 配置默认值 SSOT（Single Source of Truth）
-- 所有配置项的默认值集中在此，与 script-opts/uosc_staff_credits.conf 保持一致
-- 使用 mp.get_opt 模式读取 script-opts

local mp = require("mp")
local msg = require("mp.msg")

local M = {}

-- === 硬编码常量 ===
M.MAX_ENTRIES = 5000                          -- history LRU 阈值
M.DEFAULT_MAX_LAST_SUBJECT_ENTRIES = 50       -- state 缓存上限
M.DEFAULT_COVER_INTRO_CACHE_TTL = 1800        -- 封面缓存 30 分钟（秒）
-- 注: servers 配置版本号 SCHEMA_VERSION 由 modules/servers.lua 自己持有（当前 5），
--     此处不再重复定义，避免两处数字不同步造成误导。

-- === 配置默认值表 ===
-- 与 script-opts/uosc_staff_credits.conf 中的配置项一一对应
M.defaults = {
    api_base_url = "https://api.bangumi.one",
    api_server = "",
    danmaku_api_server = "https://api.dandanplay.net",
    tmdb_api_key = "",
    -- === Bangumi 用户鉴权与观看进度同步 (2026-10-06 新增) ===
    -- access token，留空则相关功能整体关闭（优雅降级）
    -- 获取: https://next.bgm.tv/demo/access-token
    -- 安全: 等同于账号权限，勿提交到 Git
    bangumi_token = "",
    -- 是否启用观看进度同步（需 bangumi_token 非空）
    enable_progress_sync = true,
    -- 进度同步档位: "off"（仅手动菜单，打开视频零网络请求）
    --               / "notify"（打开视频读一次进度并提示）
    --               / "auto"（达阈值后自动标记本集为看过）
    progress_sync_mode = "off",
    -- auto 模式触发阈值（播放进度百分比 1-100）
    progress_sync_threshold = 80,
    -- 标记时使用的收藏类型（仅当条目尚未收藏时生效）
    -- ⚠️ Bangumi **新 API** 取值，与旧版文档顺序不同：
    --    1=想看  2=看过  3=在看  4=搁置  5=抛弃
    collection_type_on_mark = 3,
    timeout = 8,  -- v1.9: loading 倒计时显示超时（秒）。bangumi 搜索通常 5-8s
    -- v1.9.1: 网络请求超时（curl --max-time），独立于 loading 显示超时
    --       persons/characters 等详情端点数据量大（尤其热门番剧），需要比搜索更长的超时
    request_timeout = 15,  -- 单次 HTTP 请求最大耗时（秒），仅影响 curl 子进程
    debug = true,
    max_results = 10,
    history_path = "~~/staff-credits-history.json",
    mpv_path = "",
    user_agent = "uosc_staff_credits (https://github.com/user/uosc_staff_credits)",
    title_replace = [[{"rules": [{"^〔(.-)〕": "%1"}, {"^.*《(.-)》": "%1"}]}]],
    enable_extra_search = true,
    image_cache_days = 30,
    autoload_with_danmaku = true,
    -- SSL/TLS 配置（解决 Windows curl exit code 35 握手失败）
    -- ssl_no_revoke: 禁用证书吊销列表（CRL）检查，Windows 网络受限时常用
    --   curl 在 Windows 上若 CRL 分发点不可达会报 exit code 35，禁用后仍校验证书链
    ssl_no_revoke = true,
    -- cacert_path: 指定 CA 证书 bundle 路径，留空使用系统默认
    -- 例: C:/curl-ca-bundle.crt
    cacert_path = "",
    -- insecure: 跳过证书验证（仅调试用，生产环境禁用）
    insecure = false,
    -- === 本地持久化数据缓存配置 (v1.7) ===
    -- 数据缓存有效天数（缓存文件: ~~/staff-credits-data-cache.json）
    data_cache_days = 30,
    -- 是否启用本地数据缓存
    enable_data_cache = true,
    -- 静默预加载深度: "subject" / "characters" / "persons" / "all"
    -- subject: 仅预取条目 ID
    -- characters: +角色列表
    -- persons: +角色+职员列表
    -- all: +角色+职员+条目详情
    silent_preload_depth = "all",
    -- 翻页按钮位置: "top" / "middle" / "bottom"
    pagination_position = "bottom",
}

-- === 类型转换辅助函数 ===

-- 将字符串转换为布尔值（接受 yes/no/true/false/1/0）
local function to_bool(val, default)
    if val == nil then return default end
    local v = tostring(val):lower()
    if v == "yes" or v == "true" or v == "1" then return true end
    if v == "no" or v == "false" or v == "0" then return false end
    return default
end

-- 将字符串转换为数字
local function to_number(val, default)
    if val == nil then return default end
    local n = tonumber(val)
    return n or default
end

-- 将值转换为字符串
local function to_str(val, default)
    if val == nil then return default end
    return tostring(val)
end

-- === 加载配置函数 ===
-- 使用 mp.get_opt 模式读取 script-opts，与 defaults 合并
-- 返回包含所有配置项的表（类型与 defaults 中的默认值类型一致）
function M.load_options()
    local opts = {}
    for k, default_val in pairs(M.defaults) do
        -- mp.get_opt 读取 script-opts 中以脚本名为前缀的选项
        local raw = mp.get_opt(k)
        if raw == nil then
            opts[k] = default_val
        else
            if type(default_val) == "boolean" then
                opts[k] = to_bool(raw, default_val)
            elseif type(default_val) == "number" then
                opts[k] = to_number(raw, default_val)
            else
                opts[k] = to_str(raw, default_val)
            end
        end
    end
    local count = 0
    for _ in pairs(opts) do count = count + 1 end
    msg.debug("[defaults] load_options: loaded " .. count .. " options (debug=" .. tostring(opts.debug) .. ")")
    return opts
end

return M
