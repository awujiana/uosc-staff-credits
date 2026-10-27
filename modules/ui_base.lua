-- modules/ui_base.lua
-- UI 模块公共基础设施
-- 遵循 DESIGN.md 3 节（make_panel_module）和 UI.md 11 节（图片下载缓存）
-- 提供 OSD 尺寸、按键绑定、uosc 控制、面板互斥、图片下载缓存、面板工厂等公共能力

local mp = require("mp")
local msg = require("mp.msg")
local utils = require("mp.utils")
-- 确保使用 mp.command 的工具可用

local panel_registry = require("modules.panel_registry")
local net = require("modules.utils.net")
local image = require("modules.utils.image")

local M = {}

-- ====== 1. get_osd_size ======
-- 防御性读取 osd-width/osd-height，0 或 nil 时默认 1280×720
function M.get_osd_size()
    local w = mp.get_property_native("osd-width")
    local h = mp.get_property_native("osd-height")
    if not w or w == 0 then w = 1280 end
    if not h or h == 0 then h = 720 end
    return w, h
end

-- ====== 2. safe_add_key ======
-- 注册按键绑定，pcall 保护
-- forced=true 时优先 mp.add_forced_key_binding，失败回退 mp.add_key_binding
-- opts 为可选第 4 参数（如 {repeatable=true}）
-- 返回 true/false
function M.safe_add_key(key, name, fn, forced, opts)
    if not key or not name or type(fn) ~= "function" then
        return false
    end
    if forced then
        local ok
        if opts then
            ok = pcall(mp.add_forced_key_binding, key, name, fn, opts)
        else
            ok = pcall(mp.add_forced_key_binding, key, name, fn)
        end
        if ok then return true end
        -- 回退到普通绑定
    end
    local ok
    if opts then
        ok = pcall(mp.add_key_binding, key, name, fn, opts)
    else
        ok = pcall(mp.add_key_binding, key, name, fn)
    end
    if not ok then
        msg.warn("[ui_base] safe_add_key: failed to bind '" .. tostring(key) ..
                  "' as '" .. tostring(name) .. "'")
    end
    return ok
end

-- ====== 3. disable_uosc ======
-- 禁用 uosc 控制条（面板显示时调用，避免干扰）
function M.disable_uosc()
    pcall(function() mp.commandv("script-message", "uosc", "disable") end)
end

-- ====== 4. enable_uosc ======
-- 启用 uosc 控制条（面板关闭时恢复）
function M.enable_uosc()
    pcall(function() mp.commandv("script-message", "uosc", "enable") end)
end

-- ====== 5. close_other_panels ======
-- 委托 panel_registry.close_all_except
function M.close_other_panels(except_name)
    return panel_registry.close_all_except(except_name)
end

-- ====== 6. close_all_panels ======
-- 委托 panel_registry.close_all
function M.close_all_panels()
    return panel_registry.close_all()
end

-- ====== 7. download_image_with_cache ======
-- 图片下载与 BGRA 缓存
-- 遵循 UI.md 11 节流程
-- 参数:
--   url: 下载地址
--   target_w, target_h: 目标宽高
--   opts: { prefix, cache_days, timeout, mpv_path, max_concurrent, in_flight_list, pending_retry_list, user_agent, proxy, referer }
--   callback: function(success, bgra_path, w, h)

-- 内部：缓存有效性检查
-- cache_days <= 0: 仅检查文件存在
-- 否则: age < cache_days * 86400
local function is_cache_valid(path, cache_days)
    if not path or path == "" then return false end
    local ok, meta = pcall(function() return utils.file_info(path) end)
    if not ok or not meta or not meta.is_file then return false end
    if not cache_days or cache_days <= 0 then
        return true
    end
    local mtime = meta.mtime or 0
    local now = os.time()
    local age = now - mtime
    return age < cache_days * 86400
end

-- 内部：获取文件大小（字节），失败返回 -1
local function get_file_size(path)
    if not path or path == "" then return -1 end
    local ok, meta = pcall(function() return utils.file_info(path) end)
    if not ok or not meta or not meta.is_file then return -1 end
    return meta.size or -1
end

-- 内部：清理临时图片文件
local function cleanup_file(path)
    if not path or path == "" then return end
    pcall(function() os.remove(path) end)
end

-- 内部：从 in_flight_list 中查找匹配条目（url+w+h 相同）
local function find_in_flight(in_flight_list, url, w, h)
    if type(in_flight_list) ~= "table" then return nil, 0 end
    local key = tostring(url) .. "_" .. tostring(w) .. "x" .. tostring(h)
    for i, entry in ipairs(in_flight_list) do
        if type(entry) == "table" then
            local entry_key = tostring(entry.url) .. "_" .. tostring(entry.w) .. "x" .. tostring(entry.h)
            if entry_key == key then
                return entry, i
            end
        end
    end
    return nil, 0
end

-- 内部：从 in_flight_list 中移除条目
local function remove_from_in_flight(in_flight_list, entry)
    if type(in_flight_list) ~= "table" then return end
    for i, e in ipairs(in_flight_list) do
        if e == entry then
            table.remove(in_flight_list, i)
            return
        end
    end
end

function M.download_image_with_cache(url, target_w, target_h, opts, callback)
    opts = opts or {}
    local prefix = opts.prefix or "staff_credits_"
    local cache_days = opts.cache_days or 30
    local timeout = opts.timeout or 10
    local mpv_path = opts.mpv_path or ""
    local max_concurrent = opts.max_concurrent or 4
    local in_flight_list = opts.in_flight_list or {}
    local pending_retry_list = opts.pending_retry_list or {}
    local user_agent = opts.user_agent
    local proxy = opts.proxy
    local referer = opts.referer  -- v1.6: 防盗链支持

    -- a. URL 校验：空或非 http(s):// 直接失败
    if type(url) ~= "string" or url == "" then
        if callback then callback(false, nil, 0, 0) end
        return
    end
    if not (url:find("^https?://") ~= nil) then
        if callback then callback(false, nil, 0, 0) end
        return
    end

    -- 参数类型保护
    target_w = tonumber(target_w) or 0
    target_h = tonumber(target_h) or 0
    if target_w <= 0 or target_h <= 0 then
        if callback then callback(false, nil, 0, 0) end
        return
    end

    -- b. 路径计算（v1.7: 优先使用 ~~/cache/ 持久化缓存目录，不可写时回退 TEMP）
    -- 2026-10-05 修正：去掉多余的 "command" 前缀（原写法返回 nil，
    --   导致这里**永远走 TEMP 回退分支**，~~/cache 从未被使用）。
    local cache_dir = mp.command_native({"expand-path", "~~/cache"})
    if type(cache_dir) ~= "string" or cache_dir == "" then
        cache_dir = os.getenv("TEMP") or "/tmp"
    else
        -- 尝试创建目录（已存在时无副作用）
        pcall(function() mp.commandv("run", "mkdir", cache_dir) end)
        -- Windows 上 mkdir 需要 mkdir -p 等价物，但 mpv 的 run 在 Windows 上走 cmd
        -- 简化处理: 使用 os.execute 创建目录（跨平台）
        local sys = package.config:sub(1, 1)
        if sys == "\\" then
            os.execute('mkdir "' .. cache_dir .. '" 2>nul')
        else
            os.execute('mkdir -p "' .. cache_dir .. '" 2>/dev/null')
        end
    end
    local temp_dir = cache_dir
    local hash = url:gsub("[^%w]", ""):sub(1, 32)
    if hash == "" then hash = "img" .. tostring(os.time()) end
    local ext = url:match("%.([%w]+)$") or "jpg"
    if #ext > 10 then ext = ext:sub(1, 10) end
    local img_path = utils.join_path(temp_dir, prefix .. hash .. "." .. ext)
    local bgra_path = utils.join_path(temp_dir, prefix .. hash .. "_" .. target_w .. "x" .. target_h .. "_c.bgra")

    -- c. 缓存命中检查
    if is_cache_valid(bgra_path, cache_days) then
        if callback then callback(true, bgra_path, target_w, target_h) end
        return
    end

    -- e. 去重：检查同 url+w+h 是否已在下载中
    local existing = find_in_flight(in_flight_list, url, target_w, target_h)
    if existing then
        -- 挂起 callback 到现有条目
        if callback then
            if type(existing.callbacks) ~= "table" then existing.callbacks = {} end
            table.insert(existing.callbacks, callback)
        end
        return
    end

    -- d. 并发限制：超出 max_concurrent 时延迟 0.1s 重试
    if #in_flight_list >= max_concurrent then
        local timer = mp.add_timeout(0.1, function()
            -- 从 pending_retry_list 移除自身
            for i, t in ipairs(pending_retry_list) do
                if t == timer then
                    table.remove(pending_retry_list, i)
                    break
                end
            end
            -- 重试（传入原始 opts 引用以保持 in_flight_list/pending_retry_list 同步）
            M.download_image_with_cache(url, target_w, target_h, opts, callback)
        end)
        if timer then
            table.insert(pending_retry_list, timer)
        end
        return
    end

    -- 创建下载条目
    local entry = {
        url = url,
        w = target_w,
        h = target_h,
        callbacks = {},
        img_path = img_path,
        bgra_path = bgra_path,
        abort_fn = nil,
    }
    if callback then
        table.insert(entry.callbacks, callback)
    end
    table.insert(in_flight_list, entry)

    -- 内部：完成所有挂起的 callback 并移除条目
    local function finish_callbacks(success, path, w, h)
        remove_from_in_flight(in_flight_list, entry)
        if type(entry.callbacks) == "table" then
            for i = 1, #entry.callbacks do
                local cb = entry.callbacks[i]
                if type(cb) == "function" then
                    pcall(cb, success, path, w, h)
                end
            end
            entry.callbacks = {}
        end
    end

    -- f. 第一步：HTTP 下载
    local download_opts = { timeout = timeout }
    if user_agent then download_opts.user_agent = user_agent end
    if proxy then download_opts.proxy = proxy end
    if referer then download_opts.referer = referer end  -- v1.6: 防盗链
    -- v1.6: SSL/TLS 选项透传（修复 Windows curl exit code 35）
    if opts.ssl_no_revoke == true then download_opts.ssl_no_revoke = true end
    if type(opts.cacert_path) == "string" and opts.cacert_path ~= "" then
        download_opts.cacert_path = opts.cacert_path
    end
    if opts.insecure == true then download_opts.insecure = true end

    msg.debug("[ui_base] download_image_with_cache: starting HTTP download " .. tostring(url) .. " -> " .. tostring(img_path))

    local abort_fn = net.http_download(url, img_path, download_opts, function(error)
        if error then
            -- 下载失败
            msg.debug("[ui_base] download_image_with_cache: HTTP download failed: " .. tostring(error))
            cleanup_file(img_path)
            finish_callbacks(false, nil, 0, 0)
            return
        end

        msg.debug("[ui_base] download_image_with_cache: HTTP download success, checking file size")

        -- g. 下载成功后检查文件大小：<=0 或 >10MB 失败
        local file_size = get_file_size(img_path)
        if file_size <= 0 then
            msg.debug("[ui_base] download_image_with_cache: downloaded file size <= 0")
            cleanup_file(img_path)
            finish_callbacks(false, nil, 0, 0)
            return
        end
        if file_size > 10 * 1024 * 1024 then
            msg.debug("[ui_base] download_image_with_cache: downloaded file too large: " .. file_size)
            cleanup_file(img_path)
            finish_callbacks(false, nil, 0, 0)
            return
        end

        msg.debug("[ui_base] download_image_with_cache: file size OK (" .. file_size .. " bytes), starting bgra conversion")

        -- h. 第二步：bgra 转换
        image.image_to_bgra(img_path, bgra_path, target_w, target_h, mpv_path, function(success_bgra, err_msg)
            if not success_bgra then
                -- 转换失败：清理并回调
                cleanup_file(img_path)
                cleanup_file(bgra_path)
                if err_msg and #tostring(err_msg) > 200 then
                    err_msg = tostring(err_msg):sub(1, 200)
                end
                msg.debug("[ui_base] download_image_with_cache: bgra conversion failed: " .. tostring(err_msg))
                finish_callbacks(false, nil, 0, 0)
                return
            end

            msg.debug("[ui_base] download_image_with_cache: bgra conversion success, verifying size")

            -- i. 验证 bgra 文件大小 == 4 * target_w * target_h
            local expected_size = 4 * target_w * target_h
            local actual_size = get_file_size(bgra_path)
            if actual_size ~= expected_size then
                cleanup_file(img_path)
                cleanup_file(bgra_path)
                msg.debug("[ui_base] download_image_with_cache: bgra size mismatch, expected " ..
                    expected_size .. " got " .. tostring(actual_size))
                finish_callbacks(false, nil, 0, 0)
                return
            end

            -- 成功：清理原始图片，只保留 bgra 缓存
            cleanup_file(img_path)
            finish_callbacks(true, bgra_path, target_w, target_h)
        end)
    end)

    -- 存储 abort 函数供调用方取消
    if type(abort_fn) == "function" then
        entry.abort_fn = abort_fn
    end
end

-- ====== 8. cleanup_expired_cache ======
-- 扫描 temp_dir，删除匹配前缀且超过 cache_days 的文件
-- max_files=2000 默认值防止 TEMP 目录过大时阻塞过久
function M.cleanup_expired_cache(temp_dir, prefixes, cache_days, max_files)
    if type(temp_dir) ~= "string" or temp_dir == "" then return 0 end
    if type(prefixes) ~= "table" then return 0 end
    cache_days = cache_days or 30
    max_files = max_files or 2000

    local ok, entries = pcall(function() return utils.readdir(temp_dir) end)
    if not ok or type(entries) ~= "table" then return 0 end

    local now = os.time()
    local max_age = cache_days * 86400
    local deleted_count = 0
    local checked = 0

    for _, name in pairs(entries) do
        if type(name) == "string" and name ~= "." and name ~= ".." then
            checked = checked + 1
            if checked > max_files then break end

            -- 检查是否匹配任一前缀
            local matched = false
            for _, prefix in ipairs(prefixes) do
                if type(prefix) == "string" and #prefix > 0 and name:sub(1, #prefix) == prefix then
                    matched = true
                    break
                end
            end

            if matched then
                local full_path = utils.join_path(temp_dir, name)
                local ok_info, meta = pcall(function() return utils.file_info(full_path) end)
                if ok_info and meta and meta.is_file then
                    local mtime = meta.mtime or 0
                    local age = now - mtime
                    if age > max_age then
                        local ok_rm = pcall(function() os.remove(full_path) end)
                        if ok_rm then
                            deleted_count = deleted_count + 1
                        end
                    end
                end
            end
        end
    end

    return deleted_count
end

-- ====== 9. make_panel_module ======
-- 面板模块工厂：注入 7 个公共方法到 target 表
-- 遵循 DESIGN.md 3.1-3.3 节
-- name: 面板名（用于 panel_registry 注册）
-- target: 可选，传入已存在的模块表；不传则创建新表
function M.make_panel_module(name, target)
    local P = target or {}
    P.name = name
    P.visible = false
    P.key_bindings = {}         -- 已注册按键名列表
    P._osd_unregistrers = {}    -- OSD observer 注销函数列表
    P._deps = nil               -- 通过 init_panel 注入的 deps
    P._cleanup_fn = nil          -- 模块特定清理回调

    -- register_keys: 批量注册按键
    -- key_defs: 列表，每项 {key, name, fn, forced?, opts?}
    -- 先调用 unregister_keys() 清理旧绑定
    function P.register_keys(key_defs)
        P.unregister_keys()
        if type(key_defs) ~= "table" then return end
        for _, def in ipairs(key_defs) do
            if type(def) == "table" and def.key and def.name and type(def.fn) == "function" then
                local ok = M.safe_add_key(def.key, def.name, def.fn, def.forced, def.opts)
                if ok then
                    table.insert(P.key_bindings, def.name)
                end
            end
        end
    end

    -- unregister_keys: 批量移除所有按键绑定
    function P.unregister_keys()
        for i = 1, #P.key_bindings do
            local binding_name = P.key_bindings[i]
            pcall(mp.remove_key_binding, binding_name)
        end
        P.key_bindings = {}
    end

    -- register_osd_observers: 注册 OSD 属性观察者
    -- on_change: 属性变化时触发（经过防抖）
    -- properties: 观察的属性列表，默认 {"osd-width", "osd-height"}
    -- debounce_ms: 防抖毫秒数，>0 时使用 mp.add_timeout 防抖
    -- is_visible: 可见性检查函数，仅在可见时触发 on_change
    function P.register_osd_observers(on_change, properties, debounce_ms, is_visible)
        if type(on_change) ~= "function" then return end
        properties = properties or {"osd-width", "osd-height"}
        debounce_ms = tonumber(debounce_ms) or 0
        if type(is_visible) ~= "function" then
            is_visible = function() return true end
        end

        local debounce_timer = nil

        -- 内部：实际触发 on_change
        local function trigger()
            if debounce_timer then
                pcall(function() mp.cancel_timer(debounce_timer) end)
                debounce_timer = nil
            end
            local ok_vis, vis = pcall(is_visible)
            if ok_vis and vis then
                pcall(on_change)
            end
        end

        -- 内部：属性变化回调（带防抖）
        local function on_property_change()
            local ok_vis, vis = pcall(is_visible)
            if not ok_vis or not vis then return end
            if debounce_ms > 0 then
                if debounce_timer then
                    pcall(function() mp.cancel_timer(debounce_timer) end)
                end
                debounce_timer = mp.add_timeout(debounce_ms / 1000.0, trigger)
            else
                trigger()
            end
        end

        -- 注册每个属性的 observer
        for _, prop in ipairs(properties) do
            if type(prop) == "string" and prop ~= "" then
                pcall(mp.observe_property, prop, "native", on_property_change)
            end
        end

        -- 存储注销函数
        local unreg_fn = function()
            pcall(mp.unobserve_property, on_property_change)
            if debounce_timer then
                pcall(function() mp.cancel_timer(debounce_timer) end)
                debounce_timer = nil
            end
        end
        table.insert(P._osd_unregistrers, unreg_fn)
    end

    -- unregister_osd: 注销所有 OSD 观察者
    function P.unregister_osd()
        for i = 1, #P._osd_unregistrers do
            local unreg = P._osd_unregistrers[i]
            if type(unreg) == "function" then
                pcall(unreg)
            end
        end
        P._osd_unregistrers = {}
    end

    -- set_cleanup: 注册模块特定清理回调
    function P.set_cleanup(cleanup_fn)
        P._cleanup_fn = cleanup_fn
    end

    -- close: 通用关闭骨架
    -- 顺序: visible=false → cleanup_fn() → unregister_keys() → unregister_osd() → enable_uosc()
    function P.close()
        P.visible = false
        if type(P._cleanup_fn) == "function" then
            pcall(P._cleanup_fn)
        end
        P.unregister_keys()
        P.unregister_osd()
        M.enable_uosc()
    end

    -- init_panel: 存储 deps 并自注册到 panel_registry
    -- deps: 依赖表（应包含 panel_registry）
    -- panel_interface: { is_visible = function, close = function }
    function P.init_panel(deps, panel_interface)
        P._deps = deps
        if type(deps) == "table" and type(deps.panel_registry) == "table" then
            if type(panel_interface) ~= "table" then
                panel_interface = {
                    is_visible = function() return P.visible end,
                    close = function() P.close() end,
                }
            end
            deps.panel_registry.register(P.name, panel_interface)
        end
    end

    return P
end

return M
