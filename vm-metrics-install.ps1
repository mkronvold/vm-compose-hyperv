<#
.SYNOPSIS
    Installs vm-metrics.ps1 as a Windows service using NSSM (or falls back to a scheduled task).

.USAGE
    # Run as Administrator:
    ./vm-metrics-install.ps1

.NOTES
    Prefers NSSM if available (https://nssm.cc). Falls back to a Task Scheduler workaround.
    The service runs under LocalSystem and starts automatically.
#>

#Requires -RunAsAdministrator

$ServiceName = "vm-metrics"
$DisplayName = "Hyper-V Compose Metrics Exporter"
$Description = "Exposes Hyper-V VM metrics in Prometheus format on :9090/metrics"
$ScriptPath = Join-Path $PSScriptRoot "vm-metrics.ps1"
$PwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source

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
    & nssm set $ServiceName AppStdout "$PSScriptRoot\vm-metrics.log"
    & nssm set $ServiceName AppStderr "$PSScriptRoot\vm-metrics-error.log"
} else {
    Write-Host "NSSM not found. Installing via sc.exe with wrapper..."

    # Create a wrapper script that keeps the service alive
    $wrapperPath = Join-Path $PSScriptRoot "vm-metrics-svc-wrapper.ps1"
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
Write-Host "Metrics available at: http://localhost:9090/metrics"
