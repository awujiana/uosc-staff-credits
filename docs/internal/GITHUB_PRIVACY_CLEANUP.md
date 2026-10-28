# GitHub 隐私清理记录（作者邮箱）

> **维护记录，非发布内容。**
> 本文说明 2026-10-28 对 `awujiana/uosc-staff-credits` 与 `awujiana/uosc_danmaku`
> 两个仓库做的作者邮箱清理，以及一个尚未解决的遗留问题。
>
> 出于同样的隐私原因，**本文不记录旧邮箱的字面值，也不记录仍可被直查的旧提交完整 SHA**
> （写进仓库等于二次公开）。需要这两个值时，查本机 `.workbuddy/memory/` 日志或维护者本地笔记。

## 背景

仓库作者的 Git 提交元数据里带的是旧个人邮箱。`README` 里的联系方式改成新邮箱很容易，
但 `git log` 里的 `author.email` / `committer.email` 属于历史数据，改文件不影响它。
只要历史提交还在，任何人都能通过 `git log`、commit 页面或 REST API 看到旧邮箱。

## 处理过程

### 1. 重写历史

用 `git filter-repo --email-callback`（fork 仓库用 `filter-branch --env-filter` 只重写
自有提交，保持上游 SHA 不变）把全部提交的作者与提交者邮箱换成新邮箱，
然后 `git push --force-with-lease`。

结果：分支 HEAD 上的历史干净了，`README` 也没有旧邮箱。

### 2. 遗留：force push 不删除对象

`force push` 只是让旧提交**不可达**，Git 对象仍在服务器上，按 SHA 直查依旧能取到：

```
GET /repos/<owner>/<repo>/commits/<old-sha>   →  200 + 旧邮箱
```

这一点在「非 fork 仓库」和「fork 仓库」上的解决难度完全不同，见下。

### 3. 删库重建

#### `uosc-staff-credits`：有效 ✅

普通仓库，没有共享对象池。删库 → `gh repo create` → 推回干净历史后：

```
GET /repos/awujiana/uosc-staff-credits/commits/<old-sha>   →  422 No commit found
```

旧对象随仓库一起销毁，问题彻底解决。

重建时踩到两个坑，记下来备用：

- `gh repo create --source=. --push` 在 `origin` 已存在时**只建库不推送**
  （报 `Unable to add remote "origin"`），必须补一条 `git push -u origin main`。
- Release 的 tag 当时只存在于 GitHub 侧，本地没有。重建时要先在本地
  `git tag v1.12.0` 再 `git push origin v1.12.0`，否则 `gh release create` 找不到目标。
  Release 正文建议删库前用 `gh release view --json body` 备份。

#### `uosc_danmaku`：无效 ❌

同样删库、重新 fork、强推干净历史后，旧提交**依然可以按 SHA 直查**，而且不只在
自己的 fork 下能查到 —— 在上游 `Tony15246/uosc_danmaku` 和任意第三方 fork 下都能查到。

原因：**GitHub 的 fork 网络共享同一个对象池**。向 fork 推送的提交并不是只存在自己的仓库里，
而是进入整个网络（上游 + 所有 fork）共用的对象库。删掉自己的 fork 只断开一个指针，
池子里的对象不受影响；重新 fork 回同一网络，旧提交立刻又能取到。

顺带确认：`git fetch origin <old-sha>` 取不到（不可达对象不对外提供），
只有 REST API 按 SHA 直查能命中 —— 也就是说，**必须有人手里已经有那个 SHA 才看得到**，
搜索引擎和 `git log` 都不会暴露它。

## 结论与取舍

| 仓库 | 类型 | 删库重建是否彻底 |
| --- | --- | --- |
| `uosc-staff-credits` | 普通仓库 | 是，旧 SHA 变 422 |
| `uosc_danmaku` | fork | 否，对象留在 fork 网络池里 |

由此得出两条可以复用的判断：

1. **要彻底删历史，先看仓库是不是 fork。** 不是 fork，删库重建就够；
   是 fork，删自己那份没有任何用。
2. **fork 仓库不要往分支里推含敏感信息的提交。** 一旦推上去，就只有 GitHub 官方能做清理了。

## 遗留 TODO

- [ ] 向 GitHub Support 提交工单，请求对 `Tony15246/uosc_danmaku` 的 fork 网络执行
      garbage collection，清掉含旧邮箱的不可达提交对象。
      入口：<https://support.github.com/contact>（Repository / Privacy）。
      工单里需要给出旧提交的完整 SHA —— 该值不写进本仓库，见维护者本地笔记。
- [ ] 工单处理完后复核：用 `GET /repos/Tony15246/uosc_danmaku/commits/<old-sha>`
      确认返回 404 / 422，而不是 200。

## 备份与恢复

删库前对两个仓库各做了一份 `--all` bundle（本地，未入库，勿提交）：

```
.workbuddy/tmp/repo-backup/uosc-staff-credits.bundle
.workbuddy/tmp/repo-backup/uosc_danmaku.bundle
.workbuddy/tmp/repo-backup/v1.12.0-notes.md
```

需要还原某个仓库时：

```bash
git clone uosc-staff-credits.bundle <dir>
```

注意 bundle 里是**清理后**的历史，不含旧邮箱；它只是防止误删整个仓库，不能用来找旧提交。
