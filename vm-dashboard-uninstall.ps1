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
if (-not $svc) {
    Write-Host "Service '$ServiceName' is not installed." -ForegroundColor Yellow
    exit 0
}

Write-Host "Stopping service '$ServiceName'..."
Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue

$nssm = Get-Command nssm -ErrorAction SilentlyContinue
if ($nssm) {
    & nssm remove $ServiceName confirm
} else {
    & sc.exe delete $ServiceName | Out-Null
}

$wrapperPath = Join-Path $PSScriptRoot "vm-dashboard-svc-wrapper.ps1"
if (Test-Path $wrapperPath) { Remove-Item $wrapperPath -Force }

Write-Host "Service '$ServiceName' removed." -ForegroundColor Green
