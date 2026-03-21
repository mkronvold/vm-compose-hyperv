<#
.SYNOPSIS
    Hyper-V Compose: A docker-compose-like orchestrator for Windows Server VMs.

.USAGE
    ./vm-compose.ps1 up [-DryRun]
    ./vm-compose.ps1 build [-DryRun]
    ./vm-compose.ps1 down [-DryRun]
    ./vm-compose.ps1 restart [-DryRun]
    ./vm-compose.ps1 destroy [-DryRun]
    ./vm-compose.ps1 status
    ./vm-compose.ps1 inspect <vm>
    ./vm-compose.ps1 logs <vm>
    ./vm-compose.ps1 bootlogs <vm> [tail]
    ./vm-compose.ps1 exec <vm> "<command>"
    ./vm-compose.ps1 ps <vm>
    ./vm-compose.ps1 ssh <vm>
    ./vm-compose.ps1 ip <vm>
    ./vm-compose.ps1 top <vm>
    ./vm-compose.ps1 health
    ./vm-compose.ps1 validate
    ./vm-compose.ps1 version
    ./vm-compose.ps1 mount <vm> <storageName>
    ./vm-compose.ps1 unmount <vm> <storageName>
    ./vm-compose.ps1 metrics
    ./vm-compose.ps1 web
    ./vm-compose.ps1 help [<command>]
    ./vm-compose.ps1 <command> help

.NOTES
    Requires PowerShell 7+ for ConvertFrom-Yaml.
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [ValidateSet("up","start","build","down","stop","restart","reboot","destroy","list","status","inspect","describe","show","logs","exec","ps","ssh","ip","top","health","docker","docker-compose","docker-test","validate","version","mount","unmount","storage","localmount","localunmount","cp","copy","metrics","web","dashboard","getlog","bootlogs","bootlog","note","help")]
    [string]$Command,

    [Parameter(Position=1)]
    [string]$VmName,
    [Parameter(Position=2)]
    [string]$ExecCommand,
    [Parameter(Position=3)]
    [string]$StorageName,
    [Parameter(Position=4)]
    [string]$ExtraArg,
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$DockerArgs,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Help,
    [Alias("h")][switch]$HelpShort,
    [string]$ConfigFile = "vmstack.yaml",
    [string]$VmRoot = "C:\HyperV\VMs"
)

$Version = "1.1.0"

$HelpText = @"
vm-compose $Version — Hyper-V Compose

USAGE
  ./vm-compose.ps1 <command> [options]

COMMANDS
  up / start [<vm>]   Build and start VMs (all, or a specific VM)
  build [<vm>]        Provision VMs without starting (all, or a specific VM)
  down / stop [<vm>]  Stop VMs (all, or a specific VM)
  restart / reboot [<vm>]  Restart VMs (all, or a specific VM)
  destroy [<vm>]  Delete VM definitions (all, or a specific VM)
  list            List VM names defined in vmstack.yaml
  status [<vm>]   Show status table (all, or a specific VM)
  inspect <vm>    Show detailed info for a VM (aliases: describe, show)
  logs <vm>       Show application event log from a VM
  bootlogs <vm> [tail]  Show bootstrap progress/log output from a VM
  exec <vm> <cmd> Run a command inside a VM
  docker <vm> <docker args...>         Run a docker command inside a VM
  docker-compose <vm> <compose args...> Run docker compose inside a VM
  ps <vm>         List processes inside a VM
  ssh <vm>        Open an interactive shell inside a VM
  ip <vm>         Print the VM's IP address
  top <vm>        Live CPU/memory usage
  health [<vm>]   Health check (all, or a specific VM)
  validate        Lint vmstack.yaml for errors
  version         Show version info
  mount <vm> <storage>    Hot-add a shared storage disk to a VM
  unmount <vm> <storage>  Remove a shared storage disk from a VM
  storage shared ls              List shared storage volumes
  storage shared localmount <n>  Mount shared VHDX on host (default S:)
  storage shared localunmount <n> Dismount shared VHDX from host
  storage shared health [n]      Health check for shared storage
  storage pv ls                  List persistent volumes (one per VM)
  storage pv localmount <vm>     Mount VM's persistent disk on host (default P:)
  storage pv localunmount <vm>   Dismount persistent disk from host
  storage pv create/destroy <vm> Create or delete a PV VHDX
  storage pv health [vm]         Health check for persistent volumes
  cp / copy <src> <dest>  Copy files to/from a VM  (prefix VM paths: vmname:path)
  note <show|add|edit> <vm>  Show, append to, or edit VM notes

SERVICES
  web [install|start|stop|restart|status|remove]     Manage the web dashboard (port 8080)
  metrics [install|start|stop|restart|status|remove] Manage the Prometheus metrics exporter (port 9090)

OPTIONS
  -DryRun         Preview changes without executing them
  -Force          Skip confirmation prompts (e.g. rebuild existing VM)
  -ConfigFile     Path to YAML config (default: vmstack.yaml)
  -VmRoot         Root path for VM storage (default: C:\HyperV\VMs)
  -Help, -h       Show this help message
"@

$CommandHelp = @{
    "up"       = "up / start [<vm>] [-DryRun]`n  Build and START VMs defined in vmstack.yaml.`n  Omit <vm> to target all; specify a VM name to target one.`n  Creates OS disk, optional legacy persistent disk (persistent_disk_gb > 0),`n  unattend.vhdx, unattend.xml, bootstrap.ps1, attaches networks and shared storage,`n  then starts the VM. If a VM already exists, starts it if stopped."
    "build"    = "build [<vm>] [-Force] [-DryRun]`n  Provision VMs (create disks, VM definition) WITHOUT starting them.`n  Omit <vm> to target all; specify a VM name to target one.`n  If a VM already exists, prompts to rebuild (destroy + recreate).`n  Use -Force to rebuild without prompting."
    "down"     = "down / stop [-DryRun]`n  Stop all VMs (forced power-off)."
    "restart"  = "restart / reboot [-DryRun]`n  Restart all VMs."
    "destroy"  = "destroy [-DryRun]`n  Delete VM definitions. Persistent storage VHDXes are preserved."
    "status"   = "status`n  Print a table of all VMs: state, CPU, memory, IP, uptime."
    "inspect"  = "inspect <vm>  (aliases: describe, show)`n  Show full details for a single VM: CPU, memory, disks, IPs, switches, checkpoints."
    "describe" = "describe <vm>`n  Alias for inspect."
    "show"     = "show <vm>`n  Alias for inspect."
    "logs"     = "logs <vm>`n  Show the 20 most recent Application event log entries from a VM."
    "exec"     = "exec <vm> `"<command>`"`n  Run a command inside a VM via PowerShell Direct."
    "ps"       = "ps <vm>`n  List the top 25 processes by CPU inside a VM."
    "ssh"      = "ssh <vm>`n  Open an interactive PowerShell Direct session inside a VM."
    "ip"       = "ip <vm>`n  Print the VM's first IPv4 address."
    "top"      = "top <vm>`n  Live CPU/memory loop (Ctrl+C to exit)."
    "health"       = "health [<vm>]`n  Health check: VM state, bootstrap progress, and Docker readiness. Omit <vm> for all."
    "docker"       = "docker <vm> <docker args...>`n  Run a docker command inside a VM via PowerShell Direct.`n  Example: ./vm-compose.ps1 docker solr ps`n  Example: ./vm-compose.ps1 docker solr run --rm mcr.microsoft.com/windows/nanoserver:ltsc2022 cmd /c echo hello`n  Note: args that match PowerShell parameter names (e.g. -Force) must be quoted."
    "docker-compose" = "docker-compose <vm> <compose args...>`n  Runs 'docker compose' inside a VM via PowerShell Direct.`n  Example: ./vm-compose.ps1 docker-compose solr version`n  Example: ./vm-compose.ps1 docker-compose solr build P:\app --file P:\app\docker-compose.yml"
    "docker-test"  = "docker-test <vm>`n  Pull and run a nanoserver hello-world container inside a VM.`n  Auto-detects the OS build to select the correct image tag (ltsc2022, ltsc2025).`n  Starts the Docker service if it is stopped."
    "validate" = "validate`n  Lint vmstack.yaml for missing required fields and broken references.`n  Note: persistent_disk_gb is optional."
    "version"  = "version`n  Print version, PowerShell version, and active config file path."
    "mount"    = "mount <vm> <storageName>`n  Hot-add a shared storage VHDX (from the storage: section) to a running VM."
    "unmount"  = "unmount <vm> <storageName>`n  Remove a shared storage VHDX from a VM."
    "storage"  = "storage <shared|pv> <subcommand> [name] [extra]`n  Manage shared storage and persistent volumes.`n`n  SHARED STORAGE (defined in vmstack.yaml storage: section):`n  storage shared ls                   List all volumes`n  storage shared create <name>        Create and initialize VHDX`n  storage shared rm <name>            Delete VHDX (must be unmounted)`n  storage shared mv <name> <dst>      Move VHDX (must be unmounted)`n  storage shared localmount <n> [S]   Mount on host at drive letter (default S:)`n  storage shared localunmount <n>     Dismount from host`n  storage shared health [name]        Detailed health check`n`n  PERSISTENT VOLUMES (legacy per-VM disk, optional via persistent_disk_gb):`n  storage pv ls [vm]                  List all PVs`n  storage pv create <vm>              Create VHDX`n  storage pv destroy <vm>             Delete VHDX`n  storage pv localmount <vm> [P]      Mount on host at drive letter (default P:)`n  storage pv localunmount <vm>        Dismount from host`n  storage pv health [vm]              Detailed health check`n`n  Backward compat: storage ls / rm / mv / init work as before (defaults to shared)"
    "localmount"   = "localmount <storageName> [driveLetter]`n  Mount a shared storage VHDX to a host drive letter (default S:).`n  Allows direct file access like a Docker volume.`n  Local mount and VM use are mutually exclusive."
    "localunmount" = "localunmount <storageName>`n  Dismount a shared storage VHDX from the host drive."
    "cp"       = "cp / copy <source> <destination>`n  Copy files between host and a running VM.`n  Host to VM:  cp C:\local\file.txt  myvm:C:\dest\`n  VM to host:  cp myvm:C:\path\file.txt  .`n  Prefix VM paths with vmname: (colon). VM-to-host prompts for Administrator credentials."
    "metrics"  = "metrics [install|start|stop|restart|status|remove]`n  Manage the vm-metrics Prometheus exporter. Default: status.`n  install: run vm-metrics-install.ps1`n  status: shows running state, install method (Windows service or Task Scheduler).`n  remove: stops and unregisters the service/task.`n  Install with: ./vm-metrics-install.ps1"
    "web"      = "web [install|start|stop|restart|status|remove]`n  Manage the vm-dashboard web UI. Default: status.`n  install: run vm-dashboard-install.ps1`n  status: shows running state, install method (Windows service or Task Scheduler).`n  remove: stops and unregisters the service/task.`n  Install with: ./vm-dashboard-install.ps1  |  Run directly: ./vm-dashboard.ps1"
    "note"     = "note <show|add|edit> <vm>`n  show: Print the VM's Notes field.`n  add:  Prompt for text and append it to the Notes field.`n  edit: Open the Notes field in Notepad for full editing."
    "getlog"   = "getlog <vm>`n  List logs available inside a VM and whether they exist.`n  getlog <logtype> <vm>  Fetch a specific log.`n  Log types: bootstrap, setup, setuperr, docker"
    "bootlogs" = "bootlogs <vm> [tail]`n  Show C:\Setup\bootstrap.log from the VM with bootstrap progress summary.`n  tail defaults to 200 lines from the latest bootstrap run."
    "help"     = "help [<command>]`n  Show help. Run 'help <command>' for details on a specific command."
}

if ($Help -or $HelpShort -or -not $Command -or $Command -eq "help") {
    # Per-command help: ./vm-compose.ps1 help <command>  OR  ./vm-compose.ps1 <command> help
    $targetCmd = if ($Command -eq "help" -and $VmName -and $CommandHelp.ContainsKey($VmName)) {
        $VmName
    } elseif ($Command -ne "help" -and $Command -and ($VmName -eq "help" -or $ExecCommand -eq "help")) {
        $Command
    } else { $null }

    if ($targetCmd) {
        Write-Host ""
        Write-Host "  $($CommandHelp[$targetCmd])" -ForegroundColor Cyan
        Write-Host ""
    } else {
        Write-Host $HelpText
    }
    exit 0
}

# Per-command help when passed as a sub-argument: ./vm-compose.ps1 <command> help
if ($VmName -eq "help" -or $ExecCommand -eq "help" -or $StorageName -eq "help") {
    Write-Host ""
    Write-Host "  $($CommandHelp[$Command])" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

if (-not (Test-Path $ConfigFile)) {
    Write-Host "Config file not found: $ConfigFile" -ForegroundColor Red

    $example = Join-Path $PSScriptRoot "vmstack-example.yaml"
    if (Test-Path $example) {
        try {
            $answer = Read-Host "Create '$ConfigFile' from vmstack-example.yaml? [y/N]"
            if ($answer -match '^[Yy]') {
                Copy-Item $example $ConfigFile
                Write-Host "Created $ConfigFile from example. Edit it to match your environment, then re-run." -ForegroundColor Green
            }
        } catch {
            Write-Host "Tip: Copy vmstack-example.yaml to vmstack.yaml and edit it to match your environment." -ForegroundColor Yellow
        }
    } else {
        Write-Host "Tip: Create a vmstack.yaml based on the vmstack-example.yaml in this repo." -ForegroundColor Yellow
    }
    exit 1
}

# Dry-run helper: runs the scriptblock only when not in dry-run mode.
# Always prints what would happen.
function Invoke-IfLive {
    param([string]$Description, [scriptblock]$Action)
    if ($DryRun) {
        Write-Host "[DRY RUN] Would: $Description" -ForegroundColor Cyan
    } else {
        & $Action
    }
}

# Inject keypresses into a VM console to dismiss "Press any key to boot from CD/DVD".
# Starts immediately and sends Enter every 500ms for 15 seconds (covers the 5s prompt window).
function Send-DVDBootKeypress {
    param([string]$VMName)
    Write-Host "Auto-pressing DVD boot key..." -ForegroundColor Gray
    $expiry = (Get-Date).AddSeconds(15)
    try {
        $vmCim = Get-CimInstance -Namespace 'root/virtualization/v2' -ClassName 'Msvm_ComputerSystem' -Filter "ElementName='$VMName'" -ErrorAction Stop
        $kbd   = Get-CimAssociatedInstance -InputObject $vmCim -ResultClassName 'Msvm_Keyboard' -ErrorAction Stop
        while ((Get-Date) -lt $expiry) {
            Invoke-CimMethod -InputObject $kbd -MethodName 'TypeKey' -Arguments @{ keyCode = 13 } | Out-Null
            Start-Sleep -Milliseconds 500
        }
        Write-Host "DVD boot key sent." -ForegroundColor Green
    } catch {
        Write-Host "Note: Could not auto-press DVD boot key ($($_.Exception.Message)). Press Enter in VM console if setup doesn't start." -ForegroundColor Yellow
    }
}


# ADODB.Stream.CopyFrom doesn't accept IStream; this C# shim reads it correctly.
if (-not ([System.Management.Automation.PSTypeName]'IsoHelper').Type) {
    Add-Type -TypeDefinition @'
using System; using System.IO; using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class IsoHelper {
    public static void WriteIStream(object comStream, string path) {
        var s = (IStream)comStream;
        using (var fs = File.Create(path)) {
            var buf = new byte[65536];
            var ptr = Marshal.AllocHGlobal(IntPtr.Size);
            try {
                while (true) {
                    s.Read(buf, buf.Length, ptr);
                    int n = Marshal.ReadInt32(ptr);
                    if (n == 0) break;
                    fs.Write(buf, 0, n);
                }
            } finally { Marshal.FreeHGlobal(ptr); }
        }
    }
}
'@
}

# Check for Administrator privileges (required for Hyper-V operations)
function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host ""
        Write-Host "ERROR: This command requires Administrator privileges." -ForegroundColor Red
        Write-Host "Re-run PowerShell as Administrator and try again." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host "Installing required module: powershell-yaml..." -ForegroundColor Cyan
    Install-Module powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
}
Import-Module powershell-yaml -ErrorAction Stop

$stack = Get-Content $ConfigFile | ConvertFrom-Yaml
$vms = $stack.vms.Keys

# Allow vmstack.yaml to override the VmRoot storage path
if ($stack.vm_root) { $VmRoot = $stack.vm_root }

. "$PSScriptRoot\vm-lib.ps1"

function Resolve-StoragePath {
    param([string]$path)
    $resolved = if ([System.IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $VmRoot $path }
    return $resolved -replace '/', '\'
}

function Initialize-SharedVHDX {
    param([string]$Path, [string]$Label = 'SharedData')
    Write-Host "  Initializing new VHDX with GPT + NTFS ($Label)..."
    try {
        $vhd = Mount-VHD -Path $Path -PassThru -ErrorAction Stop
        $diskNum = $vhd.DiskNumber
        Set-Disk -Number $diskNum -IsOffline $false -ErrorAction SilentlyContinue
        Set-Disk -Number $diskNum -IsReadOnly $false -ErrorAction SilentlyContinue
        Initialize-Disk -Number $diskNum -PartitionStyle GPT -PassThru -ErrorAction Stop |
            New-Partition -UseMaximumSize |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel $Label -Confirm:$false -ErrorAction Stop | Out-Null
        Write-Host "  VHDX initialized." -ForegroundColor Green
    } catch {
        Write-Host "  WARNING: Could not initialize VHDX: $_" -ForegroundColor Yellow
    } finally {
        Dismount-VHD -Path $Path -ErrorAction SilentlyContinue
    }
}

function Get-VMStorageHostConflicts {
    param($cfg)

    $conflicts = @()
    if (-not $cfg.mount -or -not $stack.storage) { return $conflicts }

    foreach ($storageName in $cfg.mount) {
        if (-not $stack.storage[$storageName]) { continue }
        $storagePath = Resolve-StoragePath $stack.storage[$storageName].path
        if (Test-StorageMountedOnHost $storagePath) {
            $conflicts += [pscustomobject]@{
                Name = $storageName
                Path = $storagePath
            }
        }
    }

    return $conflicts
}

function Write-StorageHostConflict {
    param([string]$VmName, [array]$Conflicts)

    Write-Host "ERROR: Cannot use shared storage for VM '$VmName' while it is mounted on the host." -ForegroundColor Red
    foreach ($conflict in $Conflicts) {
        Write-Host "  $($conflict.Name): $($conflict.Path)" -ForegroundColor Yellow
    }
    Write-Host "  Run './vm-compose.ps1 localunmount <storageName>' first." -ForegroundColor Gray
}

function Test-FileLocked {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $fs.Dispose()
        return $false
    } catch {
        return $true
    }
}

function Wait-VMCheckpointMerge {
    param(
        [string]$VmName,
        [int]$TimeoutSeconds = 300,
        [int]$PollSeconds = 2
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $waitingShown = $false

    while ((Get-Date) -lt $deadline) {
        $snapshots = @(Get-VMSnapshot -VMName $VmName -ErrorAction SilentlyContinue)
        $vmDiffDisks = @()
        if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
            $vmDiffDisks = @(Get-VMHardDiskDrive -VMName $VmName -ErrorAction SilentlyContinue | Where-Object { $_.Path -match '\.avhdx$' })
        }

        $activeStorageDiffs = @()
        if ($stack.storage) {
            foreach ($sName in $stack.storage.Keys) {
                $sCfg = $stack.storage[$sName]
                $sPath = Resolve-StoragePath $sCfg.path
                $sDir  = Split-Path $sPath
                $sBase = [System.IO.Path]::GetFileNameWithoutExtension($sPath)
                foreach ($f in @(Get-Item "$sDir\${sBase}_*.avhdx" -ErrorAction SilentlyContinue)) {
                    $candidate = ($f.FullName -replace '/', '\')
                    $attached = @(Get-VMsWithDisk $candidate)
                    $locked = Test-FileLocked $candidate
                    if ($attached.Count -gt 0 -or $locked) {
                        $activeStorageDiffs += $candidate
                    }
                }
            }
        }

        if ($snapshots.Count -eq 0 -and $vmDiffDisks.Count -eq 0 -and $activeStorageDiffs.Count -eq 0) {
            if ($waitingShown) { Write-Host "  Checkpoint merge complete." -ForegroundColor Gray }
            return $true
        }

        if (-not $waitingShown) {
            Write-Host "  Waiting for checkpoint merge to complete..." -ForegroundColor Yellow
            $waitingShown = $true
        }
        Start-Sleep -Seconds $PollSeconds
    }

    Write-Host "  WARNING: Timed out waiting for checkpoint merge completion; continuing rebuild." -ForegroundColor Yellow
    return $false
}

function Resolve-VMSwitch {
    param($name, $cfg)
    $switchName = $cfg.switch_name
    if (-not $switchName) {
        Write-Host "WARNING: Network '$name' has no switch_name — using 'Default Switch'" -ForegroundColor Yellow
        return "Default Switch"
    }
    if (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue) {
        return $switchName
    }
    Write-Host "WARNING: Virtual switch '$switchName' does not exist — using 'Default Switch'" -ForegroundColor Yellow
    Write-Host "  Create it in Hyper-V Manager or with: New-VMSwitch -Name '$switchName' ..." -ForegroundColor Gray
    return "Default Switch"
}

# Validate networks exist (called only by commands that need it)
function Initialize-Networks {
    if ($stack.networks) {
        foreach ($net in $stack.networks.Keys) {
            $switchName = $stack.networks[$net].switch_name
            if ($switchName -and -not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
                Write-Host "WARNING: Network '$net': switch '$switchName' not found — VMs using this network will fall back to 'Default Switch'" -ForegroundColor Yellow
            }
        }
    }
}

function Build-VM {
    param($vmName, $cfg, [switch]$AutoStart, [switch]$Rebuild)

    Write-Host ""
    Write-Host "=== Building VM: $vmName ==="

    $storageConflicts = Get-VMStorageHostConflicts $cfg
    if ($storageConflicts.Count -gt 0) {
        Write-StorageHostConflict -VmName $vmName -Conflicts $storageConflicts
        return
    }

    # If the VM already exists, handle rebuild or start logic
    $existingVm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($existingVm) {
        if ($AutoStart -and -not $Rebuild) {
            if ($existingVm.State -eq 'Running') {
                Write-Host "VM '$vmName' is already running." -ForegroundColor Green
            } else {
                Write-Host "VM '$vmName' already exists (state: $($existingVm.State)). Starting..." -ForegroundColor Yellow
                Invoke-IfLive "Start-VM $vmName" { Start-VM -Name $vmName }
                Send-DVDBootKeypress -VMName $vmName
            }
            return
        }

        if (-not $Rebuild) {
            Write-Host "VM '$vmName' already exists (state: $($existingVm.State))." -ForegroundColor Yellow
            $answer = Read-Host "  Rebuild? This will DESTROY the VM and recreate it. [y/N]"
            if ($answer -notmatch '^[Yy]') {
                Write-Host "Skipping '$vmName'." -ForegroundColor Gray
                return
            }
        }

        # Destroy VM before rebuilding
        Write-Host "Destroying '$vmName' for rebuild..." -ForegroundColor Yellow
        Invoke-IfLive "Stop-VM $vmName (force)" {
            if ($existingVm.State -ne 'Off') { Stop-VM -Name $vmName -Force -TurnOff -ErrorAction SilentlyContinue }
        }
        Invoke-IfLive "Remove snapshots for $vmName (merges checkpoint avhdx files)" {
            Get-VMSnapshot -VMName $vmName -ErrorAction SilentlyContinue |
                Remove-VMSnapshot -IncludeAllChildSnapshots -Confirm:$false -ErrorAction SilentlyContinue
        }
        Invoke-IfLive "Wait for checkpoint merge completion for $vmName" {
            Wait-VMCheckpointMerge -VmName $vmName -TimeoutSeconds 600 | Out-Null
        }
        Invoke-IfLive "Remove-VM $vmName" {
            Remove-VM -Name $vmName -Force
        }
        # Inspect orphaned avhdx differencing disks linked to shared storage.
        # Safety-first: do not auto-delete here; report unreferenced files for manual review.
        if ($stack.storage) {
            foreach ($sName in $stack.storage.Keys) {
                $sCfg = $stack.storage[$sName]
                $sPath = Resolve-StoragePath $sCfg.path
                $sDir  = Split-Path $sPath
                $sBase = [System.IO.Path]::GetFileNameWithoutExtension($sPath)
                Get-Item "$sDir\${sBase}_*.avhdx" -ErrorAction SilentlyContinue | ForEach-Object {
                    $candidatePath = ($_.FullName -replace '/', '\')
                    $attachedVms = @(Get-VMsWithDisk $candidatePath)
                    if ($attachedVms.Count -gt 0) {
                        Write-Host "  Keeping differencing disk in use: $($_.Name) (attached to: $($attachedVms -join ', '))" -ForegroundColor Yellow
                    } else {
                        Write-Host "  Found unreferenced differencing disk: $($_.Name)" -ForegroundColor Yellow
                        Write-Host "    Left in place for safety. Review before deleting manually." -ForegroundColor Gray
                    }
                }
            }
        }
        Write-Host "VM '$vmName' removed. Rebuilding..."
    }

    # -------------------------
    # Validate ISO exists
    # -------------------------
    if (-not $cfg.iso) {
        Write-Host "ERROR: VM '$vmName' has no 'iso:' field in vmstack.yaml." -ForegroundColor Red
        return
    }
    if (-not (Test-Path $cfg.iso)) {
        Write-Host ""
        Write-Host "ERROR: ISO not found for VM '$vmName':" -ForegroundColor Red
        Write-Host "  $($cfg.iso)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Download Windows Server evaluation ISOs from:" -ForegroundColor Cyan
        Write-Host "  https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Place the ISO at the path above and re-run." -ForegroundColor Gray
        return
    }

    try {
        $VmPath = Join-Path $VmRoot $vmName
    } catch {
        Write-Host ""
        Write-Host "ERROR: VM storage root '$VmRoot' is not accessible." -ForegroundColor Red
        Write-Host "Set 'vm_root:' in vmstack.yaml or pass -VmRoot to override." -ForegroundColor Yellow
        Write-Host ""
        return
    }
    $SetupDir       = Join-Path $VmPath "Setup"
    $VhdPath        = Join-Path $VmPath "$vmName.vhdx"
    $PersistentVhdPath = Join-Path $VmPath "persistent-storage.vhdx"
    $AnswerIsoPath  = Join-Path $VmPath "answer.iso"
    $persistentDiskRaw = if ($null -ne $cfg.persistent_disk_gb) { "$($cfg.persistent_disk_gb)".Trim() } else { '' }
    $persistentDiskGB = 0.0
    $hasPersistentDisk = $false
    if ($persistentDiskRaw) {
        if (-not [double]::TryParse($persistentDiskRaw, [ref]$persistentDiskGB)) {
            Write-Host "ERROR: VM '$vmName' has invalid persistent_disk_gb value '$persistentDiskRaw' (must be numeric)." -ForegroundColor Red
            return
        }
        if ($persistentDiskGB -gt 0) {
            $hasPersistentDisk = $true
        } else {
            Write-Host "WARNING: VM '$vmName' has persistent_disk_gb <= 0; skipping legacy persistent disk." -ForegroundColor Yellow
        }
    }
    $preferredDockerVolumeLabel = 'DockerData'
    $namedPvForVm = "pv-$vmName"
    if (-not $hasPersistentDisk -and $cfg.mount -and @($cfg.mount) -contains $namedPvForVm -and $stack.storage -and $stack.storage[$namedPvForVm]) {
        $preferredDockerVolumeLabel = $namedPvForVm
    }

    Invoke-IfLive "New-Item Directory $VmPath + $SetupDir" {
        New-Item -ItemType Directory -Path $VmPath -Force | Out-Null
        New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    }

    # -------------------------
    # Resolve admin password
    # -------------------------
    $adminPassword = if ($cfg.admin_password) {
        Write-Host "Using admin_password from vmstack.yaml." -ForegroundColor Gray
        $cfg.admin_password
    } else {
        $chars = ([char[]]([char]'A'..[char]'Z') + [char[]]([char]'a'..[char]'z') + [char[]]([char]'0'..[char]'9'))
        $generated = -join (1..20 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Count)] })
        Write-Host ""
        Write-Host "  Generated Administrator password for '$vmName':" -ForegroundColor Cyan
        Write-Host "  $generated" -ForegroundColor Yellow
        Write-Host "  Save this -- it will not be shown again." -ForegroundColor Gray
        Write-Host ""
        $generated
    }

    # Encode for unattend.xml: Base64(Unicode(password + "AdministratorPassword"))
    $encodedPassword = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($adminPassword + "AdministratorPassword")
    )
    # AutoLogon uses a different suffix
    $encodedAutoLogonPassword = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($adminPassword + "Password")
    )

    # DISM edition-conversion block for bootstrap.ps1 (only when product_key + product_type are set)
    $dismConversionBlock = ""
    if ($cfg.product_key -and $cfg.product_type) {
        $dismEdition = switch -Wildcard ($cfg.product_type.ToUpper()) {
            "*DATACENTER*" { "ServerDatacenter" }
            "*STANDARD*"   { "ServerStandard" }
            default        { $null }
        }
        if ($dismEdition) {
            $dismConversionBlock = @"

# Convert Windows Server Evaluation to full edition, then apply license key
Write-Host "Converting Evaluation to $($cfg.product_type)..."
`$result = & dism.exe /Online /Set-Edition:$dismEdition /ProductKey:$($cfg.product_key) /AcceptEula /NoRestart 2>&1
if (`$LASTEXITCODE -eq 0 -or `$LASTEXITCODE -eq 3010) {
    Write-BootstrapPass -Step 'DISM edition conversion' -Message 'Succeeded; rebooting to complete.'
    Write-BootstrapStatus -Step 'finalize' -State 'complete'
    Write-Host "Bootstrap complete: `$(`$script:bootstrapWarnings) warnings, `$(`$script:bootstrapFailures) failures."
    Write-Host "Bootstrap finished: `$(Get-Date)"
    Stop-Transcript | Out-Null
    Start-Sleep -Seconds 5
    Restart-Computer -Force
    exit
} else {
    Write-BootstrapFail -Step 'DISM edition conversion' -Message "Failed (exit `$LASTEXITCODE). Run manually: dism /Online /Set-Edition:$dismEdition /ProductKey:$($cfg.product_key) /AcceptEula"
    Write-BootstrapStatus -Step 'DISM edition conversion' -State 'failed'
    Write-Host "Bootstrap failed: `$(`$script:bootstrapWarnings) warnings, `$(`$script:bootstrapFailures) failures."
    Write-Host "Bootstrap finished: `$(Get-Date)"
    Stop-Transcript | Out-Null
    exit 1
}
"@
        }
    }

    # -------------------------
    # Generate unattend.xml
    # -------------------------
    $unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>EFI</Type>
              <Size>100</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>MSR</Type>
              <Size>16</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Label>EFI</Label>
              <Format>FAT32</Format>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>3</PartitionID>
              <Label>Windows</Label>
              <Letter>C</Letter>
              <Format>NTFS</Format>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
        <WillShowUI>OnError</WillShowUI>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/INDEX</Key>
              <Value>2</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>Administrator</FullName>
        <Organization>Local</Organization>
        <ProductKey><WillShowUI>OnError</WillShowUI></ProductKey>
      </UserData>
    </component>
  </settings>

  <settings pass="specialize">
    <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$vmName</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>
    <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>powershell -Command "New-Item C:\Setup -ItemType Directory -Force; `$v = Get-Volume -FileSystemLabel Unattend -EA SilentlyContinue; if (`$v) { Copy-Item (`$v.DriveLetter + ':\bootstrap.ps1') C:\Setup\bootstrap.ps1 -Force }"</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Path>reg add "HKLM\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff" /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
    <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-ServerManager-SvrMgrNc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DoNotOpenServerManagerAtLogon>true</DoNotOpenServerManagerAtLogon>
    </component>
    <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-OutOfBoxExperience" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DoNotOpenInitialConfigurationTasksAtLogon>true</DoNotOpenInitialConfigurationTasksAtLogon>
    </component>
  </settings>

  <settings pass="oobeSystem">
    <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipUserOOBE>true</SkipUserOOBE>
        <SkipMachineOOBE>true</SkipMachineOOBE>
      </OOBE>
      <AutoLogon>
        <Password>
          <Value>$encodedAutoLogonPassword</Value>
          <PlainText>false</PlainText>
        </Password>
        <Enabled>true</Enabled>
        <LogonCount>3</LogonCount>
        <Username>Administrator</Username>
      </AutoLogon>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$encodedPassword</Value>
          <PlainText>false</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>powershell -ExecutionPolicy Bypass -File C:\Setup\bootstrap.ps1</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@

    Invoke-IfLive "Write Autounattend.xml to $SetupDir" {
        # UTF-8 without BOM — WinPE's XML parser rejects BOM
        [System.IO.File]::WriteAllText("$SetupDir\Autounattend.xml", $unattend, [System.Text.UTF8Encoding]::new($false))
    }

    # -------------------------
    # Generate bootstrap.ps1 from template
    # -------------------------
    $bootstrapTemplateRel = if ($cfg.bootstrap_template) { $cfg.bootstrap_template } else { 'bootstraps/bootstrap-win2022-eval.ps1' }
    $bootstrapTemplatePath = Join-Path $PSScriptRoot $bootstrapTemplateRel.Replace('/', '\')
    if (-not (Test-Path $bootstrapTemplatePath)) {
        Write-Host "ERROR: Bootstrap template not found: $bootstrapTemplatePath" -ForegroundColor Red
        return
    }
    $bootstrap = Get-Content $bootstrapTemplatePath -Raw
    $bootstrap = $bootstrap.Replace('__PREFERRED_DOCKER_VOLUME_LABEL__', $preferredDockerVolumeLabel)
    $bootstrap = $bootstrap.Replace('__DISM_CONVERSION_BLOCK__', $dismConversionBlock)

    Invoke-IfLive "Write bootstrap.ps1 to $SetupDir" {
        $bootstrap | Out-File "$SetupDir\bootstrap.ps1" -Encoding utf8 -Force
    }

    # -------------------------
    # Create answer ISO (Windows Setup scans all optical drives for Autounattend.xml)
    # -------------------------
    Invoke-IfLive "Create answer.iso from setup files" {
        if (Test-Path $AnswerIsoPath) { Remove-Item $AnswerIsoPath -Force }
        $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $fsi.FileSystemsToCreate = 4       # Joliet
        $fsi.VolumeName = "Unattend"
        $fsi.Root.AddTree($SetupDir, $false)
        $resultImg = $fsi.CreateResultImage()
        [IsoHelper]::WriteIStream($resultImg.ImageStream, $AnswerIsoPath)
        Write-Host "Created answer.iso ($([math]::Round((Get-Item $AnswerIsoPath).Length/1KB)) KB)"
    }

    # -------------------------
    # Create OS disk
    # -------------------------
    Invoke-IfLive "New-VHD OS disk $VhdPath ($($cfg.os_disk_gb) GB)" {
        if (Test-Path $VhdPath) { Remove-Item $VhdPath -Force }
        New-VHD -Path $VhdPath -SizeBytes ($cfg.os_disk_gb * 1GB) -Dynamic | Out-Null
    }

    # -------------------------
    # Create persistent disk
    # -------------------------
    if ($hasPersistentDisk) {
        Invoke-IfLive "New-VHD persistent disk $PersistentVhdPath ($persistentDiskGB GB)" {
            if (-not (Test-Path $PersistentVhdPath)) {
                New-VHD -Path $PersistentVhdPath -SizeBytes ($persistentDiskGB * 1GB) -Dynamic | Out-Null
            } else {
                Write-Host "Persistent disk already exists — preserving data ($PersistentVhdPath)"
            }
        }
    } elseif (-not $persistentDiskRaw) {
        Write-Host "No legacy persistent disk configured (persistent_disk_gb omitted or <= 0)." -ForegroundColor Gray
    }

    # -------------------------
    # Create VM
    # -------------------------
    Invoke-IfLive "New-VM $vmName ($($cfg.memory_gb) GB RAM, $($cfg.cpus) CPUs)" {
        New-VM -Name $vmName -MemoryStartupBytes ($cfg.memory_gb * 1GB) -Generation 2 -VHDPath $VhdPath -Path $VmPath | Out-Null
        Set-VM -Name $vmName -ProcessorCount $cfg.cpus

        Add-VMDvdDrive -VMName $vmName -Path $cfg.iso | Out-Null
        Add-VMDvdDrive -VMName $vmName -Path $AnswerIsoPath | Out-Null
        if ($hasPersistentDisk) {
            Add-VMHardDiskDrive -VMName $vmName -Path $PersistentVhdPath | Out-Null
        }
        Enable-VMIntegrationService -VMName $vmName -Name "Guest Service Interface" -ErrorAction SilentlyContinue
    }

    # Attach network
    if ($cfg.network) {
        $netCfg = $stack.networks[$cfg.network]
        $switchName = if ($netCfg) { Resolve-VMSwitch $cfg.network $netCfg } else { "Default Switch" }
        if (-not $netCfg) {
            Write-Host "WARNING: Network '$($cfg.network)' not found in networks: section — using 'Default Switch'" -ForegroundColor Yellow
        }
        Invoke-IfLive "Connect-VMNetworkAdapter $vmName to switch $switchName" {
            Connect-VMNetworkAdapter -VMName $vmName -SwitchName $switchName
        }
        if ($cfg.mac_address) {
            $mac = $cfg.mac_address -replace '[:\-]', ''  # strip separators → 12 hex chars
            Invoke-IfLive "Set static MAC $($cfg.mac_address) on $vmName" {
                Set-VMNetworkAdapter -VMName $vmName -StaticMacAddress $mac
            }
        }
    }

    # -------------------------
    # Mount shared storage disks
    # -------------------------
    if ($cfg.mount -and $stack.storage) {
        foreach ($storageName in $cfg.mount) {
            $storageCfg = $stack.storage[$storageName]
            if (-not $storageCfg) {
                Write-Host "WARNING: Storage '$storageName' not found in storage: section" -ForegroundColor Yellow
                continue
            }
            $storagePath = Resolve-StoragePath $storageCfg.path
            Invoke-IfLive "Create shared VHDX $storagePath ($($storageCfg.size_gb) GB) if missing" {
                if (-not (Test-Path $storagePath)) {
                    try {
                        New-Item -ItemType Directory -Path (Split-Path $storagePath) -Force | Out-Null
                        New-VHD -Path $storagePath -SizeBytes ($storageCfg.size_gb * 1GB) -Dynamic | Out-Null
                        Initialize-SharedVHDX -Path $storagePath -Label $storageName
                    } catch {
                        Write-Host "WARNING: Could not create shared VHDX for '$storageName': $_" -ForegroundColor Yellow
                    }
                }
            }
            Invoke-IfLive "Add-VMHardDiskDrive $vmName <- $storagePath" {
                try {
                    Add-VMHardDiskDrive -VMName $vmName -Path $storagePath | Out-Null
                } catch {
                    Write-Host "WARNING: Could not attach shared VHDX '$storageName' to '$vmName': $_" -ForegroundColor Yellow
                }
            }
            Write-Host "Mounted shared storage '$storageName' on $vmName"
        }
    }

    Invoke-IfLive "Set-VMFirmware $vmName -EnableSecureBoot Off, boot from DVD first" {
        # Select the Windows installation DVD specifically (not the answer ISO)
        $dvd = Get-VMDvdDrive -VMName $vmName | Where-Object { $_.Path -eq $cfg.iso } | Select-Object -First 1
        if (-not $dvd) { $dvd = Get-VMDvdDrive -VMName $vmName | Select-Object -First 1 }
        if ($dvd) {
            Set-VMFirmware -VMName $vmName -EnableSecureBoot Off -FirstBootDevice $dvd
        } else {
            Set-VMFirmware -VMName $vmName -EnableSecureBoot Off
        }
    }

    if ($AutoStart) {
        Invoke-IfLive "Start-VM $vmName" { Start-VM $vmName }
        Send-DVDBootKeypress -VMName $vmName
        Write-Host "VM '$vmName' started and installing automatically."
    } else {
        Write-Host "VM '$vmName' built. Run 'up' to start it." -ForegroundColor Cyan
    }
}

function Resolve-TargetVMs {
    param([string]$Name)
    if ($Name) {
        if ($Name -notin $vms) {
            Write-Host "VM '$Name' is not defined in $ConfigFile" -ForegroundColor Red
            exit 1
        }
        return @($Name)
    }
    return $vms
}

function Stop-AllVMs {
    param([string]$Target)
    foreach ($vm in (Resolve-TargetVMs $Target)) {
        if (Get-VM -Name $vm -ErrorAction SilentlyContinue) {
            Invoke-IfLive "Stop-VM $vm -Force -TurnOff" {
                Stop-VM -Name $vm -Force -TurnOff
            }
            Write-Host "Stopped $vm"
        } else {
            Write-Host "VM '$vm' not found, skipping." -ForegroundColor Yellow
        }
    }
}

function Restart-AllVMs {
    param([string]$Target)
    foreach ($vm in (Resolve-TargetVMs $Target)) {
        if (Get-VM -Name $vm -ErrorAction SilentlyContinue) {
            $cfg = $stack.vms[$vm]
            $conflicts = Get-VMStorageHostConflicts $cfg
            if ($conflicts.Count -gt 0) {
                Write-StorageHostConflict -VmName $vm -Conflicts $conflicts
                continue
            }
            Invoke-IfLive "Restart-VM $vm" {
                Restart-VM -Name $vm -Force
            }
            Write-Host "Restarted $vm"
        } else {
            Write-Host "VM '$vm' not found, skipping." -ForegroundColor Yellow
        }
    }
}

function Remove-AllVMs {
    param([string]$Target)
    foreach ($vm in (Resolve-TargetVMs $Target)) {
        if (Get-VM -Name $vm -ErrorAction SilentlyContinue) {
            Invoke-IfLive "Stop-VM $vm + Remove-VM $vm (persistent disk preserved)" {
                Stop-VM -Name $vm -Force -TurnOff -ErrorAction SilentlyContinue
                Get-VMSnapshot -VMName $vm -ErrorAction SilentlyContinue |
                    Remove-VMSnapshot -IncludeAllChildSnapshots -Confirm:$false -ErrorAction SilentlyContinue
                Remove-VM -Name $vm -Force
            }
            Write-Host "Destroyed VM $vm (persistent disk preserved)"
        } else {
            Write-Host "VM '$vm' not found, skipping." -ForegroundColor Yellow
        }
    }
}

function Get-AllVMStatus {
    param([string]$Target)
    Write-Host ""
    Write-Host "=== VM Status ==="

    $rows = foreach ($vm in (Resolve-TargetVMs $Target)) {
        $info = Get-VM -Name $vm -ErrorAction SilentlyContinue
        if (-not $info) {
            [PSCustomObject]@{
                VM        = $vm
                State     = "Not Created"
                CPU       = "-"
                MemoryGB  = "-"
                IP        = "-"
                Uptime    = "-"
            }
            continue
        }

        $ip = (Get-VMNetworkAdapter -VMName $vm).IPAddresses |
              Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' } |
              Select-Object -First 1

        [PSCustomObject]@{
            VM        = $vm
            State     = $info.State
            CPU       = $info.ProcessorCount
            MemoryGB  = [math]::Round($(if ($info.MemoryAssigned -gt 0) { $info.MemoryAssigned } else { $info.MemoryStartup }) / 1GB, 2)
            IP        = $ip
            Uptime    = if ($info.Uptime) { $info.Uptime.ToString() } else { "-" }
        }
    }

    $rows | Format-Table -AutoSize
}

function Get-VMDetails {
    param($vmName)

    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Host "VM not found: $vmName" -ForegroundColor Red
        return
    }

    $adapters = Get-VMNetworkAdapter -VMName $vmName
    $disks    = Get-VMHardDiskDrive -VMName $vmName
    $switches = $adapters | Select-Object -ExpandProperty SwitchName
    $ips      = $adapters.IPAddresses | Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' }

    $obj = [PSCustomObject]@{
        Name        = $vm.Name
        State       = $vm.State
        CPUCount    = $vm.ProcessorCount
        MemoryGB    = "$([math]::Round($(if ($vm.MemoryAssigned -gt 0) { $vm.MemoryAssigned } else { $vm.MemoryStartup }) / 1GB, 2))$(if ($vm.MemoryAssigned -eq 0) { ' (configured; 0 assigned while Off)' } else { ' (assigned)' })"
        Uptime      = $vm.Uptime.ToString()
        Switches    = $switches
        IPAddresses = $ips
        Disks       = $disks.Path
        Checkpoints = (Get-VMSnapshot -VMName $vmName -ErrorAction SilentlyContinue).Name
        Generation  = $vm.Generation
        Notes       = $vm.Notes
    }

    $obj | Format-List
}

function Get-VMCredential {
    param([string]$VmName)
    $cfg = if ($stack -and $stack.vms) { $stack.vms[$VmName] } else { $null }
    if ($cfg -and $cfg.admin_password) {
        $secpw = ConvertTo-SecureString $cfg.admin_password -AsPlainText -Force
        return New-Object PSCredential('administrator', $secpw)
    }
    return Get-Credential -UserName 'administrator' -Message "Enter password for '$VmName' (administrator)"
}

function Get-VMLogs {
    param($vmName)
    if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        Write-Host "VM not found: $vmName" -ForegroundColor Red
        return
    }

    Write-Host "=== Logs for $vmName ==="
    Invoke-Command -VMName $vmName -Credential (Get-VMCredential $vmName) -ScriptBlock {
        Get-EventLog -LogName Application -Newest 20
    }
}

function Get-VMBootstrapLogs {
    param(
        [string]$vmName,
        [int]$Tail = 200
    )

    if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        Write-Host "VM not found: $vmName" -ForegroundColor Red
        return
    }

    if ($Tail -le 0) { $Tail = 200 }

    try {
        $result = Invoke-Command -VMName $vmName -Credential (Get-VMCredential $vmName) -ArgumentList $Tail -ScriptBlock {
            param([int]$tailCount)

            $path = 'C:\Setup\bootstrap.log'
            if (-not (Test-Path $path)) {
                return [PSCustomObject]@{
                    Found      = $false
                    Message    = "Log not found: $path"
                    RunId      = $null
                    State      = 'unknown'
                    Step       = $null
                    Warnings   = 0
                    Failures   = 0
                    LastStatus = '(no log)'
                    LastWriteUtc = $null
                    AgeMinutes = $null
                    IsStale    = $false
                    Lines      = @()
                }
            }

            $logItem = Get-Item $path -ErrorAction SilentlyContinue
            $lastWriteUtc = if ($logItem) { [datetime]$logItem.LastWriteTimeUtc } else { $null }
            $lines = @(Get-Content $path -ErrorAction SilentlyContinue)
            if ($lines.Count -eq 0) {
                return [PSCustomObject]@{
                    Found      = $true
                    Message    = 'Log exists but is empty.'
                    RunId      = $null
                    State      = 'unknown'
                    Step       = $null
                    Warnings   = 0
                    Failures   = 0
                    LastStatus = '(empty log)'
                    LastWriteUtc = $lastWriteUtc
                    AgeMinutes = $null
                    IsStale    = $false
                    Lines      = @()
                }
            }

            $runRegex = 'BOOTSTRAP_RUN_ID=(?<run>\S+)'
            $statusRegex = 'BOOTSTRAP_STATUS\|run=(?<run>[^|]+)\|state=(?<state>[^|]+)\|warnings=(?<warnings>\d+)\|failures=(?<failures>\d+)\|step=(?<step>.*)$'

            $runStartIndex = 0
            $activeRunId = $null
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match $runRegex) {
                    $activeRunId = $Matches['run']
                    $runStartIndex = $i
                }
            }

            $runLines = @($lines[$runStartIndex..($lines.Count - 1)])
            $statuses = @()
            foreach ($line in $runLines) {
                if ($line -match $statusRegex) {
                    $statuses += [PSCustomObject]@{
                        RunId    = $Matches['run']
                        State    = $Matches['state']
                        Warnings = [int]$Matches['warnings']
                        Failures = [int]$Matches['failures']
                        Step     = $Matches['step']
                        Line     = $line
                    }
                }
            }

            $state = 'unknown'
            $step = $null
            $warnings = 0
            $failures = 0
            $lastStatus = '(no bootstrap status marker found)'

            if ($statuses.Count -gt 0) {
                $last = $statuses | Select-Object -Last 1
                $state = $last.State
                $step = $last.Step
                $warnings = $last.Warnings
                $failures = $last.Failures
                $lastStatus = $last.Line
                if (-not $activeRunId) { $activeRunId = $last.RunId }
            } else {
                $legacy = ($runLines | Select-String 'Bootstrap' | Select-Object -Last 1).Line
                if ($legacy) {
                    $lastStatus = $legacy
                    $step = 'legacy-bootstrap-entry'
                    if ($legacy -match '(?i)bootstrap complete') {
                        $state = 'complete'
                    } else {
                        $state = 'running'
                    }
                }
            }
            $state = $state.ToLower()
            if ($state -eq 'running' -and $failures -gt 0) {
                $state = 'failed'
            }

            $ageMinutes = $null
            $isStale = $false
            if ($lastWriteUtc -and $state -in @('running', 'rebooting')) {
                $ageMinutes = [math]::Round(((Get-Date).ToUniversalTime() - $lastWriteUtc).TotalMinutes, 1)
                $staleThresholdMinutes = if ($step -match '(?i)Register bootstrap RunOnce continuation|Install Containers feature') { 15 } else { 30 }
                if ($ageMinutes -ge $staleThresholdMinutes) {
                    $isStale = $true
                }
            }

            $tailLines = if ($runLines.Count -gt $tailCount) { $runLines | Select-Object -Last $tailCount } else { $runLines }
            return [PSCustomObject]@{
                Found      = $true
                Message    = $null
                RunId      = $activeRunId
                State      = $state
                Step       = $step
                Warnings   = $warnings
                Failures   = $failures
                LastStatus = $lastStatus
                LastWriteUtc = $lastWriteUtc
                AgeMinutes = $ageMinutes
                IsStale    = $isStale
                Lines      = $tailLines
            }
        } -ErrorAction Stop

        Write-Host "=== Bootstrap logs for $vmName ===" -ForegroundColor Cyan
        if (-not $result.Found) {
            Write-Host $result.Message -ForegroundColor Yellow
            return
        }

        $statusLine = switch ($result.State) {
            'complete' { "bootstrap complete with $($result.Warnings) warnings, $($result.Failures) failures." }
            'running'  { "bootstrap running with $($result.Warnings) warnings $($result.Failures) failures." }
            'rebooting' { "bootstrap running with $($result.Warnings) warnings $($result.Failures) failures." }
            'failed' { "bootstrap failed with $($result.Warnings) warnings, $($result.Failures) failures." }
            default    { "bootstrap status unknown (warnings=$($result.Warnings), failures=$($result.Failures))." }
        }
        $statusColor = switch ($result.State) {
            'complete' { if ($result.Failures -gt 0) { 'Yellow' } else { 'Green' } }
            'running'  { 'Yellow' }
            'rebooting' { 'Yellow' }
            'failed' { 'Red' }
            default    { 'DarkGray' }
        }
        if ($result.IsStale) {
            $stepLabel = if ($result.Step) { $result.Step } else { '(unknown step)' }
            $statusLine = "bootstrap appears stalled at '$stepLabel' with $($result.Warnings) warnings $($result.Failures) failures (last update $($result.AgeMinutes) min ago)."
            $statusColor = 'Red'
        }

        Write-Host "Status : $statusLine" -ForegroundColor $statusColor
        Write-Host "Run ID : $(if ($result.RunId) { $result.RunId } else { '(legacy/no marker)' })" -ForegroundColor DarkGray
        if ($null -ne $result.AgeMinutes) {
            Write-Host "Age    : $($result.AgeMinutes) min since last log update" -ForegroundColor DarkGray
        }
        if ($result.State -eq 'failed') {
            Write-Host "Action : Sign into the VM and run C:\Setup\bootstrap.ps1 manually after fixing the failing step." -ForegroundColor Yellow
        } elseif ($result.IsStale) {
            Write-Host "Action : Sign into the VM and run C:\Setup\bootstrap.ps1 manually." -ForegroundColor Yellow
        }
        Write-Host "Marker : $($result.LastStatus)" -ForegroundColor DarkGray
        Write-Host ""

        if ($result.Lines -and $result.Lines.Count -gt 0) {
            $result.Lines | ForEach-Object { Write-Host $_ }
        } else {
            Write-Host "(No lines in selected run.)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "Error retrieving bootstrap log from '$vmName': $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Invoke-VMCommand {
    param($vmName, $cmd)
    if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        Write-Host "VM not found: $vmName" -ForegroundColor Red
        return
    }

    Write-Host "=== Executing on $vmName ==="
    Invoke-Command -VMName $vmName -Credential (Get-VMCredential $vmName) -ScriptBlock { param($c) Invoke-Expression $c } -ArgumentList $cmd
}

function Get-VMProcesses {
    param($vmName)

    if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        Write-Host "VM not found: $vmName" -ForegroundColor Red
        return
    }

    Write-Host "=== Processes in $vmName ==="
    Invoke-Command -VMName $vmName -Credential (Get-VMCredential $vmName) -ScriptBlock {
        Get-Process |
            Sort-Object CPU -Descending |
            Select-Object -First 25 Name, Id, CPU, WorkingSet |
            Format-Table -AutoSize
    }
}

function Enter-VM {
    param($vmName)

    if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        Write-Host "VM not found: $vmName" -ForegroundColor Red
        return
    }

    Write-Host "Opening PowerShell Direct session into $vmName..."
    Enter-PSSession -VMName $vmName -Credential (Get-VMCredential $vmName)
}

function Get-VMIpAddress {
    param($vmName)

    if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        Write-Host "VM not found: $vmName" -ForegroundColor Red
        return
    }

    $ip = (Get-VMNetworkAdapter -VMName $vmName).IPAddresses |
          Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' } |
          Select-Object -First 1

    if ($ip) {
        Write-Host $ip
    } else {
        Write-Host "No IP assigned yet."
    }
}

function Get-VMTop {
    param($vmName)

    if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        Write-Host "VM not found: $vmName" -ForegroundColor Red
        return
    }

    Write-Host "Press Ctrl+C to exit."

    while ($true) {
        $vm = Get-VM -Name $vmName
        $cpu = $vm.CPUUsage
        $memMB = [math]::Round($vm.MemoryAssigned / 1MB, 2)

        Clear-Host
        Write-Host "=== VM: $vmName ==="
        Write-Host "CPU Usage: $cpu %"
        Write-Host "Memory:    $memMB MB"
        Start-Sleep -Seconds 1
    }
}

function Test-AllVMs {
    param([string]$Target)
    Write-Host ""
    Write-Host "=== VM Health Check ==="

    foreach ($vm in (Resolve-TargetVMs $Target)) {
        $exists = Get-VM -Name $vm -ErrorAction SilentlyContinue
        if (-not $exists) {
            Write-Host "${vm}: NOT CREATED" -ForegroundColor Red
            continue
        }

        $state = $exists.State
        $ip = (Get-VMNetworkAdapter -VMName $vm).IPAddresses |
              Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' } |
              Select-Object -First 1

        Write-Host ""
        Write-Host "VM: $vm" -ForegroundColor Cyan
        Write-Host "  State : $state"
        Write-Host "  IP    : $(if ($ip) { $ip } else { '(none)' })"

        if ($state -ne "Running") {
            Write-Host "  Docker: VM not running" -ForegroundColor Yellow
            continue
        }

        try {
            $checks = Invoke-Command -VMName $vm -Credential (Get-VMCredential $vm) -ArgumentList $vm -ScriptBlock {
                param([string]$remoteVmName)
                # Ensure Docker binary path is in PATH for this session
                $dockerBin = 'C:\Program Files\Docker'
                if ($env:Path -notlike "*$dockerBin*") { $env:Path = "$env:Path;$dockerBin" }

                # Containers feature
                $feature = (Get-WindowsFeature -Name Containers -ErrorAction SilentlyContinue).InstallState -eq 'Installed'

                # Docker daemon.json
                $daemonJson = Test-Path 'C:\ProgramData\docker\config\daemon.json'

                # Docker data-root configured on persistent disk
                $dataRoot = $null
                if ($daemonJson) {
                    $cfg = Get-Content 'C:\ProgramData\docker\config\daemon.json' -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                    $dataRoot = $cfg.'data-root'
                }

                # Persistent data volume (legacy label DockerData or named pv-<vm>)
                $dockerVol = $null
                $dockerDataDrive = $null
                if ($dataRoot -and $dataRoot -match '^(?<dl>[A-Za-z]):\\') {
                    $dockerDataDrive = $Matches['dl'].ToUpper()
                    $dockerVol = Get-Volume -DriveLetter $dockerDataDrive -ErrorAction SilentlyContinue
                }
                if (-not $dockerVol) {
                    foreach ($label in @("pv-$remoteVmName", 'DockerData')) {
                        $dockerVol = Get-Volume -FileSystemLabel $label -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($dockerVol) {
                            if ($dockerVol.DriveLetter) { $dockerDataDrive = "$($dockerVol.DriveLetter)".ToUpper() }
                            break
                        }
                    }
                }
                if (-not $dockerDataDrive -and $dockerVol -and $dockerVol.DriveLetter) {
                    $dockerDataDrive = "$($dockerVol.DriveLetter)".ToUpper()
                }

                # Shared storage volumes (any non-OS, non-Docker data volume)
                $sharedVols = Get-Volume -ErrorAction SilentlyContinue |
                    Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and
                                   $_.FileSystemLabel -ne '' -and
                                   $_.DriveLetter -ne 'C' -and
                                   (-not $dockerDataDrive -or "$($_.DriveLetter)".ToUpper() -ne $dockerDataDrive) }

                # Windows Eval license — days remaining (GracePeriodRemaining is in minutes)
                $evalDays = $null
                $slp = Get-WmiObject -Class SoftwareLicensingProduct -ErrorAction SilentlyContinue |
                    Where-Object { $_.ApplicationID -eq '55c92734-d682-4d71-983e-d6ec3f16059f' -and
                                   $_.PartialProductKey -and $_.GracePeriodRemaining -gt 0 } |
                    Select-Object -First 1
                if ($slp) { $evalDays = [math]::Floor($slp.GracePeriodRemaining / 1440) }

                # Bootstrap status/progress from structured markers in bootstrap.log
                $bootstrapState = 'unknown'
                $bootstrapStep = $null
                $bootstrapWarnings = 0
                $bootstrapFailures = 0
                $bootstrapLast = '(no log)'
                $bootstrapRunId = $null
                $bootstrapLastWriteUtc = $null
                $bootstrapAgeMinutes = $null
                $bootstrapStalled = $false
                if (Test-Path 'C:\Setup\bootstrap.log') {
                    $logItem = Get-Item 'C:\Setup\bootstrap.log' -ErrorAction SilentlyContinue
                    if ($logItem) { $bootstrapLastWriteUtc = [datetime]$logItem.LastWriteTimeUtc }
                    $bootLines = @(Get-Content 'C:\Setup\bootstrap.log' -ErrorAction SilentlyContinue)
                    if ($bootLines.Count -gt 0) {
                        $runRegex = 'BOOTSTRAP_RUN_ID=(?<run>\S+)'
                        $statusRegex = 'BOOTSTRAP_STATUS\|run=(?<run>[^|]+)\|state=(?<state>[^|]+)\|warnings=(?<warnings>\d+)\|failures=(?<failures>\d+)\|step=(?<step>.*)$'
                        $runStartIndex = 0
                        for ($i = 0; $i -lt $bootLines.Count; $i++) {
                            if ($bootLines[$i] -match $runRegex) {
                                $bootstrapRunId = $Matches['run']
                                $runStartIndex = $i
                            }
                        }
                        $runLines = @($bootLines[$runStartIndex..($bootLines.Count - 1)])
                        $statusLines = @()
                        foreach ($line in $runLines) {
                            if ($line -match $statusRegex) {
                                $statusLines += [PSCustomObject]@{
                                    RunId    = $Matches['run']
                                    State    = $Matches['state']
                                    Warnings = [int]$Matches['warnings']
                                    Failures = [int]$Matches['failures']
                                    Step     = $Matches['step']
                                    Line     = $line
                                }
                            }
                        }
                        if ($statusLines.Count -gt 0) {
                            $lastStatus = $statusLines | Select-Object -Last 1
                            $bootstrapState = $lastStatus.State.ToLower()
                            $bootstrapStep = $lastStatus.Step
                            $bootstrapWarnings = $lastStatus.Warnings
                            $bootstrapFailures = $lastStatus.Failures
                            $bootstrapLast = $lastStatus.Line
                            if (-not $bootstrapRunId) { $bootstrapRunId = $lastStatus.RunId }
                        } else {
                            $legacy = ($runLines | Select-String 'Bootstrap' | Select-Object -Last 1).Line
                            if ($legacy) {
                                $bootstrapLast = $legacy
                                $bootstrapStep = 'legacy-bootstrap-entry'
                                if ($legacy -match '(?i)bootstrap complete') {
                                    $bootstrapState = 'complete'
                                } else {
                                    $bootstrapState = 'running'
                                }
                            } else {
                                $bootstrapLast = '(no bootstrap markers found)'
                            }
                        }
                    } else {
                        $bootstrapLast = '(empty log)'
                    }
                }
                $bootstrapState = $bootstrapState.ToLower()
                if ($bootstrapState -eq 'running' -and $bootstrapFailures -gt 0) {
                    $bootstrapState = 'failed'
                }

                if ($bootstrapLastWriteUtc -and $bootstrapState -in @('running', 'rebooting')) {
                    $bootstrapAgeMinutes = [math]::Round(((Get-Date).ToUniversalTime() - $bootstrapLastWriteUtc).TotalMinutes, 1)
                    $staleThresholdMinutes = if ($bootstrapStep -match '(?i)Register bootstrap RunOnce continuation|Install Containers feature') { 15 } else { 30 }
                    if ($bootstrapAgeMinutes -ge $staleThresholdMinutes) {
                        $bootstrapStalled = $true
                    }
                }

                $bootstrapComplete = $bootstrapState -eq 'complete'

                # Docker readiness is only enforced after bootstrap completes.
                $dockerVer = $null
                $dockerOk = $false
                $composeVer = $null
                $composeOk = $false
                if ($bootstrapComplete) {
                    try {
                        $dockerVer = & docker info --format '{{.ServerVersion}}' 2>$null
                        $dockerOk  = $LASTEXITCODE -eq 0 -and $dockerVer
                    } catch { }
                    try {
                        $composeVerRaw = & docker compose version --short 2>$null
                        if ($LASTEXITCODE -eq 0 -and $composeVerRaw) {
                            $composeVer = $composeVerRaw.ToString().Trim()
                            $composeOk = $true
                        }
                    } catch { }
                }

                $gitVer = $null; $gitOk = $false
                $ghVer = $null; $ghOk = $false
                $copilotVer = $null; $copilotOk = $false
                if ($bootstrapComplete) {
                    try {
                        $raw = & git --version 2>$null
                        if ($LASTEXITCODE -eq 0 -and $raw) {
                            $gitVer = $raw.ToString().Trim() -replace '^git version\s*', ''
                            $gitOk = $true
                        }
                    } catch { }
                    try {
                        $raw = (& gh --version 2>$null | Select-Object -First 1)
                        if ($LASTEXITCODE -eq 0 -and $raw) {
                            $ghVer = $raw.ToString().Trim() -replace '^gh version\s+(\S+).*$', '$1'
                            $ghOk = $true
                        }
                    } catch { }
                    try {
                        $raw = (& gh copilot --version 2>$null | Select-Object -First 1)
                        if ($LASTEXITCODE -eq 0 -and $raw) {
                            $copilotVer = $raw.ToString().Trim() -replace '^.*?(\d[\d.]+\S*).*$', '$1'
                            $copilotOk = $true
                        }
                    } catch { }
                }

                [PSCustomObject]@{
                    DockerOk      = $dockerOk
                    DockerVersion = $dockerVer
                    ComposeOk     = $composeOk
                    ComposeVersion = $composeVer
                    GitOk         = $gitOk
                    GitVersion    = $gitVer
                    GhOk          = $ghOk
                    GhVersion     = $ghVer
                    CopilotOk     = $copilotOk
                    CopilotVersion = $copilotVer
                    BootstrapComplete = $bootstrapComplete
                    BootstrapState = $bootstrapState
                    BootstrapWarnings = $bootstrapWarnings
                    BootstrapFailures = $bootstrapFailures
                    BootstrapRunId = $bootstrapRunId
                    BootstrapStep = $bootstrapStep
                    BootstrapAgeMinutes = $bootstrapAgeMinutes
                    BootstrapStalled = $bootstrapStalled
                    FeatureOk     = $feature
                    DockerVolume  = if ($dockerVol) { "$($dockerVol.DriveLetter): ($([math]::Round($dockerVol.SizeRemaining/1GB,1)) GB free)" } else { $null }
                    DaemonJson    = $daemonJson
                    DataRoot      = $dataRoot
                    SharedVols    = $sharedVols | ForEach-Object { "$($_.DriveLetter): $($_.FileSystemLabel)" }
                    EvalDays      = $evalDays
                    BootstrapLast = $bootstrapLast
                }
            } -ErrorAction Stop

            $fmt = { param($ok, $label, $val)
                $mark = if ($ok) { '[+]' } else { '[!]' }
                $color = if ($ok) { 'Green' } else { 'Red' }
                Write-Host ("  {0} {1,-22} {2}" -f $mark, $label, $val) -ForegroundColor $color
            }

            & $fmt $checks.FeatureOk     'Containers feature'  $(if ($checks.FeatureOk) { 'Installed' } else { 'MISSING' })
            if ($checks.BootstrapComplete) {
                & $fmt $checks.DockerOk  'Docker Engine'       $(if ($checks.DockerVersion) { "v$($checks.DockerVersion)" } else { 'NOT RUNNING' })
                & $fmt $checks.ComposeOk 'Docker Compose'      $(if ($checks.ComposeVersion) { "v$($checks.ComposeVersion)" } else { 'NOT FOUND' })
                & $fmt $checks.GitOk     'git'                 $(if ($checks.GitVersion) { "v$($checks.GitVersion)" } else { 'NOT FOUND' })
                & $fmt $checks.GhOk      'gh (GitHub CLI)'     $(if ($checks.GhVersion) { "v$($checks.GhVersion)" } else { 'NOT FOUND' })
                & $fmt $checks.CopilotOk 'gh copilot'          $(if ($checks.CopilotVersion) { "v$($checks.CopilotVersion)" } else { 'NOT FOUND' })
            } else {
                Write-Host ("  [i] {0,-22} {1}" -f 'Docker Engine', 'bootstrap not complete yet') -ForegroundColor Yellow
                Write-Host ("  [i] {0,-22} {1}" -f 'Docker Compose', 'bootstrap not complete yet') -ForegroundColor Yellow
            }
            & $fmt ($null -ne $checks.DockerVolume) 'Docker data volume' $(if ($checks.DockerVolume) { $checks.DockerVolume } else { 'NOT FOUND (check disk offline policy)' })
            & $fmt $checks.DaemonJson    'daemon.json'         $(if ($checks.DataRoot) { "data-root=$($checks.DataRoot)" } else { 'missing or unconfigured' })
            if ($checks.SharedVols) {
                foreach ($sv in $checks.SharedVols) {
                    & $fmt $true 'Shared volume' $sv
                }
            } else {
                Write-Host "  [ ] Shared volumes         (none mounted)" -ForegroundColor DarkGray
            }
            if ($null -ne $checks.EvalDays) {
                $evalColor = if ($checks.EvalDays -le 14) { 'Red' } elseif ($checks.EvalDays -le 30) { 'Yellow' } else { 'Cyan' }
                $evalMsg = "$($checks.EvalDays) days remaining"
                Write-Host ("  [i] {0,-22} {1}" -f 'Eval license', $evalMsg) -ForegroundColor $evalColor
            }
            $bState  = $checks.BootstrapState
            $bWarn   = $checks.BootstrapWarnings
            $bFail   = $checks.BootstrapFailures
            $bStep   = $checks.BootstrapStep
            $bStalled = $checks.BootstrapStalled

            $bMark  = '[i]'
            $bColor = 'Yellow'
            $bVal   = 'unknown'

            if ($bStalled) {
                $bMark  = '[!]'; $bColor = 'Red'
                $bVal   = "stalled · $bStep"
            } elseif ($bState -eq 'complete') {
                if ($bFail -gt 0)       { $bMark = '[!]'; $bColor = 'Red';    $bVal = "complete · $bFail failure(s), $bWarn warning(s)" }
                elseif ($bWarn -gt 0)   { $bMark = '[i]'; $bColor = 'Yellow'; $bVal = "complete · $bWarn warning(s)" }
                else                    { $bMark = '[+]'; $bColor = 'Green';  $bVal = 'complete' }
            } elseif ($bState -eq 'failed') {
                $bMark = '[!]'; $bColor = 'Red'
                $bVal  = "failed · $bFail failure(s), $bWarn warning(s)"
            } elseif ($bState -eq 'rebooting') {
                $bVal = 'rebooting to continue'
            } elseif ($bState -eq 'running') {
                $bVal = if ($bStep) { "running · $bStep" } else { 'running' }
            } elseif ($checks.BootstrapLast -like '*complete*') {
                $bMark = '[+]'; $bColor = 'Green'; $bVal = 'complete'
            } elseif ($checks.BootstrapLast -eq '(no log)') {
                $bVal = 'not started'
            }

            Write-Host ("  {0} {1,-22} {2}" -f $bMark, 'Bootstrap', $bVal) -ForegroundColor $bColor

            if ($bState -in 'running','rebooting' -or $bStalled) {
                if ($null -ne $checks.BootstrapAgeMinutes) {
                    Write-Host ("      last update {0} min ago" -f $checks.BootstrapAgeMinutes) -ForegroundColor DarkGray
                }
            }
            if ($bState -eq 'failed' -or $bStalled) {
                Write-Host "      run C:\Setup\bootstrap.ps1 inside the VM to retry." -ForegroundColor Yellow
            }

        } catch {
            Write-Host "  [!] Could not connect via PowerShell Direct: $_" -ForegroundColor Red
        }
    }
    Write-Host ""
}

function Invoke-DockerInVM {
    param([string]$vmName, [string[]]$dockerArgs)

    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Host "VM not found: $vmName" -ForegroundColor Red
        return
    }
    if ($vm.State -ne 'Running') {
        Write-Host "VM '$vmName' is not running (state: $($vm.State))" -ForegroundColor Red
        return
    }

    try {
        Invoke-Command -VMName $vmName -Credential (Get-VMCredential $vmName) -ScriptBlock {
            param([string[]]$a)
            $dockerBin = 'C:\Program Files\Docker'
            if ($env:Path -notlike "*$dockerBin*") { $env:Path = "$env:Path;$dockerBin" }
            $composePluginPath = 'C:\Program Files\Docker\cli-plugins\docker-compose.exe'
            function Ensure-DockerComposePlugin {
                if (Test-Path $composePluginPath) { return }
                Write-Host "Docker Compose plugin not found. Installing..."
                $composeRelease = Invoke-RestMethod 'https://api.github.com/repos/docker/compose/releases/latest' -UseBasicParsing
                $composeAsset = @($composeRelease.assets | Where-Object { $_.name -eq 'docker-compose-windows-x86_64.exe' }) | Select-Object -First 1
                if (-not $composeAsset) {
                    throw "Could not find docker-compose-windows-x86_64.exe in latest docker/compose release."
                }
                New-Item -ItemType Directory -Path 'C:\Program Files\Docker\cli-plugins' -Force | Out-Null
                Invoke-WebRequest -UseBasicParsing -Uri $composeAsset.browser_download_url -OutFile $composePluginPath
            }
            if ($a -and $a.Count -gt 0 -and $a[0] -eq 'compose') {
                Ensure-DockerComposePlugin
            }
            & docker @a
            exit $LASTEXITCODE
        } -ArgumentList (,$dockerArgs) -ErrorAction Stop
    } catch {
        Write-Host "Error running docker in '$vmName': $_" -ForegroundColor Red
    }
}

function Invoke-DockerComposeInVM {
    param([string]$vmName, [string[]]$composeArgs)

    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Host "VM not found: $vmName" -ForegroundColor Red
        return
    }
    if ($vm.State -ne 'Running') {
        Write-Host "VM '$vmName' is not running (state: $($vm.State))" -ForegroundColor Red
        return
    }

    try {
        Invoke-Command -VMName $vmName -Credential (Get-VMCredential $vmName) -ScriptBlock {
            param([string[]]$a)
            $dockerBin = 'C:\Program Files\Docker'
            if ($env:Path -notlike "*$dockerBin*") { $env:Path = "$env:Path;$dockerBin" }
            $composePluginPath = 'C:\Program Files\Docker\cli-plugins\docker-compose.exe'
            if (-not (Test-Path $composePluginPath)) {
                Write-Host "Docker Compose plugin not found. Installing..."
                $composeRelease = Invoke-RestMethod 'https://api.github.com/repos/docker/compose/releases/latest' -UseBasicParsing
                $composeAsset = @($composeRelease.assets | Where-Object { $_.name -eq 'docker-compose-windows-x86_64.exe' }) | Select-Object -First 1
                if (-not $composeAsset) {
                    throw "Could not find docker-compose-windows-x86_64.exe in latest docker/compose release."
                }
                New-Item -ItemType Directory -Path 'C:\Program Files\Docker\cli-plugins' -Force | Out-Null
                Invoke-WebRequest -UseBasicParsing -Uri $composeAsset.browser_download_url -OutFile $composePluginPath
            }
            & docker compose @a
            exit $LASTEXITCODE
        } -ArgumentList (,$composeArgs) -ErrorAction Stop
    } catch {
        Write-Host "Error running docker compose in '$vmName': $_" -ForegroundColor Red
    }
}

function Invoke-DockerTest {
    param([string]$vmName)

    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Host "VM not found: $vmName" -ForegroundColor Red
        return
    }
    if ($vm.State -ne 'Running') {
        Write-Host "VM '$vmName' is not running (state: $($vm.State))" -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "=== Docker Test: $vmName ===" -ForegroundColor Cyan

    try {
        $result = Invoke-Command -VMName $vmName -Credential (Get-VMCredential $vmName) -ScriptBlock {
            $dockerBin = 'C:\Program Files\Docker'
            if ($env:Path -notlike "*$dockerBin*") { $env:Path = "$env:Path;$dockerBin" }

            $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
            $tag = if ($build -ge 26100) { 'ltsc2025' } else { 'ltsc2022' }
            # Windows 11 builds (22000–26099) require Hyper-V isolation for Windows containers
            $isWin11 = $build -ge 22000 -and $build -lt 26100

            $svc = Get-Service docker -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Running') {
                Write-Host "  Starting Docker service..."
                Start-Service docker
                Start-Sleep 5
            }

            $image = "mcr.microsoft.com/windows/nanoserver:$tag"
            $runArgs = @('run', '--rm')
            if ($isWin11) { $runArgs += '--isolation=hyperv' }
            $runArgs += @($image, 'cmd', '/c', 'echo Hello from Windows container!')

            $output = & docker @runArgs 2>&1

            [PSCustomObject]@{
                Build   = $build
                Tag     = $tag
                IsWin11 = $isWin11
                Image   = $image
                Output  = ($output -join "`n").Trim()
                Success = $LASTEXITCODE -eq 0
            }
        } -ErrorAction Stop

        $osLabel = if ($result.Tag -eq 'ltsc2025') { "Windows Server 2025 / Win11 24H2 (build $($result.Build))" }
                   elseif ($result.IsWin11)         { "Windows 11 (build $($result.Build))" }
                   else                             { "Windows Server 2022 (build $($result.Build))" }

        Write-Host "  OS     : $osLabel"
        Write-Host "  Image  : $($result.Image)"
        if ($result.Success) {
            Write-Host "  Output : $($result.Output)" -ForegroundColor Green
            Write-Host "  [+] Docker test passed" -ForegroundColor Green
        } else {
            Write-Host "  Output : $($result.Output)" -ForegroundColor Red
            Write-Host "  [!] Docker test failed" -ForegroundColor Red
        }
    } catch {
        Write-Host "  [!] Could not connect via PowerShell Direct: $_" -ForegroundColor Red
    }
    Write-Host ""
}

function Invoke-Validate {
    $errors = @()
    $warnings = @()

    # Validate VMs
    if (-not $stack.vms) {
        $errors += "No vms: section found in $ConfigFile"
    } else {
        foreach ($vmName in $stack.vms.Keys) {
            $cfg = $stack.vms[$vmName]
            foreach ($field in @("iso","memory_gb","cpus","os_disk_gb")) {
                if (-not $cfg[$field]) {
                    $errors += "VM '$vmName': missing required field '$field'"
                }
            }
            if ($null -ne $cfg.persistent_disk_gb -and "$($cfg.persistent_disk_gb)".Trim()) {
                $pvSize = 0.0
                $rawPvSize = "$($cfg.persistent_disk_gb)".Trim()
                if (-not [double]::TryParse($rawPvSize, [ref]$pvSize) -or $pvSize -le 0) {
                    $errors += "VM '$vmName': persistent_disk_gb must be a number greater than 0 when specified"
                }
            } else {
                $warnings += "VM '$vmName': persistent_disk_gb is not set — legacy per-VM persistent-storage.vhdx will be skipped"
            }
            if ($cfg.network -and -not $stack.networks) {
                $errors += "VM '$vmName': references network '$($cfg.network)' but no networks: section exists"
            } elseif ($cfg.network -and -not $stack.networks[$cfg.network]) {
                $errors += "VM '$vmName': references unknown network '$($cfg.network)'"
            }
            if ($cfg.mount) {
                foreach ($storageName in $cfg.mount) {
                    if (-not $stack.storage) {
                        $errors += "VM '$vmName': references storage '$storageName' but no storage: section exists"
                    } elseif (-not $stack.storage[$storageName]) {
                        $errors += "VM '$vmName': references unknown storage '$storageName'"
                    }
                }
            }
        }
    }

    # Validate networks
    if ($stack.networks) {
        foreach ($netName in $stack.networks.Keys) {
            $cfg = $stack.networks[$netName]
            if (-not $cfg.switch_name) {
                $errors += "Network '$netName': missing required field 'switch_name'"
            } elseif (-not (Get-VMSwitch -Name $cfg.switch_name -ErrorAction SilentlyContinue)) {
                $warnings += "Network '$netName': switch '$($cfg.switch_name)' does not exist — VMs will fall back to 'Default Switch'"
            }
        }
    }

    # Validate storage
    if ($stack.storage) {
        foreach ($storageName in $stack.storage.Keys) {
            $cfg = $stack.storage[$storageName]
            foreach ($field in @("path","size_gb")) {
                if (-not $cfg[$field]) {
                    $errors += "Storage '$storageName': missing required field '$field'"
                }
            }
        }
    }

    if ($warnings.Count -gt 0) {
        foreach ($w in $warnings) {
            Write-Host "  WARN: $w" -ForegroundColor Yellow
        }
    }
    if ($errors.Count -eq 0) {
        Write-Host "$ConfigFile is valid." -ForegroundColor Green
        exit 0
    } else {
        Write-Host "$($errors.Count) validation error(s) in ${ConfigFile}:" -ForegroundColor Red
        foreach ($err in $errors) {
            Write-Host "  ERROR: $err" -ForegroundColor Red
        }
        exit 1
    }
}

function Mount-VMStorage {
    param($vmName, $storageName)

    if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        Write-Host "VM not found: $vmName" -ForegroundColor Red
        return
    }
    if (-not $stack.storage -or -not $stack.storage[$storageName]) {
        Write-Host "Storage '$storageName' not found in storage: section" -ForegroundColor Red
        return
    }

    $storageCfg = $stack.storage[$storageName]
    $storagePath = Resolve-StoragePath $storageCfg.path
    if (Test-StorageMountedOnHost $storagePath) {
        Write-Host "Storage '$storageName' is currently mounted on the host. Local mount and VM use are mutually exclusive." -ForegroundColor Red
        Write-Host "  Run './vm-compose.ps1 localunmount $storageName' first." -ForegroundColor Gray
        return
    }

    Invoke-IfLive "Create VHDX $storagePath if missing ($($storageCfg.size_gb) GB)" {
        if (-not (Test-Path $storagePath)) {
            New-Item -ItemType Directory -Path (Split-Path $storagePath) -Force | Out-Null
            New-VHD -Path $storagePath -SizeBytes ($storageCfg.size_gb * 1GB) -Dynamic | Out-Null
            Initialize-SharedVHDX -Path $storagePath -Label $storageName
        }
    }
    Invoke-IfLive "Add-VMHardDiskDrive $vmName <- $storagePath" {
        Add-VMHardDiskDrive -VMName $vmName -Path $storagePath | Out-Null
    }
    Write-Host "Mounted '$storageName' on $vmName"
}

function Dismount-VMStorage {
    param($vmName, $storageName)

    if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        Write-Host "VM not found: $vmName" -ForegroundColor Red
        return
    }
    if (-not $stack.storage -or -not $stack.storage[$storageName]) {
        Write-Host "Storage '$storageName' not found in storage: section" -ForegroundColor Red
        return
    }

    $storagePath = Resolve-StoragePath $stack.storage[$storageName].path
    $drive = Get-VMDiskForPath -VmName $vmName -StoragePath $storagePath

    if (-not $drive) {
        Write-Host "Storage '$storageName' is not currently mounted on $vmName" -ForegroundColor Yellow
        return
    }

    Invoke-IfLive "Remove-VMHardDiskDrive $vmName <- $storagePath" {
        $drive | Remove-VMHardDiskDrive
    }
    Write-Host "Unmounted '$storageName' from $vmName"
}

function Mount-LocalStorage {
    param([string]$StorageName, [string]$DriveLetter = 'S')

    if (-not $stack.storage -or -not $stack.storage[$StorageName]) {
        Write-Host "Storage '$StorageName' not found in $ConfigFile" -ForegroundColor Red; return
    }
    $storagePath = Resolve-StoragePath $stack.storage[$StorageName].path
    if (-not (Test-Path $storagePath)) {
        Write-Host "File not found: $storagePath" -ForegroundColor Yellow; return
    }

    $letter = $DriveLetter.TrimEnd(':').ToUpper()

    $mounted = Get-VMsWithDisk $storagePath
    if ($mounted.Count -gt 0) {
        Write-Host "Storage '$StorageName' is mounted on VM(s): $($mounted -join ', ')" -ForegroundColor Red
        Write-Host "  Local mount and VM use are mutually exclusive. Unmount it from the VM first." -ForegroundColor Gray
        return
    }

    # Check drive letter not already in use
    if (Test-Path "${letter}:\") {
        Write-Host "Drive ${letter}: is already in use." -ForegroundColor Red; return
    }

    Write-Host "Mounting $storagePath → ${letter}:\"
    $vhd = Mount-VHD -Path $storagePath -PassThru -ErrorAction Stop

    # Disk may come up offline — bring it online and writable
    $disk = Get-Disk -Number $vhd.DiskNumber
    if ($disk.IsOffline)  { Set-Disk -Number $vhd.DiskNumber -IsOffline $false }
    if ($disk.IsReadOnly) { Set-Disk -Number $vhd.DiskNumber -IsReadOnly $false }

    $partition = Get-Disk -Number $vhd.DiskNumber |
        Get-Partition |
        Where-Object { $_.Size -gt 100MB -and $_.Type -notin @('System', 'Reserved', 'Recovery') } |
        Select-Object -First 1

    if (-not $partition) {
        Write-Host "WARNING: No usable partition found on the VHDX (may not be initialized yet)." -ForegroundColor Yellow
        Write-Host "  Disk is attached as disk $($vhd.DiskNumber) — initialize it manually if needed." -ForegroundColor Gray
        return
    }

    $partition | Set-Partition -NewDriveLetter $letter
    Write-Host "Mounted as ${letter}:\" -ForegroundColor Green
}

function Dismount-LocalStorage {
    param([string]$StorageName)

    if (-not $stack.storage -or -not $stack.storage[$StorageName]) {
        Write-Host "Storage '$StorageName' not found in $ConfigFile" -ForegroundColor Red; return
    }
    $storagePath = Resolve-StoragePath $stack.storage[$StorageName].path

    # Get-VHD -Path throws permission errors when VMMS holds the file handle.
    # Use Get-Disk by Location as the reliable host-mount detector.
    $hostDisk = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.Location -eq $storagePath } | Select-Object -First 1
    if (-not $hostDisk) {
        Write-Host "'$StorageName' is not currently mounted locally." -ForegroundColor Yellow; return
    }

    Dismount-VHD -DiskNumber $hostDisk.Number -ErrorAction Stop
    Write-Host "Dismounted '$StorageName' from host." -ForegroundColor Green
}


function Get-PVPath {
    param([string]$VmName)
    return Join-Path $VmRoot $VmName "persistent-storage.vhdx"
}

function Invoke-SharedStorageCommand {
    param([string]$SubCmd, [string]$Name, [string]$Extra)

    switch -Regex ($(if ($SubCmd) { $SubCmd.ToLower() } else { '' })) {

        '^(ls|list|)$' {
            if (-not $stack.storage) { Write-Host "No storage: section in $ConfigFile" -ForegroundColor Yellow; return }
            $cols = @(
                @{L='Name';      E={ $_.Name }},
                @{L='Type';      E={ if ($_.Name -match '^pv-') { 'named-pv' } else { 'shared' } }},
                @{L='Path';      E={ Resolve-StoragePath $_.Value.path }},
                @{L='VirtGB';    E={ $_.Value.size_gb }},
                @{L='UsedGB';    E={
                    $p = Resolve-StoragePath $_.Value.path
                    if (Test-Path $p) { [math]::Round((Get-Item $p).Length / 1GB, 2) } else { '-' }
                }},
                @{L='%Alloc';    E={
                    $p = Resolve-StoragePath $_.Value.path
                    if (Test-Path $p) {
                        try {
                            $vhd = Get-VHD -Path $p -ErrorAction SilentlyContinue
                            if ($vhd -and $vhd.Size -gt 0) { '{0:0}%' -f ($vhd.FileSize / $vhd.Size * 100) } else { '-' }
                        } catch { '-' }
                    } else { 'MISSING' }
                }},
                @{L='MountedOn'; E={
                    $p = Resolve-StoragePath $_.Value.path
                    $vms = Get-VMsWithDisk $p
                    if ($vms) { $vms -join ',' } else { '-' }
                }}
            )
            $stack.storage.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = $_.Key; Value = $_.Value } } |
                Format-Table $cols -AutoSize
        }

        '^(rm|remove|destroy)$' {
            if (-not $Name) { Write-Host "Usage: storage shared rm <storageName>" -ForegroundColor Yellow; return }
            if (-not $stack.storage -or -not $stack.storage[$Name]) {
                Write-Host "Storage '$Name' not found in $ConfigFile" -ForegroundColor Red; return
            }
            $storagePath = Resolve-StoragePath $stack.storage[$Name].path
            if (-not (Test-Path $storagePath)) { Write-Host "File not found: $storagePath" -ForegroundColor Yellow; return }
            $mounted = Get-VMsWithDisk $storagePath
            if ($mounted) {
                Write-Host "ERROR: '$Name' is currently mounted on: $($mounted -join ', ')" -ForegroundColor Red
                Write-Host "  Unmount first: vm-compose.ps1 unmount <vm> $Name" -ForegroundColor Gray; return
            }
            $ans = Read-Host "Delete '$storagePath'? This cannot be undone. [y/N]"
            if ($ans -notmatch '^[Yy]') { Write-Host "Cancelled."; return }
            Remove-Item $storagePath -Force
            Write-Host "Deleted $storagePath" -ForegroundColor Green
        }

        '^(mv|move)$' {
            if (-not $Name -or -not $Extra) {
                Write-Host "Usage: storage shared mv <storageName> <newPath>" -ForegroundColor Yellow; return
            }
            if (-not $stack.storage -or -not $stack.storage[$Name]) {
                Write-Host "Storage '$Name' not found in $ConfigFile" -ForegroundColor Red; return
            }
            $storagePath = Resolve-StoragePath $stack.storage[$Name].path
            if (-not (Test-Path $storagePath)) { Write-Host "File not found: $storagePath" -ForegroundColor Red; return }
            $mounted = Get-VMsWithDisk $storagePath
            if ($mounted) {
                Write-Host "ERROR: '$Name' is currently mounted on: $($mounted -join ', ')" -ForegroundColor Red
                Write-Host "  Unmount first: vm-compose.ps1 unmount <vm> $Name" -ForegroundColor Gray; return
            }
            $dest = if ([System.IO.Path]::IsPathRooted($Extra)) { $Extra } else { Join-Path $VmRoot $Extra }
            if ((Test-Path $dest) -and (Get-Item $dest).PSIsContainer) { $dest = Join-Path $dest (Split-Path $storagePath -Leaf) }
            Move-Item $storagePath $dest -Force
            Write-Host "Moved $storagePath -> $dest" -ForegroundColor Green
            Write-Host "  Update path in $ConfigFile" -ForegroundColor Yellow
        }

        '^(init|initialize)$' {
            if (-not $Name -or -not $stack.storage -or -not $stack.storage[$Name]) {
                Write-Host "Usage: storage shared init <name>" -ForegroundColor Yellow; return
            }
            $storagePath = Resolve-StoragePath $stack.storage[$Name].path
            if (-not (Test-Path $storagePath)) { Write-Host "VHDX not found: $storagePath" -ForegroundColor Red; return }
            $vmsMounted = Get-VMsWithDisk $storagePath
            if ($vmsMounted.Count -gt 0) {
                Write-Host "Cannot init while mounted on VM(s): $($vmsMounted -join ', ')" -ForegroundColor Red; return
            }
            Initialize-SharedVHDX -Path $storagePath -Label $Name
        }

        '^(create)$' {
            if (-not $Name) { Write-Host "Usage: storage shared create <name>" -ForegroundColor Yellow; return }
            if (-not $stack.storage -or -not $stack.storage[$Name]) {
                Write-Host "Storage '$Name' not found in $ConfigFile" -ForegroundColor Red; return
            }
            $path = Resolve-StoragePath $stack.storage[$Name].path
            if (Test-Path $path) { Write-Host "Already exists: $path" -ForegroundColor Yellow; return }
            New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
            New-VHD -Path $path -SizeBytes ($stack.storage[$Name].size_gb * 1GB) -Dynamic | Out-Null
            Initialize-SharedVHDX -Path $path -Label $Name
            Write-Host "Created: $path" -ForegroundColor Green
        }

        '^(localmount)$' {
            if (-not $Name) { Write-Host "Usage: storage shared localmount <name> [driveLetter]" -ForegroundColor Yellow; return }
            $letter = if ($Extra) { $Extra } else { 'S' }
            Mount-LocalStorage -StorageName $Name -DriveLetter $letter
        }

        '^(localunmount)$' {
            if (-not $Name) { Write-Host "Usage: storage shared localunmount <name>" -ForegroundColor Yellow; return }
            Dismount-LocalStorage -StorageName $Name
        }

        '^(health|status)$' {
            if (-not $stack.storage) { Write-Host "No storage: section in $ConfigFile" -ForegroundColor Yellow; return }
            $entries = if ($Name -and $stack.storage[$Name]) { @{ $Name = $stack.storage[$Name] } } else { $stack.storage }
            foreach ($entry in $entries.GetEnumerator()) {
                $p = Resolve-StoragePath $entry.Value.path
                $exists = Test-Path $p
                Write-Host ""
                $typeLabel = if ($entry.Key -match '^pv-') { 'Named PV' } else { 'Shared Storage' }
                Write-Host "  ${typeLabel}: $($entry.Key)" -ForegroundColor Cyan
                if (-not $exists) { Write-Host "  [!] VHDX NOT FOUND: $p" -ForegroundColor Red; continue }
                $usedGB = [math]::Round((Get-Item $p).Length / 1GB, 2)
                try { $vhd = Get-VHD -Path $p -ErrorAction SilentlyContinue } catch { $vhd = $null }
                $pct = if ($vhd -and $vhd.Size -gt 0) { '{0:0}%' -f ($vhd.FileSize / $vhd.Size * 100) } else { '?' }
                Write-Host ("  [+] {0}  ({1} GB used of {2} GB, {3} allocated)" -f $p, $usedGB, $entry.Value.size_gb, $pct) -ForegroundColor Green
                $vms = Get-VM -ErrorAction SilentlyContinue | Where-Object {
                    (Get-VMHardDiskDrive -VMName $_.Name -ErrorAction SilentlyContinue | Where-Object Path -eq $p)
                }
                if ($vms) {
                    Write-Host "  [+] VM(s): $($vms.Name -join ', ')" -ForegroundColor Green
                } else {
                    Write-Host "  [ ] Not attached to any VM" -ForegroundColor DarkGray
                }
                $hostDisk = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.Location -eq $p } | Select-Object -First 1
                if ($hostDisk) {
                    $vol = Get-Partition -DiskNumber $hostDisk.Number -ErrorAction SilentlyContinue |
                        Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | Select-Object -First 1
                    Write-Host "  [i] Host-mounted at $($vol.DriveLetter):" -ForegroundColor Cyan
                }
            }
            Write-Host ""
        }

        default {
            Write-Host "Usage: ./vm-compose.ps1 storage shared <subcommand> [name] [extra]" -ForegroundColor Yellow
            Write-Host "  ls / list              List all shared storage volumes"
            Write-Host "  create <name>          Create and initialize VHDX"
            Write-Host "  rm / remove <name>     Delete a storage VHDX (must be unmounted)"
            Write-Host "  mv / move <name> <dst> Move a storage VHDX (must be unmounted)"
            Write-Host "  init <name>            Re-initialize an existing VHDX with GPT+NTFS"
            Write-Host "  localmount <name> [S]  Mount on host at drive letter (default S:)"
            Write-Host "  localunmount <name>    Dismount from host"
            Write-Host "  health [name]          Detailed health check"
        }
    }
}

function Invoke-PVCommand {
    param([string]$SubCmd, [string]$VmArg, [string]$Extra)

    switch -Regex ($(if ($SubCmd) { $SubCmd.ToLower() } else { '' })) {

        '^(ls|list|)$' {
            $targets = if ($VmArg) { @($VmArg) } else { @($stack.vms.Keys) }
            Write-Host ""
            Write-Host "  Persistent Volumes:" -ForegroundColor Cyan
            Write-Host ("  {0,-14} {1,8}  {2,8}  {3}" -f 'VM', 'Used GB', 'Cfg GB', 'Status')
            Write-Host ("  " + ("-" * 50))
            foreach ($vm in $targets) {
                $pvPath = Get-PVPath $vm
                $exists = Test-Path $pvPath
                $usedGB = if ($exists) { [math]::Round((Get-Item $pvPath).Length / 1GB, 2) } else { 0 }
                $cfgGB = '-'
                if ($stack.vms[$vm] -and $null -ne $stack.vms[$vm].persistent_disk_gb -and "$($stack.vms[$vm].persistent_disk_gb)".Trim()) {
                    $cfgGB = $stack.vms[$vm].persistent_disk_gb
                }
                $vmObj  = Get-VM -Name $vm -ErrorAction SilentlyContinue
                $attached = $exists -and $vmObj -and (Get-VMHardDiskDrive -VMName $vm -ErrorAction SilentlyContinue | Where-Object Path -eq $pvPath)
                $hostDisk = if ($exists) { Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.Location -eq $pvPath } | Select-Object -First 1 } else { $null }
                $status = if (-not $exists) { 'MISSING' } elseif ($hostDisk) { 'host-mounted' } elseif ($attached) { "vm-attached ($($vmObj.State))" } else { 'detached' }
                $color  = switch -Wildcard ($status) { 'MISSING' { 'Red' } 'host-mounted' { 'Cyan' } 'vm-attached*' { 'Green' } default { 'DarkGray' } }
                Write-Host ("  {0,-14} {1,8}  {2,8}  {3}" -f $vm, $usedGB, $cfgGB, $status) -ForegroundColor $color
            }
            Write-Host ""
        }

        '^(create)$' {
            if (-not $VmArg) { Write-Host "Usage: storage pv create <vmName>" -ForegroundColor Yellow; return }
            if (-not $stack.vms[$VmArg]) { Write-Host "VM '$VmArg' not found in $ConfigFile" -ForegroundColor Red; return }
            $pvPath = Get-PVPath $VmArg
            if (Test-Path $pvPath) { Write-Host "Already exists: $pvPath" -ForegroundColor Yellow; return }
            $gbRaw = if ($null -ne $stack.vms[$VmArg].persistent_disk_gb) { "$($stack.vms[$VmArg].persistent_disk_gb)".Trim() } else { '' }
            $gb = 0.0
            if (-not $gbRaw -or -not [double]::TryParse($gbRaw, [ref]$gb) -or $gb -le 0) {
                Write-Host "VM '$VmArg' does not define a valid persistent_disk_gb (> 0)." -ForegroundColor Red
                Write-Host "  Add it in $ConfigFile, or use named storage volumes under storage: + mount: instead." -ForegroundColor Gray
                return
            }
            New-Item -ItemType Directory -Path (Split-Path $pvPath) -Force | Out-Null
            New-VHD -Path $pvPath -SizeBytes ($gb * 1GB) -Dynamic | Out-Null
            Write-Host "Created: $pvPath ($gb GB) — will be formatted on first VM boot (P:\DockerData)" -ForegroundColor Green
        }

        '^(rm|remove|destroy)$' {
            if (-not $VmArg) { Write-Host "Usage: storage pv destroy <vmName>" -ForegroundColor Yellow; return }
            $pvPath = Get-PVPath $VmArg
            if (-not (Test-Path $pvPath)) { Write-Host "Not found: $pvPath" -ForegroundColor Yellow; return }
            $vmState = (Get-VM -Name $VmArg -ErrorAction SilentlyContinue).State
            if ($vmState -eq 'Running') { Write-Host "Stop VM '$VmArg' first." -ForegroundColor Red; return }
            $hostDisk = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.Location -eq $pvPath } | Select-Object -First 1
            if ($hostDisk) { Write-Host "PV is host-mounted. Run: storage pv localunmount $VmArg" -ForegroundColor Red; return }
            $ans = Read-Host "Delete '$pvPath'? All Docker data will be lost. [y/N]"
            if ($ans -notmatch '^[Yy]') { Write-Host "Cancelled."; return }
            Remove-Item $pvPath -Force
            Write-Host "Deleted: $pvPath" -ForegroundColor Green
        }

        '^(localmount)$' {
            if (-not $VmArg) { Write-Host "Usage: storage pv localmount <vmName> [driveLetter]" -ForegroundColor Yellow; return }
            $pvPath = Get-PVPath $VmArg
            if (-not (Test-Path $pvPath)) { Write-Host "Not found: $pvPath" -ForegroundColor Red; return }
            $letter = if ($Extra) { $Extra.TrimEnd(':').ToUpper() } else { 'P' }
            $vmsRunning = @(Get-VMsWithDisk $pvPath | Where-Object { (Get-VM -Name $_ -ErrorAction SilentlyContinue).State -eq 'Running' })
            if ($vmsRunning.Count -gt 0) { Write-Host "PV in use by running VM: $($vmsRunning -join ', ')" -ForegroundColor Red; return }
            $existing = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.Location -eq $pvPath } | Select-Object -First 1
            if ($existing) {
                $vol = Get-Partition -DiskNumber $existing.Number -ErrorAction SilentlyContinue |
                    Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | Select-Object -First 1
                Write-Host "Already mounted at $($vol.DriveLetter):" -ForegroundColor Yellow; return
            }
            if (Test-Path "${letter}:\") { Write-Host "Drive ${letter}: is already in use." -ForegroundColor Red; return }
            Write-Host "Mounting $pvPath -> ${letter}:\"
            $vhd  = Mount-VHD -Path $pvPath -PassThru -ErrorAction Stop
            $disk = Get-Disk -Number $vhd.DiskNumber
            if ($disk.IsOffline)  { Set-Disk -Number $disk.Number -IsOffline $false }
            if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }
            $part = Get-Partition -DiskNumber $disk.Number |
                Where-Object { $_.Size -gt 100MB -and $_.Type -notin @('System','Reserved','Recovery') } |
                Select-Object -First 1
            if (-not $part) {
                Write-Host "WARNING: No usable partition found — disk may not be initialized yet." -ForegroundColor Yellow; return
            }
            $part | Set-Partition -NewDriveLetter $letter
            Write-Host "Mounted PV '$VmArg' at ${letter}:\" -ForegroundColor Green
        }

        '^(localunmount)$' {
            if (-not $VmArg) { Write-Host "Usage: storage pv localunmount <vmName>" -ForegroundColor Yellow; return }
            $pvPath = Get-PVPath $VmArg
            $hostDisk = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.Location -eq $pvPath } | Select-Object -First 1
            if (-not $hostDisk) { Write-Host "PV '$VmArg' is not locally mounted." -ForegroundColor Yellow; return }
            Dismount-VHD -DiskNumber $hostDisk.Number -ErrorAction Stop
            Write-Host "Unmounted PV '$VmArg'" -ForegroundColor Green
        }

        '^(health|status)$' {
            $targets = if ($VmArg) { @($VmArg) } else { @($stack.vms.Keys) }
            Write-Host ""
            Write-Host "=== Persistent Volume Health ===" -ForegroundColor Cyan
            foreach ($vm in $targets) {
                $pvPath = Get-PVPath $vm
                $exists = Test-Path $pvPath
                Write-Host ""
                Write-Host "  VM: $vm" -ForegroundColor Cyan
                if (-not $exists) { Write-Host "  [!] VHDX not found: $pvPath" -ForegroundColor Red; continue }
                $usedGB = [math]::Round((Get-Item $pvPath).Length / 1GB, 2)
                $cfgGB = '-'
                if ($stack.vms[$vm] -and $null -ne $stack.vms[$vm].persistent_disk_gb -and "$($stack.vms[$vm].persistent_disk_gb)".Trim()) {
                    $cfgGB = $stack.vms[$vm].persistent_disk_gb
                }
                Write-Host "  [+] $pvPath" -ForegroundColor Green
                try {
                    $vhd = Get-VHD -Path $pvPath -ErrorAction Stop
                    $pct = if ($vhd.Size -gt 0) { [math]::Round($vhd.FileSize / $vhd.Size * 100, 1) } else { 0 }
                    Write-Host ("  [i] Size: {0} GB used of {1} GB ({2}% allocated)" -f $usedGB, $cfgGB, $pct) -ForegroundColor Cyan
                } catch {
                    Write-Host ("  [i] Size: {0} GB of {1} GB max" -f $usedGB, $cfgGB) -ForegroundColor Cyan
                }
                $vmObj    = Get-VM -Name $vm -ErrorAction SilentlyContinue
                $attached = $vmObj -and (Get-VMHardDiskDrive -VMName $vm -ErrorAction SilentlyContinue | Where-Object Path -eq $pvPath)
                if ($attached) {
                    Write-Host "  [+] Attached to VM (state: $($vmObj.State))" -ForegroundColor Green
                } elseif ($vmObj) {
                    Write-Host "  [ ] Not attached to VM" -ForegroundColor Yellow
                } else {
                    Write-Host "  [ ] VM not built" -ForegroundColor DarkGray
                }
                $hostDisk = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.Location -eq $pvPath } | Select-Object -First 1
                if ($hostDisk) {
                    $vol = Get-Partition -DiskNumber $hostDisk.Number -ErrorAction SilentlyContinue |
                        Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | Select-Object -First 1
                    Write-Host "  [i] Host-mounted at $($vol.DriveLetter):" -ForegroundColor Cyan
                }
            }
            Write-Host ""
        }

        default {
            Write-Host "Usage: ./vm-compose.ps1 storage pv <subcommand> [vmName] [driveLetter]" -ForegroundColor Yellow
            Write-Host "  ls [vm]               List persistent volumes"
            Write-Host "  create <vm>           Create the VHDX file"
            Write-Host "  destroy <vm>          Delete the VHDX (irreversible)"
            Write-Host "  localmount <vm> [P]   Mount on host at drive letter (default P:)"
            Write-Host "  localunmount <vm>     Dismount from host"
            Write-Host "  health [vm]           Detailed health check"
        }
    }
}

function Invoke-StorageCommand {
    param([string]$Type, [string]$SubCmd, [string]$Name, [string]$Extra)

    switch ($Type.ToLower()) {
        'shared' { Invoke-SharedStorageCommand $SubCmd $Name $Extra }
        'pv'     { Invoke-PVCommand $SubCmd $Name $Extra }
        default  { Invoke-SharedStorageCommand $Type $SubCmd $Name }  # backward compat: type IS the subcmd
    }
}


function Invoke-VMCopy {
    param(
        [string]$Source,
        [string]$Destination
    )

    function Test-IsVmPath {
        param([string]$PathValue)
        # Treat drive-letter and UNC paths as HOST paths, not vmname:path.
        if ($PathValue -match '^[A-Za-z]:[\\/]') { return $false }      # C:\... or C:/...
        if ($PathValue -match '^\\\\')           { return $false }      # \\server\share...
        return ($PathValue -match '^([^:]+):(.+)$')                      # vmname:path
    }

    # Detect which side is the VM (format: vmname:path)
    $srcIsVm  = Test-IsVmPath $Source
    $destIsVm = Test-IsVmPath $Destination

    if ($srcIsVm -and $destIsVm) {
        Write-Host "ERROR: Both source and destination cannot be VM paths." -ForegroundColor Red; return
    }
    if (-not $srcIsVm -and -not $destIsVm) {
        Write-Host "ERROR: One of source or destination must be a VM path (vmname:path)." -ForegroundColor Red; return
    }

    if ($destIsVm) {
        # Host → VM  (uses Copy-VMFile via Guest Service Interface, no credentials needed)
        $null = $Destination -match '^([^:]+):(.+)$'
        $vmName  = $Matches[1]
        $vmPath  = $Matches[2]

        if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
            Write-Host "VM '$vmName' not found." -ForegroundColor Red; return
        }
        try {
            $srcPath = Resolve-Path -LiteralPath $Source -ErrorAction Stop | Select-Object -ExpandProperty Path
            $srcItem = Get-Item -LiteralPath $srcPath -ErrorAction Stop
            Write-Host "Copying '$srcPath' → ${vmName}:$vmPath"

            if ($srcItem.PSIsContainer) {
                $srcRoot  = $srcPath.TrimEnd('\')
                $destRoot = ($vmPath -replace '/', '\').TrimEnd('\')
                $files = @(Get-ChildItem -LiteralPath $srcPath -Recurse -File -Force -ErrorAction Stop)

                foreach ($file in $files) {
                    $relative = $file.FullName.Substring($srcRoot.Length).TrimStart('\')
                    $destFile = "$destRoot\$relative"
                    Copy-VMFile -VMName $vmName -SourcePath $file.FullName -DestinationPath $destFile `
                                -FileSource Host -CreateFullPath -Force -ErrorAction Stop
                }

                if ($files.Count -eq 0) {
                    Write-Host "Source directory is empty; nothing to copy." -ForegroundColor Yellow
                } else {
                    Write-Host "Copied $($files.Count) file(s)." -ForegroundColor Green
                }
            } else {
                Copy-VMFile -VMName $vmName -SourcePath $srcPath -DestinationPath $vmPath `
                            -FileSource Host -CreateFullPath -Force -ErrorAction Stop
                Write-Host "Copied 1 file." -ForegroundColor Green
            }
            Write-Host "Done." -ForegroundColor Green
        } catch {
            Write-Host "ERROR copying host path to VM: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        # VM → Host  (uses PowerShell Direct — requires VM Integration Services)
        $null = $Source -match '^([^:]+):(.+)$'
        $vmName   = $Matches[1]
        $vmPath   = $Matches[2]
        $destPath = if ($Destination) { $Destination } else { "." }

        if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
            Write-Host "VM '$vmName' not found." -ForegroundColor Red; return
        }
        $cred = Get-VMCredential $vmName
        if (-not $cred) { Write-Host "Cancelled." -ForegroundColor Yellow; return }

        Write-Host "Copying ${vmName}:$vmPath → '$destPath'"
        $session = New-PSSession -VMName $vmName -Credential $cred -ErrorAction Stop
        try {
            Copy-Item -FromSession $session -Path $vmPath -Destination $destPath -Recurse -Force
            Write-Host "Done." -ForegroundColor Green
        } finally {
            Remove-PSSession $session -ErrorAction SilentlyContinue
        }
    }
}

function Get-WebServiceState {
    param([string]$Name)
    $svc  = Get-Service       -Name $Name -ErrorAction SilentlyContinue
    $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($svc)  { return @{ kind = 'service'; running = ($svc.Status  -eq 'Running'); raw = $svc  } }
    if ($task) { return @{ kind = 'task';    running = ($task.State  -eq 'Running'); raw = $task } }
    return $null
}

function Start-WebService {
    param([string]$Name)
    $s = Get-WebServiceState $Name
    if (-not $s) { Write-Host "'$Name' is not installed." -ForegroundColor Red; return }
    if ($s.running) { Write-Host "'$Name' is already running." -ForegroundColor Green; return }
    if ($s.kind -eq 'service') { Start-Service -Name $Name -ErrorAction SilentlyContinue }
    else                       { Start-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
    $s2 = Get-WebServiceState $Name
    if ($s2.running) { Write-Host "'$Name' started." -ForegroundColor Green }
    else             { Write-Host "Failed to start '$Name'." -ForegroundColor Red }
}

function Stop-WebService {
    param([string]$Name)
    $s = Get-WebServiceState $Name
    if (-not $s) { Write-Host "'$Name' is not installed." -ForegroundColor Red; return }
    if (-not $s.running) { Write-Host "'$Name' is already stopped." -ForegroundColor Yellow; return }
    if ($s.kind -eq 'service') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
    else                       { Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    $s2 = Get-WebServiceState $Name
    if (-not $s2.running) { Write-Host "'$Name' stopped." -ForegroundColor Green }
    else                  { Write-Host "Failed to stop '$Name'." -ForegroundColor Red }
}

function Show-WebServiceStatus {
    param([string]$Name, [string]$Label, [string]$Url, [string]$InstallScript)
    $s = Get-WebServiceState $Name
    if (-not $s) {
        Write-Host "$Label" -NoNewline
        Write-Host "  not installed" -ForegroundColor DarkGray
        Write-Host "  Install: .\$InstallScript" -ForegroundColor Gray
        return
    }
    $via   = if ($s.kind -eq 'service') { 'Windows service' } else { 'Task Scheduler' }
    $state = if ($s.running) { 'running' } else { 'stopped' }
    $color = if ($s.running) { 'Green'   } else { 'Yellow'  }
    Write-Host "$Label" -NoNewline
    Write-Host "  $state" -NoNewline -ForegroundColor $color
    Write-Host "  via $via" -ForegroundColor Gray

    if ($s.running) {
        Write-Host "  $Url" -ForegroundColor Cyan

        # HTTP health check (-SkipHttpErrorCheck lets us read 4xx/5xx bodies without throwing)
        try {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 `
                        -SkipHttpErrorCheck -ErrorAction Stop
            $code = [int]$resp.StatusCode
            if ($code -lt 400) {
                Write-Host "  HTTP $code  OK" -ForegroundColor Green
            } else {
                Write-Host "  HTTP $code  error" -ForegroundColor Red
                $body = ($resp.Content -replace '<[^>]+>','' -replace '\s+',' ').Trim()
                $snippet = if ($body.Length -gt 200) { $body.Substring(0,200) + '...' } else { $body }
                if ($snippet) { Write-Host "  $snippet" -ForegroundColor DarkRed }
            }
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match 'connect|refused|timed? ?out|unreachable') {
                Write-Host "  HTTP unreachable — process running but not yet listening" -ForegroundColor Yellow
            } else {
                Write-Host "  HTTP check failed: $msg" -ForegroundColor Yellow
            }
        }
    }
}

function Remove-WebService {
    param([string]$Name, [string]$Label)
    Assert-Admin
    $s = Get-WebServiceState $Name
    if (-not $s) { Write-Host "'$Label' is not installed." -ForegroundColor Yellow; return }

    # Stop first
    if ($s.running) {
        Write-Host "Stopping $Label..."
        if ($s.kind -eq 'service') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        else                       { Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
    }

    # Remove service
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($svc) {
        sc.exe delete $Name | Out-Null
        Write-Host "Removed Windows service '$Name'." -ForegroundColor Green
    }

    # Remove scheduled task
    $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "Removed scheduled task '$Name'." -ForegroundColor Green
    }
}

function Get-MetricsStatus {
    Show-WebServiceStatus -Name 'vm-metrics' -Label 'Metrics exporter' `
        -Url 'http://localhost:9090/metrics' -InstallScript 'vm-metrics-install.ps1'
}

# For any command, passing "help" as the vm/sub-arg shows per-command help.
# e.g. ./vm-compose.ps1 inspect help  OR  ./vm-compose.ps1 exec help
if ($VmName -eq "help" -or $ExecCommand -eq "help" -or $StorageName -eq "help") {
    Write-Host ""
    Write-Host "  $($CommandHelp[$Command])" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

switch ($Command) {
    { $_ -in "up","start" } {
        Assert-Admin
        Initialize-Networks
        foreach ($vm in (Resolve-TargetVMs $VmName)) {
            Build-VM $vm $stack.vms[$vm] -AutoStart
        }
    }

    "build" {
        Assert-Admin
        Initialize-Networks
        foreach ($vm in (Resolve-TargetVMs $VmName)) {
            Build-VM $vm $stack.vms[$vm] -Rebuild:$Force
        }
    }

    { $_ -in "down","stop" } {
        Assert-Admin
        Stop-AllVMs $VmName
    }

    { $_ -in "restart","reboot" } {
        Assert-Admin
        Restart-AllVMs $VmName
    }

    "destroy" {
        Assert-Admin
        Remove-AllVMs $VmName
    }

    "list" {
        $vms | Sort-Object | ForEach-Object { Write-Host $_ }
    }

    "status" {
        Assert-Admin
        Get-AllVMStatus $VmName
    }

    { $_ -in "inspect","describe","show" } {
        Assert-Admin
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 inspect <vmName>" -ForegroundColor Yellow
        } else {
            Get-VMDetails $VmName
        }
    }

    "logs" {
        Assert-Admin
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 logs <vmName>" -ForegroundColor Yellow
        } else {
            Get-VMLogs $VmName
        }
    }

    "getlog" {
        Assert-Admin
        # Use $null path for logs pulled via cmdlet rather than Get-Content
        $knownLogs = [ordered]@{
            bootstrap = @{ Path = 'C:\Setup\bootstrap.log';                    Desc = 'Unattend bootstrap script output' }
            setup     = @{ Path = 'C:\Windows\Panther\setupact.log';           Desc = 'Windows Setup activity log' }
            setuperr  = @{ Path = 'C:\Windows\Panther\setuperr.log';           Desc = 'Windows Setup errors' }
            docker    = @{ Path = $null;                                        Desc = 'Docker daemon (Windows Event Log)' }
        }

        $logType  = $VmName       # position 1: log type OR vm name when listing
        $vmTarget = $ExecCommand  # position 2: vm name when fetching

        # "getlog <vm>" with no log type → list available logs
        if ($logType -and -not $vmTarget -and -not $knownLogs.Contains($logType.ToLower())) {
            $vmTarget = $logType; $logType = $null
        }

        if (-not $vmTarget) {
            Write-Host "Usage: ./vm-compose.ps1 getlog <vm>                 # list available logs" -ForegroundColor Yellow
            Write-Host "       ./vm-compose.ps1 getlog <logtype> <vm>       # fetch a log" -ForegroundColor Yellow
            Write-Host "  Log types: $($knownLogs.Keys -join ', ')" -ForegroundColor Gray
        } elseif (-not $logType) {
            # List mode: show each log and whether it exists on the VM
            Write-Host "=== Logs available on $vmTarget ===" -ForegroundColor Cyan
            $checks = Invoke-Command -VMName $vmTarget -Credential (Get-VMCredential $vmTarget) -ScriptBlock {
                param($logs)
                $logs.GetEnumerator() | ForEach-Object {
                    $p = $_.Value.Path
                    [PSCustomObject]@{
                        Type   = $_.Key
                        Path   = if ($p) { $p } else { '(event log)' }
                        Exists = if ($p) { Test-Path $p } else { $true }
                        Desc   = $_.Value.Desc
                    }
                }
            } -ArgumentList $knownLogs -ErrorAction SilentlyContinue
            if ($checks) {
                $checks | ForEach-Object {
                    $mark = if ($_.Exists) { '[+]' } else { '[ ]' }
                    $color = if ($_.Exists) { 'Green' } else { 'DarkGray' }
                    Write-Host ("{0} {1,-12} {2,-40} {3}" -f $mark, $_.Type, $_.Path, $_.Desc) -ForegroundColor $color
                }
            } else {
                Write-Host "Could not connect to VM '$vmTarget'." -ForegroundColor Red
            }
        } elseif (-not $knownLogs.Contains($logType.ToLower())) {
            Write-Host "Unknown log type '$logType'. Known: $($knownLogs.Keys -join ', ')" -ForegroundColor Red
        } else {
            $entry = $knownLogs[$logType.ToLower()]
            if ($entry.Path) {
                Invoke-VMCommand $vmTarget "if (Test-Path '$($entry.Path)') { Get-Content '$($entry.Path)' } else { Write-Host 'Log not found: $($entry.Path)' -ForegroundColor Yellow }"
            } else {
                # docker → Windows Event Log
                Invoke-VMCommand $vmTarget "Get-EventLog -LogName Application -Source docker -Newest 100 -ErrorAction SilentlyContinue | Format-Table TimeGenerated,EntryType,Message -AutoSize -Wrap"
            }
        }
    }

    { $_ -in 'bootlogs','bootlog' } {
        Assert-Admin
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 bootlogs <vmName> [tailLines]" -ForegroundColor Yellow
        } else {
            $tailLines = 200
            if ($ExecCommand) {
                if (-not [int]::TryParse($ExecCommand, [ref]$tailLines)) {
                    Write-Host "Invalid tail value '$ExecCommand' (must be an integer)." -ForegroundColor Yellow
                    $tailLines = 200
                }
            }
            Get-VMBootstrapLogs -vmName $VmName -Tail $tailLines
        }
    }

    "exec" {
        Assert-Admin
        if (-not $VmName -or -not $ExecCommand) {
            Write-Host 'Usage: ./vm-compose.ps1 exec <vmName> "<command>"' -ForegroundColor Yellow
        } else {
            Invoke-VMCommand $VmName $ExecCommand
        }
    }

    "ps" {
        Assert-Admin
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 ps <vmName>" -ForegroundColor Yellow
        } else {
            Get-VMProcesses $VmName
        }
    }

    "ssh" {
        Assert-Admin
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 ssh <vmName>" -ForegroundColor Yellow
        } else {
            Enter-VM $VmName
        }
    }

    "ip" {
        Assert-Admin
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 ip <vmName>" -ForegroundColor Yellow
        } else {
            Get-VMIpAddress $VmName
        }
    }

    "top" {
        Assert-Admin
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 top <vmName>" -ForegroundColor Yellow
        } else {
            Get-VMTop $VmName
        }
    }

    "health" {
        Assert-Admin
        Test-AllVMs $VmName
    }

    "docker" {
        Assert-Admin
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 docker <vmName> <docker args...>" -ForegroundColor Yellow
        } else {
            $allDockerArgs = @()
            if ($ExecCommand) { $allDockerArgs += $ExecCommand }
            if ($StorageName) { $allDockerArgs += $StorageName }
            if ($ExtraArg)    { $allDockerArgs += $ExtraArg }
            if ($DockerArgs)  { $allDockerArgs += $DockerArgs }
            if (-not $allDockerArgs) {
                Write-Host "Usage: ./vm-compose.ps1 docker <vmName> <docker args...>" -ForegroundColor Yellow
            } else {
                Invoke-DockerInVM $VmName $allDockerArgs
            }
        }
    }

    "docker-test" {
        Assert-Admin
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 docker-test <vmName>" -ForegroundColor Yellow
        } else {
            Invoke-DockerTest $VmName
        }
    }

    "docker-compose" {
        Assert-Admin
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 docker-compose <vmName> <compose args...>" -ForegroundColor Yellow
        } else {
            $allDockerArgs = @()
            if ($ExecCommand) { $allDockerArgs += $ExecCommand }
            if ($StorageName) { $allDockerArgs += $StorageName }
            if ($ExtraArg)    { $allDockerArgs += $ExtraArg }
            if ($DockerArgs)  { $allDockerArgs += $DockerArgs }
            if (-not $allDockerArgs) {
                Write-Host "Usage: ./vm-compose.ps1 docker-compose <vmName> <compose args...>" -ForegroundColor Yellow
            } else {
                Invoke-DockerComposeInVM $VmName $allDockerArgs
            }
        }
    }

    "validate" {
        Invoke-Validate
    }

    "version" {
        Write-Host "vm-compose $Version"
        Write-Host "PowerShell $($PSVersionTable.PSVersion)"
        Write-Host "Config: $ConfigFile"
    }

    "mount" {
        Assert-Admin
        if (-not $VmName -or -not $StorageName) {
            Write-Host "Usage: ./vm-compose.ps1 mount <vmName> <storageName>" -ForegroundColor Yellow
        } else {
            Mount-VMStorage $VmName $StorageName
        }
    }

    "unmount" {
        Assert-Admin
        if (-not $VmName -or -not $StorageName) {
            Write-Host "Usage: ./vm-compose.ps1 unmount <vmName> <storageName>" -ForegroundColor Yellow
        } else {
            Dismount-VMStorage $VmName $StorageName
        }
    }

    "storage" {
        Assert-Admin
        # storage [shared|pv] <subcmd> [name] [extra]
        # Backward compat: storage <subcmd> [name] [dest] maps to "shared"
        if ($VmName -in @('shared', 'pv')) {
            Invoke-StorageCommand -Type $VmName -SubCmd $ExecCommand -Name $StorageName -Extra $ExtraArg
        } else {
            Invoke-StorageCommand -Type $VmName -SubCmd $ExecCommand -Name $StorageName -Extra $ExtraArg
        }
    }

    "localmount" {
        Assert-Admin
        # $VmName=storageName  $ExecCommand=driveLetter (optional, default S)
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 localmount <storageName> [driveLetter]" -ForegroundColor Yellow
        } else {
            $letter = if ($ExecCommand) { $ExecCommand } else { 'S' }
            Mount-LocalStorage -StorageName $VmName -DriveLetter $letter
        }
    }

    "localunmount" {
        Assert-Admin
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 localunmount <storageName>" -ForegroundColor Yellow
        } else {
            Dismount-LocalStorage -StorageName $VmName
        }
    }

    { $_ -in "cp","copy" } {
        Assert-Admin
        if (-not $VmName -or -not $ExecCommand) {
            Write-Host "Usage: ./vm-compose.ps1 cp <source> <destination>" -ForegroundColor Yellow
            Write-Host "  Host to VM:  cp C:\local\file.txt  myvm:C:\dest\" -ForegroundColor Gray
            Write-Host "  VM to host:  cp myvm:C:\path\file.txt  ." -ForegroundColor Gray
        } else {
            Invoke-VMCopy -Source $VmName -Destination $ExecCommand
        }
    }

    "metrics" {
        $subCmd = if ($VmName) { $VmName.ToLower() } else { 'status' }
        switch ($subCmd) {
            'install' { Assert-Admin; & "$PSScriptRoot\vm-metrics-install.ps1" }
            'start'   { Assert-Admin; Start-WebService 'vm-metrics' }
            'stop'    { Assert-Admin; Stop-WebService  'vm-metrics' }
            'restart' { Assert-Admin; Stop-WebService 'vm-metrics'; Start-Sleep 1; Start-WebService 'vm-metrics' }
            'remove'  { Remove-WebService 'vm-metrics' 'Metrics exporter' }
            'status'  { Get-MetricsStatus }
            default   {
                Write-Host "Usage: ./vm-compose.ps1 metrics [install|start|stop|restart|status|remove]" -ForegroundColor Yellow
            }
        }
    }

    { $_ -in "web","dashboard" } {
        $subCmd = if ($VmName) { $VmName.ToLower() } else { 'status' }
        switch ($subCmd) {
            'install' { Assert-Admin; & "$PSScriptRoot\vm-dashboard-install.ps1" }
            'start'   { Assert-Admin; Start-WebService 'vm-dashboard' }
            'stop'    { Assert-Admin; Stop-WebService  'vm-dashboard' }
            'restart' { Assert-Admin; Stop-WebService 'vm-dashboard'; Start-Sleep 1; Start-WebService 'vm-dashboard' }
            'remove'  { Remove-WebService 'vm-dashboard' 'Dashboard' }
            'status'  { Show-WebServiceStatus -Name 'vm-dashboard' -Label 'Dashboard' `
                           -Url 'http://localhost:8080' -InstallScript 'vm-dashboard-install.ps1' }
            default   {
                Write-Host "Usage: ./vm-compose.ps1 web [install|start|stop|restart|status|remove]" -ForegroundColor Yellow
            }
        }
    }

    "note" {
        Assert-Admin
        $subCmd = $VmName      # show | add | edit
        $noteVm = $ExecCommand # vm name

        if (-not $subCmd -or $subCmd -notin @("show","add","edit") -or -not $noteVm) {
            Write-Host "Usage: ./vm-compose.ps1 note <show|add|edit> <vmName>" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  note show <vm>   Print the VM's Notes field"
            Write-Host "  note add  <vm>   Append text to the Notes field (prompted)"
            Write-Host "  note edit <vm>   Open Notes in Notepad for full editing"
            break
        }

        $vmObj = Get-VM -Name $noteVm -ErrorAction SilentlyContinue
        if (-not $vmObj) {
            Write-Host "VM not found: $noteVm" -ForegroundColor Red
            break
        }

        switch ($subCmd) {
            "show" {
                if ($vmObj.Notes) {
                    Write-Host ""
                    Write-Host "Notes for '$noteVm':" -ForegroundColor Cyan
                    Write-Host $vmObj.Notes
                } else {
                    Write-Host "No notes for '$noteVm'." -ForegroundColor Gray
                }
            }

            "add" {
                $text = Read-Host "Enter note to append"
                if ($text) {
                    $existing = $vmObj.Notes
                    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm"
                    $newNote = if ($existing) { "$existing`n[$timestamp] $text" } else { "[$timestamp] $text" }
                    Set-VM -Name $noteVm -Notes $newNote
                    Write-Host "Note appended to '$noteVm'." -ForegroundColor Green
                }
            }

            "edit" {
                $tmpFile = Join-Path $env:TEMP "$noteVm-note.txt"
                $vmObj.Notes | Out-File $tmpFile -Encoding utf8 -Force
                $before = Get-Item $tmpFile | Select-Object -ExpandProperty LastWriteTime

                Start-Process notepad.exe $tmpFile -Wait

                $after = Get-Item $tmpFile | Select-Object -ExpandProperty LastWriteTime
                if ($after -gt $before) {
                    $newNote = (Get-Content $tmpFile -Raw).TrimEnd()
                    Set-VM -Name $noteVm -Notes $newNote
                    Write-Host "Notes saved for '$noteVm'." -ForegroundColor Green
                } else {
                    Write-Host "No changes made." -ForegroundColor Gray
                }
                Remove-Item $tmpFile -Force
            }
        }
    }


    "help" {
        $targetCmd = if ($VmName -and $CommandHelp.ContainsKey($VmName)) { $VmName } else { $null }
        if ($targetCmd) {
            Write-Host ""
            Write-Host "  $($CommandHelp[$targetCmd])" -ForegroundColor Cyan
            Write-Host ""
        } else {
            Write-Host $HelpText
        }
    }
}
