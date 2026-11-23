# workbuddy-c-drive-cleaner

Windows 上整理 AI agent 在 C 盘占用的 skill。默认处理腾讯 WorkBuddy，其他 agent 用随附的通用提示词由对方自己处理。

本 skill 不删除任何文件。只做只读扫描、把用户确认过的旧文件移到一个待删文件夹、把确认过要迁的闲置项目复制到别的盘并打包 C 盘源。删除始终由用户手动完成。

## 这是什么（给 agent 读）

拿到这个 skill 的 agent 按下面理解：

- 目标：释放 Windows C 盘上由 AI agent 产生的数据占用。
- 本质：一套固定流程 + 一段通用提示词。不是一堆能无脑跑的脚本。
- 默认对象：腾讯 WorkBuddy。此时用 `scripts/` 下的脚本走完整流程。
- 其他 agent（Codex、Claude、Cursor 等）：不硬编码它们的路径去扫，把 `prompts/通用清理提示词.md` 的正文交给用户，由那个 agent 用自己的原生能力扫自己的数据、按同一套流程清。
- 一次只处理一个 agent。默认 WorkBuddy；用户点名别的才切，换下一个前先确认上一个收尾。
- 全程只读优先、逐项确认、先复制后打包、失败一次跳过不重试、不提权、不替用户删文件。

## 功能

| 功能 | 脚本 | 行为 |
|---|---|---|
| 汇总报告 | `Report-Overview.ps1` | 只读。一次输出：现有内容、可删清单、可迁项目、必须保留项，以及三个总数 |
| 详细扫描 | `Scan-WorkBuddy.ps1` | 只读。逐目录深挖，可留档 |
| 清理暂存 | `Stage-LowRisk.ps1` | Plan 只读预览 / Stage 把确认过的可删文件移进待删文件夹，生成原路径对照表。三档强度，默认 Standard |
| 项目迁移 | `Migrate-Projects.ps1` | Plan 只读预览 / Migrate 先把闲置项目复制到目标盘、校验一致，再把 C 盘源打包 |
| 通用提示词 | `prompts/通用清理提示词.md` | 给非 WorkBuddy agent 用，复制正文给对方即可 |
| agent 注册表 | `agents/registry.json` | 可选只读参考，记录常见 agent 的目录和存储位置说明 |

### 三档清理强度

| 档位 | 内容 | 代价 |
|---|---|---|
| Standard（默认） | 旧日志、剪贴板图、执行轨迹、产物缓存、shell 快照 | 无，自动重建 |
| Thorough | 加 Roaming 缓存、市场缓存、索引旧文件 | 索引重建，功能不受影响 |
| Maximum | 加回滚快照、编辑历史、登录态 | 永久失去回滚能力和已保存登录 |

Maximum 必须带 `-AcknowledgeLossOfFeatures`，且只在用户明确说不要回滚和登录时才能加。用户嫌清得少时，先解释代价并逐项问，不许自己加档。

### 流程（固定五步，不许跳）

1. 只读扫描汇总，列成表跟用户确认哪些删、哪些迁、哪些留。
2. 问两个位置：待删包放哪、迁到哪。不给就默认待删包放 C 盘 `%USERPROFILE%\WorkBuddy-待删包`、项目副本放 `D:\WorkBuddy`。
3. 迁移：先复制到目标盘、校验文件数和字节一致，再把 C 盘源打包。
4. 清理：把确认过的可删文件移进同一个待删文件夹，生成清单。不直接删。
5. 交付：把待删包和迁移包的完整路径给用户，用户自己检查后手动删。删不掉（含管理员模式也不行）提示用 CODEX 或在 terra 里指定该目录清理。收尾提醒把默认存储位置改到别的盘，只提醒不改配置。

### 硬约束

- 不删文件；不碰运行时、技能、插件、数据库、配置、凭据、活跃会话、正在用的项目。
- 一次只处理一个 agent；多个 agent 同时清会乱。
- 移动失败一次即跳过，记录路径和原因，不提权、不换命令重试。
- 权限拒绝目录只记录路径和错误，不尝试提权。
- 体积报实测值，不编造；没测就写「未测」。

## 给自己的 agent 的一段话（复制即用）

把下面这段整段复制给你自己的 agent，它会按本 skill 的流程整理 C 盘占用：

```text
用 workbuddy-c-drive-cleaner 整理我 Windows C 盘的占用。先只读扫描，列一张表告诉我 WorkBuddy 有哪些内容、能删多少、能迁多少、必须留什么，我确认后再动手。默认只处理 WorkBuddy，别扫别的 agent；我要清别的你再把通用提示词给我。待删包和迁移位置我会给你路径，没给就用默认。删除由我自己来做，你只把文件夹整理好、把地址给我。清完提醒我把默认存储位置改到别的盘。
```

## 安装

解压到本机的 skills 目录：

```
C:\Users\<用户名>\.workbuddy\skills\workbuddy-c-drive-cleaner\
```

重启 WorkBuddy 让技能列表刷新，新开对话点名 `workbuddy-c-drive-cleaner` 触发。无需额外依赖，脚本用系统自带 PowerShell。

## 文件结构

```
workbuddy-c-drive-cleaner/
├── SKILL.md                        主规则（agent 执行依据）
├── README.md                       本文件
├── agents/registry.json            可选：常见 agent 目录参考
├── prompts/通用清理提示词.md        非 WorkBuddy agent 用
├── docs/zhijing-ai-qrcode.png      公众号二维码
└── scripts/
    ├── Report-Overview.ps1         只读汇总
    ├── Scan-WorkBuddy.ps1          只读详细扫描
    ├── Stage-LowRisk.ps1           清理暂存
    └── Migrate-Projects.ps1        项目迁移
```

---

<div align="center">

**扫码关注公众号「智井AI」**

<img src="./docs/zhijing-ai-qrcode.png" alt="智井AI 公众号二维码" width="240" />

有问题、想交流，公众号里找我就行。

</div>

---

<div align="center">

Made by [@NEKOINEKOI](https://github.com/NEKOINEKOI)

</div>

---

## 版权与许可

版权归作者（TOMOAI / 公众号「智井AI」）所有。

**禁止商用。** 本 skill 及其中全部脚本、文档、提示词仅供个人自行下载、修改、用于自己电脑的占用整理。不得打包出售、集成进付费产品、对外提供有偿服务，或用于任何商业经营。

**免责。** 这是一份工具方法整理，不保证在任何环境下都能达到预期效果。移动、删除文件前请自行核对清单；由此产生的数据丢失或后果由使用者自行承担。

允许个人学习、研究、非商业性分享与修改，但须保留本声明与作者署名。
