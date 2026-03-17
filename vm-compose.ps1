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
    [ValidateSet("up","build","down","restart","destroy","list","status","inspect","logs","exec","ps","ssh","ip","top","health","validate","version","mount","unmount","metrics","web","help")]
    [string]$Command,

    [Parameter(Position=1)]
    [string]$VmName,
    [Parameter(Position=2)]
    [string]$ExecCommand,
    [Parameter(Position=3)]
    [string]$StorageName,
    [switch]$DryRun,
    [switch]$Help,
    [Alias("h")][switch]$HelpShort,
    [string]$ConfigFile = "vmstack.yaml",
    [string]$VmRoot = "D:\HyperV\VMs"
)

$Version = "1.1.0"

$HelpText = @"
vm-compose $Version — Hyper-V Compose

USAGE
  ./vm-compose.ps1 <command> [options]

COMMANDS
  up [<vm>]       Build and start VMs (all, or a specific VM)
  build [<vm>]    Provision VMs without starting (all, or a specific VM)
  down [<vm>]     Stop VMs (all, or a specific VM)
  restart [<vm>]  Restart VMs (all, or a specific VM)
  destroy [<vm>]  Delete VM definitions (all, or a specific VM)
  list            List VM names defined in vmstack.yaml
  status [<vm>]   Show status table (all, or a specific VM)
  inspect <vm>    Show detailed info for a VM
  logs <vm>       Show application event log from a VM
  exec <vm> <cmd> Run a command inside a VM
  ps <vm>         List processes inside a VM
  ssh <vm>        Open an interactive shell inside a VM
  ip <vm>         Print the VM's IP address
  top <vm>        Live CPU/memory usage
  health [<vm>]   Health check (all, or a specific VM)
  validate        Lint vmstack.yaml for errors
  version         Show version info
  mount <vm> <storage>    Hot-add a shared storage disk to a VM
  unmount <vm> <storage>  Remove a shared storage disk from a VM
  metrics         Show Prometheus metrics service status
  web             Show web dashboard service status

OPTIONS
  -DryRun         Preview changes without executing them
  -ConfigFile     Path to YAML config (default: vmstack.yaml)
  -VmRoot         Root path for VM storage (default: D:\HyperV\VMs)
  -Help, -h       Show this help message
"@

$CommandHelp = @{
    "up"       = "up [-DryRun]`n  Build and START all VMs defined in vmstack.yaml.`n  Creates OS disk, persistent disk, floppy, unattend.xml, bootstrap.ps1,`n  attaches networks and shared storage, then starts the VM.`n  If a VM already exists, starts it if stopped."
    "build"    = "build [-DryRun]`n  Provision all VMs (create disks, VM definition) WITHOUT starting them.`n  If a VM already exists, reports its state and does nothing."
    "down"     = "down [-DryRun]`n  Stop all VMs (forced power-off)."
    "restart"  = "restart [-DryRun]`n  Restart all VMs."
    "destroy"  = "destroy [-DryRun]`n  Delete VM definitions. Persistent storage VHDXes are preserved."
    "status"   = "status`n  Print a table of all VMs: state, CPU, memory, IP, uptime."
    "inspect"  = "inspect <vm>`n  Show full details for a single VM: CPU, memory, disks, IPs, switches, checkpoints."
    "logs"     = "logs <vm>`n  Show the 20 most recent Application event log entries from a VM."
    "exec"     = "exec <vm> `"<command>`"`n  Run a command inside a VM via PowerShell Direct."
    "ps"       = "ps <vm>`n  List the top 25 processes by CPU inside a VM."
    "ssh"      = "ssh <vm>`n  Open an interactive PowerShell Direct session inside a VM."
    "ip"       = "ip <vm>`n  Print the VM's first IPv4 address."
    "top"      = "top <vm>`n  Live CPU/memory loop (Ctrl+C to exit)."
    "health"   = "health [<vm>]`n  Health check: VM state, IP assignment, Docker responsiveness. Omit <vm> for all."
    "validate" = "validate`n  Lint vmstack.yaml for missing required fields and broken references."
    "version"  = "version`n  Print version, PowerShell version, and active config file path."
    "mount"    = "mount <vm> <storageName>`n  Hot-add a shared storage VHDX (from the storage: section) to a running VM."
    "unmount"  = "unmount <vm> <storageName>`n  Remove a shared storage VHDX from a VM."
    "metrics"  = "metrics`n  Show status of the vm-metrics Prometheus exporter service.`n  Install with: ./vm-metrics-install.ps1"
    "web"      = "web`n  Show status of the vm-dashboard web UI service.`n  Install with: ./vm-dashboard-install.ps1  |  Run directly: ./vm-dashboard.ps1"
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

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host "Installing required module: powershell-yaml..." -ForegroundColor Cyan
    Install-Module powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
}
Import-Module powershell-yaml -ErrorAction Stop

$stack = Get-Content $ConfigFile | ConvertFrom-Yaml
$vms = $stack.vms.Keys

function Initialize-Network {
    param($name, $cfg)

    $switchName = $cfg.switch_name

    if (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue) {
        Write-Host "Network '$name' already exists as switch '$switchName'"
        return
    }

    switch ($cfg.type) {

        "internal" {
            Write-Host "Creating INTERNAL switch '$switchName'"
            Invoke-IfLive "New-VMSwitch -Name $switchName -SwitchType Internal" {
                New-VMSwitch -Name $switchName -SwitchType Internal | Out-Null
            }
        }

        "external" {
            Write-Host "Creating EXTERNAL switch '$switchName'"
            $nic = Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1
            Invoke-IfLive "New-VMSwitch -Name $switchName -NetAdapterName $($nic.Name)" {
                New-VMSwitch -Name $switchName -NetAdapterName $nic.Name -AllowManagementOS $true | Out-Null
            }
        }

        "nat" {
            Write-Host "Creating NAT switch '$switchName'"
            Invoke-IfLive "New-VMSwitch $switchName + New-NetIPAddress $($cfg.gateway) + New-NetNat $($cfg.subnet)" {
                New-VMSwitch -Name $switchName -SwitchType Internal | Out-Null
                $ifIndex = (Get-NetAdapter | Where-Object Name -eq $switchName).ifIndex
                New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $cfg.gateway -PrefixLength 24 | Out-Null
                New-NetNat -Name $switchName -InternalIPInterfaceAddressPrefix $cfg.subnet | Out-Null
            }
        }

        default {
            Write-Host "Unknown network type: $($cfg.type)" -ForegroundColor Red
        }
    }
}

# Auto-create networks
if ($stack.networks) {
    foreach ($net in $stack.networks.Keys) {
        Initialize-Network $net $stack.networks[$net]
    }
}

function Build-VM {
    param($vmName, $cfg, [switch]$AutoStart)

    Write-Host ""
    Write-Host "=== Building VM: $vmName ==="

    # If the VM already exists, optionally start it (up only), otherwise report status
    $existingVm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($existingVm) {
        if ($AutoStart) {
            if ($existingVm.State -eq 'Running') {
                Write-Host "VM '$vmName' is already running." -ForegroundColor Green
            } else {
                Write-Host "VM '$vmName' already exists (state: $($existingVm.State)). Starting..." -ForegroundColor Yellow
                Invoke-IfLive "Start-VM $vmName" { Start-VM -Name $vmName }
            }
        } else {
            Write-Host "VM '$vmName' already exists (state: $($existingVm.State)). Nothing to build." -ForegroundColor Yellow
        }
        return
    }

    $VmPath = Join-Path $VmRoot $vmName
    $SetupDir = Join-Path $VmPath "Setup"
    $VhdPath = Join-Path $VmPath "$vmName.vhdx"
    $PersistentVhdPath = Join-Path $VmPath "persistent-storage.vhdx"
    $FloppyPath = Join-Path $VmPath "autounattend.vfd"

    Invoke-IfLive "New-Item Directory $VmPath + $SetupDir" {
        New-Item -ItemType Directory -Path $VmPath -Force | Out-Null
        New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    }

    # -------------------------
    # Generate unattend.xml
    # -------------------------
    $unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
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
            <PartitionID>2</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>

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
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <PartitionID>1</PartitionID>
              <Format>FAT32</Format>
              <Label>System</Label>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <PartitionID>2</PartitionID>
              <Format>NTFS</Format>
              <Label>Windows</Label>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>

      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>Administrator</FullName>
        <Organization>Local</Organization>
      </UserData>
    </component>
  </settings>

  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$vmName</ComputerName>
    </component>
  </settings>

  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>P@ssw0rd!</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>

      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>powershell -ExecutionPolicy Bypass -File C:\Setup\bootstrap.ps1</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@

    Invoke-IfLive "Write Autounattend.xml to $SetupDir" {
        $unattend | Out-File "$SetupDir\Autounattend.xml" -Encoding utf8 -Force
    }

    # -------------------------
    # Generate bootstrap.ps1
    # -------------------------
    $bootstrap = @"
# Initialize persistent storage disk
\$rawDisks = Get-Disk | Where-Object PartitionStyle -eq 'RAW'
if (\$rawDisks.Count -ge 1) {
    \$disk = \$rawDisks[0]
    Initialize-Disk -Number \$disk.Number -PartitionStyle GPT -PassThru |
        New-Partition -UseMaximumSize -AssignDriveLetter |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel 'DockerData' -Confirm:\$false
}

# Get DockerData volume drive letter
\$dockerVolume = Get-Volume -FileSystemLabel 'DockerData' -ErrorAction SilentlyContinue
if (\$dockerVolume) {
    \$dockerDrive = \$dockerVolume.DriveLetter + ':'
    New-Item -ItemType Directory -Path "\$dockerDrive\docker-data" -Force | Out-Null

    # Configure Docker daemon
    \$daemonConfig = @{ 'data-root' = "\$dockerDrive\docker-data" }
    New-Item -ItemType Directory -Path 'C:\ProgramData\docker\config' -Force | Out-Null
    \$daemonConfig | ConvertTo-Json | Out-File 'C:\ProgramData\docker\config\daemon.json' -Encoding utf8 -Force
}

Install-WindowsFeature -Name Containers -IncludeAllSubFeature -IncludeManagementTools

Invoke-WebRequest -Uri '$($cfg.mirantis_url)' -OutFile 'C:\Setup\mcr-runtime.msi'
Start-Process msiexec.exe -ArgumentList '/i C:\Setup\mcr-runtime.msi /qn /norestart' -Wait

Start-Service docker
Set-Service docker -StartupType Automatic

docker pull mcr.microsoft.com/windows/servercore:ltsc2022
"@

    Invoke-IfLive "Write bootstrap.ps1 to $SetupDir" {
        $bootstrap | Out-File "$SetupDir\bootstrap.ps1" -Encoding utf8 -Force
    }

    # -------------------------
    # Create floppy
    # -------------------------
    Invoke-IfLive "Create floppy VFD $FloppyPath and copy setup files" {
        if (Test-Path $FloppyPath) { Remove-Item $FloppyPath -Force }
        $fs = New-Object -ComObject Scripting.FileSystemObject
        $fs.CreateTextFile($FloppyPath).Close()

        Mount-VHD -Path $FloppyPath -ReadOnly:$false | Out-Null
        $drive = (Get-DiskImage -ImagePath $FloppyPath | Get-Volume).DriveLetter + ":"
        Copy-Item "$SetupDir\Autounattend.xml" "$drive\Autounattend.xml"
        Copy-Item "$SetupDir\bootstrap.ps1" "$drive\bootstrap.ps1"
        Dismount-VHD -Path $FloppyPath
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
    Invoke-IfLive "New-VHD persistent disk $PersistentVhdPath ($($cfg.persistent_disk_gb) GB)" {
        if (Test-Path $PersistentVhdPath) { Remove-Item $PersistentVhdPath -Force }
        New-VHD -Path $PersistentVhdPath -SizeBytes ($cfg.persistent_disk_gb * 1GB) -Dynamic | Out-Null
    }

    # -------------------------
    # Create VM
    # -------------------------
    Invoke-IfLive "New-VM $vmName ($($cfg.memory_gb) GB RAM, $($cfg.cpus) CPUs)" {
        New-VM -Name $vmName -MemoryStartupBytes ($cfg.memory_gb * 1GB) -Generation 2 -VHDPath $VhdPath -Path $VmPath | Out-Null
        Set-VM -Name $vmName -ProcessorCount $cfg.cpus

        Add-VMDvdDrive -VMName $vmName -Path $cfg.iso | Out-Null
        Add-VMHardDiskDrive -VMName $vmName -Path $FloppyPath | Out-Null
        Add-VMHardDiskDrive -VMName $vmName -Path $PersistentVhdPath | Out-Null
    }

    # Attach network
    if ($cfg.network) {
        $switchName = $stack.networks[$cfg.network].switch_name
        Invoke-IfLive "Connect-VMNetworkAdapter $vmName to switch $switchName" {
            Connect-VMNetworkAdapter -VMName $vmName -SwitchName $switchName
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
            $storagePath = $storageCfg.path
            Invoke-IfLive "Create shared VHDX $storagePath ($($storageCfg.size_gb) GB) if missing" {
                if (-not (Test-Path $storagePath)) {
                    New-Item -ItemType Directory -Path (Split-Path $storagePath) -Force | Out-Null
                    New-VHD -Path $storagePath -SizeBytes ($storageCfg.size_gb * 1GB) -Dynamic | Out-Null
                }
            }
            Invoke-IfLive "Add-VMHardDiskDrive $vmName <- $storagePath" {
                Add-VMHardDiskDrive -VMName $vmName -Path $storagePath | Out-Null
            }
            Write-Host "Mounted shared storage '$storageName' on $vmName"
        }
    }

    Invoke-IfLive "Set-VMFirmware $vmName -EnableSecureBoot Off" {
        Set-VMFirmware -VMName $vmName -EnableSecureBoot Off
    }

    if ($AutoStart) {
        Invoke-IfLive "Start-VM $vmName" { Start-VM $vmName }
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
            MemoryGB  = [math]::Round($info.MemoryAssigned / 1GB, 2)
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
        MemoryGB    = [math]::Round($vm.MemoryAssigned / 1GB, 2)
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

function Get-VMLogs {
    param($vmName)
    if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        Write-Host "VM not found: $vmName" -ForegroundColor Red
        return
    }

    Write-Host "=== Logs for $vmName ==="
    Invoke-Command -VMName $vmName -ScriptBlock {
        Get-EventLog -LogName Application -Newest 20
    }
}

function Invoke-VMCommand {
    param($vmName, $cmd)
    if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        Write-Host "VM not found: $vmName" -ForegroundColor Red
        return
    }

    Write-Host "=== Executing on $vmName ==="
    Invoke-Command -VMName $vmName -ScriptBlock { param($c) Invoke-Expression $c } -ArgumentList $cmd
}

function Get-VMProcesses {
    param($vmName)

    if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        Write-Host "VM not found: $vmName" -ForegroundColor Red
        return
    }

    Write-Host "=== Processes in $vmName ==="
    Invoke-Command -VMName $vmName -ScriptBlock {
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
    Enter-PSSession -VMName $vmName
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
        Write-Host "VM: $vm"
        Write-Host "State: $state"
        Write-Host "IP: $ip"

        if ($state -ne "Running") {
            Write-Host "Docker: VM not running" -ForegroundColor Yellow
            continue
        }

        try {
            $docker = Invoke-Command -VMName $vm -ScriptBlock {
                docker info --format "{{.ServerVersion}}"
            } -ErrorAction Stop

            Write-Host "Docker: OK (version $docker)" -ForegroundColor Green
        }
        catch {
            Write-Host "Docker: NOT RESPONDING" -ForegroundColor Red
        }
    }
}

function Invoke-Validate {
    $errors = @()

    # Validate VMs
    if (-not $stack.vms) {
        $errors += "No vms: section found in $ConfigFile"
    } else {
        foreach ($vmName in $stack.vms.Keys) {
            $cfg = $stack.vms[$vmName]
            foreach ($field in @("iso","memory_gb","cpus","os_disk_gb","persistent_disk_gb","mirantis_url")) {
                if (-not $cfg[$field]) {
                    $errors += "VM '$vmName': missing required field '$field'"
                }
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
            foreach ($field in @("type","switch_name")) {
                if (-not $cfg[$field]) {
                    $errors += "Network '$netName': missing required field '$field'"
                }
            }
            if ($cfg.type -eq "nat") {
                foreach ($field in @("subnet","gateway")) {
                    if (-not $cfg[$field]) {
                        $errors += "Network '$netName' (nat): missing required field '$field'"
                    }
                }
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
    $storagePath = $storageCfg.path

    Invoke-IfLive "Create VHDX $storagePath if missing ($($storageCfg.size_gb) GB)" {
        if (-not (Test-Path $storagePath)) {
            New-Item -ItemType Directory -Path (Split-Path $storagePath) -Force | Out-Null
            New-VHD -Path $storagePath -SizeBytes ($storageCfg.size_gb * 1GB) -Dynamic | Out-Null
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

    $storagePath = $stack.storage[$storageName].path
    $drive = Get-VMHardDiskDrive -VMName $vmName | Where-Object Path -eq $storagePath

    if (-not $drive) {
        Write-Host "Storage '$storageName' is not currently mounted on $vmName" -ForegroundColor Yellow
        return
    }

    Invoke-IfLive "Remove-VMHardDiskDrive $vmName <- $storagePath" {
        $drive | Remove-VMHardDiskDrive
    }
    Write-Host "Unmounted '$storageName' from $vmName"
}

function Get-MetricsStatus {
    $svc = Get-Service -Name "vm-metrics" -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "Metrics service status: $($svc.Status)" -ForegroundColor $(if ($svc.Status -eq 'Running') { 'Green' } else { 'Yellow' })
        Write-Host "Metrics URL: http://localhost:9090/metrics"
    } else {
        Write-Host "Metrics service is not installed." -ForegroundColor Yellow
        Write-Host "Run: .\vm-metrics-install.ps1 to install it."
    }
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
    "up" {
        foreach ($vm in (Resolve-TargetVMs $VmName)) {
            Build-VM $vm $stack.vms[$vm] -AutoStart
        }
    }

    "build" {
        foreach ($vm in (Resolve-TargetVMs $VmName)) {
            Build-VM $vm $stack.vms[$vm]
        }
    }

    "down" {
        Stop-AllVMs $VmName
    }

    "restart" {
        Restart-AllVMs $VmName
    }

    "destroy" {
        Remove-AllVMs $VmName
    }

    "list" {
        $vms | Sort-Object | ForEach-Object { Write-Host $_ }
    }

    "status" {
        Get-AllVMStatus $VmName
    }

    "inspect" {
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 inspect <vmName>" -ForegroundColor Yellow
        } else {
            Get-VMDetails $VmName
        }
    }

    "logs" {
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 logs <vmName>" -ForegroundColor Yellow
        } else {
            Get-VMLogs $VmName
        }
    }

    "exec" {
        if (-not $VmName -or -not $ExecCommand) {
            Write-Host 'Usage: ./vm-compose.ps1 exec <vmName> "<command>"' -ForegroundColor Yellow
        } else {
            Invoke-VMCommand $VmName $ExecCommand
        }
    }

    "ps" {
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 ps <vmName>" -ForegroundColor Yellow
        } else {
            Get-VMProcesses $VmName
        }
    }

    "ssh" {
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 ssh <vmName>" -ForegroundColor Yellow
        } else {
            Enter-VM $VmName
        }
    }

    "ip" {
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 ip <vmName>" -ForegroundColor Yellow
        } else {
            Get-VMIpAddress $VmName
        }
    }

    "top" {
        if (-not $VmName) {
            Write-Host "Usage: ./vm-compose.ps1 top <vmName>" -ForegroundColor Yellow
        } else {
            Get-VMTop $VmName
        }
    }

    "health" {
        Test-AllVMs $VmName
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
        if (-not $VmName -or -not $StorageName) {
            Write-Host "Usage: ./vm-compose.ps1 mount <vmName> <storageName>" -ForegroundColor Yellow
        } else {
            Mount-VMStorage $VmName $StorageName
        }
    }

    "unmount" {
        if (-not $VmName -or -not $StorageName) {
            Write-Host "Usage: ./vm-compose.ps1 unmount <vmName> <storageName>" -ForegroundColor Yellow
        } else {
            Dismount-VMStorage $VmName $StorageName
        }
    }

    "metrics" {
        Get-MetricsStatus
    }

    "web" {
        $svc = Get-Service -Name "vm-dashboard" -ErrorAction SilentlyContinue
        if ($svc) {
            Write-Host "Dashboard service status: $($svc.Status)" -ForegroundColor $(if ($svc.Status -eq 'Running') { 'Green' } else { 'Yellow' })
            Write-Host "Dashboard URL: http://localhost:8080"
        } else {
            Write-Host "Dashboard service is not installed." -ForegroundColor Yellow
            Write-Host "Run: .\vm-dashboard-install.ps1 to install it."
            Write-Host "Or run directly: .\vm-dashboard.ps1"
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
