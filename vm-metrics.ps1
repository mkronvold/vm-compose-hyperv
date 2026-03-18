<#
.SYNOPSIS
    Hyper-V Compose Prometheus metrics exporter.
    Listens on http://localhost:9090/metrics and exports per-VM metrics.

.USAGE
    # Run directly (foreground):
    ./vm-metrics.ps1

    # Run as a Windows service (after installing):
    Start-Service vm-metrics

.NOTES
    Install as a service with: ./vm-metrics-install.ps1
    Requires PowerShell 7+ and Hyper-V module.
#>

param(
    [int]$Port = 9090,
    [string]$ConfigFile = "vmstack.yaml",
    [int]$RefreshSeconds = 15
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not [System.IO.Path]::IsPathRooted($ConfigFile)) {
    $ConfigFile = Join-Path $scriptDir $ConfigFile
}

if (-not (Test-Path $ConfigFile)) {
    Write-Error "Config file not found: $ConfigFile"
    exit 1
}

# Must be explicit for SYSTEM account — auto-loading doesn't always work
Import-Module powershell-yaml -ErrorAction SilentlyContinue
if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
    Write-Error "powershell-yaml module not available. Run: Install-Module powershell-yaml -Scope AllUsers"
    exit 1
}

function Get-StackConfig {
    return (Get-Content $ConfigFile | ConvertFrom-Yaml)
}

function Get-PrometheusMetrics {
    param($stack)

    $lines = @()
    $lines += "# HELP hyperv_vm_exists Whether the VM is known to Hyper-V (1=exists, 0=not found)"
    $lines += "# TYPE hyperv_vm_exists gauge"
    $lines += "# HELP hyperv_vm_state VM running state (1=Running, 0=other)"
    $lines += "# TYPE hyperv_vm_state gauge"
    $lines += "# HELP hyperv_vm_cpu_usage_percent VM CPU usage percent"
    $lines += "# TYPE hyperv_vm_cpu_usage_percent gauge"
    $lines += "# HELP hyperv_vm_memory_assigned_bytes VM currently assigned memory in bytes"
    $lines += "# TYPE hyperv_vm_memory_assigned_bytes gauge"
    $lines += "# HELP hyperv_vm_memory_startup_bytes VM configured startup memory in bytes"
    $lines += "# TYPE hyperv_vm_memory_startup_bytes gauge"
    $lines += "# HELP hyperv_vm_uptime_seconds VM uptime in seconds"
    $lines += "# TYPE hyperv_vm_uptime_seconds gauge"
    $lines += "# HELP hyperv_vm_ip_assigned Whether the VM has an IPv4 address (1=yes, 0=no)"
    $lines += "# TYPE hyperv_vm_ip_assigned gauge"
    $lines += "# HELP hyperv_vm_docker_running Whether Docker is running inside the VM (1=yes, 0=no)"
    $lines += "# TYPE hyperv_vm_docker_running gauge"
    $lines += "# HELP hyperv_vm_eval_days_remaining Days remaining on Windows evaluation license (-1 if fully licensed or unknown)"
    $lines += "# TYPE hyperv_vm_eval_days_remaining gauge"
    $lines += "# HELP hyperv_vm_docker_container_count Total Docker containers in the VM (-1 if Docker not running)"
    $lines += "# TYPE hyperv_vm_docker_container_count gauge"
    $lines += "# HELP hyperv_vm_docker_running_count Number of running Docker containers in the VM"
    $lines += "# TYPE hyperv_vm_docker_running_count gauge"
    $lines += "# HELP hyperv_vm_pv_bytes_total Total bytes on the persistent volume P: in the VM (-1 if not mounted)"
    $lines += "# TYPE hyperv_vm_pv_bytes_total gauge"
    $lines += "# HELP hyperv_vm_pv_bytes_free Free bytes on the persistent volume P: in the VM"
    $lines += "# TYPE hyperv_vm_pv_bytes_free gauge"
    $lines += "# HELP hyperv_container_running Whether the container is running (1=running, 0=stopped)"
    $lines += "# TYPE hyperv_container_running gauge"
    $lines += "# HELP hyperv_container_cpu_percent Container CPU usage percent"
    $lines += "# TYPE hyperv_container_cpu_percent gauge"
    $lines += "# HELP hyperv_container_mem_usage_bytes Container memory usage in bytes"
    $lines += "# TYPE hyperv_container_mem_usage_bytes gauge"
    $lines += "# HELP hyperv_container_mem_limit_bytes Container memory limit in bytes"
    $lines += "# TYPE hyperv_container_mem_limit_bytes gauge"

    foreach ($vmName in $stack.vms.Keys) {
        $vmCfg = $stack.vms[$vmName]
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if (-not $vm) {
            $lines += "hyperv_vm_exists{vm=`"$vmName`"} 0"
            $lines += "hyperv_vm_state{vm=`"$vmName`"} 0"
            $lines += "hyperv_vm_cpu_usage_percent{vm=`"$vmName`"} 0"
            $lines += "hyperv_vm_memory_assigned_bytes{vm=`"$vmName`"} 0"
            $lines += "hyperv_vm_memory_startup_bytes{vm=`"$vmName`"} 0"
            $lines += "hyperv_vm_uptime_seconds{vm=`"$vmName`"} 0"
            $lines += "hyperv_vm_ip_assigned{vm=`"$vmName`"} 0"
            $lines += "hyperv_vm_docker_running{vm=`"$vmName`"} 0"
            $lines += "hyperv_vm_eval_days_remaining{vm=`"$vmName`"} -1"
            $lines += "hyperv_vm_docker_container_count{vm=`"$vmName`"} -1"
            $lines += "hyperv_vm_docker_running_count{vm=`"$vmName`"} -1"
            $lines += "hyperv_vm_pv_bytes_total{vm=`"$vmName`"} -1"
            $lines += "hyperv_vm_pv_bytes_free{vm=`"$vmName`"} -1"
            continue
        }

        $isRunning   = $vm.State -eq 'Running'
        $state       = if ($isRunning) { 1 } else { 0 }
        $cpu         = $vm.CPUUsage
        $memAssigned = $vm.MemoryAssigned
        $memStartup  = $vm.MemoryStartup
        $uptimeSec   = if ($vm.Uptime) { [math]::Floor($vm.Uptime.TotalSeconds) } else { 0 }

        $ip = (Get-VMNetworkAdapter -VMName $vmName).IPAddresses |
              Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' } |
              Select-Object -First 1
        $ipAssigned = if ($ip) { 1 } else { 0 }

        $dockerRunning    = 0
        $evalDays         = -1
        $containerCount   = -1
        $runningCount     = -1
        $pvTotalBytes     = -1
        $pvFreeBytes      = -1
        $containerMetrics = @()

        if ($isRunning) {
            $cred = $null
            if ($vmCfg -and $vmCfg.admin_password) {
                $secpw = ConvertTo-SecureString $vmCfg.admin_password -AsPlainText -Force
                $cred  = New-Object PSCredential('administrator', $secpw)
            }
            $icArgs = @{
                VMName      = $vmName
                ScriptBlock = {
                    $dockerSvc = (Get-Service docker -ErrorAction SilentlyContinue).Status -eq 'Running'
                    $slp = Get-WmiObject -Class SoftwareLicensingProduct -ErrorAction SilentlyContinue |
                        Where-Object { $_.ApplicationID -eq '55c92734-d682-4d71-983e-d6ec3f16059f' -and
                                       $_.PartialProductKey -and $_.GracePeriodRemaining -gt 0 } |
                        Select-Object -First 1
                    $containerList = @()
                    $cCount = 0; $rCount = 0; $pvTotal = -1; $pvFree = -1
                    if ($dockerSvc) {
                        function ConvertDockerSize($s) {
                            if ($s -match '([\d.]+)\s*(B|kB|MB|GB|KiB|MiB|GiB)') {
                                $v = [double]$Matches[1]
                                switch ($Matches[2]) {
                                    'B'   { return [long]$v }
                                    'kB'  { return [long]($v * 1000) }
                                    'MB'  { return [long]($v * 1000000) }
                                    'GB'  { return [long]($v * 1000000000) }
                                    'KiB' { return [long]($v * 1024) }
                                    'MiB' { return [long]($v * 1048576) }
                                    'GiB' { return [long]($v * 1073741824) }
                                    default { return [long]-1 }
                                }
                            }
                            return [long]-1
                        }
                        $psLines    = @(& docker ps -a --format '{{json .}}' 2>$null)
                        $cCount     = $psLines.Count
                        $statsLines = @(& docker stats --no-stream --format '{{json .}}' 2>$null)
                        $statsMap   = @{}
                        foreach ($sl in $statsLines) {
                            try { $s = $sl | ConvertFrom-Json; $statsMap[$s.Name] = $s } catch {}
                        }
                        foreach ($pl in $psLines) {
                            try {
                                $c   = $pl | ConvertFrom-Json
                                $cn  = $c.Names
                                $run = $c.State -eq 'running'
                                if ($run) { $rCount++ }
                                $cpuPct = 0.0; $memU = [long]0; $memL = [long]0
                                if ($run -and $statsMap.ContainsKey($cn)) {
                                    $st     = $statsMap[$cn]
                                    $cpuPct = [double]($st.CPUPerc -replace '[^0-9.]', '')
                                    $parts  = $st.MemUsage -split ' / '
                                    $memU   = ConvertDockerSize $parts[0]
                                    $memL   = ConvertDockerSize $parts[1]
                                }
                                $containerList += [PSCustomObject]@{
                                    Name     = $cn
                                    Running  = if ($run) { 1 } else { 0 }
                                    CpuPct   = $cpuPct
                                    MemUsage = $memU
                                    MemLimit = $memL
                                }
                            } catch {}
                        }
                        $disk = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='P:'" -ErrorAction SilentlyContinue
                        if ($disk) { $pvTotal = [long]$disk.Size; $pvFree = [long]$disk.FreeSpace }
                    }
                    [PSCustomObject]@{
                        Docker         = $dockerSvc
                        EvalMins       = if ($slp) { $slp.GracePeriodRemaining } else { -1 }
                        ContainerCount = $cCount
                        RunningCount   = $rCount
                        Containers     = $containerList
                        PVTotalBytes   = $pvTotal
                        PVFreeBytes    = $pvFree
                    }
                }
                ErrorAction = 'Stop'
            }
            if ($cred) { $icArgs.Credential = $cred }
            try {
                $result         = Invoke-Command @icArgs
                $dockerRunning  = if ($result.Docker) { 1 } else { 0 }
                $evalDays       = if ($result.EvalMins -ge 0) { [math]::Floor($result.EvalMins / 1440) } else { -1 }
                $containerCount = $result.ContainerCount
                $runningCount   = $result.RunningCount
                $pvTotalBytes   = $result.PVTotalBytes
                $pvFreeBytes    = $result.PVFreeBytes
                $containerMetrics = @($result.Containers)
            } catch { $dockerRunning = 0; $evalDays = -1 }
        }

        $lines += "hyperv_vm_exists{vm=`"$vmName`"} 1"
        $lines += "hyperv_vm_state{vm=`"$vmName`"} $state"
        $lines += "hyperv_vm_cpu_usage_percent{vm=`"$vmName`"} $cpu"
        $lines += "hyperv_vm_memory_assigned_bytes{vm=`"$vmName`"} $memAssigned"
        $lines += "hyperv_vm_memory_startup_bytes{vm=`"$vmName`"} $memStartup"
        $lines += "hyperv_vm_uptime_seconds{vm=`"$vmName`"} $uptimeSec"
        $lines += "hyperv_vm_ip_assigned{vm=`"$vmName`"} $ipAssigned"
        $lines += "hyperv_vm_docker_running{vm=`"$vmName`"} $dockerRunning"
        $lines += "hyperv_vm_eval_days_remaining{vm=`"$vmName`"} $evalDays"
        $lines += "hyperv_vm_docker_container_count{vm=`"$vmName`"} $containerCount"
        $lines += "hyperv_vm_docker_running_count{vm=`"$vmName`"} $runningCount"
        $lines += "hyperv_vm_pv_bytes_total{vm=`"$vmName`"} $pvTotalBytes"
        $lines += "hyperv_vm_pv_bytes_free{vm=`"$vmName`"} $pvFreeBytes"
        foreach ($c in $containerMetrics) {
            $cl = $c.Name
            $lines += "hyperv_container_running{vm=`"$vmName`",container=`"$cl`"} $($c.Running)"
            $lines += "hyperv_container_cpu_percent{vm=`"$vmName`",container=`"$cl`"} $($c.CpuPct)"
            $lines += "hyperv_container_mem_usage_bytes{vm=`"$vmName`",container=`"$cl`"} $($c.MemUsage)"
            $lines += "hyperv_container_mem_limit_bytes{vm=`"$vmName`",container=`"$cl`"} $($c.MemLimit)"
        }
    }

    return $lines -join "`n"
}

$url = "http://+:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($url)

try {
    $listener.Start()
    Write-Host "vm-metrics exporter listening on http://localhost:$Port/metrics"
    Write-Host "Config: $ConfigFile | Refresh: every ${RefreshSeconds}s"

    $cachedMetrics = ""
    $lastRefresh = [datetime]::MinValue

    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response

        if ($request.Url.AbsolutePath -eq "/metrics") {
            if (([datetime]::UtcNow - $lastRefresh).TotalSeconds -ge $RefreshSeconds) {
                try {
                    $stack = Get-StackConfig
                    $cachedMetrics = Get-PrometheusMetrics $stack
                } catch {
                    $cachedMetrics = "# ERROR: $($_.Exception.Message)"
                }
                $lastRefresh = [datetime]::UtcNow
            }

            $body = [System.Text.Encoding]::UTF8.GetBytes($cachedMetrics)
            $response.ContentType = "text/plain; version=0.0.4; charset=utf-8"
            $response.ContentLength64 = $body.Length
            $response.StatusCode = 200
            $response.OutputStream.Write($body, 0, $body.Length)
        } else {
            $body = [System.Text.Encoding]::UTF8.GetBytes("Not found. Try /metrics")
            $response.StatusCode = 404
            $response.ContentLength64 = $body.Length
            $response.OutputStream.Write($body, 0, $body.Length)
        }

        $response.OutputStream.Close()
    }
} finally {
    $listener.Stop()
}
