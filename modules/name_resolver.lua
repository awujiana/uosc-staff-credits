-- modules/name_resolver.lua
-- 名称优先级解析模块
-- 根据 Bangumi / AniList / MAL / 百度百科 等数据源的字段优先级返回展示名
-- 遵循 ADR-10 统一 init(opts, deps) 接口

local M = {}

local opts, deps, init = require("modules.utils.module_loader").make_init(
    "name_resolver",
    {}
)
M.init = init

-- resolve: 条目（subject）名称解析
-- 优先级：name_cn (非空) → name (非空) → title → "未知条目"
-- subject: table，至少包含 name 字段；可选 name_cn / title
-- 返回 string
function M.resolve(subject)
    if type(subject) ~= "table" then
        return "未知条目"
    end
    if subject.name_cn and subject.name_cn ~= "" then
        return subject.name_cn
    end
    if subject.name and subject.name ~= "" then
        return tostring(subject.name)
    end
    if subject.title and subject.title ~= "" then
        return tostring(subject.title)
    end
    return "未知条目"
end

-- resolve_person: 人员（person）名称解析
-- 优先级：name (中文) → name_en → name_jp → "未知"
-- 兼容 Bangumi 与 AniList/MAL 两种字段命名：
--   Bangumi: name (日文)
--   AniList/MAL: name (默认标题), name_en 等
-- 这里按任务规约：name → name_en → name_jp
function M.resolve_person(person)
    if type(person) ~= "table" then
        return "未知"
    end
    if person.name and person.name ~= "" then
        return tostring(person.name)
    end
    if person.name_en and person.name_en ~= "" then
        return tostring(person.name_en)
    end
    if person.name_jp and person.name_jp ~= "" then
        return tostring(person.name_jp)
    end
    return "未知"
end

-- resolve_character: 角色名称解析
-- 优先级：name_cn → name → "未知角色"
function M.resolve_character(char)
    if type(char) ~= "table" then
        return "未知角色"
    end
    if char.name_cn and char.name_cn ~= "" then
        return tostring(char.name_cn)
    end
    if char.name and char.name ~= "" then
        return tostring(char.name)
    end
    return "未知角色"
end

return M
