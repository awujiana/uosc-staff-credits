-- ASS rendering and staff-grid lifecycle smoke test for mpv.
-- Run this directory together with the uosc_staff_credits package directory.

local mp = require("mp")

local script_dir = mp.get_script_directory()
package.path = script_dir .. "/../../?.lua;" .. script_dir .. "/../../?/init.lua;" .. package.path

local utils = require("mp.utils")
local project_dir = script_dir .. "/../.."

local function assert_true(value, message)
    if not value then error(message or "assertion failed", 2) end
end

local function find_upvalue(fn, target_name)
    for index = 1, 64 do
        local name, value = debug.getupvalue(fn, index)
        if not name then break end
        if name == target_name then return value end
    end
    return nil
end

local function compile_sources(directory)
    local count = 0
    for _, filename in ipairs(utils.readdir(directory, "files") or {}) do
        if filename:match("%.lua$") then
            local path = utils.join_path(directory, filename)
            local chunk, err = loadfile(path)
            assert_true(chunk ~= nil, "Lua syntax error in " .. path .. ": " .. tostring(err))
            count = count + 1
        end
    end
    for _, dirname in ipairs(utils.readdir(directory, "dirs") or {}) do
        count = count + compile_sources(utils.join_path(directory, dirname))
    end
    return count
end

local function run()
    local source_count = compile_sources(project_dir)
    assert_true(source_count > 0, "no Lua source files were compiled")
    local chapterskip_path = script_dir .. "/../../../chapterskip.lua"
    local chapterskip_chunk, chapterskip_error = loadfile(chapterskip_path)
    assert_true(chapterskip_chunk ~= nil, "chapterskip.lua syntax error: " .. tostring(chapterskip_error))

    local ass_lib = require("modules.ass_lib")
    local pagination = require("modules.pagination")
    local ui_base = require("modules.ui_base")
    local panel_registry = require("modules.panel_registry")
    local staff_grid = require("modules.staff_grid")

    local drawing = ass_lib.draw_round_rect(10, 20, 120, 40, "FF0000", "FFFFFF", 2, "80", "00", 10)
    assert_true(type(drawing) == "string" and #drawing > 0, "rounded rectangle did not produce ASS")
    assert_true(drawing:find("\\p4", 1, true), "rounded ASS path mode was not started: " .. drawing)
    assert_true(drawing:find("\\p0", 1, true), "ASS drawing mode was not closed: " .. drawing)
    assert_true(drawing:find("\\bord2", 1, true), "ASS border width was not emitted")
    assert_true(drawing:find("\\1a&H80&", 1, true), "ASS fill alpha was not emitted")
    assert_true(ass_lib.draw_round_rect(0, 0, 0, 20, "FFFFFF", nil, 0) == "", "zero-width rectangle was not rejected")

    local page_layout = pagination.compute_layout({
        ui_scale = 1,
        s = function(value) return value end,
        start_x = 20,
        total_w = 400,
        hint_y = 500,
    }, 0, 150, 50)
    assert_true(page_layout.max_offset == 100, "pagination max offset is incorrect")
    assert_true(not page_layout.is_last_page, "first page was incorrectly marked as the last page")
    local rendered_parts = {}
    pagination.render(rendered_parts, page_layout, {}, ass_lib)
    assert_true(rendered_parts[1] and rendered_parts[1]:find("\\p4", 1, true), "pagination button did not use rounded ASS path drawing")
    assert_true(pagination.hit_test(page_layout.prev_btn_x + 1, page_layout.btn_y + 1, page_layout) == "prev", "previous-page hit test failed")
    assert_true(pagination.hit_test(page_layout.next_btn_x + 1, page_layout.btn_y + 1, page_layout) == "next", "next-page hit test failed")

    local bindings = {}
    local original_add_forced_key_binding = mp.add_forced_key_binding
    mp.add_forced_key_binding = function(key, name, callback, options)
        bindings[name] = callback
        if options ~= nil then
            return original_add_forced_key_binding(key, name, callback, options)
        end
        return original_add_forced_key_binding(key, name, callback)
    end

    staff_grid.init({}, {
        ui_base = ui_base,
        panel_registry = panel_registry,
        ass_lib = ass_lib,
        notify = { warn = function(message) mp.msg.warn(message) end },
        utils = require("mp.utils"),
    })

    local entry_path = "smoke-test://staff-grid"
    local persons = {}
    for index = 1, 150 do
        persons[index] = { type = 2, name = "职员 " .. index, relation = "测试职位" }
    end

    local staff_credits = require("features.staff_credits")
    staff_credits.init({
        notify = {
            set_tag = function() end,
            show_click_hint = function() end,
            debug = function() end,
            warn = function(message) mp.msg.warn(message) end,
            error = function(message) error(message) end,
        },
        state = { search_state = { current_path = entry_path } },
        menu = { MENU_CHARACTERS = "characters" },
        api = { CHAR_TYPE_CHARACTER = 1 },
        name_resolver = { resolve_person = function(person) return person.name end },
        loading_controller = {
            finish = function() end,
            finish_silent = function() end,
        },
        history = {},
        request_registry = {},
        search_pipeline = {
            run_subject_pipeline = function(options)
                options.on_cached_hit({ id = 42, name_cn = "ASS 缓存流程验证" }, entry_path)
            end,
            resolve_cached_title = function(subject, _, callback)
                callback(subject.name_cn)
            end,
        },
        anilist = {},
        mal = {},
        baike = {},
        staff_grid = staff_grid,
        data_cache = { load = function() return persons end },
    })
    staff_credits.fetch()
    assert_true(staff_grid.is_visible(), "staff grid did not open")
    assert_true(type(bindings["staff_grid-right"]) == "function", "right-page binding was not registered")
    assert_true(type(bindings["staff_grid-left"]) == "function", "left-page binding was not registered")

    local page_down_state = find_upvalue(bindings["staff_grid-right"], "state")
    assert_true(type(page_down_state) == "table" and page_down_state.offset == 0, "staff grid initial page offset is incorrect")
    assert_true(page_down_state.title == "ASS 缓存流程验证", "cached feature title did not reach staff grid")
    assert_true(#page_down_state.items == #persons, "cached feature records did not reach staff grid")
    bindings["staff_grid-right"]()
    assert_true(page_down_state.offset > 0, "right-page action did not advance the grid")
    bindings["staff_grid-left"]()
    assert_true(page_down_state.offset == 0, "left-page action did not return to the first page")

    staff_grid.close()
    assert_true(not staff_grid.is_visible(), "staff grid did not close cleanly")
    mp.add_forced_key_binding = original_add_forced_key_binding
    mp.msg.info("[ass_render_flow] compiled " .. tostring(source_count) .. " project Lua files and chapterskip.lua")
end

mp.add_timeout(0.2, function()
    local ok, err = pcall(run)
    if not ok then
        mp.msg.error("[ass_render_flow] FAIL: " .. tostring(err))
        mp.commandv("quit", "1")
        return
    end

    local messages = {
        "main-menu",
        "staff-credits",
        "staff-credits-settings",
        "staff-credits-servers",
        "staff-credits-close",
    }
    local function dispatch_next(index)
        if index > #messages then
            mp.msg.info("[ass_render_flow] PASS: rounded ASS drawing, pagination, staff-grid open/page/close, menu routes")
            mp.commandv("quit")
            return
        end
        mp.commandv("script-message-to", "uosc_staff_credits", messages[index])
        mp.add_timeout(0.1, function() dispatch_next(index + 1) end)
    end
    dispatch_next(1)
end)
