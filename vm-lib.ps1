# vm-lib.ps1 — shared Hyper-V storage helpers
# Used by vm-compose.ps1 (dot-sourced) and vm-dashboard.ps1 (via Use-PodeScript)

# Walk the VHD parent chain from DiskPath up to 10 levels.
# Returns $true if TargetPath appears anywhere in the chain (handles .avhdx when VM has checkpoints).
function Test-VHDIsInChain {
    param([string]$DiskPath, [string]$TargetPath)
    $p = $DiskPath  -replace '/', '\'
    $t = $TargetPath -replace '/', '\'
    if ($p -ieq $t) { return $true }
    $v = Get-VHD -Path $p -ErrorAction SilentlyContinue; $i = 0
    while ($v -and $v.VhdType -eq 'Differencing' -and $v.ParentPath -and $i -lt 10) {
        $p = $v.ParentPath -replace '/', '\'
        if ($p -ieq $t) { return $true }
        $v = Get-VHD -Path $p -ErrorAction SilentlyContinue; $i++
    }
    $false
}

# Return names of all VMs that have StoragePath anywhere in any disk's VHD chain.
function Get-VMsWithDisk {
    param([string]$StoragePath)
    $sp = $StoragePath -replace '/', '\'
    @(Get-VM -ErrorAction SilentlyContinue |
        Where-Object {
            (Get-VMHardDiskDrive -VMName $_.Name -ErrorAction SilentlyContinue |
                Where-Object { Test-VHDIsInChain $_.Path $sp })
        } |
        Select-Object -ExpandProperty Name)
}

# Return the VMHardDiskDrive object for VmName whose VHD chain includes StoragePath, or $null.
function Get-VMDiskForPath {
    param([string]$VmName, [string]$StoragePath)
    $sp = $StoragePath -replace '/', '\'
    foreach ($d in @(Get-VMHardDiskDrive -VMName $VmName -ErrorAction SilentlyContinue)) {
        if (Test-VHDIsInChain $d.Path $sp) { return $d }
    }
    $null
}

# Test whether StoragePath is currently mounted on the host as a local disk.
# Uses Get-Disk by Location (more reliable than Get-VHD when VMMS holds the file handle).
function Test-StorageMountedOnHost {
    param([string]$StoragePath)
    $sp = $StoragePath -replace '/', '\'
    $null -ne (Get-Disk -ErrorAction SilentlyContinue |
        Where-Object { ($_.Location -replace '/', '\') -ieq $sp } |
        Select-Object -First 1)
}

# Stop or start the Docker service inside a running VM via PowerShell Direct.
# Used before detaching the persistent volume (P:) and after re-attaching it.
# Best-effort — errors are silently ignored so the storage operation always proceeds.
function Invoke-VMDockerControl {
    param(
        [string]$VmName,
        [PSCredential]$Cred,
        [ValidateSet('stop','start')][string]$Action,
        [string]$DockerVolumeLabel = 'DockerData',
        [switch]$EnsureDaemonConfig
    )
    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if (-not $vm -or $vm.State -ne 'Running') { return }
    $icArgs = @{
        VMName      = $VmName
        ArgumentList = @($Action, $DockerVolumeLabel, [bool]$EnsureDaemonConfig.IsPresent)
        ErrorAction  = 'SilentlyContinue'
        ScriptBlock  = {
            param([string]$act, [string]$volLabel, [bool]$ensureDaemon)
            if ($act -eq 'stop') {
                Stop-Service docker -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2   # brief pause for Docker to release P:\docker-data handles
            } elseif ($act -eq 'start') {
                # Bring any offline disks online and pin DockerData -> P: before starting Docker
                Get-Disk | Where-Object IsOffline | ForEach-Object {
                    Set-Disk -Number $_.Number -IsOffline $false  -ErrorAction SilentlyContinue
                    Set-Disk -Number $_.Number -IsReadOnly $false -ErrorAction SilentlyContinue
                }

                $targetLabel = if ([string]::IsNullOrWhiteSpace($volLabel)) { 'DockerData' } else { $volLabel }
                $vol = Get-Volume -FileSystemLabel $targetLabel -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $vol -and $targetLabel -ne 'DockerData') {
                    $vol = Get-Volume -FileSystemLabel 'DockerData' -ErrorAction SilentlyContinue | Select-Object -First 1
                }
                if ($vol -and $vol.DriveLetter -ne 'P') {
                    $part = Get-Disk | Where-Object { -not $_.IsOffline } |
                        Get-Partition | Where-Object { $_.Size -gt 100MB -and $_.Type -notin @('System','Reserved','Recovery') } |
                        Where-Object { (Get-Volume -Partition $_ -ErrorAction SilentlyContinue).FileSystemLabel -eq $vol.FileSystemLabel } |
                        Select-Object -First 1
                    if ($part) { $part | Set-Partition -NewDriveLetter 'P' -ErrorAction SilentlyContinue }
                }

                if ($ensureDaemon) {
                    $daemonPath = 'C:\ProgramData\docker\config\daemon.json'
                    $daemonConfig = @{}
                    if (Test-Path $daemonPath) {
                        try {
                            $existing = Get-Content $daemonPath -Raw | ConvertFrom-Json -ErrorAction Stop
                            if ($existing) {
                                foreach ($prop in $existing.PSObject.Properties) {
                                    $daemonConfig[$prop.Name] = $prop.Value
                                }
                            }
                        } catch {
                            $daemonConfig = @{}
                        }
                    }
                    $daemonConfig['data-root'] = 'P:\docker-data'
                    New-Item -ItemType Directory -Path 'C:\ProgramData\docker\config' -Force | Out-Null
                    if (Get-PSDrive -Name P -ErrorAction SilentlyContinue) {
                        New-Item -ItemType Directory -Path 'P:\docker-data' -Force | Out-Null
                    }
                    $daemonConfig | ConvertTo-Json -Depth 16 | Out-File $daemonPath -Encoding utf8 -Force
                }

                Start-Service docker -ErrorAction SilentlyContinue
            }
        }
    }
    if ($Cred) { $icArgs.Credential = $Cred }
    try { Invoke-Command @icArgs } catch { }
}
