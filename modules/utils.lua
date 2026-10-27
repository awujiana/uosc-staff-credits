-- modules/utils.lua
-- 工具函数门面模块（Facade）
-- Re-export modules/utils/* 子模块的常用函数
-- 提供文本处理（truncate_text）和字符串相似度（jaro_winkler / best_match_by_jw）功能

local path_mod = require("modules.utils.path")
local io_mod = require("modules.utils.io")
local net_mod = require("modules.utils.net")
local url_mod = require("modules.utils.url")
local image_mod = require("modules.utils.image")
local module_loader_mod = require("modules.utils.module_loader")

local M = {}

-- ====== Re-export path functions ======
M.get_parent_directory = path_mod.get_parent_directory
M.is_protocol = path_mod.is_protocol
M.remove_query = path_mod.remove_query
M.url_decode = path_mod.url_decode
M.hex_to_char = path_mod.hex_to_char

-- ====== Re-export io functions ======
M.read_file = io_mod.read_file
M.write_file = io_mod.write_file
M.write_json_file = io_mod.write_json_file
M.file_exists = io_mod.file_exists
M.is_writable = io_mod.is_writable
M.table_to_zero_indexed = io_mod.table_to_zero_indexed

-- ====== Re-export net functions ======
M.http_download = net_mod.http_download
M.call_cmd_async = net_mod.call_cmd_async

-- ====== Re-export url functions ======
M.url_encode = url_mod.url_encode
M.build_query = url_mod.build_query
M.parse_query = url_mod.parse_query

-- ====== Re-export image functions ======
M.image_to_bgra = image_mod.image_to_bgra
M.detect_mpv_path = image_mod.detect_mpv_path

-- ====== Re-export module_loader functions ======
M.make_init = module_loader_mod.make_init
M.make_feature_init = module_loader_mod.make_feature_init
M.make_set_opts = module_loader_mod.make_set_opts
M.safe_require = module_loader_mod.safe_require

-- ====== 文本处理工具 ======

-- UTF8 字符模式（来自 lua-users.org/wiki/LuaUnicode）
local UTF8_PATTERN = "[%z\1-\127\194-\244][\128-\191]*"

-- is_chinese: 检测字符串是否包含中文字符
-- 用于决定是否需要调用 API 转换为中文标题
-- 实现 reference: uosc_danmaku/modules/utils.lua:196
function M.is_chinese(str)
    if str == nil or type(str) ~= "string" then return false end
    -- UTF8 中文范围：\228-\233 开头的双字节字符（CJK 统一汉字）
    return str:find("[\228-\233][\128-\191]") ~= nil
end

-- truncate_text: 防御性截断文本
-- 防御性类型检查：nil -> "", 非字符串 -> tostring, 然后按 UTF8 字符数截断
-- 超过 max_len 时截取前 max_len 个字符并追加 "..."
-- max_len <= 0 或 nil 时不截断
function M.truncate_text(text, max_len)
    -- 防御性类型检查
    if text == nil then return "" end
    if type(text) ~= "string" then
        text = tostring(text)
    end

    -- 不截断的条件
    if max_len == nil then return text end
    max_len = tonumber(max_len)
    if not max_len or max_len <= 0 then return text end

    -- 计算 UTF8 字符数
    local count = 0
    for _ in text:gmatch(UTF8_PATTERN) do
        count = count + 1
    end

    -- 未超长，直接返回
    if count <= max_len then
        return text
    end

    -- 截取前 max_len 个 UTF8 字符
    local result = {}
    local idx = 0
    for char in text:gmatch(UTF8_PATTERN) do
        if idx >= max_len then break end
        table.insert(result, char)
        idx = idx + 1
    end
    return table.concat(result) .. "..."
end

-- ====== Jaro / Jaro-Winkler 字符串相似度 ======

-- jaro_similarity: Jaro 相似度算法
-- 返回 0.0 - 1.0 之间的浮点数
-- 兼容 UTF8 多字节字符
function M.jaro_similarity(s1, s2)
    -- 防御性类型转换
    if s1 == nil then s1 = "" end
    if s2 == nil then s2 = "" end
    if type(s1) ~= "string" then s1 = tostring(s1) end
    if type(s2) ~= "string" then s2 = tostring(s2) end

    -- 完全相同直接返回 1.0
    if s1 == s2 then return 1.0 end

    -- 将字符串转为 UTF8 字符数组
    local chars1 = {}
    for c in s1:gmatch(UTF8_PATTERN) do table.insert(chars1, c) end
    local chars2 = {}
    for c in s2:gmatch(UTF8_PATTERN) do table.insert(chars2, c) end
    local len1 = #chars1
    local len2 = #chars2

    -- 空字符串处理
    if len1 == 0 or len2 == 0 then return 0.0 end

    -- 匹配窗口：max(len1, len2) / 2 - 1
    local match_window = math.floor(math.max(len1, len2) / 2.0) - 1
    if match_window < 0 then match_window = 0 end

    -- 匹配标记
    local matches1 = {}
    local matches2 = {}
    local m = 0  -- 匹配数

    -- 查找匹配字符
    for i = 1, len1 do
        local start_idx = math.max(1, i - match_window)
        local end_idx = math.min(len2, i + match_window)
        for k = start_idx, end_idx do
            if not matches2[k] and chars1[i] == chars2[k] then
                matches1[i] = true
                matches2[k] = true
                m = m + 1
                break
            end
        end
    end

    -- 无匹配返回 0
    if m == 0 then return 0.0 end

    -- 计算转置数 t
    local t = 0
    local k = 1
    for i = 1, len1 do
        if matches1[i] then
            -- 找到下一个匹配的 chars2
            while not matches2[k] do
                k = k + 1
            end
            if chars1[i] ~= chars2[k] then
                t = t + 1
            end
            k = k + 1
        end
    end
    t = t / 2.0

    -- Jaro 相似度公式
    return (m / len1 + m / len2 + (m - t) / m) / 3.0
end

-- jaro_winkler: Jaro-Winkler 相似度算法
-- 在 Jaro 相似度基础上增加前缀权重，对开头相同的字符串给予更高分数
-- 返回 0.0 - 1.0 之间的浮点数
function M.jaro_winkler(s1, s2)
    -- 防御性类型转换
    if s1 == nil then s1 = "" end
    if s2 == nil then s2 = "" end
    if type(s1) ~= "string" then s1 = tostring(s1) end
    if type(s2) ~= "string" then s2 = tostring(s2) end

    -- 完全相同直接返回 1.0
    if s1 == s2 then return 1.0 end

    -- 都为空返回 0.0
    if #s1 == 0 and #s2 == 0 then return 0.0 end

    -- 计算 Jaro 相似度
    local jaro = M.jaro_similarity(s1, s2)

    -- 计算公共前缀长度（最多 4 个字符）
    local chars1 = {}
    for c in s1:gmatch(UTF8_PATTERN) do table.insert(chars1, c) end
    local chars2 = {}
    for c in s2:gmatch(UTF8_PATTERN) do table.insert(chars2, c) end
    local prefix_len = 0
    local max_prefix = math.min(4, #chars1, #chars2)
    for i = 1, max_prefix do
        if chars1[i] == chars2[i] then
            prefix_len = prefix_len + 1
        else
            break
        end
    end

    -- Jaro-Winkler 公式: jaro + prefix_len * p * (1 - jaro)
    -- p 为前缀权重因子，标准值 0.1
    local p = 0.1
    return jaro + prefix_len * p * (1 - jaro)
end

-- best_match_by_jw: 在候选列表中找最佳匹配
-- candidates: 字符串列表（数组）
-- query: 查询字符串
-- threshold: 阈值，默认 0.6，低于此分数不返回匹配
-- 返回 (best_match, best_score)
--   无匹配时返回 (nil, best_score)（best_score 可能为 0）
function M.best_match_by_jw(candidates, query, threshold)
    if not candidates or type(candidates) ~= "table" then return nil, 0 end
    if #candidates == 0 then return nil, 0 end
    if not query or query == "" then return nil, 0 end

    threshold = threshold or 0.6

    local best_match = nil
    local best_score = 0

    for _, candidate in ipairs(candidates) do
        if candidate and type(candidate) == "string" then
            local score = M.jaro_winkler(candidate, query)
            if score > best_score then
                best_score = score
                best_match = candidate
            end
        end
    end

    -- 仅当最佳分数达到阈值时返回匹配
    if best_score >= threshold then
        return best_match, best_score
    end
    return nil, best_score
end

return M
