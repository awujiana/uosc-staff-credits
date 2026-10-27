# Bangumi 镜像 API 使用文档

> **适用范围**: `api.bangumi.lol`、`api.bangumi.one` 等 Bangumi API 镜像站
> **API 协议**: 与 Bangumi 官方 API (`api.bgm.tv`) 完全兼容，URL 路径和响应结构一致
> **核心差异**: 镜像站无 User-Agent 联系方式强制要求、无每秒 1 次限流、并发数可提升至 5
> **官方 API 文档**: https://bangumi.github.io/api/

## 目录

1. [镜像站清单](#1-镜像站清单)
2. [与官方 API 的差异](#2-与官方-api-的差异)
3. [API 端点总览](#3-api-端点总览)
4. [搜索条目](#4-搜索条目)
5. [条目详情](#5-条目详情)
6. [条目关联角色](#6-条目关联角色)
7. [条目关联人物](#7-条目关联人物)
8. [角色详情](#8-角色详情)
9. [制作人员参与作品](#9-制作人员参与作品)
10. [通用响应格式](#10-通用响应格式)
11. [数据结构详解](#11-数据结构详解)
12. [错误处理](#12-错误处理)
13. [在 uosc_staff_credits 中的使用](#13-在-uosc_staff_credits-中的使用)
14. [附录：curl 测试命令](#14-附录curl-测试命令)

---

## 1. 镜像站清单

uosc_staff_credits 内置预设（位于 `modules/servers.lua` 的 `PRESET_SERVERS`）：

| URL | 类型 | 标签 | 备注 |
|-----|------|------|------|
| `https://api.bangumi.lol` | bangumi | 镜像(首选) | v4 schema 新增，并发性能最佳 |
| `https://api.bangumi.one` | bangumi | 镜像 | 备用镜像 |
| `https://api.bgm.tv` | bangumi | 官方 | 限流严格（每秒 1 次），UA 必须含联系方式 |

所有镜像站都遵循相同的 API 路径结构，可在 `staff-credits-servers` 菜单中启用/禁用、拖动排序。

---

## 2. 与官方 API 的差异

| 维度 | 镜像站 (`*.lol`/`*.one`) | 官方 API (`api.bgm.tv`) |
|------|--------------------------|-------------------------|
| **User-Agent** | 无强制要求 | 必须包含联系方式（URL 或邮箱），否则返回 403 |
| **限流** | 无已知限流 | 每秒 1 次，超限返回 429 |
| **并发数** | 5（`search_subject_parallel` 默认） | 1（检测到官方时自动降级） |
| **数据新鲜度** | 略有延迟（镜像同步周期） | 实时 |
| **数据完整性** | 与官方一致 | 完整 |
| **可用性** | 受镜像站运营影响，偶发宕机 | 稳定 |
| **HTTPS** | 支持 | 支持 |
| **`is_official` 标记** | `false` | `true`（影响并发策略） |

### `is_official` 判定逻辑

位于 `modules/api.lua` 的 `is_official_api(url)`：

```lua
-- 仅匹配以下三种 URL 视为官方 API:
url:find("//api%.bgm%.tv")     -- api.bgm.tv
url:find("//bangumi%.tv")      -- bangumi.tv
url:find("//bgm%.tv")          -- bgm.tv
```

> **注意**: 使用 `//` 前缀锚点（SEC-11），避免匹配 `evil-bangumi.tv` 等钓鱼域名。

### 并发策略

`search_subject_parallel` 在检测到服务器列表包含官方 API 时，自动将并发数降为 1：

```lua
local has_official = false
for _, srv in ipairs(servers) do
    if is_official_api(srv) then
        has_official = true
        break
    end
end
local concurrency = has_official and 1 or 5
```

---

## 3. API 端点总览

所有端点均为 GET 请求，返回 JSON。

| 端点 | 路径 | 用途 |
|------|------|------|
| 搜索条目 | `/search/subject/{keyword}?type={t}&responseGroup=small&max_results={n}` | 模糊搜索番剧/书籍/音乐/游戏/三次元 |
| 条目详情 | `/v0/subjects/{id}` | 获取条目完整信息（含 rating/tags/infobox） |
| 条目角色 | `/v0/subjects/{id}/characters` | 获取条目关联角色列表（含声优） |
| 条目人物 | `/v0/subjects/{id}/persons` | 获取条目关联人物列表（角色+职员） |
| 角色详情 | `/v0/characters/{id}` | 获取角色独立详情 |
| 人物作品 | `/v0/persons/{id}/subjects` | 获取制作人员参与的作品列表 |

### `type` 枚举（条目类型）

| 值 | 含义 |
|----|------|
| 1 | 书籍（含轻小说） |
| 2 | 动画（默认） |
| 3 | 音乐 |
| 4 | 游戏 |
| 6 | 三次元（TV 剧/电影） |

---

## 4. 搜索条目

### 请求

```
GET /search/subject/{keyword}?type=2&responseGroup=small&max_results=10
```

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `keyword` | string (URL 编码) | 是 | 搜索关键词，支持中文/日文/英文，放在 path 中 |
| `type` | number | 否 | 条目类型，默认 2（动画） |
| `responseGroup` | string | 否 | 响应字段组，`small`/`large`/`medium`/`card`，默认 `small` |
| `max_results` | number | 否 | 最大返回数，默认 10 |

### 请求示例

```
GET https://api.bangumi.lol/search/subject/葬送的芙莉莲?type=2&responseGroup=small&max_results=10
```

### 响应

```json
{
  "results": 1,
  "list": [
    {
      "id": 326180,
      "name": "葬送のフリーレン",
      "name_cn": "葬送的芙莉莲",
      "type": 2,
      "url": "http://bgm.tv/subject/326180",
      "images": {
        "large": "https://lain.bgm.tv/r/400/pic/cover/l/.../xxx.jpg",
        "common": "https://lain.bgm.tv/r/200/pic/cover/l/.../xxx.jpg",
        "medium": "https://lain.bgm.tv/r/100/pic/cover/l/.../xxx.jpg",
        "small": "https://lain.bgm.tv/r/200/pic/cover/l/.../xxx.jpg",
        "grid": "https://lain.bgm.tv/r/100/pic/cover/l/.../xxx.jpg"
      }
    }
  ]
}
```

### 搜索结果字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | number | Bangumi 条目 ID（数字，用于 `/v0/subjects/{id}` 等后续请求） |
| `name` | string | 条目原始名（日文/英文） |
| `name_cn` | string | 中文名（可能为空） |
| `type` | number | 条目类型枚举（见上表） |
| `url` | string | Bangumi 站点页面 URL |
| `images` | object | 封面图 URLs，含 `large`/`common`/`medium`/`small`/`grid` 五种尺寸 |

### `responseGroup` 说明

- `small`（默认）: 仅含 `id`/`name`/`name_cn`/`url`/`images`/`type`，用于列表展示
- `large`/`medium`/`card`: 含额外字段（如 `rating`/`summary`/`eps`），响应体积更大

---

## 5. 条目详情

### 请求

```
GET /v0/subjects/{id}
```

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `id` | number | 是 | Bangumi 条目 ID（数字） |

### 请求示例

```
GET https://api.bangumi.lol/v0/subjects/326180
```

### 响应数据结构

```json
{
  "id": 326180,
  "type": 2,
  "name": "葬送のフリーレン",
  "name_cn": "葬送的芙莉莲",
  "summary": "魔王が倒された後の物語...",
  "nsfw": false,
  "locked": false,
  "date": "2023-09-29",
  "platform": "TV",
  "images": {
    "large": "https://lain.bgm.tv/r/400/pic/cover/.../xxx.jpg",
    "common": "https://lain.bgm.tv/r/200/pic/cover/.../xxx.jpg",
    "medium": "https://lain.bgm.tv/r/100/pic/cover/.../xxx.jpg",
    "small": "https://lain.bgm.tv/r/200/pic/cover/.../xxx.jpg",
    "grid": "https://lain.bgm.tv/r/100/pic/cover/.../xxx.jpg"
  },
  "infobox": [
    { "key": "中文名", "value": "葬送的芙莉莲" },
    { "key": "别名", "value": [
      { "k": "英文名", "v": "Frieren: Beyond the Journey's End" },
      { "k": "罗马字", "v": "Sousou no Frieren" }
    ]},
    { "key": "话数", "value": 28 },
    { "key": "放送开始", "value": "2023年9月29日" },
    { "key": "导演", "value": "斎藤圭一郎" },
    { "key": "原作", "value": "山田鐘人" },
    { "key": "动画制作", "value": "マッドハウス" }
  ],
  "rating": {
    "total": 12345,
    "score": 8.7,
    "count": {
      "1": 5, "2": 3, "3": 2, "4": 5, "5": 12,
      "6": 30, "7": 120, "8": 450, "9": 1500, "10": 10218
    }
  },
  "collection": {
    "doing": 606,
    "collect": 12345,
    "wish": 5432,
    "on_hold": 123,
    "dropped": 45
  },
  "tags": [
    { "name": "奇幻", "count": 5000 },
    { "name": "冒险", "count": 4000 },
    { "name": "2023年10月", "count": 3000 }
  ],
  "eps": 28,
  "eps_count": 28,
  "total_episodes": 28
}
```

### 详情字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | number | 条目 ID |
| `type` | number | 条目类型（见枚举表） |
| `name` | string | 原始名（日文/英文） |
| `name_cn` | string | 中文名（可能为空） |
| `summary` | string | 简介（支持多行） |
| `date` | string | 首播日期（`YYYY-MM-DD` 格式） |
| `platform` | string | 播放平台/类型（`TV`/`Movie`/`OVA`/`Web`/`剧场版`等） |
| `images` | object | 封面图 URLs，含 5 种尺寸 |
| `infobox` | array | 信息框键值对数组（见 [infobox 结构](#infobox-信息框结构)） |
| `rating` | object | 评分信息（见 [rating 结构](#rating-评分结构)） |
| `collection` | object | 收藏统计（`doing`/`collect`/`wish`/`on_hold`/`dropped`） |
| `tags` | array | 标签列表，每项 `{name, count}` |
| `eps` | number\|null | 集数（部分条目为 `*` 或 null） |
| `eps_count` | number\|null | 确切集数（数字） |
| `total_episodes` | number\|null | 总集数 |
| `nsfw` | boolean | 是否 NSFW |
| `locked` | boolean | 是否锁定（锁定条目不可编辑） |

### rating 评分结构

```json
{
  "total": 12345,
  "score": 8.7,
  "count": {
    "1": 5, "2": 3, "3": 2, "4": 5, "5": 12,
    "6": 30, "7": 120, "8": 450, "9": 1500, "10": 10218
  }
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `total` | number | 总评分人数 |
| `score` | number | 平均分（0-10，保留 1 位小数） |
| `count` | object | 各分数段人数（键为 1-10，值为该分数投票数） |

### infobox 信息框结构

`infobox` 为数组，每项为键值对：

```json
[
  { "key": "中文名", "value": "葬送的芙莉莲" },
  { "key": "别名", "value": [
    { "k": "英文名", "v": "Frieren: Beyond the Journey's End" },
    { "k": "罗马字", "v": "Sousou no Frieren" }
  ]},
  { "key": "话数", "value": 28 },
  { "key": "放送开始", "value": "2023年9月29日" },
  { "key": "导演", "value": "斎藤圭一郎" },
  { "key": "原作", "value": "山田鐘人" },
  { "key": "动画制作", "value": "マッドハウス" }
]
```

- 简单值: `{ "key": "...", "value": "字符串或数字" }`
- 复合值: `{ "key": "...", "value": [{ "k": "标签", "v": "值" }, ...] }`
- 无标签复合值: `{ "key": "...", "value": [{ "v": "值1" }, { "v": "值2" }] }`

#### uosc_staff_credits 从 infobox 提取的字段

位于 `features/cover_intro_flow.lua` 的 `bangumi_detail_to_cover` 函数，通过 key 关键词匹配提取：

| infobox key 关键词 | 提取字段 | 匹配规则 |
|--------------------|----------|----------|
| `导演`/`監督`/`director` (不区分大小写) | `director` | 任一关键词命中 |
| `原作`/`original` (不区分大小写) | `original_work` | 任一关键词命中 |
| `动画制作`/`制作`（排除 `製作年`） | `studio` | 任一关键词命中 |
| `原作载体`/`连载杂志`/`连载` | `source` | 任一关键词命中 |
| `英文名`/`English` | `name_en` | 任一关键词命中 |
| `罗马字`/`Romaji`/`Hepburn` | `name_romaji` | 任一关键词命中 |

---

## 6. 条目关联角色

获取条目关联的角色列表（仅角色，不含职员）。

### 请求

```
GET /v0/subjects/{id}/characters
```

### 响应

```json
[
  {
    "id": 12345,
    "name": "フリーレン",
    "name_cn": "芙莉莲",
    "relation": "主角",
    "type": 1,
    "images": {
      "large": "https://lain.bgm.tv/r/400/pic/crt/.../xxx.jpg",
      "medium": "https://lain.bgm.tv/r/200/pic/crt/.../xxx.jpg",
      "small": "https://lain.bgm.tv/r/100/pic/crt/.../xxx.jpg",
      "grid": "https://lain.bgm.tv/r/100/pic/crt/.../xxx.jpg"
    },
    "infobox": [
      { "key": "简体中文名", "value": "芙莉莲" },
      { "key": "别名", "value": [
        { "k": "日文名", "v": "フリーレン" },
        { "k": "罗马字", "v": "Frieren" }
      ]}
    ]
  }
]
```

### 角色字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | number | 角色 ID |
| `name` | string | 角色名（通常为日文） |
| `name_cn` | string | 角色中文名（可能为空） |
| `relation` | string | 角色关系（`主角`/`配角`/`客串`） |
| `type` | number | 角色类型（**注意: characters API 的 type 与 persons API 不同**）<br/>characters API: `1`=主角/`2`=配角/`3`=客串<br/>persons API: `1`=角色/`2`=职员 |
| `images` | object | 角色图片 URLs |
| `infobox` | array | 角色信息框（用于查找中文名/别名） |

> **重要**: `characters` API 返回的所有项都是"角色"，`type` 字段表示主角/配角/客串，**不能**用于过滤"角色 vs 职员"。
> 旧代码误用 `char.type == 1` 过滤，导致无主角的番剧返回空列表（已修复，见 `api.build_character_entries` 注释）。

---

## 7. 条目关联人物

获取条目关联的人物列表（角色+职员混合，含声优映射）。

### 请求

```
GET /v0/subjects/{id}/persons
```

### 响应

```json
[
  {
    "id": 67890,
    "name": "フリーレン",
    "relation": "主角",
    "type": 1,
    "images": {
      "large": "https://lain.bgm.tv/r/400/pic/crt/.../xxx.jpg",
      "medium": "https://lain.bgm.tv/r/200/pic/crt/.../xxx.jpg",
      "small": "https://lain.bgm.tv/r/100/pic/crt/.../xxx.jpg"
    },
    "actors": [
      {
        "id": 54321,
        "name": "種﨑敦美",
        "images": {
          "large": "https://lain.bgm.tv/r/400/pic/crt/.../yyy.jpg",
          "medium": "https://lain.bgm.tv/r/200/pic/crt/.../yyy.jpg",
          "small": "https://lain.bgm.tv/r/100/pic/crt/.../yyy.jpg"
        }
      }
    ]
  },
  {
    "id": 99999,
    "name": "斎藤圭一郎",
    "relation": "导演",
    "type": 2,
    "images": {
      "large": "https://lain.bgm.tv/r/400/pic/crt/.../zzz.jpg",
      "medium": "https://lain.bgm.tv/r/200/pic/crt/.../zzz.jpg",
      "small": "https://lain.bgm.tv/r/100/pic/crt/.../zzz.jpg"
    },
    "actors": []
  }
]
```

### 人物字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | number | 人物 ID（角色 ID 或职员 ID） |
| `name` | string | 人物名（通常为日文） |
| `relation` | string | 关系/职位（角色: `主角`/`配角`；职员: `导演`/`原作`/`系列构成`等职位名） |
| `type` | number | **1**=角色（含 `actors` 声优映射）<br/>**2**=职员（`actors` 为空数组） |
| `images` | object | 人物图片 URLs |
| `actors` | array | 仅 `type=1` 角色有此字段，声优列表 |

### 声优（Actor）字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | number | 声优 ID |
| `name` | string | 声优名（通常为日文） |
| `images` | object | 声优头像 URLs（`large`/`medium`/`small`） |

### 角色与职员的区分规则

位于 `modules/api.lua` 的 `parse_characters_data` 函数：

```lua
-- type=1: 角色，含 actors 声优映射
if person.type == api.CHAR_TYPE_CHARACTER then  -- CHAR_TYPE_CHARACTER = 1
    -- 提取 id/name/relation/images/actors
    -- actors 转换为 [{id, name, image}]
-- type=2: 职员，relation 字段为职位名称
elseif person.type == api.CHAR_TYPE_STAFF then  -- CHAR_TYPE_STAFF = 2
    -- 提取 id/name/relation/images
    -- 将 relation 转为 positions 数组（统一数据结构）
    -- positions = { relation }
end
```

---

## 8. 角色详情

### 请求

```
GET /v0/characters/{id}
```

### 响应

```json
{
  "id": 12345,
  "name": "フリーレン",
  "type": 1,
  "images": {
    "large": "https://lain.bgm.tv/r/400/pic/crt/.../xxx.jpg",
    "medium": "https://lain.bgm.tv/r/200/pic/crt/.../xxx.jpg",
    "small": "https://lain.bgm.tv/r/100/pic/crt/.../xxx.jpg",
    "grid": "https://lain.bgm.tv/r/100/pic/crt/.../xxx.jpg"
  },
  "summary": "フリーレンは、孤独を愛する魔法使い...",
  "infobox": [
    { "key": "简体中文名", "value": "芙莉莲" },
    { "key": "别名", "value": [
      { "k": "日文名", "v": "フリーレン" },
      { "k": "罗马字", "v": "Frieren" }
    ]},
    { "key": "性别", "value": "女" },
    { "key": "生日", "value": "..." }
  ]
}
```

---

## 9. 制作人员参与作品

获取某个制作人员（导演/原作/声优等）参与的所有作品列表，用于"历史作品"展示。

### 请求

```
GET /v0/persons/{id}/subjects
```

### 响应

```json
[
  {
    "id": 326180,
    "type": 2,
    "name": "葬送のフリーレン",
    "name_cn": "葬送的芙莉莲",
    "staff": "导演",
    "images": {
      "large": "https://lain.bgm.tv/r/400/pic/cover/.../xxx.jpg",
      "medium": "https://lain.bgm.tv/r/200/pic/cover/.../xxx.jpg",
      "small": "https://lain.bgm.tv/r/100/pic/cover/.../xxx.jpg"
    }
  },
  {
    "id": 297,
    "type": 2,
    "name": "青春ブタ野郎はバニーガール先輩の夢を見ない",
    "name_cn": "青春猪头少年不会梦到兔女郎学姐",
    "staff": "导演"
  }
]
```

### 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | number | 条目 ID |
| `type` | number | 条目类型（2=动画） |
| `name` | string | 条目原始名 |
| `name_cn` | string | 中文名（可能为空） |
| `staff` | string | 担任职位（如 `导演`/`原作`/`系列构成`/`脚本`/`分镜`） |
| `images` | object | 条目封面图 URLs |

---

## 10. 通用响应格式

### 成功响应

```json
{
  // 直接返回数据（数组或对象，无外层包装）
}
```

Bangumi v0 API 不使用 `{success, data}` 外层包装，直接返回数组或对象。

### 错误响应

```json
{
  "title": "Not Found",
  "description": "Subject #999999 not found",
  "status": 404
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `title` | string | 错误标题 |
| `description` | string | 详细描述 |
| `status` | number | HTTP 状态码 |

---

## 11. 数据结构详解

### 11.1 images 图片结构

所有 `images` 字段统一使用以下结构：

```json
{
  "large": "...",
  "common": "...",  // 仅条目封面有此字段
  "medium": "...",
  "small": "...",
  "grid": "..."     // 仅部分条目有此字段
}
```

| 尺寸 | 用途 | 分辨率 |
|------|------|--------|
| `large` | 大图（详情页、卡片） | 400px |
| `common` | 通用尺寸（仅条目封面） | 200px |
| `medium` | 中等尺寸 | 200px |
| `small` | 缩略图 | 100px |
| `grid` | 列表网格 | 100px |

### 图片 URL 格式

```
https://lain.bgm.tv/r/{size}/pic/{type}/{path}/{filename}.jpg
```

- `size`: `100`/`200`/`400`（对应 small/medium/large）
- `type`: `cover`（条目封面）/`crt`（人物/角色）/`photo`（照片）
- 图片格式为 JPG，mpv 原生支持，**无需转换**

---

## 12. 错误处理

### HTTP 状态码

| 状态码 | 含义 | 处理建议 |
|--------|------|----------|
| 200 | 成功 | - |
| 400 | 参数错误 | 检查 keyword/type 参数 |
| 401 | 未授权 | 镜像站通常不触发，仅官方 API 需要 Bearer Token |
| 403 | 禁止访问 | 官方 API: UA 缺少联系方式 |
| 404 | 资源不存在 | 检查 ID 是否正确 |
| 429 | 限流 | 官方 API: 每秒 1 次超限；镜像站通常不触发 |
| 500 | 服务器错误 | 重试或切换数据源 |
| 502/503 | 网关错误 | 镜像站同步中或临时不可用 |

### uosc_staff_credits 错误码

`modules/api.lua` 定义的错误码常量：

| 错误码 | 含义 | 触发条件 |
|--------|------|----------|
| `ERR_NETWORK` | 网络层失败 | curl 无法连接、超时、DNS 失败 |
| `ERR_HTTP` | HTTP 层失败 | status != 0（如 4xx/5xx）或 API 业务错误 |
| `ERR_PARSE` | 解析失败 | JSON 解析失败或数据格式不符 |
| `ERR_EMPTY` | 空响应 | 请求成功但无数据（空列表） |

错误信息结构（与 utils_mod.http_request 一致）：

```lua
{
  code = "ERR_NETWORK" | "ERR_HTTP" | "ERR_PARSE" | "ERR_EMPTY",
  msg = "人类可读的错误描述"
}
```

---

## 13. 在 uosc_staff_credits 中的使用

### 配置

镜像站配置存储于 `~~/staff-credits-servers.json`，schema 版本 v5（含 `bangumi.lol` 镜像首选）。

```json
{
  "_schema_version": 5,
  "servers": [
    { "url": "https://api.bangumi.lol", "type": "bangumi", "enabled": true, "is_official": false, "note": "镜像(首选)" },
    { "url": "https://api.bangumi.one", "type": "bangumi", "enabled": true, "is_official": false, "note": "镜像" },
    { "url": "https://api.bgm.tv", "type": "bangumi", "enabled": true, "is_official": true, "note": "官方" }
  ]
}
```

### 数据源选择流程

```
servers.get_active_bangumi_servers()
      │
      ├─ 返回已启用+已排序的 bangumi 服务器 URL 列表
      │
      ▼
api.search_subject_parallel(servers, keyword, callback)
      │
      ├─ 检测列表是否含官方 API
      │   ├─ 含官方 → concurrency = 1（避免限流）
      │   └─ 全镜像 → concurrency = 5（提升吞吐）
      │
      ├─ 并发请求所有镜像
      │   └─ 首个返回有效结果即取消其他请求
      │
      └─ 全部失败 → 回退到单服务器 search_subject_with_match
```

### 模块接口

`modules/api.lua` 提供的函数（所有镜像站通用）：

#### `api.search_subject_with_match(keyword, season_num, callback, subject_type)`

单服务器模糊搜索，用三维评分（名称相似度 + 季数 + 年份）选择最佳候选。

- **subject_type**: 条目类型枚举（2=动画默认，1=书籍，3=音乐，4=游戏，6=三次元）
- **callback**: `function(success, data, err_info)`，`data` 为 `{id, name, name_cn, url}`

#### `api.search_subject_parallel(keyword, season_num, callback, subject_type)`

多服务器并发搜索（推荐使用）。

- **策略**:
  1. 优先使用 `deps.servers.get_active_bangumi_servers()` 返回的已排序+已启用列表
  2. 首个返回有效结果即取消其他请求
  3. 对返回列表用三维评分选最佳（高置信度 ≥0.35，低置信度 ≥0.25）
  4. 全部失败时回退到 `search_subject_with_match`

#### `api.search_subject_list(keyword, max_results, callback)`

搜索返回多条结果列表（不做匹配筛选）。

- **callback**: `function(success, results, err_info)`
- **results**: 数组，每项 `{id, name, name_cn, url, images, type}`

#### `api.get_subject_detail(subject_id, callback, cancel_cb)`

获取条目详情（含 rating/tags/infobox 等完整字段）。

#### `api.get_subject_characters(subject_id, callback, cancel_cb)`

获取条目关联角色列表（仅角色）。

#### `api.get_subject_persons(subject_id, callback, cancel_cb)`

获取条目关联人物列表（角色+职员混合）。

#### `api.get_person_subjects(person_id, callback, cancel_cb)`

获取制作人员参与的作品列表。

#### `api.parse_characters_data(persons_data)`

解析 persons API 返回数据，提取角色（type=1）和职员（type=2）。

- **返回**: 角色和职员列表，每项含 `{id, name, relation, image, actors, type, positions}`
- 职员的 `relation` 字段会同步到 `positions` 数组（统一数据结构）

#### `api.build_character_entries(chars_data, actors_map)`

从 characters API 数据构建卡片用角色条目，可选合并 persons API 的声优映射。

- **返回**: 角色条目列表，每项 `{id, name, name_cn, relation, images, infobox, actors}`
- **actors**: 数组，每项 `{name, images: {large, medium, small}}`

#### `api.merge_actors(characters, persons_data)`

将 persons 数据中的 actors 合并到 characters 列表。

### 数据格式（统一格式）

```lua
-- 角色数据（统一格式）
{
    id = 12345,
    name = "フリーレン",
    name_cn = "芙莉莲",
    relation = "主角",
    images = { large = "...", medium = "...", small = "..." },
    infobox = { ... },
    actors = {
        { id = 54321, name = "種﨑敦美", images = { large = "...", medium = "...", small = "..." } }
    },
    type = 1,  -- 1=角色
}

-- 职员数据（统一格式）
{
    id = 99999,
    name = "斎藤圭一郎",
    relation = "导演",
    positions = { "导演" },  -- 从 relation 转换
    images = { large = "...", medium = "...", small = "..." },
    actors = {},
    type = 2,  -- 2=职员
}
```

### 封面简介数据获取流程

位于 `features/cover_intro_flow.lua`。

```
cover_intro_flow.fetch_detail_and_show(subject, title, entry_path)
      │
      ├─ ① 本地持久化缓存命中  data_cache.load(entry_path, "detail")
      │        → OSD 提示「从本地缓存加载」
      │
      └─ ② 内存缓存命中（30 分钟 TTL）state.search_state.cover_intro_cache[title]
               → OSD 提示「从内存缓存加载」
      │
      ▼ 两者都未命中
按 subject._source 选择详情接口
      │
      ├─ bangumi（默认）  → api.get_subject_detail(subject.id, server_url)
      └─ anilist/mal/baike → 各自的 get_subject_detail_compatible(subject.id)
      │ 成功
      ▼
写回 cover_intro_cache + data_cache
      ▼
cover_intro.show(deps, detail, source)
```

搜索阶段（`app/search_pipeline.lua`）的数据源顺序：

```
servers.get_active_sources()          -- 「网站优先级」列表，按顺序尝试
      │ 逐个 try_bangumi(source.url)
      ▼ 全部失败
try_multi_source_fallback()           -- anilist → mal → baike
      ▼ 全部失败
finish_all_fail()                     -- 提示「所有数据源均无结果」
```

> 历史说明：v2.0 之前该链首位还有一个 `fankuhub` 聚合源（`fankuhub.search()` 一次请求
> 返回角色+声优+图片），并带一条「优先快速路径」。因该源已移除，链变为上述形式。

### V4-P3 面板布局规范

uosc_staff_credits 的三个主要面板均采用统一布局规范：

| 面板 | 尺寸（基准） | 布局 | 实现文件 |
|------|-------------|------|----------|
| 封面简介 | 960×580 | 左右分栏：左封面图，右名称/评分/标签/制作信息/简介 | `modules/cover_intro.lua` |
| 制作评分 | 960×580 | 左右分栏：左人员列表（5人+评分），右详情面板 | `modules/production_score.lua` |
| 职员表菜单 | 440 宽 | 垂直菜单列表（uosc menu） | `modules/menu.lua` |

#### 布局计算规则

- 基于 OSD 尺寸（`osd-width`/`osd-height`）计算面板位置
- UI 缩放比例 = `osd_w / 1920`（确保在不同窗口尺寸下视觉一致）
- 面板居中：`panel_x = (osd_w - panel_w) / 2`，`panel_y = (osd_h - panel_h) / 2`
- OSD 高度不足时，面板高度按比例缩小（`h_scale = min(1.0, max_panel_h / panel_h_base)`）
- overlay 分辨率与 OSD 尺寸一致，ASS 绘图坐标直接对应 overlay 像素位置

#### 各数据源的字段差异

`modules/cover_intro.lua` 与 `modules/cards.lua` 用同一套渲染代码消费四种格式，
下表是它们各自的字段来源：

| 信息项 | Bangumi 镜像/官方 | AniList | MAL | 百度百科 |
|--------|------------------|---------|-----|---------|
| 中文名 | `name_cn` | `name_cn`（由 `parse_media` 填充） | `name_cn`（由 `parse_anime` 填充） | `name` |
| 评分 | `rating.score`（单平台） | `score`（0-100，无投票数） | `score`（0-10）+ `_raw.scoring_users` | 无 |
| 制作信息 | 从 `infobox` 键值对提取 | 同 Bangumi | 同 Bangumi | 同 Bangumi |
| 简介 | `summary` 字段 | `summary`/`synopsis`/`description`/`intro` 多层回退 | 同 AniList | 同 AniList |
| 标签 | `tags` 对象数组 `{name, count}` | 字符串或对象数组 | 同 AniList | 同 AniList |
| 封面 | `images.large/common/medium`（JPG） | `images.large/common/medium` | 同 AniList | 无图片 |

---

## 14. 附录：curl 测试命令

### 搜索条目

```bash
# 搜索动画（默认 type=2）
curl -sS -A "uosc_staff_credits (https://github.com/chaosmist/uosc_staff_credits)" \
  "https://api.bangumi.lol/search/subject/%E8%91%AC%E9%80%81%E7%9A%84%E8%8A%99%E8%8E%89?type=2&responseGroup=small&max_results=10"

# 搜索书籍（type=1，含轻小说）
curl -sS -A "uosc_staff_credits (https://github.com/chaosmist/uosc_staff_credits)" \
  "https://api.bangumi.lol/search/subject/%E8%8C%85%E9%87%8E%E7%A7%8B%E4%BA%BA?type=1&max_results=5"
```

### 获取条目详情

```bash
curl -sS -A "uosc_staff_credits (https://github.com/chaosmist/uosc_staff_credits)" \
  "https://api.bangumi.lol/v0/subjects/326180"
```

### 获取条目角色

```bash
curl -sS -A "uosc_staff_credits (https://github.com/chaosmist/uosc_staff_credits)" \
  "https://api.bangumi.lol/v0/subjects/326180/characters"
```

### 获取条目人物（角色+职员）

```bash
curl -sS -A "uosc_staff_credits (https://github.com/chaosmist/uosc_staff_credits)" \
  "https://api.bangumi.lol/v0/subjects/326180/persons"
```

### 获取制作人员参与作品

```bash
curl -sS -A "uosc_staff_credits (https://github.com/chaosmist/uosc_staff_credits)" \
  "https://api.bangumi.lol/v0/persons/12345/subjects"
```

### PowerShell 测试命令

```powershell
$headers = @{ "User-Agent" = "uosc_staff_credits (https://github.com/chaosmist/uosc_staff_credits)" }

# 搜索
$keyword = [System.Web.HttpUtility]::UrlEncode("葬送的芙莉莲")
Invoke-RestMethod -Uri "https://api.bangumi.lol/search/subject/$keyword`?type=2&max_results=10" -Headers $headers

# 条目详情
Invoke-RestMethod -Uri "https://api.bangumi.lol/v0/subjects/326180" -Headers $headers

# 条目人物
Invoke-RestMethod -Uri "https://api.bangumi.lol/v0/subjects/326180/persons" -Headers $headers
```

### Python 测试命令

```python
import requests

UA = "uosc_staff_credits (https://github.com/chaosmist/uosc_staff_credits)"
headers = {"User-Agent": UA}

# 搜索
r = requests.get(
    "https://api.bangumi.lol/search/subject/葬送的芙莉莲",
    params={"type": 2, "responseGroup": "small", "max_results": 10},
    headers=headers,
)
print(r.json())

# 条目详情
r = requests.get("https://api.bangumi.lol/v0/subjects/326180", headers=headers)
detail = r.json()
print(f"名称: {detail['name_cn']}")
print(f"评分: {detail['rating']['score']} ({detail['rating']['total']}人)")
print(f"标签: {[t['name'] for t in detail['tags'][:5]]}")

# 提取角色列表
r = requests.get("https://api.bangumi.lol/v0/subjects/326180/persons", headers=headers)
persons = r.json()
chars = [p for p in persons if p["type"] == 1]
staff = [p for p in persons if p["type"] == 2]
print(f"角色数: {len(chars)}")
for c in chars[:5]:
    cv = [a["name"] for a in c.get("actors", [])]
    print(f"  {c['name']} ({c.get('name_cn','')}) - CV: {cv}")
print(f"职员数: {len(staff)}")
for s in staff[:5]:
    print(f"  {s['name']} - {s['relation']}")
```
