# GitHub Hosts 自动更新脚本

> 告别手动更新 hosts。一键安装，每小时自动拉取最新 GitHub 映射并验证 IP 可用性后写入系统，从此不用再管。

![Platform](https://img.shields.io/badge/platform-Windows-blue)
![Shell](https://img.shields.io/badge/shell-PowerShell-5391FE)
![Schedule](https://img.shields.io/badge/定时-每小时%20%2B%20开机-green)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

## 功能特性

- **自动更新** — 每小时 + 开机 2 分钟后自动拉取最新 GitHub hosts
- **IP 测速选优 + Failover** — 两阶段测速：Phase1 快速TCP ping所有候选IP取延迟前4名，Phase2 C#异步TLS验证（TCP 3s+TLS 2s超时，Thread+Join模式防阻塞）选最快；核心域名写入前3个最快IP实现failover（Happy Eyeballs约300ms并行尝试下一个）；**写入前TCP recheck（2秒超时）剔除此刻不可达的IP**，防止Windows hosts多行同名条目解析顺序不可控导致浏览器选到不可达IP
- **看门狗（可选）** — 轻量常驻后台进程，每8秒TCP+TLS探测核心域名的IP并测RTT；**三重防抖+退避**策略避免IP秒级波动导致的频繁切换：①迟滞——top IP连续3次失败（约24秒）才触发；②冷却——触发后60秒内不再切；③RTT阈值——非CDN域名候选IP间RTT差距>200ms才换，**CDN域名跳过rtt-improved**（所有IP指向同一Fastly边缘，RTT差异=抖动，切换无意义）；④退避——连续3次全量更新仍不通则自动降频至60秒检查，网络恢复后自动回到8秒；**不可达IP从hosts删除但不flushdns**（避免全局flushdns误伤其他域名连接），仅top IP切换时才flushdns；**最后1个IP不通时保留不删**（避免0个IP彻底断网），靠DNS补充+触发update补救；**DNS补充+自救闭环**——IP数<2时DNS解析补充可达IP（60秒冷却），DNS补充失败则触发全量update（2分钟冷却），网络恢复时自动闭环；安装时可选启用，随时一键启停
- **双源降级** — 2 个 hosts 数据源依次降级获取（GitHub 原仓库 + 作者自建 CDN），确保数据可达
- **安全校验** — hosts 格式校验 / 域名完整性校验 / 脚本 SHA256 完整性校验（注册表存储 + ACL 保护）
- **SSL 证书身份验证** — 核心域名严格校验证书CN/SAN匹配（防MITM）；`github.githubassets.com`额外DNS解析获取正确证书IP（GitHub520数据源的`.133`IP证书为`*.github.io`不含`*.githubassets.com`，浏览器校验失败导致页面无布局；DNS返回的`.215`IP证书为`*.githubassets.com`匹配通过），严格证书校验自然淘汰`.133`IP；其他CDN域名跳过证书校验（Fastly CDN证书不含GitHub域名，严格校验会误杀）
- **自动备份** — 每次更新前备份 hosts，最多保留 5 份滚动备份
- **一键回滚** — 支持 `-Restore` 参数交互式选择历史备份恢复
- **失败通知** — 更新失败时写入 Windows 事件日志 + 气泡提醒（指数退避，避免通知轰炸）
- **防并发** — 全局 Mutex 互斥锁，进程终止自动释放，无竞态风险
- **合并写入** — 按GitHub520标记块整体替换（清除旧块防重复堆积），保留用户自定义条目不丢失；过滤带`# Timeout`标记的不可达IP行
- **ACL 加固** — 脚本目录与注册表键均设置 ACL，普通用户仅可读，防止篡改
- **完整卸载** — 卸载时动态提取域名列表（与安装脚本单一数据源同步），清理 hosts 条目、计划任务、脚本文件、注册表哈希，保留用户自定义 hosts

## 快速安装

以**管理员身份**打开 PowerShell，执行：

```powershell
irm https://raw.githubusercontent.com/goiyy/github-hosts-updater/main/install.ps1 | iex
```

或下载 `install.ps1` 后右键 → **以管理员身份运行**。

安装完成后会提示是否立即触发首次更新，建议选择执行。

## 快速卸载

以**管理员身份**打开 PowerShell，执行：

```powershell
irm https://raw.githubusercontent.com/goiyy/github-hosts-updater/main/uninstall.ps1 | iex
```

卸载流程：

```
[1/6] 停止并移除更新计划任务
[2/6] 停止看门狗并移除看门狗计划任务
[3/6] 备份当前 hosts
[4/6] 清除 GitHub hosts 条目（动态提取域名列表，与安装脚本同步；保留用户自定义条目，精确匹配防误删）
[5/6] 删除脚本目录 + 清理注册表哈希
[6/6] 刷新 DNS 缓存
```

卸载完成后会询问是否删除备份目录。

## 工作原理

```
┌──────────┐    ┌──────────┐    ┌──────────────┐    ┌────────────┐    ┌──────────────┐    ┌──────────┐
│ 定时触发  │───▶│ 获取hosts │───▶│ 格式+域名校验 │───▶│ IP测速选优  │───▶│ 替换后二次校验 │───▶│ 合并写入  │
│ 每h / 开机│    │ 双源降级  │    │  完整性检查   │    │ 两阶段选最快│    │ 格式+域名再验证│    │ 保留自定义│
└──────────┘    └──────────┘    └──────────────┘    └────────────┘    └──────────────┘    └──────────┘
                       │                 │                    │                 │
                       ▼                 ▼                    ▼                 ▼
                  获取失败通知       校验失败通知         选最快IP替换       二次校验失败→回滚
```

### 详细流程

1. **获取 hosts 数据** — 依次尝试 2 个数据源（GitHub 原仓库 → HelloGitHub CDN），任一成功即停止；获取原始字节流统一按 UTF-8 解码（流位置重置后读取，失败回退到.Content）
2. **格式校验** — 逐行验证 hosts 格式合法性，IP 部分使用 `IPAddress.TryParse` 严格校验（IPv4/IPv6 均支持）
3. **域名完整性校验** — 确保关键域名（`github.com`、`avatars.githubusercontent.com`）均存在（`github.githubassets.com`不强制要求，因其DNS解析IP证书匹配而GitHub520数据源IP证书不匹配，所有候选TLS失败时跳过该域名由DNS处理）
4. **IP 测速选优（两阶段）** — Phase1：对所有候选IP快速TCP ping（2秒超时），按延迟排序取前4名；Phase2：对前4名做完整TLS验证（socket级5秒收发超时，OS底层保障不卡死），选最快IP写入；核心域名（`github.com`、`api.github.com`、`gist.github.com`、`github.githubassets.com`）写入前3个最快IP实现failover（Happy Eyeballs约300ms并行尝试下一个）；CDN域名跳过证书校验仅测TLS延迟；整体超时 5 分钟
5. **IP 替换** — 如果最快IP不是当前IP，自动替换为最快IP
6. **替换后二次校验** — 对替换后的内容再次执行格式校验 + 域名完整性校验，失败则自动回滚备份
7. **备份原 hosts** — 时间戳命名备份，滚动保留最近 5 份
8. **合并写入 hosts** — 按 `# GitHub520 Host Start/End` 标记块整体替换旧块（防止重复堆积），保留块外用户自定义条目；过滤带 `# Timeout` 标记的不可达IP行；先写临时文件再原子替换，断电不损坏
9. **刷新 DNS 缓存** — 执行 `ipconfig /flushdns`

## 安全校验机制

| 机制 | 说明 |
|------|------|
| SHA256 脚本完整性 | 安装时将哈希写入注册表 `HKLM:\SOFTWARE\GitHubHosts`（ACL 保护），每次执行前比对，防篡改 |
| hosts 格式校验 | 逐行检查 IP + 域名格式，IP 使用 `IPAddress.TryParse` 严格校验（IPv4/IPv6），非法内容拒绝写入 |
| 域名完整性校验 | 确保核心 GitHub 域名均存在于获取的 hosts 中 |
| SSL 分级验证 + 测速选优 | 两阶段测速：Phase1快速TCP ping筛前4名，Phase2完整TLS验证选最快（socket级5秒超时，OS底层保障不卡死）；`github.githubassets.com`严格证书校验+DNS解析补充候选IP（淘汰证书不匹配的`.133`IP，选中证书匹配的`.215`IP），其他CDN域名跳过证书校验仅测TLS延迟 |
| 替换后二次校验 | IP 替换后对修改内容再次校验格式 + 域名完整性，失败自动回滚备份 |
| 全局 Mutex 防并发 | `Local\GitHubHostsUpdate` 互斥锁，进程终止自动释放；看门狗写hosts前获取同一mutex（5秒超时），防止并发写互相覆盖 |
| DNS补充+自救闭环 | 看门狗每轮检查核心域名IP数<2时触发：<br>①DNS解析补充可达IP（60秒冷却，补充到2个就停防堆积）<br>②DNS补充失败→触发全量update脚本（2分钟冷却）<br>③最后1个IP不通→保留不删（避免0个IP彻底断网），靠DNS补充+触发update补救<br>④网络恢复时自动闭环 |
| 磁盘空间检查 | C 盘可用空间 < 100MB 时中止更新；检查失败时也中止（系统异常） |
| IP 验证超时保护 | C# Thread+Join TLS检查器（TCP 3秒+TLS 2秒超时），TCP连接超时直接Close不调EndConnect（避免阻塞18秒），整体5分钟超时上限 |
| 原子写入 | hosts 文件、日志截断、通知状态文件均先写临时文件再 Move-Item 原子替换，断电/崩溃不损坏 |
| 代理信息脱敏 | 日志仅记录代理是否启用，不记录代理地址和凭证，防止内网信息泄漏 |
| ACL 加固 | 脚本目录仅 Admin/SYSTEM 可写，Users 只读；注册表哈希键阻止权限继承但保留已有企业 ACL（如 Domain Admins、审计规则） |
| 合并写入 | 按GitHub520标记块整体替换（清除旧块防重复堆积），保留用户自定义条目不丢失；过滤`# Timeout`标记的不可达IP行 |

## 看门狗

看门狗是一个可选的轻量常驻后台进程，解决 GitHub IP 可达性秒级波动导致浏览器卡等超时的问题。新版采用**三重防抖 + TLS 终判 + DNS补充+自救闭环**策略，避免IP互相抖动时频繁切换反而打断浏览器连接，同时识别 TCP 通但 TLS 被 SNI 阻断的 IP，删除不可达IP后自动DNS解析补充可达IP确保failover能力不丧失，即使所有IP都丢失也能通过DNS补充→触发update→删行走DNS的闭环自动恢复。DNS补充连续失败3次后暂停，只依赖触发update恢复（update成功后自动重置），避免无效探测刷日志。

### 工作原理

```
每8秒循环:
  读取hosts → TCP快筛核心域名IP(3s超时)
    TCP不通？→ 标记down（省掉TLS等待）
    TCP通？→ TLS终判(2s超时，验证SNI握手)
      ├── TLS通 → 标记up，记录RTT
      └── TLS失败(SNI阻断) → 标记down

  top IP不通(TCP或TLS)？
  ├── 是 → 累计失败计数
  │       └── 连续3次失败(≈24s) 且 已过冷却期(60s) 且 后面有TLS通的
  │            → 按RTT升序重排hosts(TLS可达IP放前面,不可达放后面)
  └── 否 → 失败计数清零
       top IP虽通但有其他IP RTT显著更优(差>200ms)？
       ├── 是 → 切到更优IP
       └── 否 → 不做任何操作
    重排后仅在top IP切换时flushdns，删不可达IP不flushdns（避免全局flushdns误伤其他域名连接）
    不可达IP → 从hosts中**删除**该行（但不flushdns，避免误伤其他域名）
    最后1个IP不通 → 保留不删（避免0个IP彻底断网）

  DNS补充+自救闭环（每轮检查IP数<2的域名）:
    IP数<2 且 已过DNS冷却(60s)？
    ├── 只有1个IP且不通 → 保留不删（避免0个IP彻底断网），继续DNS补充+触发update补救

    ├── 1个IP且通 或 0个IP → DNS解析补充可达IP（补充到2个就停，防堆积）
    │   ├── DNS补充成功 → 写入hosts + flushdns
    │   └── DNS补充失败 → 触发全量update_github_hosts.ps1（2分钟冷却）
    └── 删行后看门狗继续尝试补充 → 网络恢复时自动闭环

   所有IP都挂？→ 连续3轮后触发完整update_github_hosts.ps1
       连续3次全量更新仍不通？→ 进入退避模式(每60s检查一次,不再触发更新)
       网络恢复？→ 自动回到正常8s间隔
```

- 监控域名：`github.com`、`api.github.com`、`gist.github.com`、`github.githubassets.com`
- **TCP 快筛 + TLS 终判**：TCP 不通的 IP 直接跳过（快），TCP 通的再做 TLS 握手验证（准），识别 SNI 阻断
- 不可达IP从hosts**删除**（但不flushdns，避免全局flushdns误伤其他域名连接）；仅top IP切换时才flushdns
- **最后1个IP不通时保留不删**（避免0个IP彻底断网），靠DNS补充+触发update补救
- **DNS补充+自救闭环**：IP数<2时DNS解析补充可达IP（60秒冷却）；DNS补充失败→触发全量update（2分钟冷却）；网络恢复时自动闭环
- 原子写入（先写临时文件再Move-Item替换），不损坏hosts
- 资源占用：每轮~15次TCP+TLS探测，CPU<0.1%
- 进程检测：优先CommandLine匹配；提权进程（Elevated token继承）CommandLine对非提权WMI不可读，fallback到PID文件+`Get-Process`验证

### 启停命令

```powershell
# 启动（开启开机自启 + 立即启动进程）
powershell -File "C:\ProgramData\GitHubHosts\github_hosts_watchdog.ps1" -Start

# 停止（关闭开机自启 + 终止进程）
powershell -File "C:\ProgramData\GitHubHosts\github_hosts_watchdog.ps1" -Stop

# 查看状态
powershell -File "C:\ProgramData\GitHubHosts\github_hosts_watchdog.ps1" -Status
```

`-Status` 输出示例：

```
=== Watchdog Status ===
  Auto-start on boot: On (will auto-start on boot)   ← 开机自启是否开启
  Task state: Running                                 ← 任务运行时状态（Ready/Running/Disabled）
  Process running: Yes (PID: 4640)                    ← watchdog 进程是否在跑
  Last log:                                           ← 日志末尾 3 行
    2026-07-27 16:24:34 github.com top IP recovered, failCount reset
```

- `Auto-start on boot: On` = 开机自启已开启（`-Start` 后的状态）
- `Auto-start on boot: Off` = 开机不自启（`-Stop` 后的状态或安装时未启用）
- 安装时可选是否启用，默认不启用

### 日志

```
C:\ProgramData\GitHubHosts\watchdog.log
```

超过 512KB 自动截断保留末尾 100 行。

## 备份与回滚

### 自动备份

每次更新前自动备份当前 hosts 文件至：

```
C:\ProgramData\ScriptBackup\GitHubHosts\backup\hosts_20260726_143000
```

- 滚动保留最近 **5** 份时间戳备份（超出部分安全清理，无索引越界风险）
- 总备份文件上限 **50** 个

### 手动回滚

```powershell
powershell -File "C:\ProgramData\GitHubHosts\update_github_hosts.ps1" -Restore
```

执行后显示最近 5 份备份列表，交互选择恢复：

```
Available backups:
 0) Skip restore, exit
 1) 20260726 143000  (C:\ProgramData\...\hosts_20260726_143000)
 2) 20260726 130000  (C:\ProgramData\...\hosts_20260726_130000)
 ...

Select backup to restore (0-5, default 1 for latest):
```

## 定时任务

| 触发条件 | 间隔 | 说明 |
|----------|------|------|
| 时间触发 | 每 1 小时 | 持续重复，不错过任何周期 |
| 开机触发 | 开机后 2 分钟 | 延迟 2 分钟等待网络就绪 |

- 以 **SYSTEM** 账户（S-1-5-18）最高权限运行
- 脚本目录 ACL 加固：Administrators/SYSTEM 全权，Users 只读执行
- 电池供电时仍执行（`DisallowStartIfOnBatteries=false`）
- 错过触发时间后立即补执行（`StartWhenAvailable=true`）
- 仅在网络可用时执行（`RunOnlyIfNetworkAvailable=true`）

手动触发：

```powershell
Start-ScheduledTask -TaskName "UpdateGitHubHosts"
```

## 文件路径

| 路径 | 说明 |
|------|------|
| `C:\ProgramData\GitHubHosts\update_github_hosts.ps1` | 更新脚本 |
| `C:\ProgramData\GitHubHosts\github_hosts_watchdog.ps1` | 看门狗脚本（可选） |
| `C:\ProgramData\GitHubHosts\update.log` | 运行日志（>1MB 原子截断保留末尾 200 行） |
| `C:\ProgramData\GitHubHosts\watchdog.log` | 看门狗日志（>512KB 原子截断保留末尾 100 行） |
| `C:\ProgramData\GitHubHosts\notify_state.txt` | 通知退避状态（2行：连续失败次数 + 上次通知时间） |
| `C:\ProgramData\GitHubHosts\task.xml` | 更新计划任务 XML 定义 |
| `C:\ProgramData\GitHubHosts\watchdog_task.xml` | 看门狗计划任务 XML 定义 |
| `HKLM:\SOFTWARE\GitHubHosts\ScriptHash` | 脚本完整性哈希（注册表，ACL 保护） |
| `C:\ProgramData\ScriptBackup\GitHubHosts\hosts.original` | 安装时原始 hosts 备份 |
| `C:\ProgramData\ScriptBackup\GitHubHosts\backup\` | 滚动备份目录 |
| `C:\Windows\System32\drivers\etc\hosts` | 系统 hosts 文件 |

## 数据源

| 优先级 | 来源 | URL |
|--------|------|-----|
| 1 | GitHub520 (GitHub) | `https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts` |
| 2 | HelloGitHub CDN | `https://raw.hellogithub.com/hosts` |

任一源获取成功即停止，全部失败时触发失败通知。

## 失败通知

更新失败时通过三种渠道通知：

1. **Windows 事件日志** — 写入 `Application` 日志，来源 `GitHubHosts`，事件 ID 1001
2. **失败标记文件** — 写入 `C:\ProgramData\GitHubHosts\last_failure.txt`，可被监控脚本或用户轮询检测
3. **气泡提醒** — 通过 `NotifyIcon.ShowBalloonTip` 在当前会话显示气泡通知，30 秒自动消失（SYSTEM账户下可能不显示，此时依赖事件日志+标记文件）

通知策略采用**指数退避**，避免持续故障时通知轰炸：

| 连续失败次数 | 行为 |
|-------------|------|
| 第 1、2 次 | 立即通知 |
| 第 3 次 | 距上次通知 ≥ 15 分钟后通知 |
| 第 4 次 | 距上次通知 ≥ 30 分钟后通知 |
| 第 5 次 | 距上次通知 ≥ 60 分钟后通知 |
| 第 N 次 | 间隔 15×2^(N-3) 分钟，上限 24 小时 |
| 更新成功 | 重置退避计数 |

> **注意**：气泡通知在 SYSTEM 账户（计划任务）下可能不显示，此时失败信息通过事件日志和 `last_failure.txt` 标记文件传递。手动执行脚本时气泡通知正常工作。

## 常见问题

### 更新后 GitHub 仍然无法访问？

浏览器会缓存 DNS 结果，请**重启浏览器**后再试。若仍不行，执行：

```powershell
ipconfig /flushdns
```

如果频繁出现访问时断时续，建议**启用看门狗**——它会在主IP持续不通（约15秒）时切换到可达IP，并对RTT更优的IP做自动选优。

### 看门狗会占用很多资源吗？

不会。看门狗每5秒做~15次TCP ping（3秒超时），CPU占用<0.1%，内存约20MB（PowerShell进程基础开销）。主IP可达且无更优IP时几乎不做任何操作。

### 更新后自定义 hosts 条目会丢失吗？

不会。脚本采用**合并策略**：按 `# GitHub520 Host Start/End` 标记块整体替换旧块，保留所有块外自定义条目（如内网域名、广告屏蔽等）。

### 如何查看更新日志？

```powershell
Get-Content "C:\ProgramData\GitHubHosts\update.log" -Tail 50
```

### 如何手动执行一次更新？

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\GitHubHosts\update_github_hosts.ps1"
```

### 脚本完整性校验失败？

说明脚本可能被篡改，请重新运行 `install.ps1` 安装。校验逻辑：安装时将脚本 SHA256 哈希写入注册表 `HKLM:\SOFTWARE\GitHubHosts\ScriptHash`（ACL 保护，普通用户无法修改），每次执行前比对，不匹配则拒绝运行。

### 支持哪些 Windows 版本？

Windows 7 及以上，需 PowerShell 5.1+（Windows 10/11 自带）和 .NET Framework 4.5+。若安装了 PowerShell 7（pwsh.exe），将优先使用。

> **注意**：Windows 7 默认 PowerShell 2.0 + .NET 3.5，需先安装 [WMF 5.1](https://www.microsoft.com/en-us/download/details.aspx?id=54616) 和 .NET 4.5+。


## 致谢

hosts 数据来源于 [521xueweihan/GitHub520](https://github.com/521xueweihan/GitHub520) 项目，感谢维护者的持续更新。

## License

[MIT](LICENSE)