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

function Get-StackVMs {
    $stack = Get-Content $ConfigFile | ConvertFrom-Yaml
    return $stack.vms.Keys
}

function Get-PrometheusMetrics {
    param([string[]]$vmNames)

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

    foreach ($vmName in $vmNames) {
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
            continue
        }

        $isRunning  = $vm.State -eq 'Running'
        $state      = if ($isRunning) { 1 } else { 0 }
        $cpu        = $vm.CPUUsage
        $memAssigned = $vm.MemoryAssigned   # 0 when VM is Off
        $memStartup  = $vm.MemoryStartup    # configured value, non-zero even when Off
        $uptimeSec  = if ($vm.Uptime) { [math]::Floor($vm.Uptime.TotalSeconds) } else { 0 }

        $ip = (Get-VMNetworkAdapter -VMName $vmName).IPAddresses |
              Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' } |
              Select-Object -First 1
        $ipAssigned = if ($ip) { 1 } else { 0 }

        $dockerRunning = 0
        if ($isRunning) {
            try {
                $result = Invoke-Command -VMName $vmName -ScriptBlock {
                    (Get-Service docker -ErrorAction SilentlyContinue).Status -eq 'Running'
                } -ErrorAction Stop
                $dockerRunning = if ($result) { 1 } else { 0 }
            } catch { $dockerRunning = 0 }
        }

        $lines += "hyperv_vm_exists{vm=`"$vmName`"} 1"
        $lines += "hyperv_vm_state{vm=`"$vmName`"} $state"
        $lines += "hyperv_vm_cpu_usage_percent{vm=`"$vmName`"} $cpu"
        $lines += "hyperv_vm_memory_assigned_bytes{vm=`"$vmName`"} $memAssigned"
        $lines += "hyperv_vm_memory_startup_bytes{vm=`"$vmName`"} $memStartup"
        $lines += "hyperv_vm_uptime_seconds{vm=`"$vmName`"} $uptimeSec"
        $lines += "hyperv_vm_ip_assigned{vm=`"$vmName`"} $ipAssigned"
        $lines += "hyperv_vm_docker_running{vm=`"$vmName`"} $dockerRunning"
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
                    $vmNames = Get-StackVMs
                    $cachedMetrics = Get-PrometheusMetrics $vmNames
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
