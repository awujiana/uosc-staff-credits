-- modules/utils/url.lua
-- URL 编解码工具函数
-- 提供 URL 编码、查询字符串构建与解析

local M = {}

-- url_encode: URL 编码
-- 将非安全字符（非字母数字及 -._~）转换为 %XX 转义
function M.url_encode(str)
    if str == nil then return nil end
    str = tostring(str)
    return (str:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- build_query: 从参数表构建查询字符串
-- params: { key1 = val1, key2 = val2, ... }
-- 返回 "key1=val1&key2=val2" 形式（已 URL 编码）
-- 跳过值为 nil 的参数
function M.build_query(params)
    if type(params) ~= "table" then return "" end
    local parts = {}
    for k, v in pairs(params) do
        if v ~= nil then
            local pair = M.url_encode(tostring(k)) .. "=" .. M.url_encode(tostring(v))
            table.insert(parts, pair)
        end
    end
    if #parts == 0 then return "" end
    return table.concat(parts, "&")
end

-- parse_query: 解析查询字符串
-- str: "key1=val1&key2=val2" 或 "?key1=val1&key2=val2"
-- 返回 { key1 = val1, key2 = val2 }（已 URL 解码，+ 转空格）
function M.parse_query(str)
    if not str or str == "" then return {} end
    -- 去掉前导 ?
    if str:sub(1, 1) == "?" then str = str:sub(2) end

    local result = {}
    for pair in str:gmatch("[^&]+") do
        local eq = pair:find("=", 1, true)
        if eq then
            local key = pair:sub(1, eq - 1)
            local val = pair:sub(eq + 1)
            key = key:gsub("%+", " "):gsub("%%(%x%x)", function(x)
                return string.char(tonumber(x, 16))
            end)
            val = val:gsub("%+", " "):gsub("%%(%x%x)", function(x)
                return string.char(tonumber(x, 16))
            end)
            result[key] = val
        else
            -- 没有 = 的视为 flag，值为空字符串
            local key = pair:gsub("%+", " "):gsub("%%(%x%x)", function(x)
                return string.char(tonumber(x, 16))
            end)
            result[key] = ""
        end
    end
    return result
end

return M
