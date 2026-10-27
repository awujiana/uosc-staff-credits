-- modules/utils/path.lua
-- 路径处理工具函数
-- 提供路径解析、协议判断、URL 解码等功能

local mp = require("mp")
local utils = require("mp.utils")

local M = {}

-- is_protocol: 判断路径是否为网络协议（http/https/rtmp 等）
-- 接受形如 "http://..." 或 "protocol:?..." 的路径
function M.is_protocol(path)
    if type(path) ~= "string" then return false end
    return path:find("^%a[%w.+-]-://") ~= nil or path:find("^%a[%w.+-]-:%?") ~= nil
end

-- hex_to_char: 将十六进制字符串转换为对应字符
-- 用于 URL 解码
function M.hex_to_char(x)
    return string.char(tonumber(x, 16))
end

-- url_decode: URL 解码
-- 去除协议前缀，解码 %XX 转义，去除查询字符串
function M.url_decode(str)
    if str == nil then return nil end
    str = str:gsub("^%a[%a%d-_]+://", "")
          :gsub("^%a[%a%d-_]+:\\?", "")
          :gsub("%%(%x%x)", M.hex_to_char)
    if str:find("://localhost:?") then
        str = str:gsub("^.*/", "")
    end
    str = str:gsub("%?.+", "")
          :gsub("%+", " ")
    return str
end

-- remove_query: 去除 URL 中的查询字符串部分
-- 例如 "http://example.com/path?a=1" -> "http://example.com/path"
function M.remove_query(url)
    if not url then return url end
    local qpos = string.find(url, "?", 1, true)
    if qpos then
        return string.sub(url, 1, qpos - 1)
    end
    return url
end

-- get_parent_directory: 获取路径的父目录
-- 对于网络协议路径返回 nil
-- 对于本地路径，先调用 normalize-path 规范化，再取 split_path
function M.get_parent_directory(path)
    if not path then return nil end
    if M.is_protocol(path) then return nil end

    local normalized = path
    -- 尝试使用 mpv 的 normalize-path 命令规范化路径
    local ok, result = pcall(function()
        return mp.command_native({"normalize-path", path})
    end)
    if ok and type(result) == "string" and result ~= "" then
        normalized = result
    end

    local dir = utils.split_path(normalized)
    return dir
end

return M
