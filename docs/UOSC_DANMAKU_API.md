# uosc_danmaku 接口集成参考

> 面向 `uosc_staff_credits` 开发者的外部调研文档：`uosc_danmaku` 暴露了哪些接口、
> 如何从中获取当前番剧的中文名、`danmaku-history.json` 的完整结构。
>
> 调研基线：`uosc_danmaku`（mpv_config-2025.11.28 版本目录）。
> 文中行号（如 `main.lua:892`）对应调研时的代码快照，后续版本可能漂移，以实际代码为准。
>
> **⚠️ 版本差异（mpv-20260831 实测）**：入站接口 27 → **33 个**，新增
> `setup-danmaku-search-history` / `auto_load_fallback` / `blacklist-deal` /
> `input-event` / `open_blacklist_menu` / `show_danmaku_count`；
> user-data 属性 2 → **4 个**（新增 `danmaku-switch-on` / `danmaku-count`）；
> 新增搜索历史文件 `~~/danmaku-search-history.json`。
>
> **⚠️ fork 版差异**：上游原版「无查询当前番剧接口」的结论仍然成立，但本仓库
> 使用 fork（<https://github.com/awujiana/uosc_danmaku>）补上了**出站广播**：
> 4 个 user-data 属性 + `danmaku-anime-info` script-message，外部脚本可直接拿到
> 当前匹配的番剧名 / 集数 / episodeId。见
> [方案 0](#方案-0主动广播本仓库-fork-版首选)。

---

## 📚 目录

- [项目结构概览](#项目结构概览)
- [script-message 入站接口清单](#script-message-入站接口清单)
- [暴露给外部的 user-data 属性](#暴露给外部的-user-data-属性)
- [获取中文名的可行方案](#获取中文名的可行方案)
  - [方案 0：主动广播（本仓库 fork 版首选）](#方案-0主动广播本仓库-fork-版首选)
- [danmaku-history.json 文件结构](#danmaku-historyjson-文件结构)
- [推荐的集成方式](#推荐的集成方式)
- [关键文件路径](#关键文件路径)
- [核心结论](#核心结论)

## 项目结构概览

```text
scripts/uosc_danmaku/
├── apis/
│   ├── dandanplay.lua   # 弹弹play API 封装（核心搜索/匹配/获取弹幕）
│   └── extra.lua        # 额外数据源（TMDB 中文翻译 + 360kan 三方源）
├── modules/
│   ├── aes.lua / base64.lua / hash.lua / md5.lua  # 加密/签名
│   ├── guess.lua        # 文件名 → 番剧名/季/集 解析
│   ├── menu.lua         # uosc 菜单 + 所有 script-message 注册
│   ├── options.lua      # 配置项
│   ├── parse.lua        # 弹幕文件解析
│   ├── render.lua       # ASS 弹幕渲染
│   ├── update.lua       # 自更新
│   └── utils.lua        # 工具函数（含 parse_title / 哈希等）
├── main.lua             # 入口（生命周期 + 主 script-message）
└── README.md
```

## script-message 入站接口清单

共 **27 个**入站接口（main.lua 9 个 + extra.lua 2 个 + menu.lua 16 个；
2026-08 版本增至 33 个，见顶部版本差异），全部是**控制类**
（开关/搜索/延迟/菜单），**没有**「查询当前番剧」的接口。

### main.lua 注册（9 个）

| 命令名 | 参数 | 用途 |
| --- | --- | --- |
| `danmaku-delay` | `<seconds> [time-pos] [source_url]` | 设置弹幕延迟（秒，可为负；0 重置；带 time-pos 时只影响该时间点之后；带 source_url 时只影响该弹幕源） |
| `show_danmaku_keyboard` | 无 | 切换弹幕开关（键盘 j） |
| `check-update` | 无 | 检查脚本更新 |
| `clear-source` | 无 | 重置当前视频所有弹幕源更改 |
| `immediately_save_danmaku` | 无 | 立即保存弹幕到本地 |
| `open_source_delay_menu` | 无 | 打开弹幕源延迟设置菜单 |
| `open_search_danmaku_menu` | 无 | 打开弹幕搜索菜单（Ctrl+d） |
| `open_add_source_menu` | 无 | 打开「从源添加弹幕」菜单 |
| `open_add_total_menu` | 无 | 打开弹幕设置总菜单 |

### apis/extra.lua 注册（2 个，菜单内部使用）

| 命令名 | 参数 | 用途 |
| --- | --- | --- |
| `get-extra-event` | `cat, id, playlink, source_id, title, year` | 选中 360kan 搜索结果后加载详情/电影 |
| `add-extra-event` | `url, episode, number, class, id, site, title, year` | 选中某集后加载该集弹幕 |

### modules/menu.lua 注册（16 个）

| 命令名 | 参数 | 用途 |
| --- | --- | --- |
| `uosc-version` | 无 | uosc 框架回执（用于探测 uosc 是否在线） |
| `set` | `prop, value` | uosc 控件状态同步（仅处理 `show_danmaku = on/off`） |
| `search-anime-event` | `query` | 用户输入搜索关键字后触发搜索 |
| `search-episodes-event` | `animeTitle, bangumiId, api_server` | 拉取某番剧的剧集列表 |
| `load-danmaku` | `animeTitle, episodeTitle, episodeId, api_server` | 加载指定剧集的弹幕（核心入口） |
| `add-source-event` | `query` | 添加弹幕源（URL/本地路径） |
| `open_danmaku_style_menu` | 无 | 打开弹幕样式菜单 |
| `open_content_danmaku_menu` | 无 | 打开弹幕内容菜单 |
| `open-latest-menu-anime` | 无 | 重新打开上次搜索结果菜单 |
| `cancel-active-request` | `[menu_type]` | 取消当前活跃的并发请求 |
| `setup-danmaku-style` | `query_or_json, [text]` | 弹幕样式菜单事件分发 |
| `setup-danmaku-source` | `json` | 弹幕源管理菜单事件（delete/block/unblock） |
| `setup-source-delay` | `query_or_json, [text]` | 弹幕源延迟菜单事件 |
| `handle-danmaku-content-action` | `json` | 弹幕内容菜单动作（block_source/adjust_delay） |
| `open_content_delay_menu` | `source, time` | 打开「以该弹幕时间为起点」的延迟菜单 |
| `setup-content-delay` | `time, source, [delay_str]` | 内容延迟菜单的输入回调 |

### 启动时对外广播

`main.lua` 启动时调用 `mp.commandv('script-message', 'uosc_danmaku-version', VERSION)`，
外部脚本可监听该消息获取版本号。

> 大量 `script-message-to uosc open-menu / close-menu / set` 是驱动 uosc UI 的
> **出站**消息，不属于入站接口。

## 暴露给外部的 user-data 属性

上游基线版本仅暴露两个属性，**没有**暴露当前番剧信息：

| 属性 | 类型 | 说明 |
| --- | --- | --- |
| `user-data/uosc_danmaku/danmaku-delay` | 数字 | 当前弹幕总延迟（秒） |
| `user-data/uosc_danmaku/has-danmaku` | 布尔 | 当前是否有弹幕在显示 |

> 2026-08 版本新增 `user-data/<script_name>/danmaku-switch-on`（弹幕总开关）与
> `user-data/<script_name>/danmaku-count`（弹幕条数）；仍不含番剧标题信息。
> 属性前缀实际使用 `mp.get_script_name()`，通常即 `uosc_danmaku`。

### fork 版新增（匹配结果）

在本仓库的 fork 中，`show_loaded`（弹幕真正渲染成功的收敛点）会写入以下属性；
换片时（`file-loaded`）先清空再广播，因此读到的一定是**当前视频**的匹配结果：

| 属性 | 类型 | 说明 |
| --- | --- | --- |
| `user-data/uosc_danmaku/anime-title` | 字符串 | 匹配到的番剧名（dandanplay 的 `animeTitle`，通常是中文） |
| `user-data/uosc_danmaku/anime-episode` | 字符串 | 集标题，如 `第3话`；无则为空串 |
| `user-data/uosc_danmaku/anime-episode-id` | 字符串 | dandanplay `episodeId`；未走该源时为空串 |
| `user-data/uosc_danmaku/anime-api-server` | 字符串 | 实际使用的 API 服务器 |

为什么同时保留 user-data 和 script-message 两条通道：mpv 按脚本名顺序加载，
`uosc_danmaku` 先于 `uosc_staff_credits`，纯消息会漏掉首次广播；
user-data 是持久状态，随时可读，天然解决加载顺序问题。

## 获取中文名的可行方案

没有专门的「翻译为中文名」接口。但 `uosc_danmaku` 内部的 `DANMAKU.anime`
字段实际已经持有中文名（`DANMAKU` 是脚本内部 Lua 全局表，含
`.anime / .episode / .source / .api_server / .extra`，上游原版**外部脚本无法直接读取**）。

### 方案 0：主动广播（本仓库 fork 版首选）

fork（<https://github.com/awujiana/uosc_danmaku>）在 `main.lua` 中新增
`broadcast_anime_info()`，于 `show_loaded()` 末尾调用，同时写 user-data 并广播：

```lua
mp.commandv("script-message", "danmaku-anime-info",
    anime, episode, episode_id, api_server, path)
-- 空字段用 "-" 占位，保证参数位固定
```

接收侧（`uosc_staff_credits/modules/danmaku_link.lua`）：

```lua
mp.register_script_message("danmaku-anime-info", function(anime, episode, id, server, path)
    -- 用 path 做新鲜度校验：换片后旧消息不会被误用
end)
```

完整取数优先级：

| 顺序 | 来源 | 说明 |
| --- | --- | --- |
| 0 | `danmaku-anime-info` 消息 | 实时，含 `episode_id`，path 校验防陈旧 |
| 1 | user-data 四个属性 | 持久，补上「脚本后加载漏掉首帧广播」的情况 |
| 2 | `danmaku-history.json` | 上游原版唯一可用方式，按路径猜，可能过期 |

**优点**：零额外网络请求、拿到的是 dandanplay 已确认的中文名与 `episodeId`、
集数不需要再用正则从 `第3话` 里抠。
**代价**：需要维护 fork（上游更新时 `main.lua` 有冲突风险，改动点仅 3 处）。

### 方案 A：直接走弹弹play API（上游原版首选）

弹弹play 的 `/api/v2/search/anime` 返回的 `animeTitle` 对中文番剧默认就是中文名。
历史记录实证：

```json
"animeTitle": "葬送的芙莉莲 第二季"
"animeTitle": "公鸡斗士"
"animeTitle": "好想告诉你 第三季"
"animeTitle": "咒术回战 死灭回游"
"animeTitle": "凉宫春日的忧郁 (2009)"
```

`uosc_danmaku` 内部调用链（见 `apis/dandanplay.lua`）：

- **哈希匹配**：`match_file` → `POST /api/v2/match` → `data.matches[1].animeTitle`
- **标题匹配**：`match_anime` → `GET /api/v2/search/anime` →
  `match_episode` → `GET /api/v2/bangumi/{bangumiId}` → `episode.episodeTitle`

外部脚本最简复用方式：

```text
GET https://api.dandanplay.net/api/v2/search/anime?keyword=<URL编码后的关键词>
```

返回 JSON 中 `animes[].animeTitle` 即中文标题，`animes[].bangumiId` 用于进一步获取剧集。

> ⚠️ dandanplay.net 官方接口需要 `X-AppId / X-Timestamp / X-Signature` 签名头，
> 签名算法见 `apis/dandanplay.lua` 的 `generateXSignature`
> （基于 AES-ECB 解密 appid+app_accept 拼接后 SHA256）。
> 可配置 `api_server` 指向不需要签名的镜像，脚本已支持多 server 并发。

### 方案 B：通过 TMDB 获取中文译名（用于非中文搜索）

见 `apis/extra.lua` 的 `query_tmdb`：

```text
GET https://api.tmdb.org/3/search/{tv|movie}?api_key=<key>&query=<关键词>&language=zh-CN
```

- 电视剧取 `data.results[1].name`，电影取 `data.results[1].title`。
- 仅当搜索词不是中文（`is_chinese(name)` 为 false）且 `tmdb_api_key` 已配置时触发，
  先翻译成中文再用 360kan 搜索。
- 默认 `tmdb_api_key` 在 `modules/options.lua` 已内置一个 base64 编码的公共 key，建议替换为自己的。

### 方案 C：直接读取 danmaku-history.json（最稳，无需联网）

如果只想知道「当前这个文件之前匹配过什么中文名」，读历史文件最快：

- 路径：`~~/danmaku-history.json`（由 `options.history_path` 配置）
- key 为文件父目录或文件路径，value 中 `animeTitle` 字段就是中文名
- 详见下一节

## danmaku-history.json 文件结构

路径：`~~/danmaku-history.json`（默认即 `portable_config/danmaku-history.json`）。

### 顶层结构

```json
{
  "<key1>": { "..." : "..." },
  "<key2>": { "..." : "..." },
  "show_danmaku": false
}
```

`<key>` 有两种情形：

- **本地文件**：当前播放文件的父目录路径（带尾部分隔符），如
  `"E:\\下载的影视资源\\26.04-公鸡斗士\\"`；文件直接放在根目录时也可能是文件路径本身。
- **网络流**：`parse_title()` 返回的 `title` 或 `title SeasonN` 字符串；
  网络路径有时也会用去除 query 后的 URL。

`show_danmaku` 是顶层的弹幕开关状态记忆。

### 记录形态一：dandanplay 主流程匹配（含 animeTitle 等元信息）

```json
{
  "fname": "[Studio GreenTea] Niwatori Fighter [07][WebRip][HEVC-10bit 1080p AAC ASSx2]",
  "source": "dandanplay",
  "animeTitle": "公鸡斗士",
  "episodeTitle": "第7话",
  "episodeNumber": 7,
  "episodeId": 187720007,
  "api_server": "https://api.dandanplay.net"
}
```

| 字段 | 含义 |
| --- | --- |
| `fname` | 触发匹配时的源文件名（no-ext） |
| `source` | 弹幕来源标识，固定 `"dandanplay"` |
| `animeTitle` | 中文名番剧标题（**核心字段**） |
| `episodeTitle` | 集标题（如 `"第7话"` 或 `"第1话 颠倒的帕特玛"`） |
| `episodeNumber` | 集数（整数） |
| `episodeId` | dandanplay 的剧集 ID（用于直接 `GET /api/v2/comment/{episodeId}` 拉取弹幕） |
| `api_server` | 实际提供弹幕的 API 服务器 URL |

### 记录形态二：360kan 三方源匹配（extra 路径）

```json
{
  "fname": "...",
  "source": "qq",
  "animeTitle": "公鸡斗士 (2025)",
  "episodeTitle": "第7话",
  "episodeNumber": 7,
  "extra": {
    "id": "...", "site": "qq", "year": "2025",
    "class": "动漫", "title": "公鸡斗士", "number": 12, "episodenum": 7
  },
  "api_server": "..."
}
```

`source` 可为 `qq / bilibili1 / qiyi / youku`；`animeTitle` 为 `title + " (" + year + ")"`。

### 记录形态三：仅记录弹幕源（sources 表，无 animeTitle）

用户手动添加了弹幕源但未走完整匹配流程时：

```json
{
  "sources": {
    "https://api.dandanplay.net/api/v2/comment/183360022?withRelated=true&chConvert=0": {
      "from": "api_server",
      "api_server": "https://api.dandanplay.net",
      "blocked": false
    },
    "https://ani.gamer.com.tw/animeVideo.php?sn=47424": {
      "from": "api_server",
      "blocked": true
    }
  }
}
```

`sources` 的 key 是弹幕源 URL（dandanplay comment 接口 URL 或第三方网页 URL），value 含：

- `from`：来源类型，`api_server / user_custom / user_local`
- `blocked`：是否被屏蔽
- `api_server`（可选）：来源 dandanplay 服务器
- `delay_segments`（可选）：分段延迟数组 `[{start, delay}, ...]`

### 记录形态四：旧格式（读取时自动升级）

```json
[
  "-<api_server>http://www.bilibili.com/video/av3330542/index_2.html",
  "-<api_server>http://www.bilibili.com/video/av3330542/index_1.html"
]
```

数组元素格式：`[-]<from>[<...>]<url>`，`-` 前缀表示 blocked，`{{delay}}` 表示延迟。
脚本读取时通过 `read_danmaku_source_record` 自动升级为形态三。

### 空记录

`[]` 表示该 key 被记下但没有有效数据。

### 实际示例（节选）

```json
{
  "E:\\下载的影视资源\\26.04-公鸡斗士\\": {
    "animeTitle": "公鸡斗士",
    "api_server": "https://api.dandanplay.net",
    "episodeTitle": "第7话",
    "episodeId": 187720007,
    "fname": "[Studio GreenTea] Niwatori Fighter [07][WebRip][HEVC-10bit 1080p AAC ASSx2]",
    "source": "dandanplay",
    "episodeNumber": 7
  },
  "E:\\下载的影视资源\\[orion origin] Dr.Stone Science Future [22] [1080p] [H265 AAC] [CHS_JPN].mp4": {
    "sources": {
      "https://api.dandanplay.net/api/v2/comment/183360022?withRelated=true&chConvert=0": {
        "from": "api_server",
        "api_server": "https://api.dandanplay.net",
        "blocked": false
      }
    }
  },
  "show_danmaku": false
}
```

## 推荐的集成方式

场景：外部脚本想获取当前播放番剧的中文名。按优先级：

### 推荐 1：读取 danmaku-history.json（最稳、零网络开销）

适合「曾经播放过、已被记录」的场景。伪流程：

1. `mp.get_property("path")` 拿当前文件路径
2. `mp.command_native({"expand-path", "~~/danmaku-history.json"})` 拿历史文件路径
3. 读取并 `utils.parse_json` 解析
4. 依次尝试以下 key 查找：
   - 文件父目录（带尾部分隔符）
   - 文件路径本身
   - 若是网络流，用 `parse_title()` 算出的 `title` 或 `title SeasonN`
5. 命中后取 `record.animeTitle`（中文名）和 `record.episodeTitle`（中文集名）

**局限**：首次播放新番剧时无记录。

### 推荐 2：直接调用 dandanplay API（最权威）

适合需要「实时获取中文名 + 完整剧集列表」的场景。
`load-danmaku` 接口是入站（设置 animeTitle），不是出站查询，无法反向利用。
外部脚本需自行实现：

1. 从 `mp.get_property("filename/no-ext")` 解析出 `title/season/episode`
   （可参考 `modules/guess.lua` 的 formatters 数组）
2. URL 编码后调用 `GET https://api.dandanplay.net/api/v2/search/anime?keyword=<title>`
3. 取 `animes[0].animeTitle` 即中文名

签名问题的两条出路：

- 改用用户配置的 `api_server`（读取 `script-opts/uosc_danmaku.conf`），
  若配了无需签名的镜像则直接用
- 自行实现签名（参考 `apis/dandanplay.lua` 的 `generateXSignature`，
  需要 AES-ECB + SHA256 + Base64，KEY 内置于 `main.lua`）

### 推荐 3：被动监听内部消息（上游原版不可行 → 本仓库已 fork 解决）

**上游原版**：`uosc_danmaku` 没有主动广播「当前番剧信息」的出站消息；
`show_loaded` 只通过 OSD 显示「匹配内容：{anime}-{episode}」，无法被外部脚本
结构化捕获，只能读历史文件猜。

**本仓库 fork 已实现**，见 [方案 0](#方案-0主动广播本仓库-fork-版首选)：
`show_loaded()` 末尾调用 `broadcast_anime_info()`，输出 4 个 user-data 属性 +
一条 `danmaku-anime-info` 消息（5 个参数，空值用 `-` 占位）。

要注意的两个坑（都已在实现里处理）：

1. **加载顺序**：mpv 按脚本名排序加载，`uosc_danmaku` 早于
   `uosc_staff_credits`，只发消息会漏掉首次广播 → 必须同时写 user-data。
2. **陈旧数据**：换片后 `DANMAKU` 表可能还留着上一部的值 → 在
   `file-loaded` 里先 `clear_anime_info()`，并在消息里带 `path` 供接收方校验。

### 推荐 4：TMDB 中文翻译（仅适合非中文文件名）

文件名是英文/日文、不想用 dandanplay 时，复用 `query_tmdb` 逻辑
（见方案 B）。**局限**：对动画番剧的覆盖不如 dandanplay 完整。

### 场景速查

| 需求 | 推荐方案 |
| --- | --- |
| 实时拿到当前番剧名 / 集数（fork 环境） | 方案 0（`danmaku-anime-info` + user-data） |
| 获取已播放过的番剧中文名 | 推荐 1（读 history.json） |
| 获取新番剧的中文名 + 剧集列表 | 推荐 2（调用 dandanplay API） |
| 上游原版环境、仅获取当前文件的中文标题 | 推荐 1 优先，miss 时降级推荐 2 |

## 关键文件路径

以下均为相对 mpv 配置目录（`~~`）的路径：

| 内容 | 路径 |
| --- | --- |
| 入口 | `~~/scripts/uosc_danmaku/main.lua` |
| 菜单与 script-message 注册 | `~~/scripts/uosc_danmaku/modules/menu.lua` |
| dandanplay API 封装 | `~~/scripts/uosc_danmaku/apis/dandanplay.lua` |
| TMDB + 360kan 三方源 | `~~/scripts/uosc_danmaku/apis/extra.lua` |
| 文件名解析（标题/季/集） | `~~/scripts/uosc_danmaku/modules/guess.lua` |
| parse_title / 工具函数 | `~~/scripts/uosc_danmaku/modules/utils.lua` |
| 配置项（history_path / api_server / tmdb_api_key） | `~~/scripts/uosc_danmaku/modules/options.lua` |
| 历史文件 | `~~/danmaku-history.json` |

## 核心结论

1. **上游原版没有**「获取中文名」的出站 script-message 接口；中文名来自 dandanplay
   返回的 `animeTitle`，只在脚本内部使用。本仓库 fork 已把这块补成正式出站协议
   （user-data 4 属性 + `danmaku-anime-info` 消息）。
2. 基线版本共 **27 个**入站接口（main.lua 9 + extra.lua 2 + menu.lua 16；
   2026-08 版本 33 个），全部是控制类；fork 在此基础上新增 1 个**出站**消息，
   未改动任何入站接口。
3. `danmaku-history.json` 包含完整中文名（`animeTitle`），按文件路径 / 目录路径
   索引，是上游原版环境下的备选数据源——但它只记录「播放过什么」，
   不保证与当前视频同步。
4. `DANMAKU` 全局表仍是脚本内部的，外部脚本读不到；fork 通过
   `broadcast_anime_info()` 把它显式导出，读取路径收敛到两条通道。
5. 若换回上游原版，`uosc_staff_credits` 会自动降级到 user-data → 历史文件，
   功能不中断，只是失去实时性与 `episode_id`。
