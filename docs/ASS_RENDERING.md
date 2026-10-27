# ASS 绘图与职员表生命周期

> 更新：2026-10-27 | 适用目录：`scripts/uosc_staff_credits/`
> 关联：[UI 文档](./UI.md) · [设计文档](./DESIGN.md)

## 绘图约定

脚本以 `mp.create_osd_overlay("ass-events")` 创建 ASS overlay。所有坐标使用 OSD 像素坐标，并在每次渲染时把当前 `osd-width`、`osd-height` 写入 `res_x`、`res_y`。

- `modules.ass_lib.draw_rect` 保留既有的方形填充与描边绘制，用于细分隔线等需要直角的形状。
- `modules.ass_lib.draw_round_rect` 用 mpv 自带的 `mp.assdraw` 构造 ASS 事件：`new_event → pos → draw_start → round_rect_cw → draw_stop`。颜色仍由 `hex_to_ass` 转换为 ASS 的 BGR 顺序；填充和描边透明度遵循 ASS alpha（`00` 不透明，`FF` 完全透明）。半径会限制在矩形短边的一半内。
- 职员表面板背景、职员单元格、关闭按钮和翻页按钮使用圆角矩形；装饰线与分隔线继续使用方形绘制。
- `draw_text` 统一转义用户/API 文本中的 ASS 控制字符，标题、职员名和职位不得直接拼入 ASS 指令。

此实现沿用 [chapterskip.lua](../chapterskip.lua) 中 `mp.assdraw.ass_new()`、`draw_start()`、`round_rect_cw()` 和 `draw_stop()` 的路径生命周期。章节跳过控件的进度分段、鼠标命中与按键绑定仍属于 chapterskip 的逻辑，职员表不复用这些业务状态。

## 职员表显示流程

```text
staff-credits 消息
  → dispatcher / features.staff_credits 获取并规整职员条目
  → staff_grid.show(items, title)
  → 关闭其他 ASS 面板并清理 uosc 菜单
  → 创建 ass-events overlay，绘制背景、标题、网格、翻页和提示
  → 注册左右翻页、ESC、关闭按钮与 OSD 尺寸观察者
  → 翻页/悬停/尺寸变化时重绘
  → close：移除 overlay、按键、observer 和鼠标订阅，恢复 uosc
```

面板渲染与数据获取解耦：数据列表为空时由 feature 发出提示，不创建空白覆盖层。页面偏移使用 `visible_count` 为单位，左右翻页共享同一组渲染闭包；关闭时同时清理 `pagination_layout`，避免点击命中使用过期坐标。

## mpv 加载方式

将 `uosc_staff_credits` 作为含根目录 `main.lua` 的脚本包加载。mpv 对脚本目录包会把包根加入 Lua `package.path`，使 `app.bootstrap`、`modules.*` 等模块可解析；直接把包内 `main.lua` 当作单文件脚本加载，不会自动获得该目录模块搜索路径。见 [mpv Lua 脚本目录说明](https://mpv.io/manual/stable/#script-location)。

## 验证

项目内 `tests/ass_render_flow/main.lua` 是基于 mpv 内嵌 LuaJIT 的无网络烟测，覆盖：

- 编译项目内所有 Lua 文件和 `chapterskip.lua` 参考脚本
- 圆角 ASS 路径开始/结束、边框、透明度及无效尺寸保护
- 翻页布局、按钮绘制与鼠标命中
- 职员表缓存命中成功路径（feature → 数据规整 → ASS overlay）、左右翻页回调和关闭清理
- 与 uosc 一起启动，并分步派发主菜单、职员表（无媒体路径的守卫分支）、设置、服务器和关闭消息

在 `mpv-20260831` 目录运行：

```powershell
& .\mpv.exe --no-config --idle=yes --force-window=no --vo=null --ao=null `
  --script=.\portable_config\scripts\uosc `
  --script=.\portable_config\scripts\uosc_staff_credits `
  --script=.\portable_config\scripts\uosc_staff_credits\tests\ass_render_flow
```

成功时日志包含 `[ass_render_flow] PASS`。完整数据源搜索还需要可用网络及 uosc；烟测不对外部 API 可用性作断言。
