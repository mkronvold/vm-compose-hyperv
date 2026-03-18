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
    [ValidateSet("up","start","build","down","stop","restart","reboot","destroy","list","status","inspect","describe","show","logs","exec","ps","ssh","ip","top","health","validate","version","mount","unmount","cp","copy","metrics","web","note","help")]
    [string]$Command,

    [Parameter(Position=1)]
    [string]$VmName,
    [Parameter(Position=2)]
    [string]$ExecCommand,
    [Parameter(Position=3)]
    [string]$StorageName,
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
  cp / copy <src> <dest>  Copy files to/from a VM  (prefix VM paths: vmname:path)
  note <show|add|edit> <vm>  Show, append to, or edit VM notes

SERVICES
  web [install|start|stop|status|remove]     Manage the web dashboard (port 8080)
  metrics [install|start|stop|status|remove] Manage the Prometheus metrics exporter (port 9090)

OPTIONS
  -DryRun         Preview changes without executing them
  -Force          Skip confirmation prompts (e.g. rebuild existing VM)
  -ConfigFile     Path to YAML config (default: vmstack.yaml)
  -VmRoot         Root path for VM storage (default: C:\HyperV\VMs)
  -Help, -h       Show this help message
"@

$CommandHelp = @{
    "up"       = "up / start [<vm>] [-DryRun]`n  Build and START VMs defined in vmstack.yaml.`n  Omit <vm> to target all; specify a VM name to target one.`n  Creates OS disk, persistent disk, unattend.vhdx, unattend.xml, bootstrap.ps1,`n  attaches networks and shared storage, then starts the VM.`n  If a VM already exists, starts it if stopped."
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
    "health"   = "health [<vm>]`n  Health check: VM state, IP assignment, Docker responsiveness. Omit <vm> for all."
    "validate" = "validate`n  Lint vmstack.yaml for missing required fields and broken references."
    "version"  = "version`n  Print version, PowerShell version, and active config file path."
    "mount"    = "mount <vm> <storageName>`n  Hot-add a shared storage VHDX (from the storage: section) to a running VM."
    "unmount"  = "unmount <vm> <storageName>`n  Remove a shared storage VHDX from a VM."
    "cp"       = "cp / copy <source> <destination>`n  Copy files between host and a running VM.`n  Host to VM:  cp C:\local\file.txt  myvm:C:\dest\`n  VM to host:  cp myvm:C:\path\file.txt  .`n  Prefix VM paths with vmname: (colon). VM-to-host prompts for Administrator credentials."
    "metrics"  = "metrics [install|start|stop|status|remove]`n  Manage the vm-metrics Prometheus exporter. Default: status.`n  install: run vm-metrics-install.ps1`n  status: shows running state, install method (Windows service or Task Scheduler).`n  remove: stops and unregisters the service/task.`n  Install with: ./vm-metrics-install.ps1"
    "web"      = "web [install|start|stop|status|remove]`n  Manage the vm-dashboard web UI. Default: status.`n  install: run vm-dashboard-install.ps1`n  status: shows running state, install method (Windows service or Task Scheduler).`n  remove: stops and unregisters the service/task.`n  Install with: ./vm-dashboard-install.ps1  |  Run directly: ./vm-dashboard.ps1"
    "note"     = "note <show|add|edit> <vm>`n  show: Print the VM's Notes field.`n  add:  Prompt for text and append it to the Notes field.`n  edit: Open the Notes field in Notepad for full editing."
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

function Resolve-StoragePath {
    param([string]$path)
    if ([System.IO.Path]::IsPathRooted($path)) { return $path }
    return Join-Path $VmRoot $path
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
            if ($existingVm.State -ne 'Off') { Stop-VM -Name $vmName -Force }
        }
        Invoke-IfLive "Remove-VM $vmName" {
            Remove-VM -Name $vmName -Force
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
    Write-Host "Edition conversion succeeded. A reboot is required to complete."
    Start-Sleep -Seconds 5
    Restart-Computer -Force
} else {
    Write-Warning "Edition conversion failed (exit `$LASTEXITCODE). Run manually: dism /Online /Set-Edition:$dismEdition /ProductKey:$($cfg.product_key) /AcceptEula"
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
          <Path>reg add "HKLM\SYSTEM\CurrentControlSet\Control\Network" /v NewNetworkWindowOff /t REG_SZ /d "" /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
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
    # Generate bootstrap.ps1
    # -------------------------
    $bootstrap = @"
`$logPath = 'C:\Setup\bootstrap.log'
Start-Transcript -Path `$logPath -Append -Force | Out-Null
Write-Host "Bootstrap started: `$(Get-Date)"

# Set network profile to Private (suppress location dialog)
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue

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
$dismConversionBlock
Write-Host "Bootstrap complete: `$(Get-Date)"
Stop-Transcript | Out-Null
"@

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
        Add-VMDvdDrive -VMName $vmName -Path $AnswerIsoPath | Out-Null
        Add-VMHardDiskDrive -VMName $vmName -Path $PersistentVhdPath | Out-Null
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
    $warnings = @()

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

    $storagePath = Resolve-StoragePath $stack.storage[$storageName].path
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

function Invoke-VMCopy {
    param(
        [string]$Source,
        [string]$Destination
    )

    # Detect which side is the VM (format: vmname:path)
    $srcIsVm  = $Source      -match '^([^:]+):(.+)$'
    $destIsVm = $Destination -match '^([^:]+):(.+)$'

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
        $srcPath = Resolve-Path $Source -ErrorAction Stop | Select-Object -ExpandProperty Path

        if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
            Write-Host "VM '$vmName' not found." -ForegroundColor Red; return
        }
        Write-Host "Copying '$srcPath' → ${vmName}:$vmPath"
        Copy-VMFile -VMName $vmName -SourcePath $srcPath -DestinationPath $vmPath `
                    -FileSource Host -CreateFullPath -Force
        Write-Host "Done." -ForegroundColor Green
    } else {
        # VM → Host  (uses PowerShell Direct — requires VM Integration Services)
        $null = $Source -match '^([^:]+):(.+)$'
        $vmName   = $Matches[1]
        $vmPath   = $Matches[2]
        $destPath = if ($Destination) { $Destination } else { "." }

        if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
            Write-Host "VM '$vmName' not found." -ForegroundColor Red; return
        }
        $cred = Get-Credential -UserName "Administrator" -Message "Enter Administrator password for '$vmName'"
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
        Get-AllVMStatus $VmName
    }

    { $_ -in "inspect","describe","show" } {
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

    { $_ -in "cp","copy" } {
        # $VmName = source, $ExecCommand = destination (positional params 1 and 2)
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
            'remove'  { Remove-WebService 'vm-metrics' 'Metrics exporter' }
            'status'  { Get-MetricsStatus }
            default   {
                Write-Host "Usage: ./vm-compose.ps1 metrics [install|start|stop|status|remove]" -ForegroundColor Yellow
            }
        }
    }

    "web" {
        $subCmd = if ($VmName) { $VmName.ToLower() } else { 'status' }
        switch ($subCmd) {
            'install' { Assert-Admin; & "$PSScriptRoot\vm-dashboard-install.ps1" }
            'start'   { Assert-Admin; Start-WebService 'vm-dashboard' }
            'stop'    { Assert-Admin; Stop-WebService  'vm-dashboard' }
            'remove' { Remove-WebService 'vm-dashboard' 'Dashboard' }
            'status' { Show-WebServiceStatus -Name 'vm-dashboard' -Label 'Dashboard' `
                           -Url 'http://localhost:8080' -InstallScript 'vm-dashboard-install.ps1' }
            default  {
                Write-Host "Usage: ./vm-compose.ps1 web [install|start|stop|status|remove]" -ForegroundColor Yellow
            }
        }
    }

    "note" {
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
