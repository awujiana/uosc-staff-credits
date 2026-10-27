-- features/shared.lua
-- Feature 层共享辅助
-- 遵循 DESIGN.md 第 2.3 节：features 通过 deps 间接获取配置
-- 提供 subject 信息构造与通用搜索成功处理，供各 feature 复用

local mp = require("mp")

local M = {}

local deps, init = require("modules.utils.module_loader").make_feature_init(
    "shared",
    {
        state = "table",
        history = "table",
        notify = "table",
    }
)
M.init = init

-- 引用基础设施
local path_mod = require("modules.utils.path")

-- build_subject_info: 构造可缓存/持久化的条目信息
-- subject: bangumi 条目表，至少含 id/name 字段
-- 返回 {id, name, name_cn, url, _ts}
function M.build_subject_info(subject)
    if type(subject) ~= "table" then return nil end
    return {
        id = subject.id,
        name = subject.name,
        name_cn = subject.name_cn,
        url = subject.url,
        _ts = mp.get_time(),
    }
end

-- handle_search_success: 通用搜索成功处理
-- 1. 写入历史缓存（按目录）
-- 2. 写入 state.last_subject_by_path（按路径）
-- 3. 调用 ctx.on_success(subject)
-- ctx 应包含:
--   path       当前视频路径
--   on_success 成功回调（subject）
function M.handle_search_success(ctx, subject)
    if type(ctx) ~= "table" then return end
    local info = M.build_subject_info(subject)
    if not info then
        if deps.notify then deps.notify.warn("条目信息构造失败") end
        return
    end

    -- 写入历史（按目录）
    local path = ctx.path
    local dir = nil
    if path and not path_mod.is_protocol(path) then
        local ok, d = pcall(path_mod.get_parent_directory, path)
        if ok then dir = d end
    end
    if dir and deps.history and type(deps.history.save) == "function" then
        pcall(deps.history.save, dir, info)
    end

    -- 写入 state 缓存（按路径）
    if path and deps.state and type(deps.state.set_last_subject) == "function" then
        pcall(deps.state.set_last_subject, path, info)
    end

    -- 调用业务回调
    if type(ctx.on_success) == "function" then
        pcall(ctx.on_success, subject)
    end
end

return M
