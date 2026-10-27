-- modules/notify.lua
-- 统一 OSD 通知模块
-- 模块工厂模式：init(opts, deps) 存储 opts 到 upvalue
-- 提供 warn / error / info / debug 五个方法
-- debug 受 opts.debug 门控，支持 string.format 占位符
-- v1.6: 支持动态 tag 前缀，通过 set_tag 设置当前 feature 标识，
--       OSD 显示 [tag] 符号 消息，便于区分来源（职员表/角色介绍/封面简介/BGM 搜索/制作评分）

local mp = require("mp")
local msg = require("mp.msg")

local M = {}

-- 模块本地 opts upvalue（通过 init 注入）
local opts = {}

-- 当前 feature tag（默认 "职员表"，向后兼容）
-- 各 feature 在 fetch 入口调用 M.set_tag 设置自己的 tag
local current_tag = "职员表"

-- init: 工厂初始化，存储 opts 到 upvalue
-- 遵循 ADR-10 统一 init(opts, deps) 接口
function M.init(new_opts, new_deps)
    opts = new_opts or {}
end

-- set_tag: 设置当前 feature tag（用于 OSD 前缀 [tag]）
-- tag: string，如 "职员表" / "角色介绍" / "封面简介" / "BGM 搜索" / "制作评分"
function M.set_tag(tag)
    if type(tag) == "string" and tag ~= "" then
        current_tag = tag
    end
end

-- get_tag: 获取当前 feature tag
function M.get_tag()
    return current_tag
end

-- warn: 警告 OSD
-- 前缀 [tag] ⚠ （黄色警告符号）
-- 默认时长 3 秒
-- text: 消息文本
-- tag: 可选，覆盖 current_tag；不传则用 current_tag
-- duration: 可选，覆盖默认时长
function M.warn(text, tag, duration)
    local use_tag = (type(tag) == "string" and tag ~= "") and tag or current_tag
    local msg_str = string.format("[%s] ⚠ %s", use_tag, tostring(text or ""))
    mp.osd_message(msg_str, duration or 3)
    msg.warn(msg_str)
end

-- error: 错误 OSD
-- 前缀 [tag] ✖ （红色错误符号）
-- 默认时长 5 秒
-- text: 消息文本
-- tag: 可选，覆盖 current_tag；不传则用 current_tag
-- duration: 可选，覆盖默认时长
function M.error(text, tag, duration)
    local use_tag = (type(tag) == "string" and tag ~= "") and tag or current_tag
    local msg_str = string.format("[%s] ✖ %s", use_tag, tostring(text or ""))
    mp.osd_message(msg_str, duration or 5)
    msg.error(msg_str)
end

-- info: 信息 OSD
-- 前缀 [tag] ℹ （蓝色信息符号）
-- 默认时长 2 秒
-- text: 消息文本
-- tag: 可选，覆盖 current_tag；不传则用 current_tag
-- duration: 可选，覆盖默认时长
function M.info(text, tag, duration)
    local use_tag = (type(tag) == "string" and tag ~= "") and tag or current_tag
    local msg_str = string.format("[%s] ℹ %s", use_tag, tostring(text or ""))
    mp.osd_message(msg_str, duration or 2)
    msg.info(msg_str)
end

-- show_click_hint: 点击功能时在 OSD 左上角显示提示
-- 使用 mp.osd_message 显示，时长 2 秒
-- feature_name: 功能名称，如 "职员表" / "角色介绍" / "封面简介" / "BGM 搜索" / "制作评分"
-- detail: 可选，加载细节，如 "加载中..." / "从本地缓存加载" / "从内存缓存加载" / "从 Bangumi 加载"
--         传入 nil 时仅显示功能名称；传入字符串会以 "功能名 · detail" 形式展示
function M.show_click_hint(feature_name, detail)
    local name = tostring(feature_name or "")
    if name == "" then return end
    local msg_str
    local det = tostring(detail or "")
    if det == "" then
        msg_str = string.format("[Bangumi 工具箱] %s", name)
    else
        msg_str = string.format("[Bangumi 工具箱] %s · %s", name, det)
    end
    mp.osd_message(msg_str, 2)
    msg.info(msg_str)
end

-- debug: 调试日志
-- 仅当 opts.debug == true 时输出
-- 前缀 [staff-credits-debug]
-- 支持 string.format 占位符（当传入额外参数时）
-- 注意：opts.debug 为 false 时完全不执行字符串拼接，避免性能开销
function M.debug(text, ...)
    if not opts or not opts.debug then return end

    local msg_str
    local nargs = select("#", ...)
    if nargs > 0 then
        -- 支持 string.format 占位符
        local ok, formatted = pcall(string.format, tostring(text or ""), ...)
        if ok then
            msg_str = "[staff-credits-debug] " .. formatted
        else
            -- format 失败时降级为直接拼接
            msg_str = "[staff-credits-debug] " .. tostring(text or "")
        end
    else
        msg_str = "[staff-credits-debug] " .. tostring(text or "")
    end
    msg.debug(msg_str)
end

return M
