-- modules/utils/io.lua
-- 文件 IO 工具函数
-- 提供文件读写、存在性检查、JSON 文件写入等功能

local utils = require("mp.utils")

local M = {}

-- file_exists: 检查文件是否存在
-- 使用 mp.utils.file_info 获取文件元信息
function M.file_exists(path)
    if not path then return false end
    local ok, meta = pcall(function()
        return utils.file_info(path)
    end)
    if not ok or not meta then return false end
    return meta.is_file == true
end

-- read_file: 读取文件全部内容
-- 失败返回 nil。使用 pcall 保护读取操作，确保文件句柄 always close
function M.read_file(path)
    if not path then return nil end
    local file = io.open(path, "r")
    if not file then return nil end
    local ok, content = pcall(function()
        return file:read("*all")
    end)
    file:close()
    if not ok then return nil end
    return content
end

-- write_file: 写入文件内容
-- 成功返回 true，失败返回 false。使用 pcall 保护写入操作
function M.write_file(path, content)
    if not path then return false end
    local file = io.open(path, "w")
    if not file then return false end
    local ok = pcall(function()
        file:write(content or "")
    end)
    file:close()
    return ok
end

-- write_json_file: 将表写入 JSON 文件
-- 使用 mp.utils.format_json 序列化。先序列化成功再写入文件，避免序列化失败导致空文件
function M.write_json_file(path, data)
    if not path then return false end
    -- 先序列化，避免打开文件后序列化失败留下空文件
    local ok_json, json_str = pcall(utils.format_json, data)
    if not ok_json or not json_str then return false end
    local file = io.open(path, "w")
    if not file then return false end
    local ok_w = pcall(function()
        file:write(json_str)
    end)
    file:close()
    return ok_w
end

-- is_writable: 检查目录（通过测试文件）是否可写
-- 使用唯一临时文件名避免截断已有文件内容
-- 删除失败时尝试再次删除，避免残留临时文件
function M.is_writable(path)
    if not path then return false end
    -- 使用唯一后缀避免覆盖已有文件
    local test_path = path .. ".writable_test_" .. tostring(os.time()) .. "_" .. tostring(math.random(1, 1000000))
    local file = io.open(test_path, "w")
    if not file then return false end
    file:close()
    -- 尝试删除临时文件，最多重试 3 次
    local removed = false
    for _ = 1, 3 do
        if os.remove(test_path) then
            removed = true
            break
        end
    end
    -- 删除失败也算可写（至少证明能创建文件），但记录日志
    if not removed then
        -- 静默处理：无法删除但可创建，仍返回 true
        -- 残留的临时文件不会影响功能，只是占用少量磁盘空间
    end
    return true
end

-- table_to_zero_indexed: 将 1-indexed 数组转为 0-indexed
-- 用于 uosc_danmaku 兼容（其 KEY 表使用 0-indexed）
-- 警告：原地修改输入表。正向迭代避免反向覆盖
function M.table_to_zero_indexed(t)
    if type(t) ~= "table" then return t end
    local n = #t
    -- 正向迭代：t[0]=t[1], t[1]=t[2], ...
    -- 注意：t[0]=t[1] 时 t[1] 还未被覆盖，安全
    for i = 1, n do
        t[i - 1] = t[i]
    end
    t[n] = nil
    return t
end

return M
