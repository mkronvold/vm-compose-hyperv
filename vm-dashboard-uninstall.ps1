<#
.SYNOPSIS
    Uninstalls the vm-dashboard Windows service.

.USAGE
    # Run as Administrator:
    ./vm-dashboard-uninstall.ps1
#>

#Requires -RunAsAdministrator

$ServiceName = "vm-dashboard"

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$task = Get-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue

if (-not $svc -and -not $task) {
    Write-Host "vm-dashboard is not installed (no service or task found)." -ForegroundColor Yellow
    exit 0
}

$nssm = Get-Command nssm -ErrorAction SilentlyContinue

if ($svc) {
    Write-Host "Stopping and removing service '$ServiceName'..."
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    if ($nssm) {
        & nssm remove $ServiceName confirm
    } else {
        & sc.exe delete $ServiceName | Out-Null
    }
}

if ($task) {
    Write-Host "Stopping and removing scheduled task '$ServiceName'..."
    Stop-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $ServiceName -Confirm:$false
}

$wrapperPath = Join-Path $PSScriptRoot "vm-dashboard-svc-wrapper.ps1"
if (Test-Path $wrapperPath) { Remove-Item $wrapperPath -Force }

Write-Host "vm-dashboard uninstalled." -ForegroundColor Green
