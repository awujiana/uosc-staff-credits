-- uosc_staff_credits (main.lua)
-- 功能: 脚本入口点，仅负责启动 bootstrap 组合根
-- ADR-10/ADR-11: 配置加载、模块加载、依赖注入、事件注册已全部迁移至 app/bootstrap.lua

local mp = require("mp")

local ok, err = pcall(function()
    local bootstrap = require("app.bootstrap")
    local success = bootstrap.run()
    if success then
        mp.msg.info("uosc_staff_credits loaded")
    else
        mp.msg.error("uosc_staff_credits 启动失败，请检查日志")
    end
end)

if not ok then
    mp.msg.error("uosc_staff_credits bootstrap 异常: " .. tostring(err))
end
