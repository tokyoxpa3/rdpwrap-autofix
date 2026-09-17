#Requires -Version 5.1
<#
.SYNOPSIS
    RDP Wrapper 自動修復 / 更新工具

.DESCRIPTION
    Windows 安裝安全性更新後 termsrv.dll 版本會改變，導致 RDP Wrapper 失效。
    本工具把「下載最新 rdpwrap.ini -> 套用 -> 必要時重新安裝 -> 重啟服務 -> 驗證」
    整合成一個步驟，不需要再手動跑 uninstall.bat / install.bat / reinstall.bat。

.PARAMETER Mode
    Menu           顯示互動選單（預設）
    Check          只顯示目前狀態，不做任何變更
    Auto           靜默自動修復：只有在目前 ini 不支援 termsrv.dll 版本時才動作
    Update         下載最新 ini；若內容相同且可用，就不重啟服務
    Force          無條件下載最新 ini、重新套用並重啟服務
    Reinstall      完整重新安裝（uninstall -> install -> 套用 ini -> 重啟）
    RegisterTask   建立登入／每日自動修復排程
    UnregisterTask 移除自動修復排程

.PARAMETER Source
    自訂 rdpwrap.ini 來源網址（省略則依序嘗試內建的多個鏡像）。

.PARAMETER Yes
    不詢問任何確認，直接執行。

.EXAMPLE
    .\RDPWrap-AutoFix.ps1 -Mode Check
    .\RDPWrap-AutoFix.ps1 -Mode Auto
    .\RDPWrap-AutoFix.ps1 -Mode Force -Yes

.NOTES
    需要系統管理員權限；未提權時會自動要求提權。
    專案首頁：https://github.com/tokyoxpa3/rdpwrap-autofix
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Auto', 'Check', 'Update', 'Force', 'Reinstall', 'RegisterTask', 'UnregisterTask')]
    [string]$Mode = 'Menu',

    [string]$Source,

    [switch]$Yes
)

try {
    & chcp.com 65001 > $null
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
} catch { }

$ErrorActionPreference = 'Stop'

$script:ToolVersion = '1.0.0'
$script:Root        = $PSScriptRoot
$script:LogPath     = Join-Path $script:Root 'RDPWrap-AutoFix.log'
$script:BackupDir   = Join-Path $script:Root 'backup'
$script:TaskName    = 'RDPWrap AutoFix'
$script:PkgIni      = Join-Path $script:Root 'rdpwrap.ini'
$script:Installer   = Join-Path $script:Root 'RDPWInst.exe'
$script:IsRdpSession = ($env:SESSIONNAME -like 'RDP*')

# sebaxakerhtc 維護的 ini；GitHub 連不上時依序改用鏡像站
$script:IniUrls = @(
    'https://raw.githubusercontent.com/sebaxakerhtc/rdpwrap.ini/master/rdpwrap.ini',
    'https://cdn.jsdelivr.net/gh/sebaxakerhtc/rdpwrap.ini@master/rdpwrap.ini',
    'https://raw.gitmirror.com/sebaxakerhtc/rdpwrap.ini/master/rdpwrap.ini',
    'https://ghproxy.net/https://raw.githubusercontent.com/sebaxakerhtc/rdpwrap.ini/master/rdpwrap.ini',
    'https://gh-proxy.com/https://raw.githubusercontent.com/sebaxakerhtc/rdpwrap.ini/master/rdpwrap.ini'
)

# 只有在需要完整重裝時才會用到安裝程式，屆時才向官方來源索取
$script:InstallerUrls = @(
    'https://github.com/stascorp/rdpwrap/releases/download/v1.6.2/RDPWrap-v1.6.2.zip',
    'https://ghproxy.net/https://github.com/stascorp/rdpwrap/releases/download/v1.6.2/RDPWrap-v1.6.2.zip',
    'https://gh-proxy.com/https://github.com/stascorp/rdpwrap/releases/download/v1.6.2/RDPWrap-v1.6.2.zip'
)

# ---------------------------------------------------------------- 輸出 / 記錄

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = "[$stamp][$Level] $Message"
    switch ($Level) {
        'OK'    { Write-Host $line -ForegroundColor Green }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'STEP'  { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
}

function Confirm-Action {
    param([Parameter(Mandatory)][string]$Message)
    if ($Yes -or $Mode -eq 'Auto') { return $true }
    $answer = Read-Host "$Message [Y/N]"
    return ($answer -match '^(y|yes)$')
}

function Initialize-Tls {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch { }
}

# -------------------------------------------------------------------- 環境偵測

function Test-Admin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevate {
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-Mode', $Mode
    )
    if ($Source) { $arguments += @('-Source', "`"$Source`"") }
    if ($Yes)    { $arguments += '-Yes' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs | Out-Null
}

function Get-WindowsBuild {
    try {
        $key   = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $build = [string]$key.CurrentBuildNumber
        if ($key.UBR) { $build = "$build.$($key.UBR)" }
        return $build
    } catch {
        return '未知'
    }
}

function Get-TermsrvVersion {
    $file = Join-Path $env:SystemRoot 'System32\termsrv.dll'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $vi = (Get-Item -LiteralPath $file).VersionInfo
    return "$($vi.FileMajorPart).$($vi.FileMinorPart).$($vi.FileBuildPart).$($vi.FilePrivatePart)"
}

function Get-WrapperInstall {
    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters'

    $dll = $null
    try {
        $dll = (Get-ItemProperty -LiteralPath $regPath -Name 'ServiceDll' -ErrorAction Stop).ServiceDll
    } catch {
        $dll = $null
    }

    $expanded = $null
    if ($dll) { $expanded = [Environment]::ExpandEnvironmentVariables($dll) }

    $dir = Join-Path ${env:ProgramFiles} 'RDP Wrapper'
    if ($expanded) { $dir = Split-Path -Parent $expanded }

    $isInstalled = $false
    if ($dll -and $dll -match 'rdpwrap\.dll' -and $expanded -and (Test-Path -LiteralPath $expanded)) {
        $isInstalled = $true
    }

    return [pscustomobject]@{
        ServiceDll  = $dll
        DllFile     = $expanded
        Dir         = $dir
        IniPath     = Join-Path $dir 'rdpwrap.ini'
        IsInstalled = $isInstalled
    }
}

function Get-IniInfo {
    param([Parameter(Mandatory)][string]$Path)

    $info = [pscustomobject]@{
        Exists  = $false
        Path    = $Path
        Updated = ''
        Builds  = @()
        Size    = 0
        Text    = ''
    }

    if (-not (Test-Path -LiteralPath $Path)) { return $info }

    $bytes = [IO.File]::ReadAllBytes($Path)
    $text  = [Text.Encoding]::UTF8.GetString($bytes)

    $info.Exists = $true
    $info.Size   = $bytes.Length
    $info.Text   = $text

    $m = [regex]::Match($text, '(?m)^\s*Updated\s*=\s*(\S+)')
    if ($m.Success) { $info.Updated = $m.Groups[1].Value }

    $info.Builds = @(
        [regex]::Matches($text, '(?m)^\[(\d+\.\d+\.\d+\.\d+)\]') |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique
    )

    return $info
}

function Get-Status {
    $version   = Get-TermsrvVersion
    $wrapper   = Get-WrapperInstall
    $installed = Get-IniInfo -Path $wrapper.IniPath

    $svc = Get-Service -Name TermService -ErrorAction SilentlyContinue
    $svcStatus = $null
    if ($svc) { $svcStatus = $svc.Status }

    $supports = $false
    if ($version -and $installed.Builds -contains $version) { $supports = $true }

    return [pscustomobject]@{
        Build         = Get-WindowsBuild
        Termsrv       = $version
        WrapperDir    = $wrapper.Dir
        WrapperOk     = $wrapper.IsInstalled
        IniPath       = $wrapper.IniPath
        IniExists     = $installed.Exists
        IniUpdated    = $installed.Updated
        IniSupports   = $supports
        ServiceStatus = $svcStatus
    }
}

function Show-Status {
    $s = Get-Status

    $wrapperText = '未安裝 / 不完整'
    if ($s.WrapperOk) { $wrapperText = "已安裝 ($($s.WrapperDir))" }

    $supportText = '否（RDP 目前應該是失效的）'
    if ($s.IniSupports) { $supportText = '是' }

    Write-Host ''
    Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host " Windows 組建     : $($s.Build)"
    Write-Host " termsrv.dll      : $($s.Termsrv)"
    Write-Host " Wrapper 狀態     : $wrapperText"
    Write-Host " 目前 ini 版本    : $($s.IniUpdated)"
    Write-Host " ini 支援此組建   : $supportText"
    Write-Host " Terminal Services: $($s.ServiceStatus)"
    Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host ''
    return $s
}

# ------------------------------------------------------------------ ini 下載

function Test-IniText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Text.Length -lt 100000) { return $false }
    if ($Text -notmatch '(?m)^\[Main\]') { return $false }
    if ($Text -notmatch '(?m)^\[PatchCodes\]') { return $false }
    if ($Text -notmatch '(?m)^\s*Updated\s*=') { return $false }
    return $true
}

function Get-NormalizedIni {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text[0] -eq [char]0xFEFF) { $Text = $Text.Substring(1) }
    return ($Text -replace "`r`n", "`n").TrimEnd()
}

function Get-RemoteIni {
    param([Parameter(Mandatory)][string[]]$Urls)

    Initialize-Tls

    foreach ($url in $Urls) {
        try {
            Write-Log "下載中：$url" 'STEP'
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 45 `
                                          -Headers @{ 'User-Agent' = "RDPWrap-AutoFix/$($script:ToolVersion)" } `
                                          -ErrorAction Stop
            $text = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())

            if (-not (Test-IniText -Text $text)) {
                Write-Log '內容驗證失敗，略過此來源。' 'WARN'
                continue
            }

            $updated = ''
            $m = [regex]::Match($text, '(?m)^\s*Updated\s*=\s*(\S+)')
            if ($m.Success) { $updated = $m.Groups[1].Value }

            $builds = @(
                [regex]::Matches($text, '(?m)^\[(\d+\.\d+\.\d+\.\d+)\]') |
                    ForEach-Object { $_.Groups[1].Value } |
                    Sort-Object -Unique
            )

            return [pscustomobject]@{
                Url     = $url
                Text    = $text
                Updated = $updated
                Builds  = $builds
                Size    = $text.Length
            }
        } catch {
            Write-Log "失敗：$($_.Exception.Message)" 'WARN'
        }
    }

    return $null
}

# ------------------------------------------------------------------ ini 套用

function Remove-OldBackups {
    param([int]$Keep = 10)
    if (-not (Test-Path -LiteralPath $script:BackupDir)) { return }
    Get-ChildItem -LiteralPath $script:BackupDir -Filter 'rdpwrap.ini.*.bak' |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $Keep |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

function Save-IniText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$InstallDir
    )

    if (-not (Test-Path -LiteralPath $script:BackupDir)) {
        New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
    }

    $target = Join-Path $InstallDir 'rdpwrap.ini'

    if (Test-Path -LiteralPath $target) {
        $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = Join-Path $script:BackupDir "rdpwrap.ini.$stamp.bak"
        Copy-Item -LiteralPath $target -Destination $backup -Force
        Write-Log "已備份舊 ini -> $backup"
    }

    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($target, $Text, $utf8NoBom)
    Write-Log "已寫入 ini：$target" 'OK'

    if (-not [string]::Equals($target, $script:PkgIni, 'OrdinalIgnoreCase')) {
        [IO.File]::WriteAllText($script:PkgIni, $Text, $utf8NoBom)
        Write-Log "已同步更新本機 ini：$script:PkgIni"
    }

    Remove-OldBackups
    return $target
}

# -------------------------------------------------------------- 服務 / 安裝

function Restart-TermService {
    $service = Get-Service -Name TermService -ErrorAction SilentlyContinue
    if (-not $service) { throw '找不到 Terminal Services (TermService) 服務。' }

    $dependents = @(
        $service.DependentServices |
            Where-Object { $_.Status -eq 'Running' } |
            Select-Object -ExpandProperty Name
    )

    if ($script:IsRdpSession) {
        Write-Log '目前是透過遠端桌面連線執行，重啟服務會中斷這條連線。' 'WARN'
    }

    if ($service.Status -ne 'Running') {
        Write-Log 'Terminal Services 目前不是執行中，嘗試啟動…' 'WARN'
        Start-Service -Name TermService
    } else {
        Write-Log '停止 Terminal Services…' 'STEP'
        Stop-Service -Name TermService -Force -ErrorAction Stop

        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Service -Name TermService).Status -ne 'Stopped' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
        }

        Write-Log '啟動 Terminal Services…' 'STEP'
        Start-Service -Name TermService
    }

    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Service -Name TermService).Status -ne 'Running' -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }

    foreach ($name in $dependents) {
        $dep = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($dep -and $dep.Status -ne 'Running') {
            try {
                Start-Service -Name $name
                Write-Log "已重新啟動相依服務：$name"
            } catch {
                Write-Log "相依服務 $name 啟動失敗：$($_.Exception.Message)" 'WARN'
            }
        }
    }

    $final = (Get-Service -Name TermService).Status
    if ($final -eq 'Running') {
        Write-Log 'Terminal Services 已重新啟動。' 'OK'
    } else {
        Write-Log "Terminal Services 狀態異常：$final" 'ERROR'
    }
    return $final
}

function Get-Installer {
    if (Test-Path -LiteralPath $script:Installer) { return $script:Installer }

    Write-Log '本機沒有 RDPWInst.exe，改從官方來源取得…' 'WARN'
    Initialize-Tls

    $tmp = Join-Path $env:TEMP ("rdpwrap-autofix-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    try {
        foreach ($url in $script:InstallerUrls) {
            try {
                Write-Log "下載安裝程式：$url" 'STEP'
                $zip = Join-Path $tmp 'rdpwrap.zip'
                Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 90 `
                                  -Headers @{ 'User-Agent' = "RDPWrap-AutoFix/$($script:ToolVersion)" } `
                                  -ErrorAction Stop

                Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force

                $found = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'RDPWInst.exe' -ErrorAction SilentlyContinue |
                         Select-Object -First 1
                if ($found) {
                    Copy-Item -LiteralPath $found.FullName -Destination $script:Installer -Force
                    Write-Log '已取得 RDPWInst.exe。' 'OK'
                    return $script:Installer
                }

                Write-Log '壓縮檔裡找不到 RDPWInst.exe，換下一個來源。' 'WARN'
            } catch {
                Write-Log "失敗：$($_.Exception.Message)" 'WARN'
            }
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    throw "無法取得 RDPWInst.exe。請手動到 https://github.com/stascorp/rdpwrap/releases 下載，解壓縮後把 RDPWInst.exe 放到 $($script:Root)"
}

function Invoke-WrapperReinstall {
    $installer = Get-Installer

    Write-Log '移除現有 RDP Wrapper…' 'STEP'
    & $installer -u | Out-Null
    Start-Sleep -Seconds 2

    Write-Log '重新安裝 RDP Wrapper…' 'STEP'
    & $installer -i | Out-Null
    Start-Sleep -Seconds 2

    $wrapper = Get-WrapperInstall
    if ($wrapper.IsInstalled) {
        Write-Log 'RDP Wrapper 重新安裝完成。' 'OK'
    } else {
        Write-Log '重新安裝後仍偵測不到 rdpwrap.dll，通常是防毒軟體阻擋。' 'WARN'
    }
    return $wrapper
}

function Test-WrapperLoaded {
    try {
        foreach ($process in (Get-Process -Name svchost -ErrorAction SilentlyContinue)) {
            try {
                $hit = $process.Modules | Where-Object { $_.ModuleName -ieq 'rdpwrap.dll' }
                if ($hit) { return $true }
            } catch { }
        }
    } catch { }
    return $false
}

# ------------------------------------------------------------------ 主流程

function Invoke-UpdateFlow {
    param(
        [switch]$Reinstall,
        [switch]$SkipIfCurrent,
        [switch]$AllowMissingBuild
    )

    $version = Get-TermsrvVersion
    Write-Log "本機 termsrv.dll 版本：$version" 'STEP'

    $wrapper = Get-WrapperInstall
    Write-Log "RDP Wrapper 安裝路徑：$($wrapper.Dir)"

    $installed = Get-IniInfo -Path $wrapper.IniPath

    $urls = $script:IniUrls
    if ($Source) { $urls = @($Source) }

    $remote = Get-RemoteIni -Urls $urls
    if (-not $remote) {
        Write-Log '所有來源都下載失敗，請檢查網路或 proxy 設定。' 'ERROR'
        return $false
    }
    Write-Log "下載成功：$($remote.Url)" 'OK'
    Write-Log "遠端 ini 版本：$($remote.Updated)（$([math]::Round($remote.Size / 1KB)) KB）"

    $supports = $false
    if ($remote.Builds -contains $version) { $supports = $true }

    if (-not $supports) {
        Write-Log "最新 ini 尚未包含 [$version] 區段，套用後 RDP 可能仍無法運作。" 'WARN'
        if (-not $AllowMissingBuild) {
            if (-not (Confirm-Action '仍要繼續套用嗎？')) {
                Write-Log '已取消。' 'WARN'
                return $false
            }
        }
    }

    $sameContent = $false
    if ($installed.Exists -and ((Get-NormalizedIni $installed.Text) -eq (Get-NormalizedIni $remote.Text))) {
        $sameContent = $true
    }

    $alreadyGood = ($wrapper.IsInstalled -and ($installed.Builds -contains $version))

    if ($SkipIfCurrent -and $sameContent -and $alreadyGood) {
        Write-Log 'ini 已是最新且支援目前組建，不需要任何變更。' 'OK'
        return $true
    }

    if ($script:IsRdpSession) {
        if (-not (Confirm-Action '重啟 Terminal Services 會中斷目前的遠端桌面連線，要繼續嗎？')) {
            Write-Log '已取消。' 'WARN'
            return $false
        }
    }

    # 先讓本機 ini 就緒，重新安裝時安裝程式會從這裡複製
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($script:PkgIni, $remote.Text, $utf8NoBom)

    if ($Reinstall) {
        $wrapper = Invoke-WrapperReinstall
    } elseif (-not $wrapper.IsInstalled) {
        Write-Log '偵測不到完整的 RDP Wrapper 安裝，改為執行完整安裝。' 'WARN'
        $wrapper = Invoke-WrapperReinstall
    }

    Save-IniText -Text $remote.Text -InstallDir $wrapper.Dir | Out-Null
    Restart-TermService | Out-Null

    Start-Sleep -Seconds 2
    $after = Get-Status

    Write-Host ''
    if (Test-WrapperLoaded) {
        Write-Log '驗證：rdpwrap.dll 已載入 Terminal Services。' 'OK'
    } else {
        Write-Log '驗證：在 svchost 中找不到 rdpwrap.dll（可能被防毒阻擋，或需要重新開機）。' 'WARN'
    }

    if ($after.IniSupports) {
        Write-Log "驗證：目前 ini 支援 termsrv.dll $($after.Termsrv)。" 'OK'
    } else {
        Write-Log "驗證：目前 ini 仍不支援 termsrv.dll $($after.Termsrv)。" 'WARN'
    }

    return $true
}

# ------------------------------------------------------------------ 排程工作

function Register-AutoFixTask {
    $argument = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode Auto"

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument -WorkingDirectory $script:Root

    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn
    $logonTrigger.Delay = 'PT30S'
    $dailyTrigger = New-ScheduledTaskTrigger -Daily -At '12:00'

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -TaskName $script:TaskName -Action $action `
        -Trigger @($logonTrigger, $dailyTrigger) -Settings $settings -Principal $principal -Force | Out-Null

    Write-Log "已建立排程工作「$($script:TaskName)」：登入後 30 秒與每日 12:00 自動檢查。" 'OK'
}

function Unregister-AutoFixTask {
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Log '沒有找到自動修復排程。' 'WARN'
        return
    }
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
    Write-Log '已移除自動修復排程。' 'OK'
}

# ------------------------------------------------------------------ 進入點

if (-not (Test-Admin)) {
    Write-Host '需要系統管理員權限，正在請求提權…' -ForegroundColor Yellow
    Invoke-SelfElevate
    exit
}

switch ($Mode) {
    'Check' {
        Show-Status | Out-Null
    }

    'Auto' {
        $status = Get-Status
        if ($status.WrapperOk -and $status.IniSupports) { exit 0 }
        Write-Log '偵測到 RDP Wrapper 失效，開始自動修復…' 'WARN'
        try {
            Invoke-UpdateFlow -SkipIfCurrent -AllowMissingBuild | Out-Null
        } catch {
            Write-Log "自動修復失敗：$($_.Exception.Message)" 'ERROR'
            exit 1
        }
    }

    'Update' {
        Show-Status | Out-Null
        Invoke-UpdateFlow -SkipIfCurrent | Out-Null
    }

    'Force' {
        Show-Status | Out-Null
        Invoke-UpdateFlow -AllowMissingBuild | Out-Null
    }

    'Reinstall' {
        Show-Status | Out-Null
        Invoke-UpdateFlow -Reinstall -AllowMissingBuild | Out-Null
    }

    'RegisterTask' {
        Register-AutoFixTask
    }

    'UnregisterTask' {
        Unregister-AutoFixTask
    }

    default {
        while ($true) {
            Clear-Host
            Write-Host '============================================================' -ForegroundColor Cyan
            Write-Host "  RDP Wrapper 一鍵修復工具  v$($script:ToolVersion)" -ForegroundColor Cyan
            Write-Host '============================================================' -ForegroundColor Cyan
            Show-Status | Out-Null

            Write-Host ' 1. 檢查並自動修復（建議）'
            Write-Host ' 2. 強制重新下載並套用最新 ini'
            Write-Host ' 3. 完整重新安裝（移除 -> 安裝 -> 套用 ini）'
            Write-Host ' 4. 只重新啟動 Terminal Services'
            Write-Host ' 5. 建立自動修復排程（登入後 / 每日）'
            Write-Host ' 6. 移除自動修復排程'
            Write-Host ' 0. 離開'
            Write-Host ''

            $choice = Read-Host '請選擇'
            try {
                switch ($choice) {
                    '1' { Invoke-UpdateFlow -SkipIfCurrent | Out-Null }
                    '2' { Invoke-UpdateFlow -AllowMissingBuild | Out-Null }
                    '3' { Invoke-UpdateFlow -Reinstall -AllowMissingBuild | Out-Null }
                    '4' { Restart-TermService | Out-Null }
                    '5' { Register-AutoFixTask }
                    '6' { Unregister-AutoFixTask }
                    '0' { return }
                    default { Write-Log '無效的選項。' 'WARN' }
                }
            } catch {
                Write-Log "執行失敗：$($_.Exception.Message)" 'ERROR'
            }

            Write-Host ''
            Read-Host '按 Enter 回到選單' | Out-Null
        }
    }
}
