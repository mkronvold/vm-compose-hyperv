<#
.SYNOPSIS
    Hyper-V Compose web dashboard (Pode-based).
    Serves a live VM management UI at http://localhost:8080.

.USAGE
    # Run directly (foreground):
    ./vm-dashboard.ps1

    # Install as a Windows service:
    ./vm-dashboard-install.ps1

.NOTES
    Requires the Pode module. Install with:
        Install-Module Pode -Scope CurrentUser
    Requires PowerShell 7+ and the Hyper-V module.
#>

param(
    [int]$Port = 8080,
    [string]$ConfigFile = "vmstack.yml"
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not [System.IO.Path]::IsPathRooted($ConfigFile)) {
    $ConfigFile = Join-Path $scriptDir $ConfigFile
}

# Ensure Pode is installed
if (-not (Get-Module -ListAvailable -Name Pode)) {
    Write-Host "Installing Pode module..." -ForegroundColor Yellow
    Install-Module Pode -Scope CurrentUser -Force -AllowClobber
}

Import-Module Pode

if (-not (Test-Path $ConfigFile)) {
    Write-Error "Config file not found: $ConfigFile"
    exit 1
}

function Get-VMList {
    $stack = Get-Content $ConfigFile | ConvertFrom-Yaml
    $vmNames = $stack.vms.Keys
    $rows = foreach ($vmName in $vmNames) {
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if (-not $vm) {
            [ordered]@{ name=$vmName; state="Not Created"; cpu="-"; memoryGB="-"; ip="-"; uptime="-" }
            continue
        }
        $ip = (Get-VMNetworkAdapter -VMName $vmName).IPAddresses |
              Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' } | Select-Object -First 1
        [ordered]@{
            name     = $vmName
            state    = $vm.State.ToString()
            cpu      = "$($vm.CPUUsage)%"
            memoryGB = [math]::Round($vm.MemoryAssigned / 1GB, 2)
            ip       = if ($ip) { $ip } else { "-" }
            uptime   = if ($vm.Uptime) { $vm.Uptime.ToString("dd\d\ hh\:mm\:ss") } else { "-" }
        }
    }
    return @($rows)
}

function Get-VMDetail {
    param([string]$vmName)
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) { return $null }
    $adapters = Get-VMNetworkAdapter -VMName $vmName
    $disks    = Get-VMHardDiskDrive -VMName $vmName
    return [ordered]@{
        name        = $vm.Name
        state       = $vm.State.ToString()
        cpuCount    = $vm.ProcessorCount
        memoryGB    = [math]::Round($vm.MemoryAssigned / 1GB, 2)
        uptime      = if ($vm.Uptime) { $vm.Uptime.ToString() } else { "-" }
        switches    = @($adapters.SwitchName)
        ipAddresses = @($adapters.IPAddresses | Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' })
        disks       = @($disks.Path)
        generation  = $vm.Generation
        checkpoints = @((Get-VMSnapshot -VMName $vmName -ErrorAction SilentlyContinue).Name)
        notes       = $vm.Notes
    }
}

# HTML helpers
$stateColor = {
    param($state)
    switch ($state) {
        "Running"    { "success" }
        "Off"        { "secondary" }
        "Saved"      { "info" }
        "Paused"     { "warning" }
        default      { "danger" }
    }
}

Start-PodeServer -Threads 2 {

    Add-PodeEndpoint -Address * -Port $Port -Protocol Http

    # -------------------------------------------------------
    # GET / — dashboard
    # -------------------------------------------------------
    Add-PodeRoute -Method Get -Path "/" -ScriptBlock {
        $vms = Get-VMList
        $rows = ""
        foreach ($vm in $vms) {
            $color = & $using:stateColor $vm.state
            $rows += @"
            <tr>
              <td><a href="/vm/$($vm.name)">$($vm.name)</a></td>
              <td><span class="badge bg-$color">$($vm.state)</span></td>
              <td>$($vm.cpu)</td>
              <td>$($vm.memoryGB) GB</td>
              <td>$($vm.ip)</td>
              <td>$($vm.uptime)</td>
              <td>
                <form method="post" action="/vm/$($vm.name)/start"   style="display:inline"><button class="btn btn-sm btn-success">Start</button></form>
                <form method="post" action="/vm/$($vm.name)/stop"    style="display:inline"><button class="btn btn-sm btn-warning">Stop</button></form>
                <form method="post" action="/vm/$($vm.name)/restart" style="display:inline"><button class="btn btn-sm btn-info">Restart</button></form>
              </td>
            </tr>
"@
        }

        Write-PodeHtmlResponse -Value @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="10">
  <title>Hyper-V Compose Dashboard</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css">
</head>
<body class="bg-light">
<div class="container mt-4">
  <h1 class="mb-1">&#x1F5A5; Hyper-V Compose</h1>
  <p class="text-muted mb-3">Auto-refreshes every 10 seconds</p>
  <table class="table table-bordered table-hover bg-white shadow-sm">
    <thead class="table-dark">
      <tr><th>VM</th><th>State</th><th>CPU</th><th>Memory</th><th>IP</th><th>Uptime</th><th>Actions</th></tr>
    </thead>
    <tbody>$rows</tbody>
  </table>
  <p class="text-muted small">Metrics: <a href="http://localhost:9090/metrics" target="_blank">http://localhost:9090/metrics</a></p>
</div>
</body>
</html>
"@
    }

    # -------------------------------------------------------
    # GET /vm/:name — detail page
    # -------------------------------------------------------
    Add-PodeRoute -Method Get -Path "/vm/:name" -ScriptBlock {
        $vmName = $WebEvent.Parameters['name']
        $vm = Get-VMDetail $vmName
        if (-not $vm) {
            Write-PodeHtmlResponse -StatusCode 404 -Value "<h3>VM '$vmName' not found</h3>"
            return
        }

        $color = & $using:stateColor $vm.state
        $diskList  = ($vm.disks       | ForEach-Object { "<li class='list-group-item'>$_</li>" }) -join ""
        $ipList    = ($vm.ipAddresses | ForEach-Object { "<li class='list-group-item'>$_</li>" }) -join ""
        $snapList  = ($vm.checkpoints | ForEach-Object { "<li class='list-group-item'>$_</li>" }) -join ""
        $switchList= ($vm.switches    | ForEach-Object { "<li class='list-group-item'>$_</li>" }) -join ""

        Write-PodeHtmlResponse -Value @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>$($vm.name) — Hyper-V Compose</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css">
</head>
<body class="bg-light">
<div class="container mt-4">
  <a href="/" class="btn btn-outline-secondary btn-sm mb-3">&larr; Back</a>
  <h2>$($vm.name) <span class="badge bg-$color">$($vm.state)</span></h2>
  <div class="row mt-3">
    <div class="col-md-4">
      <ul class="list-group mb-3">
        <li class="list-group-item"><strong>CPUs:</strong> $($vm.cpuCount)</li>
        <li class="list-group-item"><strong>Memory:</strong> $($vm.memoryGB) GB</li>
        <li class="list-group-item"><strong>Generation:</strong> $($vm.generation)</li>
        <li class="list-group-item"><strong>Uptime:</strong> $($vm.uptime)</li>
      </ul>
      <div class="d-flex gap-2">
        <form method="post" action="/vm/$($vm.name)/start">  <button class="btn btn-success">Start</button></form>
        <form method="post" action="/vm/$($vm.name)/stop">   <button class="btn btn-warning">Stop</button></form>
        <form method="post" action="/vm/$($vm.name)/restart"><button class="btn btn-info">Restart</button></form>
      </div>
    </div>
    <div class="col-md-8">
      <h5>IP Addresses</h5><ul class="list-group mb-3">$ipList</ul>
      <h5>Switches</h5><ul class="list-group mb-3">$switchList</ul>
      <h5>Disks</h5><ul class="list-group mb-3">$diskList</ul>
      <h5>Checkpoints</h5><ul class="list-group mb-3">$(if ($snapList) { $snapList } else { '<li class="list-group-item text-muted">None</li>' })</ul>
    </div>
  </div>
</div>
</body>
</html>
"@
    }

    # -------------------------------------------------------
    # POST /vm/:name/start|stop|restart — actions
    # -------------------------------------------------------
    Add-PodeRoute -Method Post -Path "/vm/:name/start" -ScriptBlock {
        $vmName = $WebEvent.Parameters['name']
        if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) { Start-VM -Name $vmName -ErrorAction SilentlyContinue }
        Move-PodeResponseUrl -Url "/"
    }

    Add-PodeRoute -Method Post -Path "/vm/:name/stop" -ScriptBlock {
        $vmName = $WebEvent.Parameters['name']
        if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) { Stop-VM -Name $vmName -Force -TurnOff -ErrorAction SilentlyContinue }
        Move-PodeResponseUrl -Url "/"
    }

    Add-PodeRoute -Method Post -Path "/vm/:name/restart" -ScriptBlock {
        $vmName = $WebEvent.Parameters['name']
        if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) { Restart-VM -Name $vmName -Force -ErrorAction SilentlyContinue }
        Move-PodeResponseUrl -Url "/"
    }

    # -------------------------------------------------------
    # GET /api/vms — JSON list
    # -------------------------------------------------------
    Add-PodeRoute -Method Get -Path "/api/vms" -ScriptBlock {
        Write-PodeJsonResponse -Value (Get-VMList)
    }

    # -------------------------------------------------------
    # GET /api/vms/:name — JSON detail
    # -------------------------------------------------------
    Add-PodeRoute -Method Get -Path "/api/vms/:name" -ScriptBlock {
        $vmName = $WebEvent.Parameters['name']
        $vm = Get-VMDetail $vmName
        if ($vm) {
            Write-PodeJsonResponse -Value $vm
        } else {
            Write-PodeJsonResponse -StatusCode 404 -Value @{ error = "VM '$vmName' not found" }
        }
    }
}
