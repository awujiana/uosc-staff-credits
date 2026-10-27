-- modules/types.lua
-- 数据结构类型守卫
-- 在数据入口（API 响应、缓存读取等）校验数据结构
-- 校验失败返回 (false, err_info)，err_info = { code = "ERR_PARSE", msg = "..." }
-- 校验成功返回 (true, normalized_data)

local M = {}

-- make_error: 构造错误信息表
function M.make_error(code, msg)
    return { code = code or "ERR_PARSE", msg = tostring(msg or "") }
end

-- validate_char: 校验角色数据
-- 必填: id (number/string), name (string)
-- 可选: relation (string)
-- 返回 (true, char_table) 或 (false, err_info)
function M.validate_char(data)
    if type(data) ~= "table" then
        return false, M.make_error("ERR_PARSE", "char data is not a table")
    end
    if data.id == nil then
        return false, M.make_error("ERR_PARSE", "char missing required field: id")
    end
    if data.name == nil then
        return false, M.make_error("ERR_PARSE", "char missing required field: name")
    end
    if type(data.name) ~= "string" then
        return false, M.make_error("ERR_PARSE", "char field 'name' must be string, got " .. type(data.name))
    end

    local char = {
        id = data.id,
        name = data.name,
    }
    if data.relation ~= nil then
        char.relation = tostring(data.relation)
    end
    return true, char
end

-- validate_person: 校验人员数据
-- 必填: id (number/string), name (string)
-- 可选: type (number/string)
-- 返回 (true, person_table) 或 (false, err_info)
function M.validate_person(data)
    if type(data) ~= "table" then
        return false, M.make_error("ERR_PARSE", "person data is not a table")
    end
    if data.id == nil then
        return false, M.make_error("ERR_PARSE", "person missing required field: id")
    end
    if data.name == nil then
        return false, M.make_error("ERR_PARSE", "person missing required field: name")
    end
    if type(data.name) ~= "string" then
        return false, M.make_error("ERR_PARSE", "person field 'name' must be string, got " .. type(data.name))
    end

    local person = {
        id = data.id,
        name = data.name,
    }
    if data.type ~= nil then
        person.type = data.type
    end
    return true, person
end

-- validate_subject: 校验条目数据
-- 必填: id (number/string), name (string)
-- 可选: name_cn (string)
-- 返回 (true, subject_table) 或 (false, err_info)
function M.validate_subject(data)
    if type(data) ~= "table" then
        return false, M.make_error("ERR_PARSE", "subject data is not a table")
    end
    if data.id == nil then
        return false, M.make_error("ERR_PARSE", "subject missing required field: id")
    end
    if data.name == nil then
        return false, M.make_error("ERR_PARSE", "subject missing required field: name")
    end
    if type(data.name) ~= "string" then
        return false, M.make_error("ERR_PARSE", "subject field 'name' must be string, got " .. type(data.name))
    end

    local subject = {
        id = data.id,
        name = data.name,
    }
    if data.name_cn ~= nil and data.name_cn ~= "" then
        subject.name_cn = tostring(data.name_cn)
    end
    return true, subject
end

-- validate_api_response: 校验 API 响应基本结构
-- 必须是 table 且非空
-- 返回 (true, data) 或 (false, err_info)
function M.validate_api_response(data)
    if data == nil then
        return false, M.make_error("ERR_PARSE", "response is nil")
    end
    if type(data) ~= "table" then
        return false, M.make_error("ERR_PARSE", "response is not a table, got " .. type(data))
    end
    -- 基本结构校验：至少有一个键（非空表）
    if next(data) == nil then
        return false, M.make_error("ERR_PARSE", "response is an empty table")
    end
    return true, data
end

return M
