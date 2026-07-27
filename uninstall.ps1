$scriptDir = "C:\ProgramData\GitHubHosts"
$hostsPath = "C:\Windows\System32\drivers\etc\hosts"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "Error: PowerShell 5.1+ is required (current: $($PSVersionTable.PSVersion)). Please install WMF 5.1." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Error: Please right-click -> Run as Administrator" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "Uninstalling GitHub Hosts Auto-Update..." -ForegroundColor Yellow
Write-Host ""

Stop-ScheduledTask -TaskName "UpdateGitHubHosts" -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Unregister-ScheduledTask -TaskName "UpdateGitHubHosts" -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "[1/6] Update task removed" -ForegroundColor Cyan

Stop-ScheduledTask -TaskName "GitHubHostsWatchdog" -ErrorAction SilentlyContinue
$wdProc = Get-Process powershell,pwsh -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*github_hosts_watchdog*" }
if (-not $wdProc) {
    $pidFile = "C:\ProgramData\GitHubHosts\watchdog.pid"
    if (Test-Path $pidFile) {
        $savedPid = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($savedPid -match '^\d+$') { $wdProc = Get-Process -Id ([int]$savedPid) -ErrorAction SilentlyContinue }
    }
}
if ($wdProc) { $wdProc | Stop-Process -Force -ErrorAction SilentlyContinue }
Unregister-ScheduledTask -TaskName "GitHubHostsWatchdog" -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "[2/6] Watchdog stopped and task removed" -ForegroundColor Cyan

Stop-ScheduledTask -TaskName "GitHubHostsWatchdogMonitor" -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "GitHubHostsWatchdogMonitor" -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "[3/6] Watchdog monitor stopped and task removed" -ForegroundColor Cyan

$backupDir = "C:\ProgramData\ScriptBackup\GitHubHosts"
$uninstallBackup = "$backupDir\hosts.before_uninstall"
$backupParent = Split-Path $uninstallBackup -Parent
if (-not (Test-Path $backupParent)) { New-Item -ItemType Directory -Path $backupParent -Force | Out-Null }
Copy-Item -Path $hostsPath -Destination $uninstallBackup -Force
Write-Host "[4/7] Current hosts backed up to $uninstallBackup" -ForegroundColor Cyan

$installedScript = "$scriptDir\update_github_hosts.ps1"
$githubDomains = @()
if (Test-Path $installedScript) {
    $scriptText = Get-Content $installedScript -Raw -ErrorAction SilentlyContinue
    if ($scriptText -match 'githubDomainPatterns\s*=\s*@\(([^)]+)\)') {
        $githubDomains = $Matches[1] -split ',' | ForEach-Object { ($_ -replace '"','' -replace '\\','' -replace '\s','').Trim() } | Where-Object { $_ -ne '' }
    }
}
if ($githubDomains.Count -eq 0) {
    $githubDomains = @("github.com","gist.github.com","api.github.com","github.githubassets.com","avatars.githubusercontent.com","codeload.github.com","objects.githubusercontent.com","media.githubusercontent.com","camo.githubusercontent.com","user-images.githubusercontent.com","docs.github.com","raw.githubusercontent.com","github.global.ssl.fastly.net","assets-cdn.github.com","collector.github.com","alive.github.com","pages.github.com","uploads.githubusercontent.com","github.cloud.github.com")
}
Write-Host "Cleaning $($githubDomains.Count) GitHub domains from hosts" -ForegroundColor Gray
$currentHosts = [System.IO.File]::ReadAllLines($hostsPath)
$filteredLines = @()
$inBlock = $false
foreach ($line in $currentHosts) {
    if ($line -match "GitHub520 Host Start") { $inBlock = $true; continue }
    if ($line -match "GitHub520 Host End") { $inBlock = $false; continue }
    if ($inBlock) { continue }
    $keep = $true
    foreach ($domain in $githubDomains) {
        if ($line -match ("^\s*\S+\s+" + [regex]::Escape($domain) + "(\s|$)")) { $keep = $false; break }
    }
    if ($keep) { $filteredLines += $line }
}
$finalContent = ($filteredLines -join "`r`n")
[System.IO.File]::WriteAllText($hostsPath, $finalContent, (New-Object System.Text.UTF8Encoding $false))
Write-Host "[5/7] GitHub hosts entries removed (including failover lines), custom entries preserved" -ForegroundColor Cyan

Remove-Item $scriptDir -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path $scriptDir) {
    Write-Host "Warning: Could not delete $scriptDir - files may be in use. Please delete manually." -ForegroundColor Yellow
} else {
    Write-Host "[6/7] Script directory removed" -ForegroundColor Cyan
}

try {
    $regKey = "HKLM:\SOFTWARE\GitHubHosts"
    if (Test-Path $regKey) {
        Remove-Item -Path $regKey -Force -ErrorAction SilentlyContinue
        Write-Host "Registry key removed: $regKey" -ForegroundColor Cyan
    }
} catch {
    Write-Host "Warning: Could not remove registry key: $_" -ForegroundColor Yellow
}

ipconfig /flushdns | Out-Null
Write-Host "[7/7] DNS cache flushed" -ForegroundColor Cyan

if (Test-Path $backupDir) {
    Write-Host ""
    Write-Host "Backup directory found: $backupDir" -ForegroundColor Yellow
    Write-Host "A pre-uninstall hosts snapshot was saved to $uninstallBackup" -ForegroundColor Cyan
    $choice = Read-Host "Delete rolling backup directory? (Y/n)"
    if ($choice -ne "n" -and $choice -ne "N") {
        Remove-Item $backupDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $backupDir) {
            Write-Host "Warning: Could not delete backup directory. Please delete manually: $backupDir" -ForegroundColor Yellow
        } else {
            Write-Host "Backup directory deleted" -ForegroundColor Cyan
        }
    } else {
        Write-Host "Backup directory kept: $backupDir" -ForegroundColor Cyan
    }
}

Write-Host ""
Write-Host "=== Uninstall Complete ===" -ForegroundColor Green
Read-Host "Press Enter to exit"