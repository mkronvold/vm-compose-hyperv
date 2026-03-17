<#
.SYNOPSIS
    Installs vm-dashboard.ps1 as a Windows service.

.USAGE
    # Run as Administrator:
    ./vm-dashboard-install.ps1

.NOTES
    Prefers NSSM (https://nssm.cc) for proper Windows service support.
    If NSSM is not present you will be prompted to install it automatically
    or fall back to a Windows Task Scheduler workaround.
    The dashboard will be available at http://localhost:8080.
#>

#Requires -RunAsAdministrator

$ServiceName = "vm-dashboard"
$DisplayName = "Hyper-V Compose Web Dashboard"
$Description = "Serves the Hyper-V Compose web UI dashboard at http://localhost:8080"
$ScriptPath  = Join-Path $PSScriptRoot "vm-dashboard.ps1"
$PwshPath    = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source ?? (Get-Command powershell).Source
$logPath     = Join-Path $PSScriptRoot "vm-dashboard.log"
$errPath     = Join-Path $PSScriptRoot "vm-dashboard-error.log"

# ── Stop and remove any existing installation ──────────────────────────────
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Write-Host "Stopping existing service '$ServiceName'..." -ForegroundColor Yellow
    Stop-Service  -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep   -Seconds 2
    if (Get-Command nssm -ErrorAction SilentlyContinue) {
        & nssm remove $ServiceName confirm | Out-Null
    } else {
        & sc.exe delete $ServiceName | Out-Null
    }
}
if (Get-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue) {
    Write-Host "Stopping existing task '$ServiceName'..." -ForegroundColor Yellow
    Stop-ScheduledTask    -TaskName $ServiceName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $ServiceName -Confirm:$false
    Start-Sleep -Seconds 2
}

# ── Ensure required modules are installed AllUsers (for SYSTEM account) ────
foreach ($mod in @('Pode','powershell-yaml')) {
    $allUsers = Get-Module -ListAvailable $mod |
                Where-Object { $_.ModuleBase -notmatch [regex]::Escape($env:USERPROFILE) }
    if (-not $allUsers) {
        Write-Host "Installing $mod (AllUsers)..." -ForegroundColor Cyan
        try { Install-Module $mod -Scope AllUsers -Force -AllowClobber -ErrorAction Stop }
        catch { Write-Warning "Could not install $mod AllUsers: $_" }
    }
}

# ── NSSM: detect or offer to install ───────────────────────────────────────
function Get-NssmMethod {
    if (Get-Command nssm -ErrorAction SilentlyContinue) { return 'nssm' }

    Write-Host ""
    Write-Host "NSSM (Non-Sucking Service Manager) is not installed." -ForegroundColor Yellow
    Write-Host "NSSM wraps PowerShell scripts as proper Windows services with auto-restart"
    Write-Host "and log capture. Without it a Task Scheduler workaround is used instead."
    Write-Host ""
    Write-Host "  [1] Install NSSM automatically  (recommended)"
    Write-Host "  [2] Use Windows Task Scheduler  (no download required)"
    Write-Host ""
    $choice = (Read-Host "Choice [1]").Trim()
    if ($choice -ne '2') {
        # Try winget
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "Installing NSSM via winget..." -ForegroundColor Cyan
            winget install NSSM.NSSM --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            $env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' +
                        [Environment]::GetEnvironmentVariable('PATH','User')
            if (Get-Command nssm -ErrorAction SilentlyContinue) {
                Write-Host "NSSM installed via winget." -ForegroundColor Green
                return 'nssm'
            }
        }
        # Try choco
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Host "Installing NSSM via Chocolatey..." -ForegroundColor Cyan
            choco install nssm -y 2>&1 | Out-Null
            $env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' +
                        [Environment]::GetEnvironmentVariable('PATH','User')
            if (Get-Command nssm -ErrorAction SilentlyContinue) {
                Write-Host "NSSM installed via Chocolatey." -ForegroundColor Green
                return 'nssm'
            }
        }
        # Direct download from nssm.cc
        Write-Host "Downloading NSSM from nssm.cc..." -ForegroundColor Cyan
        try {
            $zip  = Join-Path $env:TEMP "nssm.zip"
            $extr = Join-Path $env:TEMP "nssm-extract"
            Invoke-WebRequest "https://nssm.cc/release/nssm-2.24.zip" -OutFile $zip -UseBasicParsing -TimeoutSec 30
            Expand-Archive -Path $zip -DestinationPath $extr -Force
            $exe = Get-ChildItem $extr -Filter nssm.exe -Recurse |
                   Where-Object { $_.DirectoryName -match 'win64' } | Select-Object -First 1
            if (-not $exe) { $exe = Get-ChildItem $extr -Filter nssm.exe -Recurse | Select-Object -First 1 }
            Copy-Item $exe.FullName "C:\Windows\System32\nssm.exe" -Force
            Remove-Item $zip,$extr -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "NSSM installed to C:\Windows\System32\nssm.exe" -ForegroundColor Green
            return 'nssm'
        } catch {
            Write-Host "NSSM download failed: $_" -ForegroundColor Red
            Write-Host "Falling back to Task Scheduler." -ForegroundColor Yellow
        }
    }
    return 'task'
}

$method = Get-NssmMethod

# ── Install via chosen method ───────────────────────────────────────────────
if ($method -eq 'nssm') {
    Write-Host "Installing '$ServiceName' via NSSM..." -ForegroundColor Cyan
    & nssm install  $ServiceName $PwshPath "-NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""
    & nssm set      $ServiceName DisplayName $DisplayName
    & nssm set      $ServiceName Description $Description
    & nssm set      $ServiceName Start       SERVICE_AUTO_START
    & nssm set      $ServiceName AppStdout   $logPath
    & nssm set      $ServiceName AppStderr   $errPath

    Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    Start-Sleep   -Seconds 3
    $svc     = Get-Service -Name $ServiceName
    $running = $svc.Status -eq 'Running'
    Write-Host "Service status: $($svc.Status)" -ForegroundColor $(if ($running) { 'Green' } else { 'Red' })

} else {
    Write-Host "Installing '$ServiceName' via Task Scheduler..." -ForegroundColor Cyan
    $wrapperPath = Join-Path $PSScriptRoot "vm-dashboard-svc-wrapper.ps1"
    @"
try {
    Set-Location '$PSScriptRoot'
    & '$ScriptPath' *>> '$logPath'
} catch {
    Add-Content '$errPath' "`$([datetime]::Now) ERROR: `$_"
}
"@ | Out-File $wrapperPath -Encoding utf8 -Force

    $action    = New-ScheduledTaskAction -Execute $PwshPath `
                   -Argument "-NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$wrapperPath`""
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::Zero) `
                   -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
                   -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -TaskName $ServiceName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Description $Description | Out-Null

    Start-ScheduledTask -TaskName $ServiceName
    Start-Sleep -Seconds 5

    $task    = Get-ScheduledTask -TaskName $ServiceName
    $running = $task.State -eq 'Running'
    Write-Host "Task state: $($task.State)" -ForegroundColor $(if ($running) { 'Green' } else { 'Red' })
}

# ── Final status ────────────────────────────────────────────────────────────
if ($running) {
    Write-Host "Dashboard available at: http://localhost:8080" -ForegroundColor Green
} else {
    Write-Host "Failed to start. Check the log:" -ForegroundColor Red
    Write-Host "  $errPath" -ForegroundColor Yellow
    Write-Host "Or run directly: pwsh -File '$ScriptPath'" -ForegroundColor Yellow
}

