-- modules/utils/image.lua
-- 图片处理工具函数
-- 提供 mpv 子进程将图片转换为 BGRA 原始位图格式
-- 以及 mpv 可执行文件路径的 4 级回退检测

local mp = require("mp")
local msg = require("mp.msg")
local utils = require("mp.utils")

local M = {}

-- 内部：检测文件是否存在
local function check_file_exists(path)
    if not path or path == "" then return false end
    local ok, meta = pcall(function()
        return utils.file_info(path)
    end)
    if not ok or not meta then return false end
    return meta.is_file == true
end

-- 内部：根据当前平台生成 mpv 候选路径列表
local function get_mpv_candidates(base_dir)
    local candidates = {}
    if not base_dir or base_dir == "" then return candidates end
    -- 判断是否 Windows（package.config 第一字符为 \\ 表示 Windows 路径分隔符）
    local is_windows = (package.config:sub(1, 1) == "\\")
    if is_windows then
        table.insert(candidates, utils.join_path(base_dir, "mpv.exe"))
        table.insert(candidates, utils.join_path(base_dir, "mpv"))
    else
        table.insert(candidates, utils.join_path(base_dir, "mpv"))
        table.insert(candidates, utils.join_path(base_dir, "mpv.exe"))
    end
    return candidates
end

-- 内部：去掉路径末尾的分隔符
local function strip_trailing_sep(path)
    if not path or path == "" then return path end
    while path:sub(-1) == "/" or path:sub(-1) == "\\" do
        path = path:sub(1, -2)
    end
    return path
end

-- detect_mpv_path: 4 级回退检测 mpv 可执行文件路径
-- 1. 用户配置的 mpv_path（通过参数传入）
-- 2. config-dir 上层目录（便携版，mpv.exe 通常在 portable_config 的上层）
-- 3. package.path 中的 lua 目录上层（便携版备选）
-- 4. PATH 中的 mpv / mpv.exe（直接返回名称让系统查找）
function M.detect_mpv_path(user_mpv_path)
    -- 1. 用户配置
    if user_mpv_path and user_mpv_path ~= "" then
        msg.debug("[image] detect_mpv_path: using user config: " .. tostring(user_mpv_path))
        return user_mpv_path
    end

    -- 2. config-dir 上层目录（便携版）
    -- config-dir 通常是 .../portable_config/，其上层是 .../mpv/
    local ok, config_dir = pcall(function()
        return mp.command_native({"expand-path", "~~/"})
    end)
    if ok and config_dir and config_dir ~= "" then
        local dir = strip_trailing_sep(config_dir)
        local parent = utils.split_path(dir)
        parent = strip_trailing_sep(parent)
        if parent and parent ~= "" and parent ~= dir then
            for _, candidate in ipairs(get_mpv_candidates(parent)) do
                if check_file_exists(candidate) then
                    msg.debug("[image] detect_mpv_path: found in config-dir parent: " .. candidate)
                    return candidate
                end
            end
        end
    end

    -- 3. package.path 中的 lua 目录上层
    -- package.path 包含脚本搜索路径，例如 .../scripts/uosc_staff_credits/?.lua
    -- 通过替换 ? 找到脚本所在路径，再向上找到 mpv 可执行文件目录
    for path_entry in package.path:gmatch("[^;]+") do
        -- 替换 ? 为本模块路径（移除 .lua 后缀）
        local script_path = path_entry:gsub("%%", "%%%%"):gsub("%?%.lua", "modules/utils/image")
        -- 检查是否包含 uosc_staff_credits（确保是本脚本的搜索路径）
        local idx = script_path:find("uosc_staff_credits")
        if idx then
            -- 找到 scripts 目录的位置，取其上层
            local scripts_idx = script_path:find("[/\\]scripts[/\\]")
            if scripts_idx then
                local base_dir = script_path:sub(1, scripts_idx - 1)
                if base_dir and base_dir ~= "" then
                    for _, candidate in ipairs(get_mpv_candidates(base_dir)) do
                        if check_file_exists(candidate) then
                            msg.debug("[image] detect_mpv_path: found via package.path: " .. candidate)
                            return candidate
                        end
                    end
                end
            end
        end
    end

    -- 4. PATH 中的 mpv / mpv.exe
    -- 直接返回名称，让系统 PATH 查找
    local fallback = "mpv"
    if package.config:sub(1, 1) == "\\" then
        fallback = "mpv.exe"
    end
    msg.debug("[image] detect_mpv_path: fallback to PATH: " .. fallback)
    return fallback
end

-- image_to_bgra: 用 mpv 子进程将图片转换为 BGRA 原始位图
-- img_path: 输入图片路径
-- bgra_path: 输出 BGRA 文件路径
-- target_w, target_h: 目标宽高（像素）
-- mpv_path: mpv 可执行文件路径（空则自动检测）
-- callback: function(success, error_msg)
-- 返回 abort 函数
function M.image_to_bgra(img_path, bgra_path, target_w, target_h, mpv_path, callback)
    if not img_path or not bgra_path then
        if callback then callback(false, "invalid img_path or bgra_path") end
        return function() end
    end
    target_w = tonumber(target_w)
    target_h = tonumber(target_h)
    if not target_w or not target_h or target_w <= 0 or target_h <= 0 then
        if callback then callback(false, "invalid target dimensions") end
        return function() end
    end

    -- 检测 mpv 路径
    mpv_path = mpv_path or M.detect_mpv_path()
    if not mpv_path or mpv_path == "" then
        if callback then callback(false, "mpv executable not found") end
        return function() end
    end

    -- 构建 video filter
    -- force_original_aspect_ratio=decrease: 等比缩放不变形
    -- pad=W:H:-1:-1:0x000000@1.0: 居中填充黑色不透明背景（@1.0 表示 alpha=255 完全不透明）
    -- scale=W:H: 强制缩放到目标尺寸
    -- format=bgra: 转换为 BGRA 原始格式
    local vf = string.format(
        "scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:-1:-1:0x000000@1.0,scale=%d:%d,format=bgra",
        target_w, target_h, target_w, target_h, target_w, target_h
    )

    local args = {
        mpv_path,
        "--no-config",
        "--msg-level=all=error",
        "--really-quiet",
        "--no-terminal",
        "--load-scripts=no",
        "--osc=no",
        "--ytdl=no",
        "--load-stats-overlay=no",
        "--load-osd-console=no",
        "--load-auto-profiles=no",
        "--vid=auto",
        "--no-audio",
        "--no-sub",
        "--frames=1",
        "--vf=" .. vf,
        "--ovc=rawvideo",
        "--of=rawvideo",
        "--o=" .. bgra_path,
        img_path,
    }

    msg.debug("[image] image_to_bgra: " .. tostring(img_path) .. " -> " .. tostring(bgra_path) ..
              " (" .. target_w .. "x" .. target_h .. ")")

    local abort_signal = mp.command_native_async({
        name = "subprocess",
        capture_stderr = true,
        capture_stdout = true,
        playback_only = true,
        args = args,
    }, function(success, result, error)
        if not success or not result or result.status ~= 0 then
            local err_msg = "image_to_bgra failed"
            if result then
                local combined = (result.stdout or "") .. (result.stderr or "")
                if combined and combined ~= "" then
                    err_msg = err_msg .. ": " .. combined
                end
            elseif error then
                err_msg = err_msg .. ": " .. tostring(error)
            end
            -- 截断 200 字符避免日志爆炸
            if #err_msg > 200 then
                err_msg = err_msg:sub(1, 200)
            end
            if callback then callback(false, err_msg) end
            return
        end
        if callback then callback(true, nil) end
    end)

    return function()
        pcall(function() mp.abort_async_command(abort_signal) end)
    end
end

return M
