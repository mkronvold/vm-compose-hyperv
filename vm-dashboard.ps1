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

    # Load shared VHD/storage helper functions into all route runspaces
    Use-PodeScript (Join-Path $PSScriptRoot 'vm-lib.ps1')

    # -------------------------------------------------------
    # Background timer: refresh Docker stats for all VMs every 10 s.
    # Results are cached in Pode state so the route returns instantly,
    # preventing concurrent Invoke-Command calls that race on
    # Pode's internal GetNewClosure() and cause NullReferenceExceptions.
    # -------------------------------------------------------
    Add-PodeTimer -Name 'DockerStatsPoller' -Interval 10 -ScriptBlock {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            if (-not $cfgFile) { return }
            $stack = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            if (-not $stack) { return }
            foreach ($vmName in $stack.vms.Keys) {
                $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
                if (-not $vm -or $vm.State -ne 'Running') { continue }
                $vmCfg = $stack.vms[$vmName]
                $cred  = $null
                if ($vmCfg -and $vmCfg.admin_password) {
                    $secpw = ConvertTo-SecureString $vmCfg.admin_password -AsPlainText -Force
                    $cred  = New-Object PSCredential('administrator', $secpw)
                }
                $icArgs = @{
                    VMName      = $vmName
                    ErrorAction = 'Stop'
                    ScriptBlock = {
                        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
                            return '{"dockerInstalled":false,"dockerRunning":false,"containers":[],"pvTotalGB":null,"pvFreeGB":null}'
                        }
                        $svc = Get-Service docker -ErrorAction SilentlyContinue
                        $dockerRunning = [bool]($svc -and $svc.Status -eq 'Running')
                        if (-not $dockerRunning) {
                            return ([PSCustomObject]@{ dockerInstalled=$true; dockerRunning=$false; containers=@(); pvTotalGB=$null; pvFreeGB=$null } | ConvertTo-Json -Compress)
                        }
                        $ps = @(& docker ps -a --format '{{json .}}' 2>$null)
                        $statsJob = Start-Job { & docker stats --no-stream --format '{{json .}}' 2>$null }
                        $null = Wait-Job $statsJob -Timeout 6
                        $sts = @(Receive-Job $statsJob 2>$null)
                        Remove-Job $statsJob -Force -ErrorAction SilentlyContinue
                        $sm = @{}
                        foreach ($s in $sts) {
                            try { $o = $s | ConvertFrom-Json; if ($o.Name) { $sm[$o.Name] = $o } } catch {}
                        }
                        $pvDisk = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='P:'" -ErrorAction SilentlyContinue
                        $out = [System.Collections.Generic.List[object]]::new()
                        foreach ($line in $ps) {
                            try {
                                $c = $line | ConvertFrom-Json
                                $cpu = '0%'; $mem = '0B / 0B'
                                if ($c -and $c.State -eq 'running' -and $c.Names -and $sm.ContainsKey($c.Names)) {
                                    $cpu = $sm[$c.Names].CPUPerc; $mem = $sm[$c.Names].MemUsage
                                }
                                if ($c) { $out.Add([PSCustomObject]@{ name=$c.Names; image=$c.Image; status=$c.Status; state=$c.State; cpu=$cpu; mem=$mem; ports=$c.Ports; id=$c.ID }) }
                            } catch {}
                        }
                        $pvTotal = if ($pvDisk) { [math]::Round($pvDisk.Size / 1GB, 1) } else { $null }
                        $pvFree  = if ($pvDisk) { [math]::Round($pvDisk.FreeSpace / 1GB, 2) } else { $null }
                        return ([PSCustomObject]@{ dockerInstalled=$true; dockerRunning=$true; containers=$out.ToArray(); pvTotalGB=$pvTotal; pvFreeGB=$pvFree } | ConvertTo-Json -Compress -Depth 5)
                    }
                }
                if ($cred) { $icArgs.Credential = $cred }
                try {
                    $raw = Invoke-Command @icArgs
                    $json = if ($raw -is [array]) { $raw | Where-Object { $_ -is [string] } | Select-Object -Last 1 } else { [string]$raw }
                    if ($json) { Set-PodeState -Name "DockerCache_$vmName" -Value $json }
                } catch {
                    # Keep stale cache on error; don't overwrite good data with an error
                }
            }
        } catch {}
    }

    # -------------------------------------------------------
    # GET / — dashboard
    # -------------------------------------------------------
    Add-PodeRoute -Method Get -Path "/" -ScriptBlock {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            $stack   = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $flashMsg = if ($WebEvent.Query.ContainsKey('flash')) { [uri]::UnescapeDataString($WebEvent.Query['flash']) } else { '' }
            $flashAlert = if ($flashMsg) { "<div class='alert alert-danger alert-dismissible fade show' role='alert'><strong>Error:</strong> $([System.Net.WebUtility]::HtmlEncode($flashMsg))<button type='button' class='btn-close' data-bs-dismiss='alert'></button></div>" } else { '' }

            $rows = ""
            foreach ($vmName in $stack.vms.Keys) {
                $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
                if (-not $vm) {
                    $rows += "<tr><td><a href='/vm/$vmName'>$vmName</a></td><td><span class='badge bg-secondary'>Not Created</span></td><td>-</td><td>-</td><td>-</td><td>-</td><td>-</td><td></td></tr>"
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
                # Docker status from cache (populated by background timer — no blocking call here)
                $dockerCell = if ($vm.State -ne 'Running') { '<td>-</td>' } else {
                    $dc = Get-PodeState -Name "DockerCache_$vmName"
                    if (-not $dc) { '<td><span class="text-muted">…</span></td>' }
                    else {
                        try {
                            $dcObj = $dc | ConvertFrom-Json
                            if ($dcObj.dockerRunning) { '<td><span class="badge bg-success">&#x1F433; Running</span></td>' }
                            else { '<td><span class="badge bg-danger">Stopped</span></td>' }
                        } catch { '<td>-</td>' }
                    }
                }
                $rows += @"
                <tr>
                  <td><a href="/vm/$vmName">$vmName</a>$evalBadge</td>
                  <td><span class="badge bg-$color">$($vm.State)</span></td>
                  <td>$cpuLabel</td>
                  <td>$memLabel</td>
                  <td>$(if ($ip) { $ip } else { '-' })</td>
                  <td>$uptime</td>
                  $dockerCell
                  <td>
                    <form method="post" action="/vm/$vmName/start"   style="display:inline"><button class="btn btn-sm btn-success">Start</button></form>
                    <form method="post" action="/vm/$vmName/stop"    style="display:inline"><button class="btn btn-sm btn-warning">Stop</button></form>
                    <form method="post" action="/vm/$vmName/restart" style="display:inline"><button class="btn btn-sm btn-info">Restart</button></form>
                  </td>
                </tr>
"@
            }

            # Build unified storage table (shared storage + persistent volumes)
            $vmRoot = if ($stack.vm_root) { $stack.vm_root } else { "C:\HyperV\VMs" }
            $vmRootPrefix = $vmRoot.TrimEnd('\') + '\'
            $storageRows = ""

            # Helper: compute disk size/alloc/hostDrive from a vhdx path
            # Returns hashtable: usedGB, pctAlloc, diskNum, hostDrive
            function Get-VHDStats {
                param([string]$sp)
                $r = @{ usedGB = '-'; pctAlloc = '-'; diskNum = $null; hostDrive = '-' }
                if (-not (Test-Path $sp)) { return $r }
                $r.usedGB = [math]::Round((Get-Item $sp).Length / 1GB, 2)
                $vhd = Get-VHD -Path $sp -ErrorAction SilentlyContinue
                if ($vhd -and $vhd.Size -gt 0) { $r.pctAlloc = '{0:0}%' -f ($vhd.FileSize / $vhd.Size * 100) }
                $dnStr = "$($vhd.DiskNumber)"
                if ($vhd -and $vhd.Attached -and $dnStr -match '^\d+$') { $r.diskNum = [int]$dnStr }
                if ($null -eq $r.diskNum) {
                    $hd = Get-Disk -ErrorAction SilentlyContinue | Where-Object { ($_.Location -replace '/', '\') -ieq $sp } | Select-Object -First 1
                    if ($hd) { $r.diskNum = [int]$hd.Number }
                }
                if ($null -ne $r.diskNum) {
                    $dl = Get-Disk -Number $r.diskNum -ErrorAction SilentlyContinue |
                          Get-Partition -ErrorAction SilentlyContinue |
                          Where-Object { $_.DriveLetter -and $_.DriveLetter -ne [char]0 } |
                          Select-Object -First 1 -ExpandProperty DriveLetter
                    $r.hostDrive = if ($dl) { "${dl}:\" } else { "Attached" }
                }
                $r
            }

            # Helper: build the Actions dropdown cell for a storage item
            function Get-StorageActions {
                param([string]$hostDrive, [string[]]$mountedVMs, [hashtable]$routes)
                # $routes keys: localmount, localunmount, vmount_prefix (base url, vmname appended), vunmount_prefix, driveLetter
                if ($hostDrive -ne '-') {
                    return "<form method='post' action='$($routes.localunmount)' style='display:inline'><button class='btn btn-sm btn-warning'>&#x23CF; Unmount from Host</button></form>"
                }
                if ($mountedVMs.Count -gt 0) {
                    $ddItems = ""
                    foreach ($vn in $mountedVMs) {
                        $url = if ($routes.vunmount_prefix) { "$($routes.vunmount_prefix)$vn" } else { $routes.vunmount }
                        $ddItems += "<li><form method='post' action='$url' style='margin:0'><button type='submit' class='dropdown-item'>&#x23CF; Detach from VM: $vn</button></form></li>"
                    }
                    $ddItems += "<li><hr class='dropdown-divider'></li>"
                    $ddItems += "<li><form method='post' action='$($routes.localmount)' style='margin:0'><button type='submit' class='dropdown-item'>&#x1F5A5; Move to Host ($($routes.driveLetter):)</button></form></li>"
                    return "<div class='btn-group'><button type='button' class='btn btn-sm btn-outline-warning dropdown-toggle' data-bs-toggle='dropdown'>&#x23CF; Detach / Move</button><ul class='dropdown-menu'>$ddItems</ul></div>"
                }
                # Neither — show Mount dropdown
                $ddItems = "<li><form method='post' action='$($routes.localmount)' style='margin:0'><button type='submit' class='dropdown-item'>&#x1F5A5; Mount on Host ($($routes.driveLetter):)</button></form></li>"
                foreach ($vn in $routes.vmsForMount) {
                    $url = if ($routes.vmount_prefix) { "$($routes.vmount_prefix)$vn" } else { $routes.vmount }
                    $ddItems += "<li><form method='post' action='$url' style='margin:0'><button type='submit' class='dropdown-item'>&#x1F4BB; Add to VM: $vn</button></form></li>"
                }
                return "<div class='btn-group'><button type='button' class='btn btn-sm btn-outline-primary dropdown-toggle' data-bs-toggle='dropdown'>&#x1F4BE; Mount</button><ul class='dropdown-menu'>$ddItems</ul></div>"
            }

            # ---- Shared storage rows ----
            if ($stack.storage) {
                foreach ($storageName in $stack.storage.Keys) {
                    $sCfg    = $stack.storage[$storageName]
                    $rawPath = $sCfg.path
                    $sp      = if ([System.IO.Path]::IsPathRooted($rawPath)) { $rawPath } else { Join-Path $vmRoot $rawPath }
                    $sp      = $sp -replace '/', '\'
                    $spShort = if ($sp.StartsWith($vmRootPrefix, [StringComparison]::OrdinalIgnoreCase)) { $sp.Substring($vmRootPrefix.Length) } else { $sp }
                    $virtGB  = $sCfg.size_gb
                    $vmsForStorage = @($stack.vms.Keys | Where-Object { $stack.vms[$_].mount -contains $storageName })
                    $mountedVMsArray = @(Get-VMsWithDisk $sp)

                    if (Test-Path $sp) {
                        $stats = Get-VHDStats $sp
                        $mountedDisplay = if ($stats.hostDrive -ne '-') {
                            "<span class='badge bg-info text-dark'>Host: $($stats.hostDrive)</span>"
                        } elseif ($mountedVMsArray.Count -gt 0) {
                            ($mountedVMsArray | ForEach-Object { "<span class='badge bg-success'>$_</span>" }) -join ' '
                        } else { '-' }

                        $actionBtn = Get-StorageActions -hostDrive $stats.hostDrive -mountedVMs $mountedVMsArray -routes @{
                            localmount    = "/storage/$storageName/localmount"
                            localunmount  = "/storage/$storageName/localunmount"
                            vmount_prefix = "/storage/$storageName/vmount/"
                            vunmount_prefix = "/storage/$storageName/vunmount/"
                            vmsForMount   = $vmsForStorage
                            driveLetter   = 'S'
                        }
                        $storageRows += "<tr><td><strong>$storageName</strong></td><td><code class='small'>$spShort</code></td><td>$($virtGB) GB</td><td>$($stats.usedGB) GB</td><td>$($stats.pctAlloc)</td><td>$mountedDisplay</td><td>$actionBtn</td></tr>"
                    } else {
                        $storageRows += "<tr><td><strong>$storageName</strong></td><td><code class='small'>$spShort</code></td><td>$($virtGB) GB</td><td>-</td><td>-</td><td>-</td><td><span class='badge bg-danger'>MISSING</span></td></tr>"
                    }
                }
            }

            # ---- Persistent volume rows ----
            foreach ($pvVmName in $stack.vms.Keys) {
                $vmCfg = $stack.vms[$pvVmName]
                if (-not $vmCfg.persistent_disk_gb) { continue }
                $pvPath  = (Join-Path $vmRoot $pvVmName "persistent-storage.vhdx") -replace '/', '\'
                $pvShort = if ($pvPath.StartsWith($vmRootPrefix, [StringComparison]::OrdinalIgnoreCase)) { $pvPath.Substring($vmRootPrefix.Length) } else { $pvPath }
                $virtGB  = $vmCfg.persistent_disk_gb
                $mountedVMsArray = @(Get-VMsWithDisk $pvPath)

                if (Test-Path $pvPath) {
                    $stats = Get-VHDStats $pvPath
                    $mountedDisplay = if ($stats.hostDrive -ne '-') {
                        "<span class='badge bg-info text-dark'>Host: $($stats.hostDrive)</span>"
                    } elseif ($mountedVMsArray.Count -gt 0) {
                        ($mountedVMsArray | ForEach-Object { "<span class='badge bg-success'>$_</span>" }) -join ' '
                    } else { '-' }

                    $actionBtn = Get-StorageActions -hostDrive $stats.hostDrive -mountedVMs $mountedVMsArray -routes @{
                        localmount   = "/vm/$pvVmName/pv/localmount"
                        localunmount = "/vm/$pvVmName/pv/localunmount"
                        vmount_prefix = $null
                        vmount       = "/vm/$pvVmName/pv/vmount"
                        vunmount_prefix = $null
                        vunmount     = "/vm/$pvVmName/pv/vunmount"
                        vmsForMount  = @($pvVmName)
                        driveLetter  = 'P'
                    }
                    $storageRows += "<tr><td><strong>$pvVmName</strong> <span class='badge bg-secondary'>PV</span></td><td><code class='small'>$pvShort</code></td><td>$($virtGB) GB</td><td>$($stats.usedGB) GB</td><td>$($stats.pctAlloc)</td><td>$mountedDisplay</td><td>$actionBtn</td></tr>"
                } else {
                    $storageRows += "<tr><td><strong>$pvVmName</strong> <span class='badge bg-secondary'>PV</span></td><td><code class='small'>$pvShort</code></td><td>$($virtGB) GB</td><td>-</td><td>-</td><td>-</td><td><span class='badge bg-danger'>MISSING</span></td></tr>"
                }
            }

            $storageSection = if ($storageRows) { @"
<h4 class="mt-4">&#x1F4BE; Storage</h4>
<table class="table table-sm table-bordered bg-white shadow-sm">
  <thead class="table-dark">
    <tr><th>Name</th><th>Path</th><th>Virtual</th><th>On Disk</th><th>%Alloc</th><th>Mounted</th><th>Actions</th></tr>
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
  $flashAlert
  <h1 class="mb-1">&#x1F5A5; Hyper-V Compose</h1>
  <p class="text-muted mb-3">Auto-refreshes every 10 seconds</p>
  <table class="table table-bordered table-hover bg-white shadow-sm">
    <thead class="table-dark">
      <tr><th>VM</th><th>State</th><th>CPU</th><th>Memory</th><th>IP</th><th>Uptime</th><th>Docker</th><th>Actions</th></tr>
    </thead>
    <tbody>$rows</tbody>
  </table>
  $storageSection
  <p class="text-muted small">Metrics: <a href="http://localhost:9090/metrics" target="_blank">http://localhost:9090/metrics</a></p>
</div>
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/js/bootstrap.bundle.min.js"></script>
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
            # Docker status from cache (non-blocking)
            $dockerStatusHtml = ''
            if ($vm.State -eq 'Running') {
                $dc = Get-PodeState -Name "DockerCache_$vmName"
                if ($dc) {
                    try {
                        $dcObj = $dc | ConvertFrom-Json
                        $dockerStatusHtml = if ($dcObj.dockerRunning) {
                            "<span class='badge bg-success'>&#x1F433; Running</span>"
                        } else {
                            "<span class='badge bg-danger'>Stopped</span>"
                        }
                    } catch { $dockerStatusHtml = '-' }
                } else { $dockerStatusHtml = '<span class="text-muted">…</span>' }
            } else { $dockerStatusHtml = '-' }
            $color    = switch ($vm.State.ToString()) {
                "Running" { "success" } "Off" { "secondary" } "Saved" { "info" }
                "Paused"  { "warning" } default { "danger" }
            }
            $ips      = @($adapters.IPAddresses | Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' })
            $ipList   = ($ips        | ForEach-Object { "<li class='list-group-item'>$_</li>" }) -join ""
            $snapList = ($snaps.Name | ForEach-Object { "<li class='list-group-item'>$_</li>" }) -join ""
            $macList  = ($adapters | ForEach-Object {
                $mac = $_.MacAddress -replace '(..)(?!$)','$1:'
                "<li class='list-group-item'><code>$mac</code></li>"
            }) -join ""
            $swList   = ($adapters | ForEach-Object {
                "<li class='list-group-item'>$($_.SwitchName)&nbsp;<span class='text-muted small'>$($_.Name)</span></li>"
            }) -join ""

            # Build disk table (merges VM disks + persistent volume mount controls)
            $vmRootPrefix = $vmRoot.TrimEnd('\') + '\'
            $pvPath = Join-Path $vmRoot $vmName "persistent-storage.vhdx"
            # Build shared storage path map
            $sharedPathMap = @{}
            if ($stack.storage) {
                foreach ($sn in $stack.storage.Keys) {
                    $rp = $stack.storage[$sn].path
                    $sPath = if ([System.IO.Path]::IsPathRooted($rp)) { $rp } else { Join-Path $vmRoot $rp }
                    $sPath = $sPath -replace '/', '\'
                    $sharedPathMap[$sPath.ToLower()] = $sn
                }
            }
            $hasPvDisk = $false
            $diskTableRows = ($disks | ForEach-Object {
                $rawDiskPath = $_.Path
                # Walk VHD chain to base (resolve .avhdx differencing disk -> root .vhdx)
                $basePath = $rawDiskPath
                $baseVhd  = Get-VHD -Path $rawDiskPath -ErrorAction SilentlyContinue
                $itr = 0
                while ($baseVhd -and $baseVhd.VhdType -eq 'Differencing' -and $baseVhd.ParentPath -and $itr -lt 10) {
                    $basePath = $baseVhd.ParentPath
                    $baseVhd  = Get-VHD -Path $basePath -ErrorAction SilentlyContinue
                    $itr++
                }
                $basePath = $basePath -replace '/', '\'  # normalize separators for consistent comparison
                $shortPath = if ($basePath.StartsWith($vmRootPrefix, [StringComparison]::OrdinalIgnoreCase)) { $basePath.Substring($vmRootPrefix.Length) } else { $basePath }

                # Determine disk role
                $diskRole = 'OS Disk'
                if ($basePath -ieq $pvPath) {
                    $diskRole = 'Persistent Volume'
                } elseif ($sharedPathMap.ContainsKey($basePath.ToLower())) {
                    $diskRole = "SharedData: $($sharedPathMap[$basePath.ToLower()])"
                }

                # Size info from base VHD
                $vSizeGB = '-'; $uSizeGB = '-'; $pctStr = '-'
                if ($baseVhd -and $baseVhd.Size -gt 0) {
                    $vSizeGB = "$([math]::Round($baseVhd.Size / 1GB, 1)) GB"
                    $uSizeGB = "$([math]::Round($baseVhd.FileSize / 1GB, 2)) GB"
                    $pctStr  = '{0:0}%' -f ($baseVhd.FileSize / $baseVhd.Size * 100)
                }

                $statusCell  = "<span class='badge bg-info'>VM attached</span>"
                $actionsCell = ''

                if ($diskRole -eq 'Persistent Volume') {
                    $script:hasPvDisk = $true
                    $pvHostDisk = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.Location -eq $basePath } | Select-Object -First 1
                    if ($pvHostDisk) {
                        $pvDl = Get-Disk -Number $pvHostDisk.Number -ErrorAction SilentlyContinue |
                            Get-Partition -ErrorAction SilentlyContinue |
                            Where-Object { $_.DriveLetter -and $_.DriveLetter -ne [char]0 } |
                            Select-Object -First 1 -ExpandProperty DriveLetter
                        $pvLabel = if ($pvDl) { "${pvDl}:\" } else { "Attached" }
                        $statusCell  = "<span class='badge bg-warning text-dark'>Host: $pvLabel</span>"
                        $actionsCell = "<button type='button' class='btn btn-sm btn-danger' data-bs-toggle='modal' data-bs-target='#pvUnmountModal'>&#x23CF; Unmount from Host</button>"
                    } else {
                        $actionsCell = @"
<form method='post' action='/vm/$vmName/pv/vunmount' style='display:inline'>
  <button class='btn btn-sm btn-outline-secondary' onclick="return confirm('Detach persistent volume from this VM?')">&#x23CF; Detach</button>
</form>
<form method='post' action='/vm/$vmName/pv/localmount' style='display:inline'>
  <button class='btn btn-sm btn-outline-primary' onclick="return confirm('Detach persistent volume from VM and mount on host (P:)?')">&#x1F5A5; Move to Host</button>
</form>
"@
                    }
                } elseif ($diskRole -like 'SharedData: *') {
                    $sn = $diskRole.Substring(12)  # strip 'SharedData: ' prefix
                    $actionsCell = @"
<form method='post' action='/storage/$sn/vunmount/$vmName' style='display:inline'>
  <button class='btn btn-sm btn-outline-secondary' onclick="return confirm('Detach $sn from this VM?')">&#x23CF; Detach</button>
</form>
<form method='post' action='/storage/$sn/localmount' style='display:inline'>
  <button class='btn btn-sm btn-outline-primary' onclick="return confirm('Detach $sn from this VM and mount on host (S:)?')">&#x1F5A5; Move to Host</button>
</form>
"@
                }

                "<tr><td>$diskRole</td><td><code class='small'>$shortPath</code></td><td>$vSizeGB</td><td>$uSizeGB</td><td>$pctStr</td><td>$statusCell</td><td>$actionsCell</td></tr>"
            }) -join ""

            $pvUnmountModal = if ($hasPvDisk) { "<div class='modal fade' id='pvUnmountModal' tabindex='-1'><div class='modal-dialog'><div class='modal-content'><div class='modal-header'><h5 class='modal-title'>Unmount Persistent Volume?</h5><button type='button' class='btn-close' data-bs-dismiss='modal'></button></div><div class='modal-body'><p class='text-danger fw-bold'>Warning: unmounting while Docker containers are running may cause data loss or container crashes.</p></div><div class='modal-footer'><button type='button' class='btn btn-secondary' data-bs-dismiss='modal'>Cancel</button><form method='post' action='/vm/$vmName/pv/localunmount' style='display:inline'><button class='btn btn-danger'>Unmount</button></form></div></div></div></div>" } else { "" }

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
        <li class="list-group-item"><strong>Docker:</strong> $dockerStatusHtml</li>
      </ul>
      <div class="d-flex gap-2 mb-3">
        <form method="post" action="/vm/$vmName/start">  <button class="btn btn-success">Start</button></form>
        <form method="post" action="/vm/$vmName/stop">   <button class="btn btn-warning">Stop</button></form>
        <form method="post" action="/vm/$vmName/restart"><button class="btn btn-info">Restart</button></form>
      </div>
    </div>
    <div class="col-md-8">
      <h5>IP Addresses</h5><ul class="list-group mb-3">$(if ($ipList) { $ipList } else { '<li class="list-group-item text-muted">None</li>' })</ul>
      <h5>MAC Addresses</h5><ul class="list-group mb-3">$(if ($macList) { $macList } else { '<li class="list-group-item text-muted">None</li>' })</ul>
      <h5>Switches</h5><ul class="list-group mb-3">$(if ($swList) { $swList } else { '<li class="list-group-item text-muted">None</li>' })</ul>
      <h5>Checkpoints</h5><ul class="list-group mb-3">$(if ($snapList) { $snapList } else { '<li class="list-group-item text-muted">None</li>' })</ul>
      $(if ($vm.Notes) { "<h5>Notes</h5><pre class='bg-white p-2 border rounded'>$($vm.Notes)</pre>" })
    </div>
  </div>
  <h5 class="mt-2">Disks</h5>
  <table class="table table-sm table-bordered bg-white shadow-sm">
    <thead class="table-dark">
      <tr><th>Role</th><th>Path</th><th>Virtual Size</th><th>On Disk</th><th>% Alloc</th><th>Status</th><th></th></tr>
    </thead>
    <tbody>$(if ($diskTableRows) { $diskTableRows } else { '<tr><td colspan="7" class="text-muted">No disks</td></tr>' })</tbody>
  </table>
</div>
$pvUnmountModal
</body>
</html>
"@
        } catch {
            Write-PodeHtmlResponse -StatusCode 500 -Value "<pre>$($_.Exception.Message)`n$($_.ScriptStackTrace)</pre>"
        }
    }

    # -------------------------------------------------------
    # POST /vm/:name/pv/vmount|localmount|localunmount|vunmount
    # -------------------------------------------------------
    Add-PodeRoute -Method Post -Path "/vm/:name/pv/vmount" -ScriptBlock {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $vmName  = $WebEvent.Parameters['name']
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            $stack   = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmRoot  = if ($stack.vm_root) { $stack.vm_root } else { "C:\HyperV\VMs" }
            $vmCfg   = $stack.vms[$vmName]
            $cred    = $null
            if ($vmCfg -and $vmCfg.admin_password) {
                $secpw = ConvertTo-SecureString $vmCfg.admin_password -AsPlainText -Force
                $cred  = New-Object PSCredential('administrator', $secpw)
            }
            $storageName = "pv-$vmName"
            $labelName = if ($stack.storage -and $stack.storage[$storageName]) { $storageName } else { 'DockerData' }
            $pvPath  = (Join-Path $vmRoot $vmName "persistent-storage.vhdx") -replace '/', '\'
            if (-not (Test-Path $pvPath)) { throw "VHDX not found: $pvPath" }
            $hostDisk = Get-Disk -ErrorAction SilentlyContinue | Where-Object { ($_.Location -replace '/', '\') -ieq $pvPath } | Select-Object -First 1
            if ($hostDisk) { throw "PV is currently mounted on the host. Unmount it first." }
            if (-not (Get-VMDiskForPath -VmName $vmName -StoragePath $pvPath)) {
                Add-VMHardDiskDrive -VMName $vmName -Path $pvPath -ErrorAction Stop
            }
            # Start Docker inside the VM now that P:\docker-data is available again
            Invoke-VMDockerControl -VmName $vmName -Cred $cred -Action 'start' -DockerVolumeLabel $labelName -EnsureDaemonConfig
        } catch { }
        Move-PodeResponseUrl -Url "/"
    }

    Add-PodeRoute -Method Post -Path "/vm/:name/pv/localmount" -ScriptBlock {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $vmName  = $WebEvent.Parameters['name']
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            $stack   = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmRoot  = if ($stack.vm_root) { $stack.vm_root } else { "C:\HyperV\VMs" }
            $vmCfg   = $stack.vms[$vmName]
            $cred    = $null
            if ($vmCfg -and $vmCfg.admin_password) {
                $secpw = ConvertTo-SecureString $vmCfg.admin_password -AsPlainText -Force
                $cred  = New-Object PSCredential('administrator', $secpw)
            }
            $pvPath  = (Join-Path $vmRoot $vmName "persistent-storage.vhdx") -replace '/', '\'
            if (-not (Test-Path $pvPath)) { throw "VHDX not found: $pvPath" }
            # Stop Docker inside the VM before detaching P:\docker-data
            Invoke-VMDockerControl -VmName $vmName -Cred $cred -Action 'stop'
            # Detach from VM if currently attached (handles .avhdx differencing disks)
            $drive = Get-VMDiskForPath -VmName $vmName -StoragePath $pvPath
            if ($drive) { Remove-VMHardDiskDrive -VMHardDiskDrive $drive -ErrorAction SilentlyContinue }
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
        Move-PodeResponseUrl -Url "/"
    }

    Add-PodeRoute -Method Post -Path "/vm/:name/pv/vunmount" -ScriptBlock {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $vmName  = $WebEvent.Parameters['name']
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            $stack   = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmRoot  = if ($stack.vm_root) { $stack.vm_root } else { "C:\HyperV\VMs" }
            $vmCfg   = $stack.vms[$vmName]
            $cred    = $null
            if ($vmCfg -and $vmCfg.admin_password) {
                $secpw = ConvertTo-SecureString $vmCfg.admin_password -AsPlainText -Force
                $cred  = New-Object PSCredential('administrator', $secpw)
            }
            $storageName = "pv-$vmName"
            $labelName = if ($stack.storage -and $stack.storage[$storageName]) { $storageName } else { 'DockerData' }
            # Stop Docker inside the VM before losing access to P:\docker-data
            Invoke-VMDockerControl -VmName $vmName -Cred $cred -Action 'stop' -DockerVolumeLabel $labelName
            $pvPath  = (Join-Path $vmRoot $vmName "persistent-storage.vhdx") -replace '/', '\'
            $drive = Get-VMDiskForPath -VmName $vmName -StoragePath $pvPath
            if ($drive) { Remove-VMHardDiskDrive -VMHardDiskDrive $drive -ErrorAction Stop }
        } catch { }
        Move-PodeResponseUrl -Url "/"
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
        Move-PodeResponseUrl -Url "/"
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
                $sp = $sp -replace '/', '\'
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
                $sp = $sp -replace '/', '\'
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
        $routeError = $null
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $storageName = $WebEvent.Parameters['name']
            $cfgFile  = Get-PodeState -Name 'ConfigFile'
            $stack    = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmRoot   = if ($stack.vm_root) { $stack.vm_root } else { "C:\HyperV\VMs" }
            $rawPath  = $stack.storage[$storageName].path
            $sp       = if ([System.IO.Path]::IsPathRooted($rawPath)) { $rawPath } else { Join-Path $vmRoot $rawPath }
            $sp       = $sp -replace '/', '\'

            $letter = 'S','T','U','V','W','X','Y','Z','R','Q','P' |
                      Where-Object { -not (Test-Path "${_}:\") } | Select-Object -First 1
            if (-not $letter) { $letter = 'S' }

            # Check if any VM currently has this disk attached (by base .vhdx, not differencing .avhdx)
            $attachedVMNames = @(Get-VMsWithDisk $sp)

            if ($attachedVMNames.Count -gt 0) {
                # Detach from every VM and retry mount (VMMS can be slow to release the handle)
                $vhd = $null; $lastMountErrMsg = '(unknown)'
                for ($attempt = 0; $attempt -lt 15; $attempt++) {
                    $attachedVMNames | ForEach-Object {
                        $drive = Get-VMDiskForPath -VmName $_ -StoragePath $sp
                        if ($drive) { Remove-VMHardDiskDrive -VMHardDiskDrive $drive -ErrorAction SilentlyContinue }
                    }
                    try {
                        $vhd = Mount-VHD -Path $sp -PassThru -ErrorAction Stop
                        break
                    } catch {
                        $lastMountErrMsg = $_.Exception.Message
                        if ($attempt -lt 14) { Start-Sleep -Seconds 1 }
                    }
                }
                if (-not $vhd) { throw "Mount-VHD failed after 15 attempts: $lastMountErrMsg" }
            } else {
                # No VM has the disk — check for file lock (vmwp.exe still releasing handle)
                $fileLocked = $false
                try {
                    $fs = [System.IO.File]::Open($sp, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                    $fs.Dispose()
                } catch { $fileLocked = $true }

                if ($fileLocked) {
                    throw "The VHD file is still locked by the Hyper-V worker process (vmwp.exe). " +
                          "This happens when Docker containers inside the VM have the volume mounted — " +
                          "stop those containers first, then try again in a few seconds."
                }

                # VHD in orphaned attached state? Try Dismount-VHD first.
                $vhdInfo = Get-VHD -Path $sp -ErrorAction SilentlyContinue
                if ($vhdInfo -and $vhdInfo.Attached) {
                    Dismount-VHD -Path $sp -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 1
                }

                $vhd = Mount-VHD -Path $sp -PassThru -ErrorAction Stop
            }

            # Disk may come up offline — bring it online and writable before partition access
            $disk = Get-Disk -Number $vhd.DiskNumber
            if ($disk.IsOffline)  { Set-Disk -Number $vhd.DiskNumber -IsOffline $false }
            if ($disk.IsReadOnly) { Set-Disk -Number $vhd.DiskNumber -IsReadOnly $false }
            $partition = Get-Disk -Number $vhd.DiskNumber |
                Get-Partition |
                Where-Object { $_.Size -gt 100MB -and $_.Type -notin @('System','Reserved','Recovery') } |
                Select-Object -First 1
            if ($partition) { $partition | Set-Partition -NewDriveLetter $letter }
        } catch {
            $routeError = "localmount '$storageName': $($_.Exception.Message)"
        }
        if ($routeError) {
            $errMsg = [uri]::EscapeDataString($routeError)
            Move-PodeResponseUrl -Url "/?flash=$errMsg"
        } else {
            Move-PodeResponseUrl -Url "/"
        }
    }

    Add-PodeRoute -Method Post -Path "/storage/:name/localunmount" -ScriptBlock {
        $routeError = $null
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $storageName = $WebEvent.Parameters['name']
            $cfgFile  = Get-PodeState -Name 'ConfigFile'
            $stack    = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmRoot   = if ($stack.vm_root) { $stack.vm_root } else { "C:\HyperV\VMs" }
            $rawPath  = $stack.storage[$storageName].path
            $sp       = if ([System.IO.Path]::IsPathRooted($rawPath)) { $rawPath } else { Join-Path $vmRoot $rawPath }
            $sp       = $sp -replace '/', '\'
            # Dismount-VHD -Path fails when VMMS holds the file handle; use DiskNumber
            $hostDisk = Get-Disk -ErrorAction SilentlyContinue | Where-Object { ($_.Location -replace '/', '\') -ieq $sp } | Select-Object -First 1
            if ($hostDisk) {
                Dismount-VHD -DiskNumber $hostDisk.Number -ErrorAction Stop
            } else {
                Dismount-VHD -Path $sp -ErrorAction Stop
            }
        } catch {
            $routeError = "localunmount '$storageName': $($_.Exception.Message)"
        }
        if ($routeError) {
            Move-PodeResponseUrl -Url "/?flash=$([uri]::EscapeDataString($routeError))"
        } else {
            Move-PodeResponseUrl -Url "/"
        }
    }

    # -------------------------------------------------------
    # POST /storage/:name/vmount/:vmname   — add VHDX to VM as a disk
    # POST /storage/:name/vunmount/:vmname — remove VHDX from VM
    # -------------------------------------------------------
    Add-PodeRoute -Method Post -Path "/storage/:name/vmount/:vmname" -ScriptBlock {
        $routeError = $null
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $storageName = $WebEvent.Parameters['name']
            $vmName      = $WebEvent.Parameters['vmname']
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            $stack   = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmRoot  = if ($stack.vm_root) { $stack.vm_root } else { "C:\HyperV\VMs" }
            $rawPath = $stack.storage[$storageName].path
            $sp      = if ([System.IO.Path]::IsPathRooted($rawPath)) { $rawPath } else { Join-Path $vmRoot $rawPath }
            $sp      = $sp -replace '/', '\'

            $hostDisk = Get-Disk -ErrorAction SilentlyContinue | Where-Object { ($_.Location -replace '/', '\') -ieq $sp } | Select-Object -First 1
            if ($hostDisk) { throw "Storage '$storageName' is currently mounted on the host. Unmount it first." }

            $alreadyAttached = @(Get-VMsWithDisk $sp | Where-Object { $_ -ne $vmName })
            if ($alreadyAttached.Count -gt 0) { throw "Storage '$storageName' is already attached to VM(s): $($alreadyAttached -join ', ')" }

            $vmCfg = $stack.vms[$vmName]
            $cred = $null
            if ($vmCfg -and $vmCfg.admin_password) {
                $secpw = ConvertTo-SecureString $vmCfg.admin_password -AsPlainText -Force
                $cred  = New-Object PSCredential('administrator', $secpw)
            }
            $isNamedPvForVm = ($storageName -match '^pv-') -and (($storageName -replace '^pv-','') -ieq $vmName)
            if ($isNamedPvForVm) {
                Invoke-VMDockerControl -VmName $vmName -Cred $cred -Action 'stop' -DockerVolumeLabel $storageName
            }

            if (-not (Get-VMDiskForPath -VmName $vmName -StoragePath $sp)) {
                Add-VMHardDiskDrive -VMName $vmName -Path $sp -ErrorAction Stop
            }

            if ($isNamedPvForVm) {
                Invoke-VMDockerControl -VmName $vmName -Cred $cred -Action 'start' -DockerVolumeLabel $storageName -EnsureDaemonConfig
            }
        } catch {
            $routeError = "vmount '$storageName' -> '$vmName': $($_.Exception.Message)"
        }
        if ($routeError) {
            Move-PodeResponseUrl -Url "/?flash=$([uri]::EscapeDataString($routeError))"
        } else {
            Move-PodeResponseUrl -Url "/"
        }
    }

    Add-PodeRoute -Method Post -Path "/storage/:name/vunmount/:vmname" -ScriptBlock {
        $routeError = $null
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $storageName = $WebEvent.Parameters['name']
            $vmName      = $WebEvent.Parameters['vmname']
            $cfgFile = Get-PodeState -Name 'ConfigFile'
            $stack   = Get-Content $cfgFile -Raw | ConvertFrom-Yaml
            $vmRoot  = if ($stack.vm_root) { $stack.vm_root } else { "C:\HyperV\VMs" }
            $rawPath = $stack.storage[$storageName].path
            $sp      = if ([System.IO.Path]::IsPathRooted($rawPath)) { $rawPath } else { Join-Path $vmRoot $rawPath }
            $sp      = $sp -replace '/', '\'

            $vmCfg = $stack.vms[$vmName]
            $cred = $null
            if ($vmCfg -and $vmCfg.admin_password) {
                $secpw = ConvertTo-SecureString $vmCfg.admin_password -AsPlainText -Force
                $cred  = New-Object PSCredential('administrator', $secpw)
            }
            $isNamedPvForVm = ($storageName -match '^pv-') -and (($storageName -replace '^pv-','') -ieq $vmName)
            if ($isNamedPvForVm) {
                Invoke-VMDockerControl -VmName $vmName -Cred $cred -Action 'stop' -DockerVolumeLabel $storageName
            }

            $drive = Get-VMDiskForPath -VmName $vmName -StoragePath $sp
            if ($drive) { Remove-VMHardDiskDrive -VMHardDiskDrive $drive -ErrorAction Stop }
        } catch {
            $routeError = "vunmount '$storageName' from '$vmName': $($_.Exception.Message)"
        }
        if ($routeError) {
            Move-PodeResponseUrl -Url "/?flash=$([uri]::EscapeDataString($routeError))"
        } else {
            Move-PodeResponseUrl -Url "/"
        }
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
    # GET /api/vm/:name/docker/ps — container list JSON (served from cache)
    # The actual polling is done by the DockerStatsPoller timer so this
    # route always returns in <1 ms, eliminating concurrent-request races.
    # -------------------------------------------------------
    Add-PodeRoute -Method Get -Path "/api/vm/:name/docker/ps" -ScriptBlock {
        $vmName  = $WebEvent.Parameters['name']
        $jsonStr = Get-PodeState -Name "DockerCache_$vmName"
        if (-not $jsonStr) {
            $jsonStr = '{"dockerInstalled":true,"containers":[],"pvTotalGB":null,"pvFreeGB":null}'
        }
        Write-PodeTextResponse -ContentType 'application/json' -Value $jsonStr
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
                if ($s) {
                    $o = $s | ConvertFrom-Json
                    return ([PSCustomObject]@{ cpu=$o.CPUPerc; mem=$o.MemUsage; netIO=$o.NetIO; blockIO=$o.BlockIO; pids=$o.PIDs } | ConvertTo-Json -Compress)
                } else {
                    return '{"cpu":"0%","mem":"0B / 0B","netIO":"-","blockIO":"-","pids":"0"}'
                }
            } }
            if ($cred) { $icArgs.Credential = $cred }
            $jsonStr = [string](Invoke-Command @icArgs | Where-Object { $_ -is [string] } | Select-Object -Last 1)
            if (-not $jsonStr) { $jsonStr = '{"cpu":"0%","mem":"0B / 0B","netIO":"-","blockIO":"-","pids":"0"}' }
            Write-PodeTextResponse -ContentType 'application/json' -Value $jsonStr
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
                # Force all output (including 2>&1 ErrorRecords) to strings before returning
                @(& docker logs --timestamps --tail 200 $cn 2>&1) | ForEach-Object { "$_" }
            } }
            if ($cred) { $icArgs.Credential = $cred }
            $lines = @(Invoke-Command @icArgs) | ForEach-Object { "$_" }
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
      if (data.dockerInstalled === false) {
        document.getElementById('ctrBody').innerHTML = '<tr><td colspan="7" class="text-center text-warning fw-semibold">&#x26A0;&#xFE0F; Docker is not installed on this VM</td></tr>';
        return;
      }
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
