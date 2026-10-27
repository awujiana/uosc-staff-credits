-- modules/utils/net.lua
-- 网络工具函数
-- 提供 HTTP 下载（curl 子进程）和异步命令执行
-- 所有网络请求通过 mp.command_native_async 实现，支持取消

local mp = require("mp")
local msg = require("mp.msg")

local M = {}

-- build_ssl_args: 根据 opts 构建 curl SSL 相关命令行参数
-- 解决 Windows curl exit code 35（SSL/TLS 握手失败）问题
-- opts: 配置表（含 ssl_no_revoke / cacert_path / insecure 字段，可选）
-- 返回 args 列表（可能为空）
function M.build_ssl_args(opts)
    local args = {}
    if not opts or type(opts) ~= "table" then return args end
    -- 1. 禁用证书吊销列表检查（Windows schannel CRL 不可达时必需）
    if opts.ssl_no_revoke == true then
        table.insert(args, "--ssl-no-revoke")
    end
    -- 2. 自定义 CA 证书 bundle
    if type(opts.cacert_path) == "string" and opts.cacert_path ~= "" then
        table.insert(args, "--cacert")
        table.insert(args, opts.cacert_path)
    end
    -- 3. 跳过证书验证（仅调试，生产环境禁用）
    if opts.insecure == true then
        table.insert(args, "--insecure")
    end
    return args
end

-- call_cmd_async: 异步执行子进程命令
-- args: 命令参数列表（如 {"curl", "-L", "-s", url}）
-- callback: function(error)  -- error 为 nil 表示成功，字符串表示失败信息
-- 返回 abort 函数，调用可取消异步命令
function M.call_cmd_async(args, callback)
    if not args or type(args) ~= "table" then
        if callback then callback("invalid args") end
        return function() end
    end

    local abort_signal = mp.command_native_async({
        name = "subprocess",
        capture_stderr = true,
        capture_stdout = true,
        playback_only = true,
        args = args,
    }, function(success, result, error)
        if not success or not result or result.status ~= 0 then
            local exit_code = (result and result.status) or "unknown"
            local message = error or ""
            if result then
                local combined = (result.stdout or "") .. (result.stderr or "")
                if combined and combined ~= "" then
                    if message and message ~= "" then
                        message = message .. " | " .. combined
                    else
                        message = combined
                    end
                end
            end
            if callback then
                callback("Calling failed. Exit code: " .. tostring(exit_code) .. " Error: " .. tostring(message))
            end
            return
        end
        if callback then callback(nil) end
    end)

    return function()
        pcall(function() mp.abort_async_command(abort_signal) end)
    end
end

-- http_download: 通过 curl 子进程下载文件
-- url: 下载地址
-- output_path: 输出文件路径
-- opts: { user_agent, timeout, proxy, cookie_file, referer, ssl_no_revoke, cacert_path, insecure }
-- callback: function(error)  -- error 为 nil 表示成功
-- 返回 abort 函数
function M.http_download(url, output_path, opts, callback)
    if not url or not output_path then
        if callback then callback("invalid url or output_path") end
        return function() end
    end

    opts = opts or {}
    local user_agent = opts.user_agent or "uosc_staff_credits"
    local timeout = opts.timeout or 10
    local proxy = opts.proxy
    local cookie_file = opts.cookie_file
    local referer = opts.referer  -- v1.6: 防盗链支持

    local args = {"curl", "-L", "-s", "-S"}
    -- SSL/TLS 选项（v1.6: 修复 Windows curl exit code 35）
    local ssl_args = M.build_ssl_args(opts)
    for _, a in ipairs(ssl_args) do table.insert(args, a) end
    -- User-Agent
    table.insert(args, "--user-agent")
    table.insert(args, user_agent)
    -- 超时
    if timeout and tonumber(timeout) and tonumber(timeout) > 0 then
        table.insert(args, "--max-time")
        table.insert(args, tostring(timeout))
    end
    -- 代理
    if proxy and proxy ~= "" then
        table.insert(args, "-x")
        table.insert(args, proxy)
    end
    -- Cookie 文件
    if cookie_file and cookie_file ~= "" then
        table.insert(args, "-b")
        table.insert(args, cookie_file)
    end
    -- v1.6: Referer（防盗链绕过，部分图床需要）
    if referer and type(referer) == "string" and referer ~= "" then
        table.insert(args, "-e")
        table.insert(args, referer)
    end
    -- 输出路径
    table.insert(args, "--output")
    table.insert(args, output_path)
    -- URL
    table.insert(args, url)

    msg.debug("[net] http_download: " .. tostring(url) .. " -> " .. tostring(output_path))
    return M.call_cmd_async(args, callback)
end

return M
