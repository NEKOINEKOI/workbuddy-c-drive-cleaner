---
name: workbuddy-c-drive-cleaner
description: 通用 skill，本质是一套流程 + 一段提示词，整理 Windows 上 AI agent 在 C 盘的占用。默认腾讯 WorkBuddy 走脚本；其他 agent 由用户把 prompts/通用清理提示词.md 交给对方 agent 自己扫、按同流程清，一次只清一个。WorkBuddy 端到端流程固定五步：先跑 Report-Overview.ps1 一次扫描汇总成一张表（有哪些内容、能删多少、能迁多少、必须留什么），跟用户沟通确认哪些删哪些迁哪些留；问待删包和迁移目标的位置（不给就默认待删包放 C 盘 %USERPROFILE%\WorkBuddy-待删包、项目副本放 D 盘 D:\WorkBuddy）；再用 Migrate-Projects.ps1 把确认过的闲置项目复制到目标盘、校验后把 C 盘源打包；用 Stage-LowRisk.ps1 把确认过的可删文件拢进同一个待删文件夹；最后给用户地址让他自己检查后手动删除，自己删不掉（含管理员模式也删不掉）时提示用 CODEX 或在 terra 里指定该目录让它清理。默认 Standard 档不碰回滚快照和登录状态；用户嫌少才解释代价并询问是否升级 Thorough / Maximum，只有明确说不要回滚和登录才用 Maximum。永久排除当前活跃工作区。不删除文件，不碰活跃会话、插件、运行时、数据库，不提权，失败一次跳过。触发场景：C 盘满了、WorkBuddy 占用太大、清理 .workbuddy、项目迁到 D 盘、深度清理。
---

# WorkBuddy C 盘清理

版权归作者（TOMOAI / 公众号「智井AI」）所有，禁止商用，详见 README.md「版权与许可」。个人学习研究可用，转载须保留署名。

面向本机 Windows 上 AI agent 的磁盘占用治理。本质是一套流程 + 一段提示词：默认对象腾讯 WorkBuddy，走仓库脚本；其他 agent 由用户把 `prompts/通用清理提示词.md` 交给对方 agent 自己扫、按同流程清——**一次只处理一个 agent**，清完一个再清下一个。本 skill 自身从不删除文件。

**这是一条端到端流程，不是两个各干各的功能。** 顺序固定，不许跳步：

1. **开局扫描汇总**：`Report-Overview.ps1` 一次扫清楚——有哪些内容、能删多少、能迁多少、必须留什么，列成一张表给用户看，先沟通确认。
2. **用户确认清理方式**：问待删包放哪、迁移到哪；确认哪些删、哪些迁、哪些留。
3. **迁移**：`Migrate-Projects.ps1` 把确认过的闲置项目复制到目标盘、校验、C 盘源打包。
4. **打包**：`Stage-LowRisk.ps1` 把确认过的可删文件拢进同一个待删文件夹。
5. **交付**：给用户一个本地地址，里面是「已迁走的 C 盘源 + 可删文件」，让他检查后自己删除。自己删不掉（含管理员模式也删不掉）时，提示用 CODEX，或在 terra 里指定该目录让它清理。

三个脚本各管一段：`Report-Overview.ps1`（汇总）/ `Migrate-Projects.ps1`（迁移）/ `Stage-LowRisk.ps1`（打包删除）。`Scan-WorkBuddy.ps1` 是详细版扫描，需要逐目录深挖时才用。

## 硬约束（任何情况下不得违反）

1. 先只读扫描，不因为一个目录大就判定它是垃圾。体积包含个人数据和回滚快照，不等于可释放空间。
2. 不移动、不删除以下任何对象：`.workbuddy` 整体、`workspace`、`workspace\sessions`、`projects` 中正在使用的项目、`file-history`、`file-tree-manifests`、`changes-detail`、`changes-index`、`buddy-snapshots`、`space-history`、`blobs`、`plugins`、`skills`、`binaries`、所有 `.db`/`.db-wal`/`.db-shm`/`.vscdb`、配置与凭据文件（`settings.json`、`mcp.json`、`keyblob`、`device-id`、`SOUL.md`、`IDENTITY.md`、`USER.md`、`MEMORY.md`）、程序安装目录。
3. 禁止 `Remove-Item`、`del`、`rmdir`、`robocopy /MOVE`、`takeown`、`icacls`、`shutdown`、改注册表、关杀软、自我提权、终止进程。
4. 用户说「都清理掉」不等于授权删除全部匹配项。必须展示具体清单并取得逐项确认。用户说「清理太少了/没腾出多少」也不等于授权升级到深度档，必须先按下面的「强度确认」流程解释并逐项询问。
5. 任何文件移动失败一次即跳过，记录完整路径、操作和错误原因，不换命令、不换 shell、不提权、不重试。
6. 暂存目录仍在 C 盘以外的位置，暂存本身不释放空间；只有人工核对后删除才释放。
7. 不编造结果。体积取脚本实测值；C 盘可用空间变化只有前后实测才报，没测就写「未测」。
8. 遇到无权限目录，只记录完整路径和错误，不做提权尝试。

## 多 agent 复用（一次只清一个）

这套 skill 本质是**一套流程 + 一段提示词**，不是一堆脚本。清 WorkBuddy 走仓库脚本；清别的 agent 靠提示词让那个 agent 用自己的原生能力处理自己的数据。

1. **默认只认 WorkBuddy**。用户没点名别的 agent，就只处理 WorkBuddy，走下面的端到端脚本流程。
2. **用户点名才切**。用户说「清完 WorkBuddy 了，再帮我清 Codex」时，切到那个 agent。**一次只清一个**——多个 agent 的目录交错、规则不同，同时清会把 AI 和用户都搞乱。换下一个前先确认上一个收尾（待删包已交付、用户已确认）。
3. **清别的 agent = 给提示词**。把 `prompts/通用清理提示词.md` 里的「提示词正文」整段交给用户，让他粘贴到那个 agent 的对话里。那段词agent 无关、自包含，对方拿到就知道按同一套六步流程扫描自己、四分类、先确认、只攒包不直删、最后提醒改默认存储位置。
4. **用对方 agent 的原生能力，不用我们的脚本去扫它**。每个 agent 最清楚自己的数据在哪、什么能删，硬编码别人的路径去猜既不准也容易误删。`Stage-LowRisk.ps1` / `Migrate-Projects.ps1` 的完整白名单**只为 WorkBuddy 实现**，绝不套到别的 agent 上。
5. **收尾**：提示词里已含所有提醒（改默认存储位置、删不掉用 CODEX/terra），不用额外补。清完问一句「还要不要清别的 agent」，要就重发提示词给下一个，一次一个。

### 可选只读参考（不是必经步骤）

`agents/registry.json` 记了几个常见 agent 的目录、默认存储位置说明；`Scan-Agent.ps1` 能按注册表对某个 agent 出纯只读概览。仅在需要「快速知道某 agent 有哪些目录、默认存储往哪改」时查一下。**主线是把提示词交给对方的 agent 自己扫**，这两个只是辅助，不跑也能完成清理。

`Scan-Agent.ps1` 用法（选做）：

```powershell
powershell.exe -NoProfile -File "<skill-folder>\scripts\Scan-Agent.ps1" -ListAgents
powershell.exe -NoProfile -File "<skill-folder>\scripts\Scan-Agent.ps1" -Agent codex
```

它只输出概览、不移动不删除；对非 WorkBuddy agent 不提供暂存/迁移白名单，不要拿它当清理依据。

## 分级口径

扫描结果必须按四类标注：

- **保留**：应用运行时、会话、历史恢复备份、插件、技能、数据库、配置、活跃项目。原因写清楚，不得建议删除。
- **迁移到 D 盘**：已停用的旧工作区目录、体积大且可整体搬走的冷数据。只给方案，不自动执行；迁移后要验证 WorkBuddy 重启、旧会话、技能、项目仍可用。
- **可清理（白名单）**：旧日志、独立临时缓存。只有这类会被暂存脚本处理，且必须经逐项确认。
- **保护或未知**：看不懂用途的一律不动，标注「需单独调查」。

## 清理强度三档（必须先按「强度确认」流程让用户选）

脚本用 `-Depth` 控制，默认 `Standard`。三档范围固定，不得自己扩大：

| 档位 | 包含内容 | 用户代价 | 默认 |
|---|---|---|---|
| `Standard` | 旧日志、剪贴板图片、执行轨迹、产物缓存、shell 快照 | 无，全部自动重建 | 是 |
| `Thorough` | Standard 全部 + Roaming 四类缓存 + 三个市场缓存 + 文件树索引/变更索引/产物索引/审计日志的旧文件 | 索引重建要花点时间，功能不受影响 | 否，需用户选 |
| `Maximum` | Thorough 全部 + `file-history` + `workspace\sessions\*\modify_backup` 回滚快照 + `zsxq-profile` 登录状态 | **永久失去文件回滚能力和已保存的登录态，下次用要重新登录** | 否，严格受限 |

`Maximum` 的门槛：`-Depth Maximum` 必须同时带 `-AcknowledgeLossOfFeatures`，脚本缺这个会直接报错。这个开关只有用户明确说过「回滚、登录这些都不要了」才能加，不能替用户决定。

## 强度确认流程（用户说清得太少 / 不满意 / 没腾出多少时必做）

用户嫌空间没清出来时，不许直接加档、不许默默扩大范围、也不许只回一句「就这样了」。按顺序做：

1. **报实测数**：当前档位清出了多少（用脚本实测的 eligible bytes），剩余可清的理论上限是多少。没测的写「未测」。
2. **解释为什么剩下的没清**：逐项说明剩余内容是什么、删了会失去什么。重点是回滚快照（文件改动的历史版本，删了那些老版本回不来）和登录状态（删了下次要重新登录）。用大白话，不要用「索引」「profile」这类词搪塞。
3. **问用户要不要**：把选择摆出来——「回滚和登录你还用不用？用的话这几项就不动；真不用的话我可以再清出约 X GB，但删了就回不来。」
4. **按回答决定**：
   - 用户说「还得用 / 不行 / 别删」→ 停在当前档，明确告诉他这就是保守模式的上限，不再劝。
   - 用户明确说「都不要了 / 不在乎登录和回滚」→ 才允许 `-Depth Maximum -AcknowledgeLossOfFeatures`，并且执行前把清单再给他确认一次。
5. **不许替用户猜**：用户没正面回答要不要牺牲功能，就当作「不要用」，保持当前档。

## 参考基线（样例量级，非固定值）

某台 Windows 上 WorkBuddy 相关合计约 12.9 GB：

| 根目录 | 样例大小 |
|---|---|
| `%USERPROFILE%\.workbuddy` | ~11,400 MB |
| `%LOCALAPPDATA%\Programs\WorkBuddy`（安装目录） | ~1,300 MB |
| `%APPDATA%\WorkBuddy` | ~475 MB |
| `%LOCALAPPDATA%\WorkBuddy` | ~11 MB |

`.workbuddy` 内部大项：`binaries` 3,794 MB（Python/Node/PortableGit，保留）、`workspace\sessions` 2,490 MB（会话，保留）、`projects` 1,194 MB（含多个停用旧工作区，可迁）、`blobs` 771 MB（会话附件，保留）、`file-tree-manifests` 628 MB（索引缓存，保留或迁）、`app` 431 MB、`skills` 378 MB、`plugins` 332 MB、`traces` 273 MB、`cache` 179 MB、`logs` 157 MB、`file-history` 154 MB、`clipboard-images` 152 MB、`zsxq-profile` 125 MB。

该基线只作对照。每次都重新实测，不拿旧数字当结论。

## 端到端工作流（严格按顺序，先沟通再动手）

定位脚本所在目录（不要凭空猜 `<skill-folder>`）。每一步做完都要跟用户对齐，没确认不许进下一步。

### 第 1 步 · 开局扫描汇总（只读，必做，第一件事）

```powershell
powershell.exe -NoProfile -File "<skill-folder>\scripts\Report-Overview.ps1"
```

**先做这一步，不要一上来就问路径或开删。** 脚本一次输出四段：现有内容体积、可删清单（DEL_）、可迁项目清单（MIG_）、必须保留项（KEEP），末尾 SUMMARY 给出三个数：能删多少文件多大、能迁多少项目多大、理论总共能腾多少。默认 7 天/30 天阈值，可用 `-MinAgeDays` / `-IdleDays` 调。

需要逐目录深挖时才跑详细版 `Scan-WorkBuddy.ps1`（支持 `-ReportPath` 留档）。

### 第 2 步 · 把汇总列成表，先跟用户沟通确认（必做）

**不要直接执行任何移动。** 用脚本实测数字列一张表给用户，分三类讲清楚：

| 类别 | 内容 | 大小 |
|---|---|---|
| 可删除 | 旧日志、剪贴板图、轨迹、缓存（哪些自动重建） | DEL_TOTAL 实测值 |
| 可迁移 | 闲置项目目录（列出名字、多久没动、迁走后是否还能用） | MIG_TOTAL 实测值 |
| 必须保留 | 运行时、会话、回滚快照、登录态、技能插件、数据库、活跃工作区 | 不删，说明删了会丢什么 |

然后明确告诉用户两个总数：「能删 X，能迁 Y，全部处理完理论上腾出 X+Y。」体积必须是实测值，没测写「未测」。

**这一步还要问清三件事，问了才动手：**

1. 这些分类你认不认可？哪些删、哪些迁、哪些留？不认可的不要动。
2. **待删包放哪**：删下来的东西在 C 盘拢成一个文件夹给你手动删。给个完整路径；**你不给就默认放 `%USERPROFILE%\WorkBuddy-待删包`**（C 盘）。
3. **迁移到哪**：迁走的项目副本放哪个盘哪个文件夹；**你不给就默认放 `D:\WorkBuddy`**（脚本会在 D 盘单独建这个 WorkBuddy 文件夹再装进去）。目标盘要存在且可写，不存在就让你换。

用户说「默认 / 随便 / 你定」才用默认值；否则用他给的路径。两个路径分别传给 `Stage-LowRisk.ps1` 的 `-StageRoot` 和 `Migrate-Projects.ps1` 的 `-TargetRoot`。

**如果用户嫌清得少 / 不满意**，不要自己加档，走上面的「强度确认流程」解释代价再问。

### 第 3 步 · 迁移项目（先复制，后打包源）

用户确认要迁的项目后：

```powershell
powershell.exe -NoProfile -File "<skill-folder>\scripts\Migrate-Projects.ps1" -Mode Plan -TargetRoot "<用户给的或默认的路径>"
```

先 Plan 只读预览，把要迁的目录列给用户。**只迁用户点名的**，用 `-IncludeName "目录名"` 精确指定（这是严格白名单）。用户确认后执行：

```powershell
powershell.exe -NoProfile -File "<skill-folder>\scripts\Migrate-Projects.ps1" -Mode Migrate -TargetRoot "<路径>" -ConfirmMigrate
```

脚本顺序：复制到目标盘 → 校验文件数和字节一致 → 才把 C 盘源打包 → 出清单。失败一次跳过、记录原因、不提权不重试。当前活跃工作区 `d-WorkBuddy 工作区` 永远排除，点名也不迁。**迁走的是现在没在用、迁了也不影响使用的项目**；活跃的一律留。

**迁移完成后必须提醒用户一件事**（这是提醒，不是替他改）：把相关应用/agent 的默认存储位置、缓存目录、下载/输出目录改到新的盘，否则 C 盘会再次被填满。具体改哪里取决于应用，注册表 `agents\registry.json` 里每个 agent 的 `default_storage_note` 写了提示方向。用户没要求就只提醒，不动任何配置。

### 第 4 步 · 打包可删文件（同一个待删文件夹）

用户确认要删的项目后：

```powershell
powershell.exe -NoProfile -File "<skill-folder>\scripts\Stage-LowRisk.ps1" -Mode Plan -Depth Standard -StageRoot "<用户给的或默认的路径>"
```

先 Plan 只读预览。默认 `-Depth Standard`；要升级必须先走「强度确认流程」得到用户明确同意。确认后执行：

```powershell
powershell.exe -NoProfile -File "<skill-folder>\scripts\Stage-LowRisk.ps1" -Mode Stage -Depth Standard -ConfirmStage -StageRoot "<路径>"
```

活动：把确认过的可删文件拢进 `stage-<档位>-<时间戳>\` 文件夹，生成 `manifest.csv` 和 `READ-ME-FIRST.txt`。失败跳过，不删文件。

迁移的 C 盘源包（`c-drive-projects-<时间戳>`）和这里的删除包（`stage-<时间戳>`）都放在**同一个待删根文件夹**下（第 2 步问的那个位置），最后一起交给用户。

### 第 5 步 · 给一个地址，用户检查后自己删

把这两个文件夹的完整路径一起给用户：

```
REVIEW BUNDLE（迁移走的 C 盘源）: <路径>
REVIEW FOLDER（可删文件）: <路径>
```

告诉用户：
1. 项目副本已经复制到目标盘并校验过，C 盘源和可删文件都在上面这两个文件夹里。
2. 先自己检查一遍：副本能用、WorkBuddy 正常、`manifest.csv` 对照表看过。要还原就按表把文件移回去。
3. **由用户自己手动删除这两个文件夹**（包括清空回收站），本 skill 不代为删除。删掉才真正释放对应盘的空间。
4. 删不掉的文件（占用、路径太长、权限），提示用户：可在这个文件夹打开 CODEX 让它删，或在 terra 里指定这个目录让它清理。用户若说管理员模式也删不掉，同样给这两个选项，不再建议提权、不改权限、不换命令反复试。
5. **提醒改默认存储位置**：清完/迁完后提醒用户把该应用或 agent 的默认存储、缓存、输出目录改到别的盘，不然 C 盘还会再涨。只提醒，不替用户改配置；用户说要改再单独处理。

**收尾时问一句**：「这个 agent 清完了，还要不要清别的 agent？」要的话按「多 agent 复用」规则，把通用提示词交给下一个 agent 自己清，一次一个；不要就结束。

## 白名单范围（脚本严格限定）

脚本只处理下列位置中「修改时间早于阈值」的文件，不递归到其它目录。按档位启用：

**Standard（默认）**
- `%USERPROFILE%\.workbuddy\logs` 下的 `.log` / `.log.N` 文件及其子目录内的旧文件
- `%LOCALAPPDATA%\WorkBuddy\logs` 下的 `.log` / `.log.N` 文件
- `%USERPROFILE%\.workbuddy\clipboard-images`
- `%USERPROFILE%\.workbuddy\cache\conversation-product-spill`
- `%USERPROFILE%\.workbuddy\traces`
- `%USERPROFILE%\.workbuddy\shell-snapshots`

**Thorough（额外）**
- `%APPDATA%\WorkBuddy\WebStorage`、`CachedData`、`Cache`、`logs`
- `%USERPROFILE%\.workbuddy\connectors-marketplace-sources`、`connectors-marketplace`、`skills-marketplace`
- `%USERPROFILE%\.workbuddy\file-tree-manifests`、`changes-detail`、`changes-index`、`artifact-index`、`audit-log`

**Maximum（额外，需 `-AcknowledgeLossOfFeatures`）**
- `%USERPROFILE%\.workbuddy\file-history`
- `%USERPROFILE%\.workbuddy\workspace\sessions\*\modify_backup`（严格限定只匹配 modify_backup 子目录，不碰会话正文）
- `%USERPROFILE%\.workbuddy\zsxq-profile`

任何解析后落在上述路径之外的目标一律拒绝。符号链接/junction 不跟随、不移动。旧的 `-IncludeProfileCache` 开关保留兼容，但登录态现在归 Maximum 档管理。

## 失败处理速查

| 情况 | 处理 |
|---|---|
| 工具不可用 | 说明本次没有实际扫描，给出两个脚本的完整路径和手动执行方式 |
| 权限拒绝 | 记录路径和错误，停在该文件，不提权 |
| 文件被占用 | 跳过，建议退出 WorkBuddy 后手动处理 |
| 路径过长 / 非法字符 | 记录，不重命名、不强删 |
| junction / 符号链接 | 不遍历、不删除链接和目标 |
| 不同来源给出不同体积 | 以本机脚本实测为准，不用记忆里的数字 |

## 报告格式

每次结束前必须交代：C 盘可用空间（前后实测）、`.workbuddy` 逻辑体积、候选总量、实际暂存量、人工删除量（只有核实过才报）、会话/技能/项目是否仍可用。用户还没删就写「空间释放：尚未 / 暂存为 0」。

---

# 功能二：迁移项目目录到别的盘

## 用途

把 `%USERPROFILE%\.workbuddy\projects` 下**闲置的项目/工作区目录**搬到用户指定的盘，C 盘上的原目录打包成一个文件夹，交给用户手动删除。跟功能一的区别：这里动的是整个项目目录，不是散落的旧文件。

## 安全顺序（脚本严格执行，不可改）

1. **复制**：先把源目录完整复制到目标盘。只尝试一次，失败就跳过，C 盘源保持原样。
2. **校验**：源文件数和字节数与目标副本完全一致，才继续。不一致就跳过。
3. **打包源**：校验通过后，才把 C 盘原目录移到待删文件夹。
4. **出清单和地址**：生成 manifest，报告迁了多少、多大、目标文件夹、待删文件夹地址。

任何一步失败一次即跳过，记录原因，不换命令、不提权、不重试。脚本从不删除文件。

## 硬排除（永远不迁）

- 当前活跃工作区 `d-WorkBuddy 工作区`
- `workbuddy`
- 所有 junction / 符号链接
- 任何不在 `projects` 目录下的路径
- skills、插件、运行时、数据库、配置一律不在迁移范围

## 工作流

### 1. 问两个路径（必做，不强制手填）

- 目标盘：项目副本放哪（`TargetRoot`）。用户不给就默认 `D:\WorkBuddy`，脚本在这个文件夹下再建带时间戳的子目录装副本。
- 待删包：C 盘原目录打包后放哪（`ReviewRoot`）。用户不给就默认 `%USERPROFILE%\WorkBuddy-待删包`（C 盘）。

脚本会先问；用户说「默认 / 随便 / 你定」或没给具体路径，才用默认值，并在输出里用 `NOTE:` 行写明用了哪个默认路径。目标盘不存在直接报错让用户换。两个路径不能相同。

### 2. 预览（只读）

```powershell
powershell.exe -NoProfile -File "<skill-folder>\scripts\Migrate-Projects.ps1" -Mode Plan -TargetRoot "<目标路径>" -ReviewRoot "<打包路径>"
```

默认只列**30 天没动过**的闲置目录（`-MinIdleDays` 可调）。输出每个候选的名字、大小、文件数、最后修改时间、源路径。这一步不复制、不移动、不删除。

只迁指定目录时加 `-IncludeName "目录名"`，这是**严格白名单**：给了就只处理这些名字，别的全不碰。注意活跃工作区即使点名也会被硬排除。

### 3. 逐项确认

把预览清单给用户看，说清每个目录是什么、多大、多久没动。问哪些同意迁。默认不动活跃工作区。用户没确认的目录一个都不迁。

### 4. 执行迁移

```powershell
powershell.exe -NoProfile -File "<skill-folder>\scripts\Migrate-Projects.ps1" -Mode Migrate -TargetRoot "<目标路径>" -ReviewRoot "<打包路径>" -ConfirmMigrate
```

复制 → 校验 → 打包源 → 出清单。失败跳过。不删除任何文件。

### 5. 交付

把这几行原样交给用户：

```
MIGRATED COUNT: N folders / M files / X MB
TARGET FOLDER: <项目副本所在路径>
REVIEW BUNDLE (delete this manually): <C盘源打包路径，用户手动删>
```

告诉用户：副本已在目标盘且校验过；确认 WorkBuddy 正常后，自己删除 REVIEW BUNDLE 释放 C 盘空间；自己删不掉（含管理员模式也删不掉）就用 CODEX，或在 terra 里指定这个目录让它清理。`manifest.csv` 可逐目录还原（把包里的目录移回 OriginalPath）。

## 已知环境限制

复制步骤依赖对源目录的读权限和对目标盘的写权限。**受限沙箱里复制会被安全策略拒绝**——此时脚本会跳过全部目录、C 盘源不动，属正常行为，不提权、不换命令重试。需在正常的用户环境执行。

## 沙箱验证记录

- Plan 模式（只读）：实测 105 个闲置目录、约 755 MB；活跃工作区命中 0；`-IncludeName` 严格白名单通过（指定 1 个只出 1 个，点名活跃工作区返回 0）；缺参数明确报错。
- Migrate 模式：受限沙箱内复制被拒，全部 SKIPPED，C 盘源一个未动——失败处理符合规则。全链路在正常环境未实测。
