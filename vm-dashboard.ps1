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
                # Eval days remaining (only query when VM is running, non-blocking)
                $evalBadge = ''
                if ($vm.State -eq 'Running') {
                    try {
                        $slp = Invoke-Command -VMName $vmName -ScriptBlock {
                            Get-WmiObject -Class SoftwareLicensingProduct -ErrorAction SilentlyContinue |
                                Where-Object { $_.ApplicationID -eq '55c92734-d682-4d71-983e-d6ec3f16059f' -and
                                               $_.PartialProductKey -and $_.GracePeriodRemaining -gt 0 } |
                                Select-Object -First 1 -ExpandProperty GracePeriodRemaining
                        } -ErrorAction SilentlyContinue
                        if ($slp) {
                            $days = [math]::Floor($slp / 1440)
                            $badgeColor = if ($days -le 14) { 'danger' } elseif ($days -le 30) { 'warning' } else { 'info' }
                            $evalBadge = " <span class='badge bg-$badgeColor' title='Evaluation license'>Eval: $days d</span>"
                        }
                    } catch { }
                }
                $rows += @"
                <tr>
                  <td><a href="/vm/$vmName">$vmName</a>$evalBadge</td>
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

            # Build shared storage rows
            $vmRoot = if ($stack.vm_root) { $stack.vm_root } else { "C:\HyperV\VMs" }
            $storageRows = ""
            if ($stack.storage) {
                foreach ($storageName in $stack.storage.Keys) {
                    $sCfg = $stack.storage[$storageName]
                    $rawPath = $sCfg.path
                    $sp = if ([System.IO.Path]::IsPathRooted($rawPath)) { $rawPath } else { Join-Path $vmRoot $rawPath }
                    $virtGB   = $sCfg.size_gb
                    $usedGB   = '-'
                    $pctAlloc = '-'
                    $hostDrive = '-'
                    $mountBtn  = ''
                    $mountedVMsArray = @(
                        Get-VM -ErrorAction SilentlyContinue |
                            Where-Object { (Get-VMHardDiskDrive -VMName $_.Name -ErrorAction SilentlyContinue |
                                Where-Object Path -eq $sp) } |
                            Select-Object -ExpandProperty Name
                    )
                    $mountedVMs = $mountedVMsArray -join ', '
                    if (-not $mountedVMs) { $mountedVMs = '-' }

                    if (Test-Path $sp) {
                        $usedGB = [math]::Round((Get-Item $sp).Length / 1GB, 2)
                        $vhd = Get-VHD -Path $sp -ErrorAction SilentlyContinue
                        if ($vhd -and $vhd.Size -gt 0) {
                            $pctAlloc = '{0:0}%' -f ($vhd.FileSize / $vhd.Size * 100)
                        }
                        $diskNum = $null; $dnStr = "$($vhd.DiskNumber)"
                        if ($vhd -and $vhd.Attached -and $dnStr -match '^\d+$') { $diskNum = [int]$dnStr }
                        # Get-VHD throws a permission error when the disk is host-mounted (VMMS locks it).
                        # Fall back to Get-Disk by Location to detect host mounts reliably.
                        if ($null -eq $diskNum) {
                            $hostDisk = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.Location -eq $sp }
                            if ($hostDisk) { $diskNum = [int]$hostDisk.Number }
                        }
                        if ($null -ne $diskNum) {
                            $dl = Get-Disk -Number $diskNum -ErrorAction SilentlyContinue |
                                  Get-Partition -ErrorAction SilentlyContinue |
                                  Where-Object { $_.DriveLetter -and $_.DriveLetter -ne [char]0 } |
                                  Select-Object -First 1 -ExpandProperty DriveLetter
                            $hostDrive = if ($dl) { "${dl}:\" } else { "Attached" }
                            $mountBtn  = "<form method='post' action='/storage/$storageName/localunmount' style='display:inline'><button class='btn btn-sm btn-warning'>&#x23CF; Unmount</button></form>"
                        } elseif ($mountedVMsArray.Count -gt 0) {
                            $mountBtn  = "<button class='btn btn-sm btn-outline-secondary' disabled title='Unmount from VM first'>&#x1F512; In use by VM</button>"
                        } else {
                            $mountBtn  = "<form method='post' action='/storage/$storageName/localmount' style='display:inline'><button class='btn btn-sm btn-outline-primary'>&#x1F4BE; Mount</button></form>"
                        }
                    } else {
                        $mountBtn = "<span class='badge bg-danger'>MISSING</span>"
                    }

                    $storageRows += "<tr><td><strong>$storageName</strong></td><td><code class='small'>$sp</code></td><td>${virtGB} GB</td><td>${usedGB} GB</td><td>$pctAlloc</td><td>$mountedVMs</td><td>$hostDrive</td><td>$mountBtn</td></tr>"
                }
            }
            $storageSection = if ($storageRows) { @"
<h4 class="mt-4">&#x1F4BE; Shared Storage</h4>
<table class="table table-sm table-bordered bg-white shadow-sm">
  <thead class="table-dark">
    <tr><th>Name</th><th>Path</th><th>Virtual</th><th>On Disk</th><th>%Alloc</th><th>VM Mounts</th><th>Host Drive</th><th></th></tr>
  </thead>
  <tbody>$storageRows</tbody>
</table>
"@ } else { "" }

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
  $storageSection
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
            Import-Module powershell-yaml -ErrorAction Stop
            $vmName  = $WebEvent.Parameters['name']
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            $stack   = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmRoot  = if ($stack.vm_root) { $stack.vm_root } else { "C:\HyperV\VMs" }

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
            $ips      = @($adapters.IPAddresses | Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' })
            $diskList = ($disks | ForEach-Object {
                $dPath = $_.Path
                $vhd = Get-VHD -Path $dPath -ErrorAction SilentlyContinue
                $sizeInfo = if ($vhd -and $vhd.Size -gt 0) {
                    $v = [math]::Round($vhd.Size / 1GB, 1)
                    $u = [math]::Round($vhd.FileSize / 1GB, 2)
                    $p = '{0:0}' -f ($vhd.FileSize / $vhd.Size * 100)
                    " &nbsp;<span class='badge bg-secondary'>${v} GB</span> <span class='text-muted small'>${u} GB used (${p}%)</span>"
                } else { "" }
                "<li class='list-group-item small'><code>$dPath</code>$sizeInfo</li>"
            }) -join ""
            $ipList   = ($ips        | ForEach-Object { "<li class='list-group-item'>$_</li>" }) -join ""
            $snapList = ($snaps.Name | ForEach-Object { "<li class='list-group-item'>$_</li>" }) -join ""
            $macList  = ($adapters | ForEach-Object {
                $mac = $_.MacAddress -replace '(..)(?!$)','$1:'
                "<li class='list-group-item'><code>$mac</code></li>"
            }) -join ""
            $swList   = ($adapters | ForEach-Object {
                "<li class='list-group-item'>$($_.SwitchName)&nbsp;<span class='text-muted small'>$($_.Name)</span></li>"
            }) -join ""

            # Persistent volume (P:) on the host — detect if VHDX is host-mounted
            $pvPath   = Join-Path $vmRoot $vmName "persistent-storage.vhdx"
            $pvExists = Test-Path $pvPath
            $pvSection = ""
            if ($pvExists) {
                $pvHostDisk = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.Location -eq $pvPath } | Select-Object -First 1
                if ($pvHostDisk) {
                    $pvDriveLetter = Get-Disk -Number $pvHostDisk.Number -ErrorAction SilentlyContinue |
                        Get-Partition -ErrorAction SilentlyContinue |
                        Where-Object { $_.DriveLetter -and $_.DriveLetter -ne [char]0 } |
                        Select-Object -First 1 -ExpandProperty DriveLetter
                    $pvDriveLabel = if ($pvDriveLetter) { "${pvDriveLetter}:\" } else { "Attached (no letter)" }
                    $pvSection = "<div class='card mb-3 border-warning'><div class='card-header bg-warning text-dark fw-bold'>&#x1F4BE; Persistent Volume (host-mounted: $pvDriveLabel)</div><div class='card-body d-flex align-items-center gap-3'><code class='small'>$pvPath</code><button type='button' class='btn btn-sm btn-danger ms-auto' data-bs-toggle='modal' data-bs-target='#pvUnmountModal'>&#x23CF; Unmount</button></div></div><div class='modal fade' id='pvUnmountModal' tabindex='-1'><div class='modal-dialog'><div class='modal-content'><div class='modal-header'><h5 class='modal-title'>Unmount Persistent Volume?</h5><button type='button' class='btn-close' data-bs-dismiss='modal'></button></div><div class='modal-body'><p class='text-danger fw-bold'>Warning: unmounting while Docker containers are running on this VM may cause data loss or container crashes.</p><p>Are you sure you want to unmount <code>$pvPath</code> from the host?</p></div><div class='modal-footer'><button type='button' class='btn btn-secondary' data-bs-dismiss='modal'>Cancel</button><form method='post' action='/vm/$vmName/pv/localunmount' style='display:inline'><button class='btn btn-danger'>Unmount</button></form></div></div></div></div>"
                } else {
                    $pvVhd = Get-VHD -Path $pvPath -ErrorAction SilentlyContinue
                    $pvGB  = if ($pvVhd -and $pvVhd.Size -gt 0) { [math]::Round($pvVhd.Size / 1GB, 1) } else { '?' }
                    $pvSection = "<div class='card mb-3'><div class='card-header fw-bold'>&#x1F4BE; Persistent Volume ($pvGB GB)</div><div class='card-body d-flex align-items-center gap-3'><code class='small'>$pvPath</code><form method='post' action='/vm/$vmName/pv/localmount' style='display:inline' class='ms-auto'><button class='btn btn-sm btn-outline-primary'>&#x1F4E5; Mount on Host (P:)</button></form></div></div>"
                }
            }

            Write-PodeHtmlResponse -Value @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>$vmName — Hyper-V Compose</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css">
  <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/js/bootstrap.bundle.min.js"></script>
</head>
<body class="bg-light">
<div class="container mt-4">
  <a href="/" class="btn btn-outline-secondary btn-sm mb-3">&larr; Back</a>
  <h2>$vmName <span class="badge bg-$color">$($vm.State)</span>
    <a href="/vm/$vmName/docker" class="btn btn-info btn-sm ms-3">&#x1F433; Docker</a>
  </h2>
  <div class="row mt-3">
    <div class="col-md-4">
      <ul class="list-group mb-3">
        <li class="list-group-item"><strong>CPU:</strong> $cpuLabel</li>
        <li class="list-group-item"><strong>Memory:</strong> $memLabel</li>
        <li class="list-group-item"><strong>Generation:</strong> $($vm.Generation)</li>
        <li class="list-group-item"><strong>Uptime:</strong> $uptime</li>
      </ul>
      <div class="d-flex gap-2 mb-3">
        <form method="post" action="/vm/$vmName/start">  <button class="btn btn-success">Start</button></form>
        <form method="post" action="/vm/$vmName/stop">   <button class="btn btn-warning">Stop</button></form>
        <form method="post" action="/vm/$vmName/restart"><button class="btn btn-info">Restart</button></form>
      </div>
      $pvSection
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
    # POST /vm/:name/pv/localmount|localunmount
    # -------------------------------------------------------
    Add-PodeRoute -Method Post -Path "/vm/:name/pv/localmount" -ScriptBlock {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $vmName  = $WebEvent.Parameters['name']
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            $stack   = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmRoot  = if ($stack.vm_root) { $stack.vm_root } else { "C:\HyperV\VMs" }
            $pvPath  = Join-Path $vmRoot $vmName "persistent-storage.vhdx"
            if (-not (Test-Path $pvPath)) { throw "VHDX not found: $pvPath" }
            $vhd  = Mount-VHD -Path $pvPath -PassThru -ErrorAction Stop
            $disk = Get-Disk -Number $vhd.DiskNumber
            if ($disk.IsOffline)  { Set-Disk -Number $vhd.DiskNumber -IsOffline $false }
            if ($disk.IsReadOnly) { Set-Disk -Number $vhd.DiskNumber -IsReadOnly $false }
            $part = Get-Disk -Number $vhd.DiskNumber |
                Get-Partition |
                Where-Object { $_.Size -gt 100MB -and $_.Type -notin @('System','Reserved','Recovery') } |
                Select-Object -First 1
            if ($part) { $part | Set-Partition -NewDriveLetter 'P' }
        } catch { }
        Move-PodeResponseUrl -Url "/vm/$($WebEvent.Parameters['name'])"
    }

    Add-PodeRoute -Method Post -Path "/vm/:name/pv/localunmount" -ScriptBlock {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $vmName  = $WebEvent.Parameters['name']
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            $stack   = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmRoot  = if ($stack.vm_root) { $stack.vm_root } else { "C:\HyperV\VMs" }
            $pvPath  = Join-Path $vmRoot $vmName "persistent-storage.vhdx"
            $hostDisk = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.Location -eq $pvPath } | Select-Object -First 1
            if ($hostDisk) {
                Dismount-VHD -DiskNumber $hostDisk.Number -ErrorAction Stop
            } else {
                Dismount-VHD -Path $pvPath -ErrorAction Stop
            }
        } catch { }
        Move-PodeResponseUrl -Url "/vm/$($WebEvent.Parameters['name'])"
    }

    # -------------------------------------------------------
    # POST /vm/:name/start|stop|restart — actions
    # -------------------------------------------------------
    Add-PodeRoute -Method Post -Path "/vm/:name/start" -ScriptBlock {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $vmName = $WebEvent.Parameters['name']
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            $stack = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmCfg = $stack.vms[$vmName]
            $vmRoot = if ($stack.vm_root) { $stack.vm_root } else { "C:\HyperV\VMs" }

            $hasHostMountedConflict = $false
            foreach ($storageName in @($vmCfg.mount)) {
                if (-not $stack.storage[$storageName]) { continue }
                $rawPath = $stack.storage[$storageName].path
                $sp = if ([System.IO.Path]::IsPathRooted($rawPath)) { $rawPath } else { Join-Path $vmRoot $rawPath }
                $vhd = Get-VHD -Path $sp -ErrorAction SilentlyContinue
                $dnStr = "$($vhd.DiskNumber)"
                if ($vhd -and $vhd.Attached -and $dnStr -match '^\d+$') {
                    $hasHostMountedConflict = $true; break
                }
            }

            if (-not $hasHostMountedConflict -and (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
                Start-VM -Name $vmName -ErrorAction SilentlyContinue
            }
        } catch { }
        Move-PodeResponseUrl -Url "/"
    }

    Add-PodeRoute -Method Post -Path "/vm/:name/stop" -ScriptBlock {
        $vmName = $WebEvent.Parameters['name']
        if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) { Stop-VM -Name $vmName -Force -TurnOff -ErrorAction SilentlyContinue }
        Move-PodeResponseUrl -Url "/"
    }

    Add-PodeRoute -Method Post -Path "/vm/:name/restart" -ScriptBlock {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $vmName = $WebEvent.Parameters['name']
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            $stack = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmCfg = $stack.vms[$vmName]
            $vmRoot = if ($stack.vm_root) { $stack.vm_root } else { "C:\HyperV\VMs" }

            $hasHostMountedConflict = $false
            foreach ($storageName in @($vmCfg.mount)) {
                if (-not $stack.storage[$storageName]) { continue }
                $rawPath = $stack.storage[$storageName].path
                $sp = if ([System.IO.Path]::IsPathRooted($rawPath)) { $rawPath } else { Join-Path $vmRoot $rawPath }
                $vhd = Get-VHD -Path $sp -ErrorAction SilentlyContinue
                $dnStr = "$($vhd.DiskNumber)"
                if ($vhd -and $vhd.Attached -and $dnStr -match '^\d+$') {
                    $hasHostMountedConflict = $true; break
                }
            }

            if (-not $hasHostMountedConflict -and (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
                Restart-VM -Name $vmName -Force -ErrorAction SilentlyContinue
            }
        } catch { }
        Move-PodeResponseUrl -Url "/"
    }

    # -------------------------------------------------------
    # POST /storage/:name/localmount|localunmount — host drive actions
    # -------------------------------------------------------
    Add-PodeRoute -Method Post -Path "/storage/:name/localmount" -ScriptBlock {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $storageName = $WebEvent.Parameters['name']
            $cfgFile  = Get-PodeState -Name 'ConfigFile'
            $stack    = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmRoot   = if ($stack.vm_root) { $stack.vm_root } else { "C:\HyperV\VMs" }
            $rawPath  = $stack.storage[$storageName].path
            $sp       = if ([System.IO.Path]::IsPathRooted($rawPath)) { $rawPath } else { Join-Path $vmRoot $rawPath }

            $mountedVMs = @(
                Get-VM -ErrorAction SilentlyContinue |
                    Where-Object { (Get-VMHardDiskDrive -VMName $_.Name -ErrorAction SilentlyContinue |
                        Where-Object Path -eq $sp) } |
                    Select-Object -ExpandProperty Name
            )
            if ($mountedVMs.Count -gt 0) { throw "Storage '$storageName' is attached to VM(s): $($mountedVMs -join ', ')" }

            # Pick first available letter starting from S
            $letter = 'S','T','U','V','W','X','Y','Z','R','Q','P' |
                      Where-Object { -not (Test-Path "${_}:\") } | Select-Object -First 1
            if (-not $letter) { $letter = 'S' }

            $vhd = Mount-VHD -Path $sp -PassThru -ErrorAction Stop
            # Disk may come up offline — bring it online and writable before partition access
            $disk = Get-Disk -Number $vhd.DiskNumber
            if ($disk.IsOffline)  { Set-Disk -Number $vhd.DiskNumber -IsOffline $false }
            if ($disk.IsReadOnly) { Set-Disk -Number $vhd.DiskNumber -IsReadOnly $false }
            $partition = Get-Disk -Number $vhd.DiskNumber |
                Get-Partition |
                Where-Object { $_.Size -gt 100MB -and $_.Type -notin @('System','Reserved','Recovery') } |
                Select-Object -First 1
            if ($partition) { $partition | Set-Partition -NewDriveLetter $letter }
        } catch { }
        Move-PodeResponseUrl -Url "/"
    }

    Add-PodeRoute -Method Post -Path "/storage/:name/localunmount" -ScriptBlock {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $storageName = $WebEvent.Parameters['name']
            $cfgFile  = Get-PodeState -Name 'ConfigFile'
            $stack    = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmRoot   = if ($stack.vm_root) { $stack.vm_root } else { "C:\HyperV\VMs" }
            $rawPath  = $stack.storage[$storageName].path
            $sp       = if ([System.IO.Path]::IsPathRooted($rawPath)) { $rawPath } else { Join-Path $vmRoot $rawPath }
            # Dismount-VHD -Path fails when VMMS holds the file handle; use DiskNumber
            $hostDisk = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.Location -eq $sp } | Select-Object -First 1
            if ($hostDisk) {
                Dismount-VHD -DiskNumber $hostDisk.Number -ErrorAction Stop
            } else {
                Dismount-VHD -Path $sp -ErrorAction Stop
            }
        } catch { }
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

    # -------------------------------------------------------
    # GET /api/vm/:name/docker/ps — container list JSON
    # -------------------------------------------------------
    Add-PodeRoute -Method Get -Path "/api/vm/:name/docker/ps" -ScriptBlock {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $vmName  = $WebEvent.Parameters['name']
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            $stack   = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmCfg   = $stack.vms[$vmName]
            $cred    = $null
            if ($vmCfg -and $vmCfg.admin_password) {
                $secpw = ConvertTo-SecureString $vmCfg.admin_password -AsPlainText -Force
                $cred  = New-Object PSCredential('administrator', $secpw)
            }
            $icArgs = @{ VMName = $vmName; ErrorAction = 'Stop'; ScriptBlock = {
                $ps  = @(& docker ps -a --format '{{json .}}' 2>$null)
                $sts = @(& docker stats --no-stream --format '{{json .}}' 2>$null)
                $sm  = @{}; foreach ($s in $sts) { try { $o = $s | ConvertFrom-Json; $sm[$o.Name] = $o } catch {} }
                $pvDisk = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='P:'" -ErrorAction SilentlyContinue
                $out = @()
                foreach ($line in $ps) {
                    try {
                        $c = $line | ConvertFrom-Json
                        $cpu = '0%'; $mem = '0B / 0B'
                        if ($c.State -eq 'running' -and $sm.ContainsKey($c.Names)) {
                            $cpu = $sm[$c.Names].CPUPerc; $mem = $sm[$c.Names].MemUsage
                        }
                        $out += @{ name=$c.Names; image=$c.Image; status=$c.Status; state=$c.State; cpu=$cpu; mem=$mem; ports=$c.Ports; id=$c.ID }
                    } catch {}
                }
                [PSCustomObject]@{
                    Containers  = $out
                    PVTotalGB   = if ($pvDisk) { [math]::Round($pvDisk.Size / 1GB, 1) } else { $null }
                    PVFreeGB    = if ($pvDisk) { [math]::Round($pvDisk.FreeSpace / 1GB, 2) } else { $null }
                }
            } }
            if ($cred) { $icArgs.Credential = $cred }
            $res = Invoke-Command @icArgs
            Write-PodeJsonResponse -Value @{ containers = @($res.Containers); pvTotalGB = $res.PVTotalGB; pvFreeGB = $res.PVFreeGB }
        } catch {
            Write-PodeJsonResponse -StatusCode 500 -Value @{ error = $_.Exception.Message }
        }
    }

    # -------------------------------------------------------
    # GET /api/vm/:name/docker/:container/stats
    # -------------------------------------------------------
    Add-PodeRoute -Method Get -Path "/api/vm/:name/docker/:container/stats" -ScriptBlock {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $vmName    = $WebEvent.Parameters['name']
            $ctrName   = $WebEvent.Parameters['container']
            $cfgFile   = Get-PodeState -Name 'ConfigFile'
            $stack     = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmCfg     = $stack.vms[$vmName]
            $cred      = $null
            if ($vmCfg -and $vmCfg.admin_password) {
                $secpw = ConvertTo-SecureString $vmCfg.admin_password -AsPlainText -Force
                $cred  = New-Object PSCredential('administrator', $secpw)
            }
            $icArgs = @{ VMName = $vmName; ArgumentList = $ctrName; ErrorAction = 'Stop'; ScriptBlock = {
                param($cn)
                $s = & docker stats --no-stream --format '{{json .}}' $cn 2>$null | Select-Object -First 1
                if ($s) { return ($s | ConvertFrom-Json) } else { return $null }
            } }
            if ($cred) { $icArgs.Credential = $cred }
            $result = Invoke-Command @icArgs
            if ($result) {
                Write-PodeJsonResponse -Value @{ cpu=$result.CPUPerc; mem=$result.MemUsage; netIO=$result.NetIO; blockIO=$result.BlockIO; pids=$result.PIDs }
            } else {
                Write-PodeJsonResponse -Value @{ cpu='0%'; mem='0B / 0B'; netIO='-'; blockIO='-'; pids='0' }
            }
        } catch {
            Write-PodeJsonResponse -StatusCode 500 -Value @{ error = $_.Exception.Message }
        }
    }

    # -------------------------------------------------------
    # GET /api/vm/:name/docker/:container/logs
    # -------------------------------------------------------
    Add-PodeRoute -Method Get -Path "/api/vm/:name/docker/:container/logs" -ScriptBlock {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $vmName  = $WebEvent.Parameters['name']
            $ctrName = $WebEvent.Parameters['container']
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            $stack   = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmCfg   = $stack.vms[$vmName]
            $cred    = $null
            if ($vmCfg -and $vmCfg.admin_password) {
                $secpw = ConvertTo-SecureString $vmCfg.admin_password -AsPlainText -Force
                $cred  = New-Object PSCredential('administrator', $secpw)
            }
            $icArgs = @{ VMName = $vmName; ArgumentList = $ctrName; ErrorAction = 'Stop'; ScriptBlock = {
                param($cn)
                @(& docker logs --timestamps --tail 200 $cn 2>&1)
            } }
            if ($cred) { $icArgs.Credential = $cred }
            $lines = @(Invoke-Command @icArgs)
            Write-PodeJsonResponse -Value @{ lines = $lines }
        } catch {
            Write-PodeJsonResponse -StatusCode 500 -Value @{ error = $_.Exception.Message }
        }
    }

    # -------------------------------------------------------
    # POST /api/vm/:name/docker/:container/exec
    # -------------------------------------------------------
    Add-PodeRoute -Method Post -Path "/api/vm/:name/docker/:container/exec" -ScriptBlock {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $vmName  = $WebEvent.Parameters['name']
            $ctrName = $WebEvent.Parameters['container']
            $cmd     = $WebEvent.Data['cmd']
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            $stack   = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmCfg   = $stack.vms[$vmName]
            $cred    = $null
            if ($vmCfg -and $vmCfg.admin_password) {
                $secpw = ConvertTo-SecureString $vmCfg.admin_password -AsPlainText -Force
                $cred  = New-Object PSCredential('administrator', $secpw)
            }
            $icArgs = @{ VMName = $vmName; ArgumentList = $ctrName,$cmd; ErrorAction = 'Stop'; ScriptBlock = {
                param($cn, $userCmd)
                $parts = $userCmd -split '\s+', 2
                $exe   = $parts[0]
                $args2 = if ($parts.Count -gt 1) { $parts[1] } else { '' }
                if ($args2) {
                    @(& docker exec $cn cmd /c "$exe $args2" 2>&1)
                } else {
                    @(& docker exec $cn $exe 2>&1)
                }
            } }
            if ($cred) { $icArgs.Credential = $cred }
            $output = @(Invoke-Command @icArgs)
            Write-PodeJsonResponse -Value @{ output = ($output -join "`n") }
        } catch {
            Write-PodeJsonResponse -StatusCode 500 -Value @{ error = $_.Exception.Message }
        }
    }

    # -------------------------------------------------------
    # POST /vm/:name/docker/:container/start|stop|restart|remove
    # -------------------------------------------------------
    foreach ($action in @('start','stop','restart','remove')) {
        $actionCopy = $action
        Add-PodeRoute -Method Post -Path "/vm/:name/docker/:container/$action" -ScriptBlock {
            try {
                Import-Module powershell-yaml -ErrorAction Stop
                $vmName  = $WebEvent.Parameters['name']
                $ctrName = $WebEvent.Parameters['container']
                $act     = $WebEvent.Parameters['action']  # captured via route wildcard
                # Re-detect actual action from URL path
                $urlAct  = ($WebEvent.Request.Url.AbsolutePath -split '/')[-1]
                $cfgFile = Get-PodeState -Name 'ConfigFile'
                $stack   = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
                $vmCfg   = $stack.vms[$vmName]
                $cred    = $null
                if ($vmCfg -and $vmCfg.admin_password) {
                    $secpw = ConvertTo-SecureString $vmCfg.admin_password -AsPlainText -Force
                    $cred  = New-Object PSCredential('administrator', $secpw)
                }
                $icArgs = @{ VMName = $vmName; ArgumentList = $ctrName,$urlAct; ErrorAction = 'Stop'; ScriptBlock = {
                    param($cn, $a)
                    if ($a -eq 'remove') { & docker rm -f $cn 2>&1 }
                    elseif ($a -eq 'stop') { & docker stop $cn 2>&1 }
                    elseif ($a -eq 'start') { & docker start $cn 2>&1 }
                    elseif ($a -eq 'restart') { & docker restart $cn 2>&1 }
                } }
                if ($cred) { $icArgs.Credential = $cred }
                Invoke-Command @icArgs | Out-Null
            } catch { }
            Move-PodeResponseUrl -Url "/vm/$($WebEvent.Parameters['name'])/docker"
        }
    }

    # -------------------------------------------------------
    # GET /vm/:name/docker — Docker status page
    # -------------------------------------------------------
    Add-PodeRoute -Method Get -Path "/vm/:name/docker" -ScriptBlock {
        try {
            $vmName = $WebEvent.Parameters['name']
            $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
            if (-not $vm) { Write-PodeHtmlResponse -StatusCode 404 -Value "<h3>VM not found</h3>"; return }

            Write-PodeHtmlResponse -Value @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>$vmName Docker — Hyper-V Compose</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css">
</head>
<body class="bg-light">
<div class="container-fluid mt-3">
  <div class="d-flex align-items-center mb-3 gap-3">
    <a href="/vm/$vmName" class="btn btn-outline-secondary btn-sm">&larr; Back</a>
    <h3 class="mb-0">&#x1F433; $vmName — Docker</h3>
    <span id="pvBadge" class="badge bg-secondary ms-auto">P: loading...</span>
  </div>
  <div id="errorBanner" class="alert alert-danger d-none"></div>
  <table class="table table-sm table-bordered bg-white shadow-sm" id="ctrTable">
    <thead class="table-dark">
      <tr><th>Container</th><th>Image</th><th>Status</th><th>CPU</th><th>Memory</th><th>Ports</th><th>Actions</th></tr>
    </thead>
    <tbody id="ctrBody"><tr><td colspan="7" class="text-center text-muted">Loading...</td></tr></tbody>
  </table>
</div>
<script>
const vmName = '$vmName';
function pollContainers() {
  fetch('/api/vm/' + vmName + '/docker/ps')
    .then(r => r.json())
    .then(data => {
      if (data.error) { document.getElementById('errorBanner').textContent = data.error; document.getElementById('errorBanner').classList.remove('d-none'); return; }
      document.getElementById('errorBanner').classList.add('d-none');
      const pv = data.pvTotalGB != null ? 'P: ' + data.pvFreeGB + ' GB free / ' + data.pvTotalGB + ' GB' : 'P: not mounted';
      document.getElementById('pvBadge').textContent = pv;
      document.getElementById('pvBadge').className = 'badge ms-auto ' + (data.pvTotalGB != null ? 'bg-success' : 'bg-secondary');
      const tbody = document.getElementById('ctrBody');
      if (!data.containers || data.containers.length === 0) {
        tbody.innerHTML = '<tr><td colspan="7" class="text-center text-muted">No containers</td></tr>'; return;
      }
      tbody.innerHTML = data.containers.map(c => {
        const running = c.state === 'running';
        const badge = running ? '<span class="badge bg-success">running</span>' : '<span class="badge bg-secondary">' + c.state + '</span>';
        const actions = '<form method="post" action="/vm/' + vmName + '/docker/' + c.name + '/start" style="display:inline"><button class="btn btn-xs btn-sm btn-success py-0">&#x25B6;</button></form> ' +
          '<form method="post" action="/vm/' + vmName + '/docker/' + c.name + '/stop" style="display:inline"><button class="btn btn-xs btn-sm btn-warning py-0">&#x23F9;</button></form> ' +
          '<form method="post" action="/vm/' + vmName + '/docker/' + c.name + '/restart" style="display:inline"><button class="btn btn-xs btn-sm btn-info py-0">&#x21BA;</button></form> ' +
          '<form method="post" action="/vm/' + vmName + '/docker/' + c.name + '/remove" style="display:inline" onsubmit="return confirm(\'Remove ' + c.name + '?\')"><button class="btn btn-xs btn-sm btn-danger py-0">&#x1F5D1;</button></form>';
        const link = '<a href="/vm/' + vmName + '/docker/' + c.name + '">' + c.name + '</a>';
        return '<tr><td>' + link + '</td><td class="small"><code>' + c.image + '</code></td><td>' + badge + ' <span class="text-muted small">' + c.status + '</span></td><td>' + c.cpu + '</td><td class="small">' + c.mem + '</td><td class="small">' + (c.ports||'-') + '</td><td>' + actions + '</td></tr>';
      }).join('');
    })
    .catch(e => { document.getElementById('errorBanner').textContent = 'Fetch error: ' + e; document.getElementById('errorBanner').classList.remove('d-none'); });
}
pollContainers();
setInterval(pollContainers, 5000);
</script>
</body>
</html>
"@
        } catch {
            Write-PodeHtmlResponse -StatusCode 500 -Value "<pre>$($_.Exception.Message)`n$($_.ScriptStackTrace)</pre>"
        }
    }

    # -------------------------------------------------------
    # GET /vm/:name/docker/:container — container detail page
    # -------------------------------------------------------
    Add-PodeRoute -Method Get -Path "/vm/:name/docker/:container" -ScriptBlock {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $vmName  = $WebEvent.Parameters['name']
            $ctrName = $WebEvent.Parameters['container']
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            $stack   = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmCfg   = $stack.vms[$vmName]
            $cred    = $null
            if ($vmCfg -and $vmCfg.admin_password) {
                $secpw = ConvertTo-SecureString $vmCfg.admin_password -AsPlainText -Force
                $cred  = New-Object PSCredential('administrator', $secpw)
            }
            $icArgs = @{ VMName = $vmName; ArgumentList = $ctrName; ErrorAction = 'Stop'; ScriptBlock = {
                param($cn)
                $insp = & docker inspect $cn 2>$null | ConvertFrom-Json
                if (-not $insp) { return $null }
                $i = $insp[0]
                [PSCustomObject]@{
                    Name    = $i.Name.TrimStart('/')
                    Image   = $i.Config.Image
                    State   = $i.State.Status
                    Created = $i.Created
                    Cmd     = ($i.Config.Cmd -join ' ')
                    Env     = @($i.Config.Env)
                    Mounts  = @($i.Mounts | ForEach-Object { "$($_.Source) -> $($_.Destination) ($($_.Mode))" })
                    IPs     = @($i.NetworkSettings.Networks.Values | ForEach-Object { $_.IPAddress })
                    Ports   = ($i.NetworkSettings.Ports | ConvertTo-Json -Depth 2 -Compress)
                }
            } }
            if ($cred) { $icArgs.Credential = $cred }
            $info = Invoke-Command @icArgs

            if (-not $info) {
                Write-PodeHtmlResponse -StatusCode 404 -Value "<h3>Container '$ctrName' not found in VM '$vmName'</h3>"
                return
            }

            $envRows = ($info.Env | ForEach-Object { "<tr><td class='small font-monospace'>$_</td></tr>" }) -join ""
            $mntRows = ($info.Mounts | ForEach-Object { "<tr><td class='small'>$_</td></tr>" }) -join ""
            $ipList2 = ($info.IPs | Where-Object { $_ } | ForEach-Object { "<span class='badge bg-primary me-1'>$_</span>" }) -join ""
            $stateColor = if ($info.State -eq 'running') { 'success' } else { 'secondary' }

            Write-PodeHtmlResponse -Value @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>$ctrName — $vmName Docker</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css">
</head>
<body class="bg-light">
<div class="container-fluid mt-3">
  <div class="d-flex align-items-center mb-3 gap-2">
    <a href="/vm/$vmName/docker" class="btn btn-outline-secondary btn-sm">&larr; Back</a>
    <h3 class="mb-0">&#x1F4E6; $ctrName <span class="badge bg-$stateColor">$($info.State)</span></h3>
  </div>
  <div class="row">
    <div class="col-md-5">
      <div class="card mb-3">
        <div class="card-header fw-bold">Details</div>
        <ul class="list-group list-group-flush">
          <li class="list-group-item"><strong>Image:</strong> <code>$($info.Image)</code></li>
          <li class="list-group-item"><strong>Created:</strong> $($info.Created)</li>
          <li class="list-group-item"><strong>Command:</strong> <code class="small">$($info.Cmd)</code></li>
          <li class="list-group-item"><strong>IPs:</strong> $ipList2</li>
          <li class="list-group-item"><strong>Ports:</strong> <code class="small">$($info.Ports)</code></li>
        </ul>
      </div>
      <div class="card mb-3" id="statsCard">
        <div class="card-header fw-bold">Live Stats</div>
        <ul class="list-group list-group-flush">
          <li class="list-group-item"><strong>CPU:</strong> <span id="sCpu">-</span></li>
          <li class="list-group-item"><strong>Memory:</strong> <span id="sMem">-</span></li>
          <li class="list-group-item"><strong>Net I/O:</strong> <span id="sNet">-</span></li>
          <li class="list-group-item"><strong>Block I/O:</strong> <span id="sBlock">-</span></li>
          <li class="list-group-item"><strong>PIDs:</strong> <span id="sPids">-</span></li>
        </ul>
      </div>
      <div class="d-flex gap-2 mb-3 flex-wrap">
        <form method="post" action="/vm/$vmName/docker/$ctrName/start"><button class="btn btn-success btn-sm">&#x25B6; Start</button></form>
        <form method="post" action="/vm/$vmName/docker/$ctrName/stop"><button class="btn btn-warning btn-sm">&#x23F9; Stop</button></form>
        <form method="post" action="/vm/$vmName/docker/$ctrName/restart"><button class="btn btn-info btn-sm">&#x21BA; Restart</button></form>
        <form method="post" action="/vm/$vmName/docker/$ctrName/remove" onsubmit="return confirm('Remove $ctrName?')"><button class="btn btn-danger btn-sm">&#x1F5D1; Remove</button></form>
      </div>
      <div class="card mb-3">
        <div class="card-header fw-bold">Mounts</div>
        <table class="table table-sm mb-0">$(if ($mntRows) { $mntRows } else { '<tr><td class="text-muted">None</td></tr>' })</table>
      </div>
      <div class="card mb-3">
        <div class="card-header fw-bold">Environment</div>
        <div style="max-height:200px;overflow-y:auto"><table class="table table-sm mb-0">$(if ($envRows) { $envRows } else { '<tr><td class="text-muted">None</td></tr>' })</table></div>
      </div>
    </div>
    <div class="col-md-7">
      <div class="card mb-3">
        <div class="card-header fw-bold d-flex align-items-center">
          Terminal
          <button class="btn btn-sm btn-outline-secondary ms-auto py-0" onclick="document.getElementById('termLog').textContent=''">Clear</button>
        </div>
        <div class="card-body p-2">
          <div id="termLog" style="background:#111;color:#eee;font-family:monospace;font-size:12px;height:180px;overflow-y:auto;padding:8px;white-space:pre-wrap;"></div>
          <div class="input-group mt-2">
            <span class="input-group-text">$</span>
            <input id="termInput" type="text" class="form-control font-monospace" placeholder="command..." />
            <button class="btn btn-primary" onclick="runCmd()">Run</button>
          </div>
        </div>
      </div>
      <div class="card">
        <div class="card-header fw-bold d-flex align-items-center">
          Stdout Log <span class="badge bg-secondary ms-2" id="logCount">0 lines</span>
          <button class="btn btn-sm btn-outline-secondary ms-auto py-0" id="copyBtn" onclick="copyLog()">&#x1F4CB; Copy</button>
        </div>
        <div id="logViewer" style="background:#111;color:#eee;font-family:monospace;font-size:12px;height:350px;overflow-y:auto;padding:8px;white-space:pre-wrap;"></div>
      </div>
    </div>
  </div>
</div>
<script>
const vmName = '$vmName', ctrName = '$ctrName';
let logLines = [];
function pollStats() {
  fetch('/api/vm/' + vmName + '/docker/' + ctrName + '/stats')
    .then(r => r.json()).then(d => {
      if (d.error) return;
      document.getElementById('sCpu').textContent   = d.cpu;
      document.getElementById('sMem').textContent   = d.mem;
      document.getElementById('sNet').textContent   = d.netIO;
      document.getElementById('sBlock').textContent = d.blockIO;
      document.getElementById('sPids').textContent  = d.pids;
    }).catch(() => {});
}
function pollLogs() {
  fetch('/api/vm/' + vmName + '/docker/' + ctrName + '/logs')
    .then(r => r.json()).then(d => {
      if (d.error || !d.lines) return;
      logLines = d.lines;
      const el = document.getElementById('logViewer');
      el.textContent = logLines.join('\n');
      el.scrollTop = el.scrollHeight;
      document.getElementById('logCount').textContent = logLines.length + ' lines';
    }).catch(() => {});
}
function copyLog() {
  navigator.clipboard.writeText(logLines.join('\n')).then(() => {
    const btn = document.getElementById('copyBtn');
    btn.textContent = '✓ Copied!'; setTimeout(() => btn.innerHTML = '&#x1F4CB; Copy', 2000);
  });
}
function runCmd() {
  const input = document.getElementById('termInput');
  const cmd = input.value.trim();
  if (!cmd) return;
  const log = document.getElementById('termLog');
  log.textContent += '$ ' + cmd + '\n';
  input.value = '';
  fetch('/api/vm/' + vmName + '/docker/' + ctrName + '/exec', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'cmd=' + encodeURIComponent(cmd)
  }).then(r => r.json()).then(d => {
    log.textContent += (d.output || d.error || '') + '\n';
    log.scrollTop = log.scrollHeight;
  }).catch(e => { log.textContent += '[error] ' + e + '\n'; log.scrollTop = log.scrollHeight; });
}
document.getElementById('termInput').addEventListener('keydown', e => { if (e.key === 'Enter') runCmd(); });
pollStats(); pollLogs();
setInterval(pollStats, 3000);
setInterval(pollLogs, 2000);
</script>
</body>
</html>
"@
        } catch {
            Write-PodeHtmlResponse -StatusCode 500 -Value "<pre>$($_.Exception.Message)`n$($_.ScriptStackTrace)</pre>"
        }
    }
}
