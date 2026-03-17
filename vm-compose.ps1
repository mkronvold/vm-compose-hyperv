<#
.SYNOPSIS
    Hyper-V Compose: A docker-compose-like orchestrator for Windows Server VMs.

.USAGE
    ./vm-compose.ps1 up
    ./vm-compose.ps1 down
    ./vm-compose.ps1 restart
    ./vm-compose.ps1 destroy
    ./vm-compose.ps1 status
    ./vm-compose.ps1 inspect <vm>
    ./vm-compose.ps1 logs <vm>
    ./vm-compose.ps1 exec <vm> "<command>"
    ./vm-compose.ps1 ps <vm>
    ./vm-compose.ps1 ssh <vm>
    ./vm-compose.ps1 ip <vm>
    ./vm-compose.ps1 top <vm>
    ./vm-compose.ps1 health

.NOTES
    Requires PowerShell 7+ for ConvertFrom-Yaml.
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("up","down","restart","destroy","status","inspect","logs","exec","ps","ssh","ip","top","health")]
    [string]$Command,

    [string]$VmName,
    [string]$ExecCommand,
    [string]$ConfigFile = "vmstack.yml",
    [string]$VmRoot = "D:\HyperV\VMs"
)

if (-not (Test-Path $ConfigFile)) {
    Write-Host "Config file not found: $ConfigFile" -ForegroundColor Red
    exit 1
}

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
            New-VMSwitch -Name $switchName -SwitchType Internal | Out-Null
        }

        "external" {
            Write-Host "Creating EXTERNAL switch '$switchName'"
            $nic = Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1
            New-VMSwitch -Name $switchName -NetAdapterName $nic.Name -AllowManagementOS $true | Out-Null
        }

        "nat" {
            Write-Host "Creating NAT switch '$switchName'"
            New-VMSwitch -Name $switchName -SwitchType Internal | Out-Null

            $ifIndex = (Get-NetAdapter | Where-Object Name -eq $switchName).ifIndex
            New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $cfg.gateway -PrefixLength 24 | Out-Null

            New-NetNat -Name $switchName -InternalIPInterfaceAddressPrefix $cfg.subnet | Out-Null
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
    param($vmName, $cfg)

    Write-Host ""
    Write-Host "=== Building VM: $vmName ==="

    $VmPath = Join-Path $VmRoot $vmName
    $SetupDir = Join-Path $VmPath "Setup"
    $VhdPath = Join-Path $VmPath "$vmName.vhdx"
    $PersistentVhdPath = Join-Path $VmPath "persistent-storage.vhdx"
    $FloppyPath = Join-Path $VmPath "autounattend.vfd"

    New-Item -ItemType Directory -Path $VmPath -Force | Out-Null
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null

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

    $unattend | Out-File "$SetupDir\Autounattend.xml" -Encoding utf8 -Force

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

    $bootstrap | Out-File "$SetupDir\bootstrap.ps1" -Encoding utf8 -Force

    # -------------------------
    # Create floppy
    # -------------------------
    if (Test-Path $FloppyPath) { Remove-Item $FloppyPath -Force }
    $fs = New-Object -ComObject Scripting.FileSystemObject
    $fs.CreateTextFile($FloppyPath).Close()

    Mount-VHD -Path $FloppyPath -ReadOnly:$false | Out-Null
    $drive = (Get-DiskImage -ImagePath $FloppyPath | Get-Volume).DriveLetter + ":"
    Copy-Item "$SetupDir\Autounattend.xml" "$drive\Autounattend.xml"
    Copy-Item "$SetupDir\bootstrap.ps1" "$drive\bootstrap.ps1"
    Dismount-VHD -Path $FloppyPath

    # -------------------------
    # Create OS disk
    # -------------------------
    if (Test-Path $VhdPath) { Remove-Item $VhdPath -Force }
    New-VHD -Path $VhdPath -SizeBytes ($cfg.os_disk_gb * 1GB) -Dynamic | Out-Null

    # -------------------------
    # Create persistent disk
    # -------------------------
    if (Test-Path $PersistentVhdPath) { Remove-Item $PersistentVhdPath -Force }
    New-VHD -Path $PersistentVhdPath -SizeBytes ($cfg.persistent_disk_gb * 1GB) -Dynamic | Out-Null

    # -------------------------
    # Create VM
    # -------------------------
    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        Write-Host "VM '$vmName' already exists. Skipping." -ForegroundColor Yellow
        return
    }

    New-VM -Name $vmName -MemoryStartupBytes ($cfg.memory_gb * 1GB) -Generation 2 -VHDPath $VhdPath -Path $VmPath | Out-Null
    Set-VM -Name $vmName -ProcessorCount $cfg.cpus

    Add-VMDvdDrive -VMName $vmName -Path $cfg.iso | Out-Null
    Add-VMHardDiskDrive -VMName $vmName -Path $FloppyPath | Out-Null
    Add-VMHardDiskDrive -VMName $vmName -Path $PersistentVhdPath | Out-Null

    # Attach network
    if ($cfg.network) {
        $switchName = $stack.networks[$cfg.network].switch_name
        Connect-VMNetworkAdapter -VMName $vmName -SwitchName $switchName
    }

    Set-VMFirmware -VMName $vmName -EnableSecureBoot Off

    Start-VM $vmName

    Write-Host "VM '$vmName' started and installing automatically."
}

function Stop-AllVMs {
    foreach ($vm in $vms) {
        if (Get-VM -Name $vm -ErrorAction SilentlyContinue) {
            Stop-VM -Name $vm -Force -TurnOff
            Write-Host "Stopped $vm"
        }
    }
}

function Restart-AllVMs {
    foreach ($vm in $vms) {
        if (Get-VM -Name $vm -ErrorAction SilentlyContinue) {
            Restart-VM -Name $vm
            Write-Host "Restarted $vm"
        }
    }
}

function Remove-AllVMs {
    foreach ($vm in $vms) {
        if (Get-VM -Name $vm -ErrorAction SilentlyContinue) {
            Stop-VM -Name $vm -Force -TurnOff -ErrorAction SilentlyContinue
            Remove-VM -Name $vm -Force
            Write-Host "Destroyed VM $vm (persistent disk preserved)"
        }
    }
}

function Get-AllVMStatus {
    Write-Host ""
    Write-Host "=== VM Status ==="

    $rows = foreach ($vm in $vms) {
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
    Write-Host ""
    Write-Host "=== VM Health Check ==="

    foreach ($vm in $vms) {
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

switch ($Command) {
    "up" {
        foreach ($vm in $vms) {
            Build-VM $vm $stack.vms[$vm]
        }
    }

    "down" {
        Stop-AllVMs
    }

    "restart" {
        Restart-AllVMs
    }

    "destroy" {
        Remove-AllVMs
    }

    "status" {
        Get-AllVMStatus
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
        Test-AllVMs
    }
}
