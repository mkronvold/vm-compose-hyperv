<#
.SYNOPSIS
    Installs vm-dashboard.ps1 as a Windows service.

.USAGE
    # Run as Administrator:
    ./vm-dashboard-install.ps1

.NOTES
    Prefers NSSM if available. Falls back to sc.exe.
    The dashboard will be available at http://localhost:8080.
#>

#Requires -RunAsAdministrator

$ServiceName = "vm-dashboard"
$DisplayName = "Hyper-V Compose Web Dashboard"
$Description = "Serves the Hyper-V Compose web UI dashboard at http://localhost:8080"
$ScriptPath  = Join-Path $PSScriptRoot "vm-dashboard.ps1"
$PwshPath    = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source

if (-not $PwshPath) {
    $PwshPath = (Get-Command powershell).Source
}

if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Write-Host "Service '$ServiceName' already exists. Stopping and removing..." -ForegroundColor Yellow
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    & sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
}

$nssm = Get-Command nssm -ErrorAction SilentlyContinue

if ($nssm) {
    Write-Host "Installing via NSSM..."
    & nssm install $ServiceName $PwshPath "-NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""
    & nssm set $ServiceName DisplayName $DisplayName
    & nssm set $ServiceName Description $Description
    & nssm set $ServiceName Start SERVICE_AUTO_START
    & nssm set $ServiceName AppStdout "$PSScriptRoot\vm-dashboard.log"
    & nssm set $ServiceName AppStderr "$PSScriptRoot\vm-dashboard-error.log"
} else {
    Write-Host "NSSM not found. Installing via sc.exe..."
    $wrapperPath = Join-Path $PSScriptRoot "vm-dashboard-svc-wrapper.ps1"
    @"
Set-Location '$PSScriptRoot'
& '$ScriptPath'
"@ | Out-File $wrapperPath -Encoding utf8 -Force

    $binPath = "`"$PwshPath`" -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$wrapperPath`""
    & sc.exe create $ServiceName binPath= $binPath start= auto DisplayName= $DisplayName | Out-Null
    & sc.exe description $ServiceName $Description | Out-Null
}

Start-Service -Name $ServiceName
$svc = Get-Service -Name $ServiceName
Write-Host "Service '$ServiceName' status: $($svc.Status)" -ForegroundColor $(if ($svc.Status -eq 'Running') { 'Green' } else { 'Red' })
Write-Host "Dashboard available at: http://localhost:8080"
