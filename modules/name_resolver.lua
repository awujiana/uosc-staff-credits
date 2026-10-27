-- modules/name_resolver.lua
-- 名称优先级解析模块
-- 根据 Bangumi / AniList / MAL / 百度百科 等数据源的字段优先级返回展示名
-- 遵循 ADR-10 统一 init(opts, deps) 接口

local M = {}
local title_normalize = require("modules.title_normalize")

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
    local name = title_normalize.resolve_display_name(subject)
    return name ~= "" and name or "未知条目"
end

-- resolve_person: 人员（person）名称解析
-- 优先级：中文字段 → name（原名，多为日文汉字）→ name_en → name_jp → "未知"
-- 兼容 Bangumi 与 AniList/MAL 两种字段命名：
--   Bangumi: name (日文原名), name_cn (中文译名)
--   AniList/MAL: name (默认标题), name_en 等
--
-- ⚠️ name_en / name_jp 只能作为**兜底**，不能插在 name 前面：
--    职员没有中文译名时，日文原名「宮崎駿」对中文用户远好于罗马字
--    「Miyazaki Hayao」。resolve_display_name 的 fallback 参数会排在
--    entity.name 之前（那是给「已转中文的搜索标题」用的），所以这里
--    不传 fallback，先按实体自身字段解析，解析不到再单独兜底。
function M.resolve_person(person)
    if type(person) ~= "table" then
        return "未知"
    end
    local name = title_normalize.resolve_display_name(person)
    if name == "" then
        name = title_normalize.resolve_display_name(nil, person.name_en or person.name_jp)
    end
    return name ~= "" and name or "未知"
end

-- resolve_character: 角色名称解析
-- 优先级：name_cn → name → "未知角色"
function M.resolve_character(char)
    if type(char) ~= "table" then
        return "未知角色"
    end
    local name = title_normalize.resolve_display_name(char)
    return name ~= "" and name or "未知角色"
end

return M
