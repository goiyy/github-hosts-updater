$scriptDir = "C:\ProgramData\GitHubHosts"
$scriptName = "update_github_hosts.ps1"
$scriptPath = "$scriptDir\$scriptName"
$hostsPath = "C:\Windows\System32\drivers\etc\hosts"
$originalHostsBackup = "C:\ProgramData\ScriptBackup\GitHubHosts\hosts.original"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "Error: PowerShell 5.1+ is required (current: $($PSVersionTable.PSVersion)). Please install WMF 5.1: https://www.microsoft.com/en-us/download/details.aspx?id=54616" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Error: Please right-click -> Run as Administrator" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

$updateScript = @'
param([switch]$Restore)

$hostsUrl1 = "https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts"
$hostsUrl2 = "https://raw.hellogithub.com/hosts"
$hostsPath = "C:\Windows\System32\drivers\etc\hosts"
$backupDir = "C:\ProgramData\ScriptBackup\GitHubHosts\backup"
$logPath = "C:\ProgramData\GitHubHosts\update.log"
$lockPath = "C:\ProgramData\GitHubHosts\update.lock"
$mutexName = "Local\GitHubHostsUpdate"

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13 } catch {}

if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }

$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0)) {
    Write-Host "Another instance is running, waiting for it to finish (max 120s)..." -ForegroundColor Yellow
    if (-not $mutex.WaitOne(120000)) {
        Write-Host "Timed out waiting for other instance, exiting" -ForegroundColor Red
        exit 1
    }
}

try {

function Write-Log {
    param([string]$Msg)
    $logDir = Split-Path $logPath -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    [System.IO.File]::AppendAllText($logPath, "$ts $Msg`r`n", [System.Text.Encoding]::UTF8)
    $log = Get-Item $logPath -ErrorAction SilentlyContinue
    if ($log -and $log.Length -gt 1MB) {
        $lines = Get-Content $logPath -Tail 200
        $logTmp = "$logPath.tmp"
        [System.IO.File]::WriteAllLines($logTmp, $lines, [System.Text.Encoding]::UTF8)
        Move-Item -Path $logTmp -Destination $logPath -Force
    }
}

function Send-FailureNotification {
    param([string]$Message)
    $notifyStateFile = "C:\ProgramData\GitHubHosts\notify_state.txt"
    $notifyDir = Split-Path $notifyStateFile -Parent
    if (-not (Test-Path $notifyDir)) { New-Item -ItemType Directory -Path $notifyDir -Force | Out-Null }
    $consecutiveFailures = 0
    $lastNotifyTime = $null
    if (Test-Path $notifyStateFile) {
        $lines = Get-Content $notifyStateFile -ErrorAction SilentlyContinue
        if ($lines.Count -ge 1) { [int]::TryParse($lines[0], [ref]$consecutiveFailures) | Out-Null }
        if ($lines.Count -ge 2) {
            try { $lastNotifyTime = [datetime]::ParseExact($lines[1], "yyyyMMddHHmmss", $null) } catch { $lastNotifyTime = $null }
        }
    }
    $consecutiveFailures++
    $shouldNotify = $false
    if ($consecutiveFailures -le 2) {
        $shouldNotify = $true
    } else {
        $backoffMinutes = 15 * [math]::Pow(2, $consecutiveFailures - 3)
        if ($backoffMinutes -gt 1440) { $backoffMinutes = 1440 }
        if ($null -eq $lastNotifyTime -or ((Get-Date) - $lastNotifyTime).TotalMinutes -ge $backoffMinutes) {
            $shouldNotify = $true
        }
    }
    $notifyLines = @($consecutiveFailures.ToString())
    if ($lastNotifyTime) { $notifyLines += $lastNotifyTime.ToString("yyyyMMddHHmmss") } else { $notifyLines += "" }
    $notifyTmp = "$notifyStateFile.tmp"
    [System.IO.File]::WriteAllLines($notifyTmp, $notifyLines, [System.Text.Encoding]::UTF8)
    Move-Item -Path $notifyTmp -Destination $notifyStateFile -Force
    if (-not $shouldNotify) {
        Write-Log "Notification suppressed: consecutive failure #$consecutiveFailures, backoff active"
        return
    }
    try {
        [System.Diagnostics.EventLog]::WriteEntry("GitHubHosts", $Message, [System.Diagnostics.EventLogEntryType]::Error, 1001)
    } catch { Write-Log "EventLog write failed: $_" }
    try {
        $alertFile = "C:\ProgramData\GitHubHosts\last_failure.txt"
        $alertTmp = "$alertFile.tmp"
        [System.IO.File]::WriteAllText($alertTmp, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')|GitHub Hosts Update Failed|$Message", [System.Text.Encoding]::UTF8)
        Move-Item -Path $alertTmp -Destination $alertFile -Force
    } catch { Write-Log "Alert file write failed: $_" }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Warning
        $notify.Visible = $true
        $notify.ShowBalloonTip(30000, "GitHub Hosts Update", $Message, [System.Windows.Forms.ToolTipIcon]::Warning)
        Start-Sleep -Seconds 5
        $notify.Dispose()
    } catch { Write-Log "Balloon notification failed (expected under SYSTEM): $_" }

    Write-Log "Notification sent: $Message (failure #$consecutiveFailures)"
}

Add-Type -TypeDefinition @"
using System;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
public class UpdateTlsChecker {
    volatile static int _result;
    public static int CheckTls(string ip, int port, string sniName, int connectTimeoutMs, int tlsTimeoutMs, bool skipCertCheck) {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        using (var tcp = new TcpClient()) {
            var ar = tcp.BeginConnect(ip, port, null, null);
            if (!ar.AsyncWaitHandle.WaitOne(connectTimeoutMs, false)) {
                tcp.Close();
                return -1;
            }
            try { tcp.EndConnect(ar); } catch {}
            sw.Stop();
            RemoteCertificateValidationCallback validator;
            if (skipCertCheck) {
                validator = (sender, cert, chain, errors) => true;
            } else {
                validator = (sender, cert, chain, errors) => errors == System.Net.Security.SslPolicyErrors.None;
            }
            using (var ssl = new SslStream(tcp.GetStream(), false, validator)) {
                _result = -2;
                var thread = new System.Threading.Thread(() => {
                    try {
                        ssl.AuthenticateAsClient(sniName, null, System.Security.Authentication.SslProtocols.Tls12, false);
                        _result = (int)sw.ElapsedMilliseconds;
                    } catch {}
                });
                thread.IsBackground = true;
                thread.Start();
                if (!thread.Join(tlsTimeoutMs)) {
                    try { tcp.Close(); } catch {}
                    thread.Join(500);
                    return -2;
                }
                return _result;
            }

        }
    }
}
"@ -ErrorAction Stop

function Test-HostsIP {
    param([string]$Domain, [string]$Ip, [switch]$SkipCertCheck)
    try {
        $result = [UpdateTlsChecker]::CheckTls($Ip, 443, $Domain, 3000, 2000, $SkipCertCheck.IsPresent)
        if ($result -eq -1) { return -1 }
        if ($result -eq -2) { Write-Log "SSL verify failed for $Domain : $Ip : TLS handshake failed/timeout"; return -1 }
        return $result
    } catch { Write-Log "Test-HostsIP exception for $Domain : $Ip : $_"; return -1 }
}


function Get-HostsContent {
    function Get-ResponseContent($resp) {
        try {
            if ($resp.RawContentStream.CanSeek) { $resp.RawContentStream.Position = 0 }
            return [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
        } catch {
            return $resp.Content
        }
    }
    try { return Get-ResponseContent (Invoke-WebRequest -Uri $hostsUrl1 -UseBasicParsing -TimeoutSec 20) }
    catch { Write-Log "URL1 failed: $_" }
    try { return Get-ResponseContent (Invoke-WebRequest -Uri $hostsUrl2 -UseBasicParsing -TimeoutSec 20) }
    catch { Write-Log "URL2 failed: $_" }
    Send-FailureNotification -Message "Failed to fetch hosts data from all 2 sources"
    return $null
}

$regKey = "HKLM:\SOFTWARE\GitHubHosts"
$regHash = $null
try { $regHash = (Get-ItemProperty $regKey -ErrorAction Stop).ScriptHash } catch {}
if ($regHash) {
    $currentHash = (Get-FileHash $PSCommandPath -Algorithm SHA256).Hash
    if ($currentHash -ne $regHash) {
        Write-Log "Script integrity check FAILED: hash mismatch, possible tampering"
        Send-FailureNotification -Message "Script integrity check failed, possible tampering detected"
        exit 1
    }
    Write-Log "Script integrity check passed (registry)"
} else {
    Write-Log "WARNING: No integrity hash found in registry, skipping check"
}

try { $proxy = [System.Net.WebRequest]::GetSystemWebProxy(); $proxyUrl = $proxy.GetProxy($hostsUrl1); $proxyActive = ($proxyUrl -ne $hostsUrl1); if ($proxyActive) { Write-Log "Proxy: enabled (address sanitized)" } else { Write-Log "Proxy: not detected" } } catch { Write-Log "Proxy check: none or unavailable" }

try { $drive = Get-PSDrive -Name C; $freeMB = [math]::Round($drive.Free / 1MB, 1); if ($freeMB -lt 100) { Write-Log "Low disk space: ${freeMB}MB free, aborting"; exit 1 }; Write-Log "Disk space: ${freeMB}MB free" } catch { Write-Log "Disk space check failed: $_"; exit 1 }

if ($Restore) {
    $backupList = Get-ChildItem "$backupDir\hosts_*" -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    if (-not $backupList) {
        Write-Log "Restore: no backup found"
        Write-Host "No backup found in $backupDir" -ForegroundColor Red
        exit 1
    }
    Write-Host ""
    Write-Host "Available backups:" -ForegroundColor Cyan
    Write-Host " 0) Skip restore, exit" -ForegroundColor Gray
    for ($i = 0; $i -lt [math]::Min(5, $backupList.Count); $i++) {
        $b = $backupList[$i]
        $ts = $b.Name -replace 'hosts_', '' -replace '^(\d{8})_(\d{6})$', '$1 $2'
        Write-Host " $($i+1)) $($ts)  ($($b.FullName))" -ForegroundColor White
    }
    Write-Host ""
    $choice = Read-Host "Select backup to restore (0-5, default 1 for latest)"
    if ($choice -eq "" -or $choice -eq "1") { $idx = 0 }
    elseif ($choice -match "^\d+$") { $idx = [int]$choice - 1 }
    else { $idx = 0 }
    if ($idx -lt 0 -or $idx -ge $backupList.Count) {
        Write-Host "Invalid selection, exiting" -ForegroundColor Yellow
        exit 0
    }
    $selected = $backupList[$idx]
    Copy-Item -Path $selected.FullName -Destination $hostsPath -Force
    ipconfig /flushdns | Out-Null
    Write-Log "Restored from $($selected.Name), DNS flushed"
    Write-Host "Hosts restored from $($selected.Name), DNS flushed" -ForegroundColor Green
    exit 0
}

Write-Log "=== Update started ==="

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
Copy-Item -Path $hostsPath -Destination "$backupDir\hosts_$ts" -Force
$backups = Get-ChildItem "$backupDir\hosts_*" | Sort-Object Name -Descending
if ($backups.Count -gt 5) { $backups | Select-Object -Skip 5 | Remove-Item -Force }
$allBackups = Get-ChildItem "$backupDir\*" | Sort-Object Name -Descending
if ($allBackups.Count -gt 50) { $allBackups | Select-Object -Skip 50 | Remove-Item -Force }

$newHosts = Get-HostsContent
if (-not $newHosts) { Write-Log "Fetch failed, aborting"; exit 1 }

function Test-ValidHostsContent {
    param([string]$Content)
    foreach ($line in ($Content -split "`n")) {
        $t = $line.Trim()
        if ($t -eq "" -or $t -match "^\s*#") { continue }
        if ($t -match "^\s*(\S+)\s+(\S+)") {
            $ipPart = $Matches[1]
            $ipObj = $null
            if ([System.Net.IPAddress]::TryParse($ipPart, [ref]$ipObj)) { continue }
        }
        Write-Log "Invalid hosts format detected: $t"
        return $false
    }
    return $true
}

function Test-ExpectedDomains {
    param([string]$Content)
    $expectedDomains = @("github.com", "avatars.githubusercontent.com")
    $found = @{}
    foreach ($line in ($Content -split "`n")) {
        if ($line -match "^\s*\d+\.\d+\.\d+\.\d+\s+(\S+)") {
            $found[$Matches[1]] = $true
        }
    }
    foreach ($domain in $expectedDomains) {
        if (-not $found.ContainsKey($domain)) {
            Write-Log "Expected domain $domain not found in hosts content"
            return $false
        }
    }
    return $true
}

if (-not (Test-ValidHostsContent -Content $newHosts)) {
    Write-Log "Hosts content validation failed, aborting"
    Send-FailureNotification -Message "Hosts content validation failed, update aborted"
    exit 1
}

if (-not (Test-ExpectedDomains -Content $newHosts)) {
    Write-Log "Hosts content integrity check failed, aborting"
    Send-FailureNotification -Message "Hosts content integrity check failed, expected domains missing"
    exit 1
}

$domainBackups = @{
    "github.com" = @("140.82.112.3","140.82.112.4","140.82.113.3","140.82.113.4","140.82.114.3","140.82.114.4")
    "gist.github.com" = @("140.82.112.3","140.82.112.4","140.82.113.3","140.82.113.4","140.82.114.3","140.82.114.4")
    "api.github.com" = @("140.82.112.3","140.82.112.4","140.82.113.3","140.82.113.4","140.82.114.3","140.82.114.4")
    "github.githubassets.com" = @("185.199.108.133","185.199.109.133","185.199.110.133","185.199.111.133")
    "avatars.githubusercontent.com" = @("185.199.108.133","185.199.109.133","185.199.110.133","185.199.111.133")
    "codeload.github.com" = @("185.199.108.133","185.199.109.133","185.199.110.133","185.199.111.133")
    "objects.githubusercontent.com" = @("185.199.108.133","185.199.109.133","185.199.110.133","185.199.111.133")
}

$dynamicFallbacks = @{}
foreach ($line in ($newHosts -split "`n")) {
    if ($line -match "^\s*(\S+)\s+(\S+)\s*$") {
        $ip = $Matches[1]; $domain = $Matches[2]
        $ipObj = $null
        if ([System.Net.IPAddress]::TryParse($ip, [ref]$ipObj) -and $domainBackups.ContainsKey($domain)) {
            if (-not $dynamicFallbacks.ContainsKey($domain)) { $dynamicFallbacks[$domain] = @() }
            if ($ip -notin $dynamicFallbacks[$domain]) { $dynamicFallbacks[$domain] += $ip }
        }
    }
}
foreach ($domain in $dynamicFallbacks.Keys) {
    $domainBackups[$domain] = @($domainBackups[$domain]) + @($dynamicFallbacks[$domain]) | Select-Object -Unique
}

$cdnDomains = @(
    "github.githubassets.com", "avatars.githubusercontent.com",
    "codeload.github.com", "objects.githubusercontent.com",
    "media.githubusercontent.com", "camo.githubusercontent.com",
    "user-images.githubusercontent.com", "raw.githubusercontent.com",
    "uploads.githubusercontent.com", "private-user-images.githubusercontent.com",
    "github.global.ssl.fastly.net", "assets-cdn.github.com"
)

$dnsResolveDomains = @("github.githubassets.com")

foreach ($dnsDomain in $dnsResolveDomains) {
    try {
        $dnsIps = [System.Net.Dns]::GetHostAddresses($dnsDomain) | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { $_.ToString() }
        if ($dnsIps.Count -gt 0) {
            Write-Log "DNS resolve $dnsDomain -> $($dnsIps -join ',')"
            if (-not $domainBackups.ContainsKey($dnsDomain)) { $domainBackups[$dnsDomain] = @() }
            $existing = @($domainBackups[$dnsDomain])
            foreach ($dip in $dnsIps) {
                if ($dip -notin $existing) { $existing += $dip }
            }
            $domainBackups[$dnsDomain] = $existing
        }
    } catch { Write-Log "DNS resolve $dnsDomain failed: $_" }
}

$failoverDomains = @(
    "github.com", "api.github.com", "gist.github.com", "github.githubassets.com"
)

$lines = $newHosts -split "`n"
$modified = @()
$verifyStart = Get-Date
$verifyTimeout = [TimeSpan]::FromMinutes(5)

function Test-TcpOnly([string]$Ip, [int]$Ms=3000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $connect = $tcp.BeginConnect($Ip, 443, $null, $null)
        $wait = $connect.AsyncWaitHandle.WaitOne($Ms, $false)
        $sw.Stop()
        if (-not $wait) { $tcp.Close(); return -1 }
        try { $tcp.EndConnect($connect) } catch {}
        $tcp.Close()
        return [int]$sw.ElapsedMilliseconds
    } catch { $sw.Stop(); return -1 }
    finally { if ($tcp) { try { $tcp.Close() } catch {} } }
}

foreach ($line in $lines) {
    if ((Get-Date) - $verifyStart -gt $verifyTimeout) {
        Write-Log "IP verification timeout exceeded (5 min), using remaining lines as-is"
        $modified += $line
        continue
    }
    if ($line -match "#\s*Timeout") {
        Write-Log "Skipping timeout-marked line: $line"
        continue
    }
    if ($line -match "^\s*(\S+)\s+(\S+)") {
        $origIp = $Matches[1]
        $domain = $Matches[2]
        $ipObj = $null
        if (-not [System.Net.IPAddress]::TryParse($origIp, [ref]$ipObj)) {
            $modified += $line
            continue
        }
        if ($domainBackups.ContainsKey($domain)) {
            $skipCert = ($cdnDomains -contains $domain) -and ($dnsResolveDomains -notcontains $domain)


            $candidates = @($origIp) + @($domainBackups[$domain] | Where-Object { $_ -ne $origIp })

            Write-Log "${domain}: phase 1 - TCP ping $($candidates.Count) candidates"
            $tcpOk = @()
            foreach ($candidate in $candidates) {
                $lat = Test-TcpOnly $candidate 2000
                if ($lat -ge 0) {
                    $tcpOk += [PSCustomObject]@{IP=$candidate; Latency=$lat}
                }
            }
            $topN = $tcpOk | Sort-Object Latency | Select-Object -First 4
            Write-Log "${domain}: phase 2 - TLS verify $($topN.Count) reachable candidates"

            $verifiedResults = @()
            foreach ($entry in $topN) {
                $lat = Test-HostsIP -Domain $domain -Ip $entry.IP -SkipCertCheck:$skipCert
                if ($lat -ge 0) {
                    Write-Log "$domain $($entry.IP) -> ${lat}ms"
                    $verifiedResults += [PSCustomObject]@{IP=$entry.IP; Latency=$lat}
                } else {
                    Write-Log "$domain $($entry.IP) -> TLS FAILED"
                }
            }

            $isFailover = $failoverDomains -contains $domain
            if ($verifiedResults.Count -gt 0) {
                $sorted = $verifiedResults | Sort-Object Latency
                if ($isFailover -and $sorted.Count -gt 1) {
                    $failoverCount = [math]::Min(3, $sorted.Count)
                    $failoverIPs = @()
                    for ($fi = 0; $fi -lt $failoverCount; $fi++) {
                        $failoverIPs += $sorted[$fi].IP
                    }
                    Write-Log "$domain pre-write recheck: TCP ping $($failoverIPs.Count) selected IPs"
                    $recheckOk = @()
                    foreach ($fip in $failoverIPs) {
                        $rlat = Test-TcpOnly $fip 2000
                        if ($rlat -ge 0) {
                            $recheckOk += $fip
                        } else {
                            Write-Log "$domain $fip FAILED recheck, dropping"
                        }
                    }
                    if ($recheckOk.Count -eq 0) {
                        Write-Log "$domain all failover IPs failed recheck, using best TLS candidate"
                        $recheckOk = @($sorted[0].IP)
                    }
                    if ($recheckOk -contains $origIp) {
                        $otherIPs = $recheckOk | Where-Object { $_ -ne $origIp }
                        $ipList = @($origIp) + @($otherIPs)
                    } else {
                        $ipList = $recheckOk
                    }
                    $ipStr = $ipList -join " + "
                    Write-Log "$domain failover ($($ipList.Count) IPs): $ipStr"
                    foreach ($fip in $ipList) {
                        $modified += $line -replace [regex]::Escape($origIp), $fip
                    }
                } else {
                    $best = $sorted[0]
                    if ($best.IP -eq $origIp) {
                        Write-Log "$domain using original $origIp (${best.Latency}ms, fastest)"
                        $modified += $line
                    } else {
                        Write-Log "$domain replacing $origIp with fastest $($best.IP) (${best.Latency}ms)"
                        $modified += $line -replace [regex]::Escape($origIp), $best.IP
                    }
                }
            } else {
                if ($dnsResolveDomains -contains $domain) {
                    Write-Log "$domain all candidates FAILED, skipping (DNS-resolved domain, cert-mismatch IP would break browser)"
            } else {
                if ($dnsResolveDomains -contains $domain) {
                    Write-Log "$domain all candidates FAILED, skipping (cert-mismatch IP would break browser, let DNS handle it)"
                } else {
                    Write-Log "$domain all candidates FAILED, keeping original"
                    $modified += $line
                }
            }
            }

        } else {
            $modified += $line
        }
    } else { $modified += $line }
}

$finalContent = $modified -join "`r`n"
if (-not (Test-ValidHostsContent -Content $finalContent)) {
    Write-Log "Post-modification validation FAILED, restoring backup"
    Copy-Item "$backupDir\hosts_$ts" $hostsPath -Force
    Send-FailureNotification -Message "Post-modification hosts validation failed, backup restored"
    exit 1
}
if (-not (Test-ExpectedDomains -Content $finalContent)) {
    Write-Log "Post-modification domain integrity check FAILED, restoring backup"
    Copy-Item "$backupDir\hosts_$ts" $hostsPath -Force
    Send-FailureNotification -Message "Post-modification domain integrity check failed, backup restored"
    exit 1
}
Write-Log "Post-modification validation passed"

$githubDomainPatterns = @(
    "github\.com", "gist\.github\.com", "api\.github\.com",
    "github\.githubassets\.com", "avatars\.githubusercontent\.com",
    "codeload\.github\.com", "objects\.githubusercontent\.com",
    "media\.githubusercontent\.com", "camo\.githubusercontent\.com",
    "user-images\.githubusercontent\.com", "docs\.github\.com",
    "raw\.githubusercontent\.com", "github\.global\.ssl\.fastly\.net",
    "assets-cdn\.github\.com", "collector\.github\.com",
    "alive\.github\.com", "pages\.github\.com",
    "uploads\.githubusercontent\.com", "github\.cloud\.github\.com"
)
$githubRegex = "^\s*\S+\s+(" + ($githubDomainPatterns -join "|") + ")(\s|$)"

$currentHosts = [System.IO.File]::ReadAllLines($hostsPath)
$customLines = @()
$customCount = 0
$inGitHubBlock = $false
foreach ($hline in $currentHosts) {
    if ($hline -match "GitHub520 Host Start") {
        $inGitHubBlock = $true
        continue
    }
    if ($hline -match "GitHub520 Host End") {
        $inGitHubBlock = $false
        continue
    }
    if ($inGitHubBlock) { continue }
    $customLines += $hline
    $customCount++
}
Write-Log "Preserved $customCount custom/non-GitHub lines from current hosts (old GitHub520 blocks removed)"

$githubBlock = $modified -join "`r`n"

$finalContent = if ($customLines.Count -gt 0) {
    ($customLines -join "`r`n") + "`r`n" + $githubBlock
} else {
    $githubBlock
}

$hostsFile = Get-Item $hostsPath -ErrorAction SilentlyContinue
if ($hostsFile -and $hostsFile.IsReadOnly) {
    Write-Log "Hosts file is read-only, removing readonly attribute"
    $hostsFile.IsReadOnly = $false
}
$hostsTmp = "$hostsPath.tmp"
[System.IO.File]::WriteAllText($hostsTmp, $finalContent, (New-Object System.Text.UTF8Encoding $false))
Move-Item -Path $hostsTmp -Destination $hostsPath -Force
ipconfig /flushdns | Out-Null
$notifyStateFile = "C:\ProgramData\GitHubHosts\notify_state.txt"
if (Test-Path $notifyStateFile) { Remove-Item $notifyStateFile -Force -ErrorAction SilentlyContinue; Write-Log "Notification backoff reset (update succeeded)" }
Write-Log "Hosts updated, DNS flushed"
Write-Log "=== Update finished ==="

} finally {
    try { $mutex.ReleaseMutex() } catch {}
    try { $mutex.Dispose() } catch {}
}
'@

$watchdogScript = @'
param(
    [switch]$Start,
    [switch]$Stop,
    [switch]$Status
)

$watchdogTask = "GitHubHostsWatchdog"
$scriptPath = "C:\ProgramData\GitHubHosts\github_hosts_watchdog.ps1"
$logPath = "C:\ProgramData\GitHubHosts\watchdog.log"
$hostsPath = "C:\Windows\System32\drivers\etc\hosts"
$updateScript = "C:\ProgramData\GitHubHosts\update_github_hosts.ps1"
$mutexName = "Local\GitHubHostsWatchdog"
$pidFilePath = "C:\ProgramData\GitHubHosts\watchdog.pid"
$watchdogStartTime = Get-Date

# 全局 trap：捕获任何未处理的异常，写入日志后退出
trap {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $errMsg = "FATAL: Unhandled exception: $_ (at line $($_.InvocationInfo.ScriptLineNumber))"
    try { [System.IO.File]::AppendAllText($logPath, "$ts $errMsg`r`n", [System.Text.Encoding]::UTF8) } catch {}
    Write-Host $errMsg -ForegroundColor Red
    try { $mutex.ReleaseMutex() } catch {}
    try { $mutex.Dispose() } catch {}
    exit 1
}

function Get-WatchdogProcess {
    $proc = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*github_hosts_watchdog*" -and $_.CommandLine -notlike "*-Status*" -and $_.CommandLine -notlike "*-Start*" -and $_.CommandLine -notlike "*-Stop*" } | ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
    if (-not $proc -and (Test-Path $pidFilePath)) {
        $savedPid = Get-Content $pidFilePath -Raw -ErrorAction SilentlyContinue
        if ($savedPid) {
            $savedPid = $savedPid.Trim()
            if ($savedPid -match '^\d+$') {
                $proc = Get-Process -Id ([int]$savedPid) -ErrorAction SilentlyContinue
            }
        }
    }
    $proc
}

if ($Status) {
    $taskState = "Unknown"
    $taskStateFile = "C:\ProgramData\GitHubHosts\watchdog_task_state.txt"
    $autoStart = "Unknown"
    try {
        $task = Get-ScheduledTask -TaskName $watchdogTask -ErrorAction Stop
        $taskState = [string]$task.State
        $autoStart = if ($taskState -eq 'Disabled') { "Off" } else { "On" }
        try { $taskState, $autoStart | Out-File $taskStateFile -Encoding UTF8 -Force } catch {}
    } catch {
        if (Test-Path $taskStateFile) {
            $cached = Get-Content $taskStateFile -ErrorAction SilentlyContinue
            if ($cached.Count -ge 2) {
                $taskState = $cached[0]
                $autoStart = $cached[1]
            }
        }
    }
    $proc = Get-WatchdogProcess
    $autoStartStr = if ($autoStart -eq 'Off') { "Off (no auto-start on boot)" }
                    elseif ($autoStart -eq 'Unknown') { "Unknown" }
                    else { "On (will auto-start on boot)" }

    # 根据日志新鲜度判断进程是否真的存活
    $processAlive = $false
    $processInfo = "No"
    if ($proc) {
        $processAlive = $true
        $processInfo = "Yes (PID: $($proc.Id -join ','))"
    }
    $logAge = -1
    if (Test-Path $logPath) {
        $logLastWrite = (Get-Item $logPath).LastWriteTime
        $logAge = [int]((Get-Date) - $logLastWrite).TotalSeconds
        if ($logAge -gt 120 -and -not $proc) {
            $processInfo = "No (log stale ${logAge}s ago)"
        } elseif ($proc -and $logAge -gt 120) {
            $processInfo = "Yes (PID: $($proc.Id -join ','), but log stale ${logAge}s)"
        }
    }

    Write-Host ""
    Write-Host "=== Watchdog Status ===" -ForegroundColor Cyan
    Write-Host "  Auto-start on boot: $autoStartStr"
    Write-Host "  Task state: $taskState"
    Write-Host "  Process running: $processInfo"
    if (Test-Path $logPath) {
        $logItem = Get-Item $logPath
        $logTime = $logItem.LastWriteTime
        $logAgeStr = if ($logAge -ge 0) { "(last log ${logAge}s ago)" } else { "" }
        Write-Host "  Last log time: $($logTime.ToString('yyyy-MM-dd HH:mm:ss')) $logAgeStr" -ForegroundColor Gray
        Write-Host "  Last log:" -ForegroundColor Gray
        Get-Content $logPath -Tail 3 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }
    Write-Host ""
    exit 0
}

if ($Stop) {
    $stopOk = $true
    try { Stop-ScheduledTask -TaskName $watchdogTask -ErrorAction Stop } catch {
        try { schtasks /change /tn $watchdogTask /disable 2>&1 | Out-Null } catch { $stopOk = $false }
    }
    try { Disable-ScheduledTask -TaskName $watchdogTask -ErrorAction Stop } catch { $stopOk = $false }
    try { Stop-ScheduledTask -TaskName "GitHubHostsWatchdogMonitor" -ErrorAction Stop } catch {
        try { schtasks /change /tn "GitHubHostsWatchdogMonitor" /disable 2>&1 | Out-Null } catch {}
    }
    try { Disable-ScheduledTask -TaskName "GitHubHostsWatchdogMonitor" -ErrorAction Stop } catch {}
    try { "Disabled", "Off" | Out-File "C:\ProgramData\GitHubHosts\watchdog_task_state.txt" -Encoding UTF8 -Force } catch {}
    $proc = Get-WatchdogProcess
    if ($proc) {
        try { $proc | Stop-Process -Force -ErrorAction Stop } catch { $stopOk = $false }
    }
    try { Remove-Item "C:\ProgramData\GitHubHosts\watchdog.pid" -Force -ErrorAction SilentlyContinue } catch {}
    if ($stopOk) {
        Write-Host "Watchdog stopped. Auto-start on boot: OFF" -ForegroundColor Yellow
    } else {
        Write-Host "Warning: Some stop operations failed. Try running as Administrator." -ForegroundColor Red
        Write-Host "  Command: powershell -File `"$scriptPath`" -Stop" -ForegroundColor Yellow
    }
    exit 0
}

if ($Start) {
    if (-not (Test-Path $scriptPath)) {
        Write-Host "Watchdog script not found. Run install.ps1 first." -ForegroundColor Red
        exit 1
    }
    $startOk = $true
    try { Enable-ScheduledTask -TaskName $watchdogTask -ErrorAction Stop } catch {
        try { schtasks /change /tn $watchdogTask /enable 2>&1 | Out-Null } catch { $startOk = $false }
    }
    try { Enable-ScheduledTask -TaskName "GitHubHostsWatchdogMonitor" -ErrorAction Stop } catch {
        try { schtasks /change /tn "GitHubHostsWatchdogMonitor" /enable 2>&1 | Out-Null } catch {}
    }
    try { "Ready", "On" | Out-File "C:\ProgramData\GitHubHosts\watchdog_task_state.txt" -Encoding UTF8 -Force } catch {}
    $proc = Get-WatchdogProcess
    if (-not $proc) {
        $psExe = "powershell.exe"
        $pwshPath = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
        if ($pwshPath) { $psExe = $pwshPath }
        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) {
            try { Start-Process $psExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -WindowStyle Hidden -ErrorAction Stop } catch { $startOk = $false }
        } else {
            try { Start-Process $psExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs -ErrorAction Stop } catch { $startOk = $false }
        }
    }
    if ($startOk) {
        Write-Host "Watchdog started. Auto-start on boot: ON" -ForegroundColor Green
    } else {
        Write-Host "Warning: Some start operations failed. Try running as Administrator." -ForegroundColor Red
        Write-Host "  Command: powershell -File `"$scriptPath`" -Start" -ForegroundColor Yellow
    }
    exit 0
}

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Error: Please right-click -> Run as Administrator" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

$watchDomains = @("github.com", "api.github.com", "gist.github.com", "github.githubassets.com")
$cdnDomains = @("github.githubassets.com", "codeload.github.com", "objects.githubusercontent.com", "avatars.githubusercontent.com", "media.githubusercontent.com")

# 编译 C# TLS 检查器 — 一次编译，稳定运行
# 优点：有超时控制 + 不崩溃 + 资源正确释放
Add-Type -TypeDefinition @"
using System;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
public class TlsChecker {
    volatile static int _result;
    public static int CheckTls(string ip, int port, string sniName, int connectTimeoutMs, int tlsTimeoutMs) {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        using (var tcp = new TcpClient()) {
            var ar = tcp.BeginConnect(ip, port, null, null);
            if (!ar.AsyncWaitHandle.WaitOne(connectTimeoutMs, false)) {
                tcp.Close();
                return -1;
            }
            try { tcp.EndConnect(ar); } catch {}
            sw.Stop();
            using (var ssl = new SslStream(tcp.GetStream(), false, (sender, cert, chain, errors) => true)) {
                _result = -2;
                var thread = new System.Threading.Thread(() => {
                    try {
                        ssl.AuthenticateAsClient(sniName, null, System.Security.Authentication.SslProtocols.Tls12, false);
                        _result = (int)sw.ElapsedMilliseconds;
                    } catch {}
                });
                thread.IsBackground = true;
                thread.Start();
                if (!thread.Join(tlsTimeoutMs)) {
                    try { tcp.Close(); } catch {}
                    thread.Join(500);
                    return -2;
                }
                return _result;
            }
        }
    }
}
"@ -ErrorAction Stop

$checkInterval = 8        # 5s → 8s：给 TLS 探测留时间
$tcpTimeout = 3000        # TCP 连接超时
$tlsTimeout = 2000        # TLS 握手超时
$maxAllFail = 3
$maxFullUpdates = 3       # 连续全量更新 N 次仍不通则退避，避免无效循环
$backoffInterval = 60     # 退避检查间隔（秒）
$hysteresisThreshold = 3  # 连续 N 次失败才重排（=24s），避免被瞬时抖动触发
$reorderCooldown = 60     # 切换后 60s 内不再切，避免 IP 互相抖动时来回切
$rttThreshold = 200       # 候选 IP 间 RTT 差距 < 200ms 不切换，避免无意义切换

function Write-WatchLog {
    param([string]$Msg)
    try {
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        [System.IO.File]::AppendAllText($logPath, "$ts $Msg`r`n", [System.Text.Encoding]::UTF8)
        $log = Get-Item $logPath -ErrorAction SilentlyContinue
        if ($log -and $log.Length -gt 512KB) {
            $lines = Get-Content $logPath -Tail 100
            [System.IO.File]::WriteAllLines("$logPath.tmp", $lines, [System.Text.Encoding]::UTF8)
            Move-Item "$logPath.tmp" $logPath -Force
        }
    } catch {}
}

# TCP 快筛 + TLS 终判：返回 RTT 毫秒数
# -1 = TCP 不通, -2 = TCP 通但 TLS 失败（SNI 阻断等）
# 底层由 C# 编译的 TlsChecker 实现，异步 + 超时 + 不崩溃
function Test-TcpQuick([string]$Ip, [int]$TimeoutMs, [string]$SniName) {
    try {
        return [TlsChecker]::CheckTls($Ip, 443, $SniName, $TimeoutMs, $tlsTimeout)
    } catch {
        return -1
    }
}

$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0)) {
    Write-Host "Watchdog already running" -ForegroundColor Yellow
    exit 0
}

try {
    $currentPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
    if (Test-Path $pidFilePath) {
        $oldPid = (Get-Content $pidFilePath -Raw -ErrorAction SilentlyContinue).Trim()
        if ($oldPid -match '^\d+$' -and (Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue)) {
            Write-WatchLog "FATAL: Watchdog already running (PID $oldPid), exiting"
            exit 1
        }
        Remove-Item $pidFilePath -Force -ErrorAction SilentlyContinue
    }
    try { [System.IO.File]::WriteAllText($pidFilePath, "$currentPid", [System.Text.Encoding]::UTF8) } catch { Write-WatchLog "FATAL: Cannot write PID file: $_"; exit 1 }
    Write-WatchLog "=== Watchdog started (interval=${checkInterval}s, tcpTimeout=${tcpTimeout}ms, tlsTimeout=${tlsTimeout}ms, hysteresis=${hysteresisThreshold}, cooldown=${reorderCooldown}s, rttThreshold=${rttThreshold}ms) ==="
    $consecutiveAllFail = 0
    $fullUpdateCount = 0
    $heartbeatCount = 0

    # 每个域名的连续失败计数（迟滞）+ 上次重排时间（冷却）+ 上次落盘的 top IP
    $domainState = @{}
    foreach ($d in $watchDomains) {
        $domainState[$d] = [PSCustomObject]@{ FailCount = 0; LastReorder = [DateTime]::MinValue; LastTopIP = $null; LastReplenish = [DateTime]::MinValue; LastUpdateTrigger = [DateTime]::MinValue }
    }

    while ($true) {
        try {
            $sleepSec = if ($fullUpdateCount -gt $maxFullUpdates) { $backoffInterval } else { $checkInterval }
            Start-Sleep -Seconds $sleepSec

            $heartbeatCount++
            if ($heartbeatCount % 30 -eq 0) {
                Write-WatchLog "heartbeat: alive (PID=$([System.Diagnostics.Process]::GetCurrentProcess().Id), uptime=$([math]::Round(((Get-Date)-$watchdogStartTime).TotalMinutes))min)"
            }

            $hostsContent = [System.IO.File]::ReadAllLines($hostsPath)
            $modified = $false
            $anyReachable = $false
            $needFlushDns = $false  # 仅 failover 时才 flushdns，rtt-improved 不刷新避免断连

            foreach ($domain in $watchDomains) {
                $domainLines = @()
                $domainIndices = @()
                for ($i = 0; $i -lt $hostsContent.Count; $i++) {
                    $line = $hostsContent[$i]
                    if ($line -match "^\s*(\S+)\s+(\S+)" -and $Matches[2] -eq $domain -and $line -notmatch "^\s*#") {
                        $domainLines += $line
                        $domainIndices += $i
                    }
                }

                if ($domainLines.Count -le 1) { continue }
                $st = $domainState[$domain]

                # TCP 快筛 + TLS 终判：>=0 表示 TLS 通，-1=TCP 不通，-2=TLS 阻断
                $ipResults = @()
                foreach ($dl in $domainLines) {
                    if ($dl -match "^\s*(\S+)\s+") {
                        $ip = $Matches[1]
                        $rtt = Test-TcpQuick $ip $tcpTimeout $domain
                        $ipResults += [PSCustomObject]@{IP=$ip; Line=$dl; RTT=$rtt}
                    }
                }

                $reachCount = ($ipResults | Where-Object { $_.RTT -ge 0 }).Count
                if ($reachCount -gt 0) { $anyReachable = $true }

                $firstRtt = $ipResults[0].RTT
                $laterReachable = ($ipResults[1..($ipResults.Count-1)] | Where-Object { $_.RTT -ge 0 } | Measure-Object).Count -gt 0

                # 迟滞：top IP 不通时累计失败次数，连续 N 次才考虑切换
                if ($firstRtt -lt 0) {
                    $st.FailCount++
                } else {
                    if ($st.FailCount -gt 0) { Write-WatchLog "$domain top IP recovered, failCount reset" }
                    $st.FailCount = 0
                }

                # 切换条件：top 连续失败达阈值 & 后面有通的 & 已过冷却期
                $canReorder = ($st.FailCount -ge $hysteresisThreshold) -and $laterReachable -and ((Get-Date) - $st.LastReorder).TotalSeconds -ge $reorderCooldown

                # RTT 优化排序：top IP 虽通，但有其他 IP RTT 显著更优（差 > rttThreshold）也切换
                # CDN 域名跳过：所有 IP 指向同一 Fastly CDN 边缘，RTT 差异=抖动，切换无意义且导致频繁写 hosts
                $rttImproved = $false
                if ($firstRtt -ge 0 -and $reachCount -gt 1 -and ((Get-Date) - $st.LastReorder).TotalSeconds -ge 30 -and ($cdnDomains -notcontains $domain)) {
                    $bestOther = ($ipResults[1..($ipResults.Count-1)] | Where-Object { $_.RTT -ge 0 } | Sort-Object RTT | Select-Object -First 1)
                    if ($bestOther -and ($firstRtt - $bestOther.RTT) -gt $rttThreshold) {
                        $rttImproved = $true
                    }
                }

                if (-not $canReorder -and -not $rttImproved) { continue }

                $unreachableLines = $ipResults | Where-Object { $_.RTT -lt 0 }
                $reachableLines = $ipResults | Where-Object { $_.RTT -ge 0 } | Sort-Object RTT | Select-Object -ExpandProperty Line

                if ($unreachableLines) {
                    $uIPs = ($unreachableLines | ForEach-Object { if ($_.Line -match "^\s*(\S+)") { $Matches[1] } }) -join ","
                    Write-WatchLog "$domain removing unreachable IPs: [$uIPs]"
                    foreach ($ul in $unreachableLines) {
                        $idx = [Array]::IndexOf($hostsContent, $ul.Line)
                        if ($idx -ge 0) { $hostsContent[$idx] = $null }
                    }
                    $hostsContent = $hostsContent | Where-Object { $_ -ne $null }
                    $modified = $true

                }

                if ($reachableLines) {
                    if ($reachableLines[0] -match "^\s*(\S+)\s+") { $newTopIP = $Matches[1] } else { $newTopIP = $null }
                    if ($newTopIP -ne $st.LastTopIP) { $needFlushDns = $true }
                    $st.LastTopIP = $newTopIP
                }

                $st.LastReorder = Get-Date
                $st.FailCount = 0

                $rIPs = ($ipResults | Where-Object { $_.RTT -ge 0 } | Sort-Object RTT | Select-Object -ExpandProperty IP) -join ","
                $rRtts = ($ipResults | Where-Object { $_.RTT -ge 0 } | Sort-Object RTT | ForEach-Object { "$($_.IP)=$($_.RTT)ms" }) -join " "
                $tlsBlocked = ($ipResults | Where-Object { $_.RTT -eq -2 } | Select-Object -ExpandProperty IP) -join ","
                $logExtra = if ($tlsBlocked) { " tls-blocked=[$tlsBlocked]" } else { "" }
                Write-WatchLog "$domain failover: up=[$rIPs] rtt=[$rRtts]$logExtra"
            }

            # DNS补充+自救闭环：IP数<2时尝试恢复
            # 1) DNS补充可达IP  2) DNS补充失败→触发update  3) 最后1个IP不通→删行走DNS
            # 冷却60秒(DNS)+2分钟(update触发) 防刷
            foreach ($domain in $watchDomains) {
                $st = $domainState[$domain]
                if (((Get-Date) - $st.LastReplenish).TotalSeconds -lt 60) { continue }
                $currentDomainLines = @()
                for ($i = 0; $i -lt $hostsContent.Count; $i++) {
                    $line = $hostsContent[$i]
                    if ($line -match "^\s*(\S+)\s+(\S+)" -and $Matches[2] -eq $domain -and $line -notmatch "^\s*#") {
                        $currentDomainLines += $line
                    }
                }
                if ($currentDomainLines.Count -ge 2) { continue }

                # 只有1个IP且不通→保留不删，避免0个IP彻底断网；继续走DNS补充+触发update补救
                if ($currentDomainLines.Count -eq 1) {
                    $onlyIp = if ($currentDomainLines[0] -match "^\s*(\S+)\s+") { $Matches[1] } else { "" }
                    $onlyRtt = Test-TcpQuick $onlyIp $tcpTimeout $domain
                    if ($onlyRtt -lt 0) {
                        Write-WatchLog "$domain last IP $onlyIp unreachable, keeping (avoid 0-IP state, will try DNS supplement + update)"
                    }
                }

                # 1个IP且通或0个IP→尝试DNS补充到2个
                Write-WatchLog "$domain has $($currentDomainLines.Count) IP(s) in hosts, DNS resolving to replenish"
                $dnsSupplementOk = $false
                try {
                    $dnsIps = [System.Net.Dns]::GetHostAddresses($domain) | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { $_.ToString() }
                    $existingIps = @()
                    foreach ($dl in $currentDomainLines) {
                        if ($dl -match "^\s*(\S+)\s+") { $existingIps += $Matches[1] }
                    }
                    $newIps = $dnsIps | Where-Object { $_ -notin $existingIps }
                    if ($newIps.Count -eq 0) {
                        Write-WatchLog "$domain DNS returned no new IPs"
                        $st.LastReplenish = Get-Date
                    } else {
                        $supplemented = @()
                        foreach ($nip in $newIps) {
                            $nrtt = Test-TcpQuick $nip $tcpTimeout $domain
                            if ($nrtt -ge 0) {
                                $newLine = "$nip`t`t$domain"
                                $hostsContent += $newLine
                                $supplemented += "$nip=${nrtt}ms"
                                if (($currentDomainLines.Count + $supplemented.Count) -ge 2) { break }
                            }
                        }
                        if ($supplemented.Count -gt 0) {
                            $st.LastReplenish = Get-Date
                            $modified = $true
                            $needFlushDns = $true
                            $dnsSupplementOk = $true
                            Write-WatchLog "$domain DNS replenished: $($supplemented -join ', ')"
                        } else {
                            Write-WatchLog "$domain DNS returned $($newIps.Count) new IP(s), all unreachable"
                            $st.LastReplenish = Get-Date
                        }
                    }
                } catch {
                    Write-WatchLog "$domain DNS resolve for replenish failed: $_"
                    $st.LastReplenish = Get-Date
                }

                # DNS补充失败→触发update（2分钟冷却）
                if (-not $dnsSupplementOk -and ((Get-Date) - $st.LastUpdateTrigger).TotalSeconds -ge 120) {
                    Write-WatchLog "$domain DNS supplement failed, triggering update to restore IPs"
                    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$updateScript`"" -WindowStyle Hidden
                    $st.LastUpdateTrigger = Get-Date
                }
            }


            if ($modified) {
                $updateMutex = $null
                $gotUpdateMutex = $false
                try {
                    $updateMutex = New-Object System.Threading.Mutex($false, "Local\GitHubHostsUpdate")
                    $gotUpdateMutex = $updateMutex.WaitOne(5000)
                    if (-not $gotUpdateMutex) { Write-WatchLog "Update running, skipping hosts write this cycle" }
                } catch { $gotUpdateMutex = $false }
                if ($gotUpdateMutex) {
                    try {
                        $tmpPath = "$hostsPath.wdtmp"
                        [System.IO.File]::WriteAllLines($tmpPath, $hostsContent, (New-Object System.Text.UTF8Encoding $false))
                        Move-Item $tmpPath $hostsPath -Force
                    } finally {
                        try { $updateMutex.ReleaseMutex() } catch {}
                        try { $updateMutex.Dispose() } catch {}
                    }
                }
                if ($needFlushDns) {
                    ipconfig /flushdns | Out-Null
                    Write-WatchLog "Hosts modified (top IP changed), DNS flushed"
                } else {
                    Write-WatchLog "Hosts modified (unreachable IPs removed), DNS not flushed to avoid disruption"
                }
            }

            if (-not $anyReachable) {
                $consecutiveAllFail++
                if ($consecutiveAllFail -ge $maxAllFail) {
                    $fullUpdateCount++
                    if ($fullUpdateCount -le $maxFullUpdates) {
                        Write-WatchLog "All IPs unreachable x$consecutiveAllFail, triggering full update ($fullUpdateCount/$maxFullUpdates)"
                        Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$updateScript`"" -WindowStyle Hidden
                    } elseif ($fullUpdateCount -eq $maxFullUpdates + 1) {
                        Write-WatchLog "All IPs still unreachable after $maxFullUpdates updates, entering backoff (check every ${backoffInterval}s)"
                    }
                    $consecutiveAllFail = 0
                }
            } else {
                if ($fullUpdateCount -gt 0) {
                    Write-WatchLog "Network recovered, resuming normal interval ($checkInterval s)"
                }
                $consecutiveAllFail = 0
                $fullUpdateCount = 0
            }

        } catch {
            Write-WatchLog "Error: $_"
            Start-Sleep -Seconds 10
        }
    }
} finally {
    Write-WatchLog "=== Watchdog stopped ==="
    try { $mutex.ReleaseMutex() } catch {}
    try { $mutex.Dispose() } catch {}
}
'@

New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null

Remove-Item "$scriptDir\update_github_hosts.sha256" -Force -ErrorAction SilentlyContinue
Remove-Item "$scriptDir\update.lock" -Force -ErrorAction SilentlyContinue

try {
    $dirAcl = Get-Acl $scriptDir
    $dirAcl.SetAccessRuleProtection($true, $true)
    $adminAccess = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $systemAccess = New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $usersAccess = New-Object System.Security.AccessControl.FileSystemAccessRule("Users", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
    $dirAcl.AddAccessRule($adminAccess)
    $dirAcl.AddAccessRule($systemAccess)
    $dirAcl.AddAccessRule($usersAccess)
    Set-Acl $scriptDir $dirAcl
    Write-Host "Script directory ACL hardened (Admin/SYSTEM: Full, Users: Read)" -ForegroundColor Green
} catch {
    Write-Host "Warning: Could not set ACL on script directory: $_" -ForegroundColor Yellow
}

if (-not ([System.Diagnostics.EventLog]::SourceExists("GitHubHosts"))) {
    [System.Diagnostics.EventLog]::CreateEventSource("GitHubHosts", "Application")
    Write-Host "Event log source 'GitHubHosts' registered" -ForegroundColor Green
}

$backupParent = Split-Path $originalHostsBackup -Parent
New-Item -ItemType Directory -Path $backupParent -Force | Out-Null

Copy-Item -Path $hostsPath -Destination $originalHostsBackup -Force
Write-Host "Original hosts backed up" -ForegroundColor Green

[System.IO.File]::WriteAllText($scriptPath, $updateScript, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Script installed to $scriptPath" -ForegroundColor Green

$scriptHash = (Get-FileHash $scriptPath -Algorithm SHA256).Hash
$regKey = "HKLM:\SOFTWARE\GitHubHosts"
if (-not (Test-Path $regKey)) { New-Item -Path $regKey -Force | Out-Null }
Set-ItemProperty -Path $regKey -Name "ScriptHash" -Value $scriptHash -Type String -Force
$acl = Get-Acl $regKey
$acl.SetAccessRuleProtection($true, $true)
$adminRule = New-Object System.Security.AccessControl.RegistryAccessRule("Administrators", "FullControl", "Allow")
$systemRule = New-Object System.Security.AccessControl.RegistryAccessRule("SYSTEM", "FullControl", "Allow")
$usersRule = New-Object System.Security.AccessControl.RegistryAccessRule("Users", "ReadKey", "Allow")
$acl.AddAccessRule($adminRule)
$acl.AddAccessRule($systemRule)
$acl.AddAccessRule($usersRule)
Set-Acl $regKey $acl
Write-Host "Script integrity hash saved to registry (ACL protected)" -ForegroundColor Green

Unregister-ScheduledTask -TaskName "UpdateGitHubHosts" -Confirm:$false -ErrorAction SilentlyContinue

$psExe = "powershell.exe"
$pwshPath = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if ($pwshPath) { $psExe = $pwshPath }

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Auto update GitHub hosts with verification</Description>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>

  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
  </Settings>
  <Triggers>
    <TimeTrigger>
      <Repetition>
        <Interval>PT1H</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
    <BootTrigger>
      <Enabled>true</Enabled>
      <Delay>PT2M</Delay>
    </BootTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>$psExe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File "$scriptPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$watchdogPath = "$scriptDir\github_hosts_watchdog.ps1"
[System.IO.File]::WriteAllText($watchdogPath, $watchdogScript, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Watchdog script installed to $watchdogPath" -ForegroundColor Green

$xmlPath = "$scriptDir\task.xml"
$xml | Out-File -FilePath $xmlPath -Encoding unicode -Force
schtasks /create /tn "UpdateGitHubHosts" /xml $xmlPath /f

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "=== Install Complete ===" -ForegroundColor Green
    Write-Host "Task: UpdateGitHubHosts (hourly + boot)" -ForegroundColor Cyan
    Write-Host "Script: $scriptPath" -ForegroundColor Cyan
    Write-Host "Log: $scriptDir\update.log" -ForegroundColor Cyan
    Write-Host "Backup: C:\ProgramData\ScriptBackup\GitHubHosts\backup\" -ForegroundColor Cyan
    Write-Host "Original hosts: $originalHostsBackup" -ForegroundColor Cyan
    Write-Host "Note: If GitHub still unreachable after update, restart your browser to clear its DNS cache." -ForegroundColor Yellow
    Write-Host "Restore: Run 'powershell -File \"$scriptPath\" -Restore' to rollback to a previous hosts backup." -ForegroundColor Yellow
    Write-Host ""

    # 记住 watchdog 是否已启用，重装后恢复
    $wasEnabled = $false
    try { $wasEnabled = (Get-ScheduledTask -TaskName "GitHubHostsWatchdog" -ErrorAction Stop).Enabled } catch {}

    $watchdogXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>GitHub Hosts Watchdog - real-time IP failover</Description>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>false</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
  </Settings>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
      <Delay>PT1M</Delay>
    </BootTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>$psExe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File "$watchdogPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    $watchdogXmlPath = "$scriptDir\watchdog_task.xml"
    $watchdogXml | Out-File -FilePath $watchdogXmlPath -Encoding unicode -Force
    schtasks /create /tn "GitHubHostsWatchdog" /xml $watchdogXmlPath /f | Out-Null

    # 创建监视器任务：每 5 分钟检查 watchdog 是否存活，崩溃后自动重启
    $monitorScript = @'
$watchdogTask = "GitHubHostsWatchdog"
$watchdogScript = "C:\ProgramData\GitHubHosts\github_hosts_watchdog.ps1"
$monitorLog = "C:\ProgramData\GitHubHosts\watchdog_monitor.log"
$pidFile = "C:\ProgramData\GitHubHosts\watchdog.pid"

$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
try {
    # 检查 watchdog 进程是否存活
    $wdProc = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*github_hosts_watchdog*" -and $_.CommandLine -notlike "*-Status*" -and $_.CommandLine -notlike "*-Start*" -and $_.CommandLine -notlike "*-Stop*" }
    if (-not $wdProc -and (Test-Path $pidFile)) {
        $savedPid = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($savedPid -match '^\d+$') { $wdProc = Get-Process -Id ([int]$savedPid) -ErrorAction SilentlyContinue }
    }
    if (-not $wdProc) {
        # 检查 watchdog 任务是否启用
        $taskEnabled = $false
        try {
            $task = Get-ScheduledTask -TaskName $watchdogTask -ErrorAction Stop
            $taskEnabled = $task.Enabled
        } catch {
            $sq = schtasks /query /tn $watchdogTask /fo LIST 2>&1
            if ($sq -match "Status:\s*Disabled") { $taskEnabled = $false } else { $taskEnabled = $true }
        }
        if ($taskEnabled) {
            Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$watchdogScript`"" -WindowStyle Hidden
            "$ts Watchdog not running, restarted" | Out-File $monitorLog -Append -Encoding UTF8
        }
    }
} catch {
    "$ts Monitor error: $_" | Out-File $monitorLog -Append -Encoding UTF8
}
'@
    $monitorScriptPath = "$scriptDir\watchdog_monitor.ps1"
    $monitorScript | Out-File -FilePath $monitorScriptPath -Encoding unicode -Force
    $monitorXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>GitHub Hosts Watchdog Monitor - restarts watchdog if crashed</Description>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
  </Settings>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
      <Repetition>
        <Interval>PT5M</Interval>
        <Duration>P1D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </CalendarTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>$psExe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File "$monitorScriptPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    $monitorXmlPath = "$scriptDir\watchdog_monitor_task.xml"
    $monitorXml | Out-File -FilePath $monitorXmlPath -Encoding unicode -Force
    schtasks /create /tn "GitHubHostsWatchdogMonitor" /xml $monitorXmlPath /f | Out-Null
    Write-Host "Monitor task created: checks watchdog every 5min, auto-restarts if crashed" -ForegroundColor Cyan

    # 如果之前 watchdog 已启用，恢复启用状态（不因重装而丢失）
    if ($wasEnabled) {
        try { Enable-ScheduledTask -TaskName "GitHubHostsWatchdog" -ErrorAction Stop } catch { schtasks /change /tn "GitHubHostsWatchdog" /enable 2>&1 | Out-Null }
        try { "Ready", "On" | Out-File "C:\ProgramData\GitHubHosts\watchdog_task_state.txt" -Encoding UTF8 -Force } catch {}
        Write-Host "Watchdog: re-enabled (was previously enabled)" -ForegroundColor Green
    } else {
        try { "Disabled", "Off" | Out-File "C:\ProgramData\GitHubHosts\watchdog_task_state.txt" -Encoding UTF8 -Force } catch {}
        Write-Host "Watchdog: installed (disabled by default)" -ForegroundColor Cyan
    }
    Write-Host "  Enable: powershell -File `"$watchdogPath`" -Start" -ForegroundColor Gray
    Write-Host "  Disable: powershell -File `"$watchdogPath`" -Stop" -ForegroundColor Gray
    Write-Host "  Status:  powershell -File `"$watchdogPath`" -Status" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Enable watchdog now? It monitors IP reachability and reorders hosts for instant failover." -ForegroundColor Yellow
    Write-Host "Type 'y' to enable, or Enter to skip." -ForegroundColor Yellow
    $wdChoice = Read-Host
    if ($wdChoice -eq "y" -or $wdChoice -eq "Y") {
        $oldWd = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*github_hosts_watchdog*" -and $_.CommandLine -notlike "*-Status*" -and $_.CommandLine -notlike "*-Start*" -and $_.CommandLine -notlike "*-Stop*" } | ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
        if (-not $oldWd -and (Test-Path "C:\ProgramData\GitHubHosts\watchdog.pid")) {
            $savedPid = (Get-Content "C:\ProgramData\GitHubHosts\watchdog.pid" -Raw -ErrorAction SilentlyContinue).Trim()
            if ($savedPid -match '^\d+$') { $oldWd = Get-Process -Id ([int]$savedPid) -ErrorAction SilentlyContinue }
        }
        if ($oldWd) { $oldWd | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1 }
        try { Enable-ScheduledTask -TaskName "GitHubHostsWatchdog" -ErrorAction Stop } catch { schtasks /change /tn "GitHubHostsWatchdog" /enable 2>&1 | Out-Null }
        # 以当前用户身份直接启动（不用 schtasks /run，避免 SYSTEM 账户网络问题）
        Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$watchdogPath`"" -WindowStyle Hidden
        try { "Ready", "On" | Out-File "C:\ProgramData\GitHubHosts\watchdog_task_state.txt" -Encoding UTF8 -Force } catch {}
        Write-Host "Watchdog enabled and started" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Press Enter to trigger first update now (make sure network is ready)," -ForegroundColor Yellow
    Write-Host "or type 's' then Enter to skip and run later automatically." -ForegroundColor Yellow
    $choice = Read-Host
    if ($choice -ne "s" -and $choice -ne "S") {
        Write-Host "Running first update..." -ForegroundColor Cyan
        $psExe = "powershell.exe"
        $pwshPath = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
        if ($pwshPath) { $psExe = $pwshPath }
        $proc = Start-Process $psExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -NoNewWindow -PassThru -Wait
        if ($proc.ExitCode -eq 0) {
            Write-Host "First run completed successfully!" -ForegroundColor Green
        } else {
            Write-Host "First run finished with exit code: $($proc.ExitCode)" -ForegroundColor Yellow
        }
        if (Test-Path "$scriptDir\update.log") {
            Write-Host ""
            Write-Host "=== Last 15 log lines ===" -ForegroundColor Cyan
            Get-Content "$scriptDir\update.log" -Tail 15 | ForEach-Object { Write-Host $_ }
        }

    } else {
        Write-Host "Skipped. Task will run on next scheduled trigger." -ForegroundColor Cyan
    }
} else {
    Write-Host "Failed to create scheduled task" -ForegroundColor Red
}

Read-Host "Press Enter to exit"
