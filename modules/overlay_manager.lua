-- modules/overlay_manager.lua
-- 通用图片 overlay 管理器
-- 统一管理 overlay id 分配、添加、移除，避免各面板独立管理导致 id 冲突
-- 适用面板: cards(0-31 角色 / 32-47 CV 头像), cover_intro(62 单张封面), staff_grid 等
-- 不使用 make_init 工厂模式，直接 require 即可用

local mp = require("mp")
local utils = require("mp.utils")

local M = {}

-- ====== 模块内部状态 ======
-- 已分配区间表: panel_name -> {start_id, end_id}
local allocations = {}
-- 已添加 overlay id 列表
local active_ids = {}

-- ====== 常量 ======
local MAX_ID = 62  -- 最大可用 id（63 是 mpv 最大值，保留给其他用途）

-- ====== 内部辅助：检查区间重叠 ======
-- 判断 [s1, e1] 与 [s2, e2] 是否重叠
local function is_overlap(s1, e1, s2, e2)
    return s1 <= e2 and s2 <= e1
end

-- ====== 内部辅助：释放面板的旧分配 ======
local function release_allocation(panel_name)
    allocations[panel_name] = nil
end

-- ====== 公共接口 ======

-- 分配连续 id 范围
-- 参数:
--   panel_name: 面板名（如 "cards", "cover_intro", "staff_grid"）
--   count: 需要分配的 id 数量
-- 返回: {start_id, end_id} 表；分配失败（超出 MAX_ID）返回 nil
-- 行为:
--   - 同一面板重复调用时，先释放旧分配再重新分配
--   - 新分配避免与已有区间重叠
--   - 起始 id 从 0 开始，最大 id 不超过 62
function M.alloc_id(panel_name, count)
    if type(panel_name) ~= "string" or panel_name == "" then return nil end
    count = tonumber(count)
    if count == nil or count <= 0 then return nil end

    -- 释放旧分配（同一面板重复调用场景）
    release_allocation(panel_name)

    -- 在 [0, MAX_ID] 区间内寻找连续 count 个空闲 id
    local start_id = 0
    while start_id + count - 1 <= MAX_ID do
        local end_id = start_id + count - 1
        local conflict = false
        for _, range in pairs(allocations) do
            if is_overlap(start_id, end_id, range.start_id, range.end_id) then
                conflict = true
                break
            end
        end
        if not conflict then
            allocations[panel_name] = {start_id = start_id, end_id = end_id}
            return {start_id = start_id, end_id = end_id}
        end
        start_id = start_id + 1
    end

    -- 分配失败
    return nil
end

-- 添加 overlay（含文件验证）
-- 参数: overlay id, 坐标 x/y, BGRA 文件路径, 宽 w, 高 h
-- 返回: true/false
-- 行为:
--   - 先验证文件存在且大小 > 0（使用 mp.utils.file_info）
--   - 验证失败时返回 false，不调用 overlay-add
--   - 验证通过后执行 overlay-add（offset=0, format="bgra", stride=4*w）
--   - 记录 id 到 active_ids 表
--   - 使用 pcall 包裹 mp.commandv 避免异常
function M.add(id, x, y, bgra_path, w, h)
    id = tonumber(id)
    x = tonumber(x)
    y = tonumber(y)
    w = tonumber(w)
    h = tonumber(h)
    if id == nil or x == nil or y == nil or w == nil or h == nil then
        return false
    end
    if type(bgra_path) ~= "string" or bgra_path == "" then
        return false
    end
    if w <= 0 or h <= 0 then
        return false
    end

    -- 文件验证：存在且大小 > 0
    local file_info = utils.file_info(bgra_path)
    if not file_info or not file_info.is_file then
        return false
    end
    local file_size = file_info.size or 0
    if file_size <= 0 then
        return false
    end

    -- 执行 overlay-add（pcall 包裹）
    -- 参数: id, x, y, path, offset(0), format("bgra"), w, h, stride(4*w)
    local ok = pcall(mp.commandv, "overlay-add",
        id, x, y, bgra_path, 0, "bgra", w, h, 4 * w)
    if not ok then
        return false
    end

    -- 记录到 active_ids（去重）
    for _, existing_id in ipairs(active_ids) do
        if existing_id == id then
            return true
        end
    end
    table.insert(active_ids, id)
    return true
end

-- 移除单个 overlay
-- 参数: overlay id
-- 返回: 无
-- 行为:
--   - 执行 overlay-remove（pcall 包裹）
--   - 从 active_ids 中移除
function M.remove(id)
    pcall(mp.commandv, "overlay-remove", id)
    for i = #active_ids, 1, -1 do
        if active_ids[i] == id then
            table.remove(active_ids, i)
        end
    end
end

-- 批量移除所有已添加 overlay
-- 返回: 无
-- 行为: 遍历 active_ids，逐个 remove，清空 active_ids
function M.remove_all()
    for _, id in ipairs(active_ids) do
        pcall(mp.commandv, "overlay-remove", id)
    end
    active_ids = {}
end

-- 获取已添加 id 列表
-- 返回: 已添加 overlay id 的数组（浅拷贝）
function M.get_active_ids()
    local copy = {}
    for _, id in ipairs(active_ids) do
        table.insert(copy, id)
    end
    return copy
end

return M
