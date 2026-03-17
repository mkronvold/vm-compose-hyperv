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
        Install-Module Pode -Scope AllUsers
    Requires PowerShell 7+ and the Hyper-V module.
#>

param(
    [int]$Port = 8080,
    [string]$ConfigFile = "vmstack.yaml"
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not [System.IO.Path]::IsPathRooted($ConfigFile)) {
    $ConfigFile = Join-Path $scriptDir $ConfigFile
}

# Ensure Pode is installed (install script should have done this AllUsers; this is a fallback for direct runs)
if (-not (Get-Module -ListAvailable -Name Pode)) {
    Write-Host "Installing Pode module..." -ForegroundColor Yellow
    $scope = if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator')) { 'AllUsers' } else { 'CurrentUser' }
    Install-Module Pode -Scope $scope -Force -AllowClobber
}

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host "Installing powershell-yaml module..." -ForegroundColor Yellow
    $scope = if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator')) { 'AllUsers' } else { 'CurrentUser' }
    Install-Module powershell-yaml -Scope $scope -Force -AllowClobber
}

Import-Module Pode
Import-Module powershell-yaml

if (-not (Test-Path $ConfigFile)) {
    Write-Error "Config file not found: $ConfigFile"
    exit 1
}

Start-PodeServer -Threads 2 {

    Add-PodeEndpoint -Address localhost -Port $Port -Protocol Http

    # Share modules and config path with all route runspaces
    Set-PodeState -Name 'ConfigFile' -Value $ConfigFile

    # -------------------------------------------------------
    # GET / — dashboard
    # -------------------------------------------------------
    Add-PodeRoute -Method Get -Path "/" -ScriptBlock {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            $stack   = Get-Content $cfgFile -Raw | ConvertFrom-Yaml

            $rows = ""
            foreach ($vmName in $stack.vms.Keys) {
                $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
                if (-not $vm) {
                    $rows += "<tr><td><a href='/vm/$vmName'>$vmName</a></td><td><span class='badge bg-secondary'>Not Created</span></td><td>-</td><td>-</td><td>-</td><td>-</td><td></td></tr>"
                    continue
                }
                $ip       = (Get-VMNetworkAdapter -VMName $vmName).IPAddresses |
                            Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' } | Select-Object -First 1
                $memLimit = [math]::Round($vm.MemoryStartup / 1GB, 1)
                $memUsed  = [math]::Round(($vm.MemoryAssigned) / 1GB, 1)
                $memPct   = if ($vm.MemoryStartup -gt 0) { [math]::Round($memUsed / $memLimit * 100) } else { 0 }
                $cpuLabel = "$($vm.CPUUsage)% of $($vm.ProcessorCount) vCPUs"
                $memLabel = "${memPct}% of ${memLimit} GB"
                $uptime   = if ($vm.Uptime -and $vm.Uptime.TotalSeconds -gt 0) { $vm.Uptime.ToString("dd\d\ hh\:mm\:ss") } else { "-" }
                $color    = switch ($vm.State.ToString()) {
                    "Running" { "success" } "Off" { "secondary" } "Saved" { "info" }
                    "Paused"  { "warning" } default { "danger" }
                }
                $rows += @"
                <tr>
                  <td><a href="/vm/$vmName">$vmName</a></td>
                  <td><span class="badge bg-$color">$($vm.State)</span></td>
                  <td>$cpuLabel</td>
                  <td>$memLabel</td>
                  <td>$(if ($ip) { $ip } else { '-' })</td>
                  <td>$uptime</td>
                  <td>
                    <form method="post" action="/vm/$vmName/start"   style="display:inline"><button class="btn btn-sm btn-success">Start</button></form>
                    <form method="post" action="/vm/$vmName/stop"    style="display:inline"><button class="btn btn-sm btn-warning">Stop</button></form>
                    <form method="post" action="/vm/$vmName/restart" style="display:inline"><button class="btn btn-sm btn-info">Restart</button></form>
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
        } catch {
            Write-PodeHtmlResponse -StatusCode 500 -Value @"
<!doctype html><html><head><title>500 — Dashboard Error</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css">
</head><body class="bg-light"><div class="container mt-4">
<h2 class="text-danger">Dashboard Error</h2>
<pre class="bg-white p-3 border rounded">$($_.Exception.Message)

$($_.ScriptStackTrace)</pre>
<a href="/" class="btn btn-outline-secondary mt-2">Retry</a>
</div></body></html>
"@
        }
    }

    # -------------------------------------------------------
    # GET /vm/:name — detail page
    # -------------------------------------------------------
    Add-PodeRoute -Method Get -Path "/vm/:name" -ScriptBlock {
        try {
            $vmName = $WebEvent.Parameters['name']
            $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
            if (-not $vm) {
                Write-PodeHtmlResponse -StatusCode 404 -Value "<h3>VM '$vmName' not found</h3>"
                return
            }

            $adapters = Get-VMNetworkAdapter -VMName $vmName
            $disks    = Get-VMHardDiskDrive -VMName $vmName
            $snaps    = Get-VMSnapshot -VMName $vmName -ErrorAction SilentlyContinue
            $memLimit = [math]::Round($vm.MemoryStartup / 1GB, 1)
            $memUsed  = [math]::Round($vm.MemoryAssigned / 1GB, 1)
            $memPct   = if ($vm.MemoryStartup -gt 0) { [math]::Round($memUsed / $memLimit * 100) } else { 0 }
            $cpuLabel = "$($vm.CPUUsage)% of $($vm.ProcessorCount) vCPUs"
            $memLabel = "${memPct}% of ${memLimit} GB  ($memUsed GB assigned)"
            $uptime   = if ($vm.Uptime -and $vm.Uptime.TotalSeconds -gt 0) { $vm.Uptime.ToString() } else { "-" }
            $color    = switch ($vm.State.ToString()) {
                "Running" { "success" } "Off" { "secondary" } "Saved" { "info" }
                "Paused"  { "warning" } default { "danger" }
            }
            $ips       = @($adapters.IPAddresses | Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' })
            $diskList  = ($disks.Path        | ForEach-Object { "<li class='list-group-item'>$_</li>" }) -join ""
            $ipList    = ($ips               | ForEach-Object { "<li class='list-group-item'>$_</li>" }) -join ""
            $snapList  = ($snaps.Name        | ForEach-Object { "<li class='list-group-item'>$_</li>" }) -join ""
            $macList   = ($adapters | ForEach-Object {
                $mac = $_.MacAddress -replace '(..)(?!$)','$1:'
                "<li class='list-group-item'><code>$mac</code></li>"
            }) -join ""
            $swList    = ($adapters | ForEach-Object {
                "<li class='list-group-item'>$($_.SwitchName)&nbsp;<span class='text-muted small'>$($_.Name)</span></li>"
            }) -join ""

            Write-PodeHtmlResponse -Value @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>$vmName — Hyper-V Compose</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css">
</head>
<body class="bg-light">
<div class="container mt-4">
  <a href="/" class="btn btn-outline-secondary btn-sm mb-3">&larr; Back</a>
  <h2>$vmName <span class="badge bg-$color">$($vm.State)</span></h2>
  <div class="row mt-3">
    <div class="col-md-4">
      <ul class="list-group mb-3">
        <li class="list-group-item"><strong>CPU:</strong> $cpuLabel</li>
        <li class="list-group-item"><strong>Memory:</strong> $memLabel</li>
        <li class="list-group-item"><strong>Generation:</strong> $($vm.Generation)</li>
        <li class="list-group-item"><strong>Uptime:</strong> $uptime</li>
      </ul>
      <div class="d-flex gap-2">
        <form method="post" action="/vm/$vmName/start">  <button class="btn btn-success">Start</button></form>
        <form method="post" action="/vm/$vmName/stop">   <button class="btn btn-warning">Stop</button></form>
        <form method="post" action="/vm/$vmName/restart"><button class="btn btn-info">Restart</button></form>
      </div>
    </div>
    <div class="col-md-8">
      <h5>IP Addresses</h5><ul class="list-group mb-3">$(if ($ipList) { $ipList } else { '<li class="list-group-item text-muted">None</li>' })</ul>
      <h5>MAC Addresses</h5><ul class="list-group mb-3">$(if ($macList) { $macList } else { '<li class="list-group-item text-muted">None</li>' })</ul>
      <h5>Switches</h5><ul class="list-group mb-3">$(if ($swList) { $swList } else { '<li class="list-group-item text-muted">None</li>' })</ul>
      <h5>Disks</h5><ul class="list-group mb-3">$(if ($diskList) { $diskList } else { '<li class="list-group-item text-muted">None</li>' })</ul>
      <h5>Checkpoints</h5><ul class="list-group mb-3">$(if ($snapList) { $snapList } else { '<li class="list-group-item text-muted">None</li>' })</ul>
      $(if ($vm.Notes) { "<h5>Notes</h5><pre class='bg-white p-2 border rounded'>$($vm.Notes)</pre>" })
    </div>
  </div>
</div>
</body>
</html>
"@
        } catch {
            Write-PodeHtmlResponse -StatusCode 500 -Value "<pre>$($_.Exception.Message)`n$($_.ScriptStackTrace)</pre>"
        }
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
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            $stack   = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $rows = foreach ($vmName in $stack.vms.Keys) {
                $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
                if (-not $vm) { @{ name=$vmName; state="Not Created"; cpu="-"; memoryGB="-"; ip="-"; uptime="-" }; continue }
                $ip  = (Get-VMNetworkAdapter -VMName $vmName).IPAddresses |
                       Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' } | Select-Object -First 1
                $mem = if ($vm.MemoryAssigned -gt 0) { $vm.MemoryAssigned } else { $vm.MemoryStartup }
                @{
                    name     = $vmName
                    state    = $vm.State.ToString()
                    cpu      = "$($vm.CPUUsage)%"
                    memoryGB = [math]::Round($mem / 1GB, 2)
                    ip       = if ($ip) { $ip } else { "-" }
                    uptime   = if ($vm.Uptime -and $vm.Uptime.TotalSeconds -gt 0) { $vm.Uptime.ToString("dd\d\ hh\:mm\:ss") } else { "-" }
                }
            }
            Write-PodeJsonResponse -Value @($rows)
        } catch {
            Write-PodeJsonResponse -StatusCode 500 -Value @{ error = $_.Exception.Message }
        }
    }

    # -------------------------------------------------------
    # GET /api/vms/:name — JSON detail
    # -------------------------------------------------------
    Add-PodeRoute -Method Get -Path "/api/vms/:name" -ScriptBlock {
        try {
            $vmName = $WebEvent.Parameters['name']
            $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
            if (-not $vm) { Write-PodeJsonResponse -StatusCode 404 -Value @{ error = "VM '$vmName' not found" }; return }
            $adapters = Get-VMNetworkAdapter -VMName $vmName
            $mem = if ($vm.MemoryAssigned -gt 0) { $vm.MemoryAssigned } else { $vm.MemoryStartup }
            Write-PodeJsonResponse -Value @{
                name        = $vm.Name
                state       = $vm.State.ToString()
                cpuCount    = $vm.ProcessorCount
                memoryGB    = [math]::Round($mem / 1GB, 2)
                uptime      = if ($vm.Uptime -and $vm.Uptime.TotalSeconds -gt 0) { $vm.Uptime.ToString() } else { "-" }
                switches    = @($adapters.SwitchName)
                ipAddresses = @($adapters.IPAddresses | Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' })
                disks       = @((Get-VMHardDiskDrive -VMName $vmName).Path)
                generation  = $vm.Generation
                checkpoints = @((Get-VMSnapshot -VMName $vmName -ErrorAction SilentlyContinue).Name)
                notes       = $vm.Notes
            }
        } catch {
            Write-PodeJsonResponse -StatusCode 500 -Value @{ error = $_.Exception.Message }
        }
    }
}
