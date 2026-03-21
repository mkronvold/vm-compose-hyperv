$logPath = 'C:\Setup\bootstrap.log'
$script:bootstrapRunId = [guid]::NewGuid().ToString('N')
$script:bootstrapWarnings = 0
$script:bootstrapFailures = 0
$script:bootstrapState = 'running'
$script:bootstrapCurrentStep = 'startup'
$script:dockerDataVol = $null

function Write-BootstrapStatus {
    param(
        [string]$Step,
        [string]$State = $script:bootstrapState
    )
    if ($Step) { $script:bootstrapCurrentStep = $Step }
    if ($State) { $script:bootstrapState = $State }
    Write-Host ("BOOTSTRAP_STATUS|run={0}|state={1}|warnings={2}|failures={3}|step={4}" -f `
        $script:bootstrapRunId, $script:bootstrapState, $script:bootstrapWarnings, $script:bootstrapFailures, $script:bootstrapCurrentStep)
}

function Write-BootstrapPass {
    param([string]$Step, [string]$Message)
    $suffix = if ($Message) { " :: $Message" } else { '' }
    Write-Host ("[PASS] {0}{1}" -f $Step, $suffix)
    Write-BootstrapStatus -Step $Step -State $script:bootstrapState
}

function Write-BootstrapWarn {
    param([string]$Step, [string]$Message)
    $script:bootstrapWarnings++
    $suffix = if ($Message) { " :: $Message" } else { '' }
    Write-Host ("[WARN] {0}{1}" -f $Step, $suffix) -ForegroundColor Yellow
    Write-BootstrapStatus -Step $Step -State $script:bootstrapState
}

function Write-BootstrapFail {
    param([string]$Step, [string]$Message)
    $script:bootstrapFailures++
    $suffix = if ($Message) { " :: $Message" } else { '' }
    Write-Host ("[FAIL] {0}{1}" -f $Step, $suffix) -ForegroundColor Red
    Write-BootstrapStatus -Step $Step -State $script:bootstrapState
}

function Invoke-BootstrapStep {
    param(
        [string]$Step,
        [scriptblock]$Action,
        [switch]$WarnOnError
    )
    Write-BootstrapStatus -Step $Step -State $script:bootstrapState
    try {
        & $Action
        Write-BootstrapPass -Step $Step
        return $true
    } catch {
        $msg = $_.Exception.Message
        if ($WarnOnError) {
            Write-BootstrapWarn -Step $Step -Message $msg
            return $false
        }
        Write-BootstrapFail -Step $Step -Message $msg
        return $false
    }
}

function Finish-BootstrapFailure {
    param([string]$Step, [string]$Message)
    Write-BootstrapFail -Step $Step -Message $Message
    Write-BootstrapStatus -Step $Step -State 'failed'
    Write-Host "Bootstrap failed: $($script:bootstrapWarnings) warnings, $($script:bootstrapFailures) failures."
    Write-Host "Bootstrap finished: $(Get-Date)"
    Stop-Transcript | Out-Null
    exit 1
}

Start-Transcript -Path $logPath -Append -Force | Out-Null
Write-Host "BOOTSTRAP_RUN_ID=$($script:bootstrapRunId)"
Write-Host "Bootstrap started: $(Get-Date)"
Write-BootstrapStatus -Step 'startup' -State 'running'

$null = Invoke-BootstrapStep -Step 'Set network profile private' -WarnOnError -Action {
    Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction Stop
}

$null = Invoke-BootstrapStep -Step 'Apply desktop UX defaults' -WarnOnError -Action {
    reg.exe add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "HideFileExt" /t REG_DWORD /d 0 /f | Out-Null
    reg.exe add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v "SearchboxTaskbarMode" /t REG_DWORD /d 0 /f | Out-Null
    reg.exe add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarDa" /t REG_DWORD /d 0 /f | Out-Null
    reg.exe add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarMn" /t REG_DWORD /d 0 /f | Out-Null
}

$null = Invoke-BootstrapStep -Step 'Disable sleep timeouts' -WarnOnError -Action {
    powercfg -X -standby-timeout-ac 0
    powercfg -X -standby-timeout-dc 0
}

$null = Invoke-BootstrapStep -Step 'Set SAN policy OnlineAll' -WarnOnError -Action {
    Set-StorageSetting -NewDiskPolicy OnlineAll -ErrorAction Stop
}

$null = Invoke-BootstrapStep -Step 'Bring offline disks online' -WarnOnError -Action {
    $offlineDisks = @(Get-Disk | Where-Object IsOffline)
    if ($offlineDisks.Count -eq 0) {
        Write-Host 'No offline disks found.'
        return
    }
    foreach ($disk in $offlineDisks) {
        Write-Host "Bringing disk $($disk.Number) ($($disk.FriendlyName)) online..."
        Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction Stop
        Set-Disk -Number $disk.Number -IsReadOnly $false -ErrorAction Stop
    }
}

$null = Invoke-BootstrapStep -Step 'Initialize legacy persistent disk' -WarnOnError -Action {
    $rawDisk = Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Select-Object -First 1
    if (-not $rawDisk) {
        Write-Host 'No RAW legacy persistent disk detected.'
        return
    }
    Write-Host "Initializing persistent disk $($rawDisk.Number)..."
    Initialize-Disk -Number $rawDisk.Number -PartitionStyle GPT -PassThru -ErrorAction Stop |
        New-Partition -UseMaximumSize -AssignDriveLetter -ErrorAction Stop |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel 'DockerData' -Confirm:$false -ErrorAction Stop | Out-Null
}

$null = Invoke-BootstrapStep -Step 'Resolve Docker data volume label' -WarnOnError -Action {
    $dockerPreferredLabel = '__PREFERRED_DOCKER_VOLUME_LABEL__'
    $dockerCandidateLabels = @($dockerPreferredLabel, 'DockerData') | Select-Object -Unique
    $script:dockerDataVol = $null
    foreach ($lbl in $dockerCandidateLabels) {
        $script:dockerDataVol = Get-Volume -FileSystemLabel $lbl -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($script:dockerDataVol) { break }
    }
    if (-not $script:dockerDataVol) {
        throw "No docker data volume found for labels: $($dockerCandidateLabels -join ', ')"
    }
}

$null = Invoke-BootstrapStep -Step 'Assign drive letters to partitions without one' -WarnOnError -Action {
    Get-Disk | Where-Object { $_.PartitionStyle -ne 'RAW' -and -not $_.IsOffline } |
        Get-Partition | Where-Object { -not $_.DriveLetter -and $_.Size -gt 100MB -and $_.Type -notin @('System','Reserved','Recovery') } |
        ForEach-Object { $_ | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue }
}

$null = Invoke-BootstrapStep -Step 'Pin Docker and shared drive letters' -WarnOnError -Action {
    $pinTargets = [System.Collections.ArrayList]@()
    if ($script:dockerDataVol) { [void]$pinTargets.Add([PSCustomObject]@{ Label = $script:dockerDataVol.FileSystemLabel; Letter = 'P' }) }
    [void]$pinTargets.Add([PSCustomObject]@{ Label = 'SharedData'; Letter = 'S' })
    $pinTargets | ForEach-Object {
        $pinLabel = $_.Label; $pinLetter = $_.Letter
        $vol = Get-Volume -FileSystemLabel $pinLabel -ErrorAction SilentlyContinue
        if (-not $vol) { return }
        if ($vol.DriveLetter -eq $pinLetter) { return }
        $part = Get-Disk | Where-Object { -not $_.IsOffline -and $_.PartitionStyle -ne 'RAW' } |
            Get-Partition |
            Where-Object { $_.Size -gt 100MB -and $_.Type -notin @('System','Reserved','Recovery') } |
            Where-Object { (Get-Volume -Partition $_ -ErrorAction SilentlyContinue).FileSystemLabel -eq $pinLabel } |
            Select-Object -First 1
        if ($part) {
            $part | Set-Partition -NewDriveLetter $pinLetter -ErrorAction Stop
            Write-Host "Assigned $($pinLetter): to $pinLabel"
        }
    }
}

$null = Invoke-BootstrapStep -Step 'Write docker daemon.json data-root' -WarnOnError -Action {
    if (-not $script:dockerDataVol) {
        throw 'Docker data volume unavailable; cannot ensure daemon.json data-root.'
    }
    if (Test-Path 'C:\ProgramData\docker\config\daemon.json') {
        Write-Host 'daemon.json already exists; preserving existing config.'
        return
    }
    New-Item -ItemType Directory -Path 'P:\docker-data' -Force | Out-Null
    $daemonConfig = @{ 'data-root' = 'P:\docker-data' }
    New-Item -ItemType Directory -Path 'C:\ProgramData\docker\config' -Force | Out-Null
    $daemonConfig | ConvertTo-Json | Out-File 'C:\ProgramData\docker\config\daemon.json' -Encoding utf8 -Force
}

$containerFeature = Get-WindowsFeature -Name Containers -ErrorAction SilentlyContinue
if ($containerFeature.InstallState -ne 'Installed') {
    $runOnceOk = Invoke-BootstrapStep -Step 'Register bootstrap RunOnce continuation' -Action {
        New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'BootstrapContinue' -PropertyType String -Value 'powershell -ExecutionPolicy Bypass -File "C:\Setup\bootstrap.ps1"' -Force -ErrorAction Stop | Out-Null
    }
    if (-not $runOnceOk) {
        Finish-BootstrapFailure -Step 'Register bootstrap RunOnce continuation' -Message 'Cannot continue without RunOnce registration.'
    }
    Write-BootstrapPass -Step 'Install Containers feature' -Message 'Installing and rebooting to continue bootstrap.'
    Write-BootstrapStatus -Step 'Install Containers feature' -State 'rebooting'
    Write-Host "Bootstrap rebooting with $($script:bootstrapWarnings) warnings, $($script:bootstrapFailures) failures."
    Stop-Transcript | Out-Null
    Install-WindowsFeature -Name Containers -IncludeAllSubFeature -IncludeManagementTools -Restart
    exit
}
Write-BootstrapPass -Step 'Install Containers feature' -Message 'Already installed.'

$dockerEngineOk = Invoke-BootstrapStep -Step 'Install Docker Engine' -Action {
    if (Get-Service docker -ErrorAction SilentlyContinue) {
        Write-Host 'Docker service already installed; skipping installation.'
        return
    }
    $release = Invoke-RestMethod 'https://api.github.com/repos/moby/moby/releases/latest' -UseBasicParsing
    $dockerVersion = [regex]::Match($release.tag_name, '\d+\.\d+\.\d+').Value
    if (-not $dockerVersion) { throw 'Could not resolve Docker version from moby release tag.' }
    Write-Host "Docker version: $dockerVersion"
    $zipUrl = "https://download.docker.com/win/static/stable/x86_64/docker-$dockerVersion.zip"
    Invoke-WebRequest -UseBasicParsing -Uri $zipUrl -OutFile 'C:\Setup\docker.zip'
    Expand-Archive -Path 'C:\Setup\docker.zip' -DestinationPath 'C:\Program Files' -Force
    $env:Path = "$env:Path;C:\Program Files\Docker"
    [Environment]::SetEnvironmentVariable('Path', "$([Environment]::GetEnvironmentVariable('Path','Machine'));C:\Program Files\Docker", 'Machine')
    dockerd --register-service
    sc.exe config docker start= delayed-auto | Out-Null
    sc.exe failure docker reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
    Start-Service docker -ErrorAction Stop
}
if (-not $dockerEngineOk) {
    Finish-BootstrapFailure -Step 'Install Docker Engine' -Message 'Cannot continue without Docker Engine.'
}

$null = Invoke-BootstrapStep -Step 'Install Docker Compose plugin' -WarnOnError -Action {
    $composePluginPath = 'C:\Program Files\Docker\cli-plugins\docker-compose.exe'
    if (Test-Path $composePluginPath) {
        Write-Host 'Docker Compose plugin already installed; skipping.'
        return
    }
    $composeRelease = Invoke-RestMethod 'https://api.github.com/repos/docker/compose/releases/latest' -UseBasicParsing
    $composeAsset = @($composeRelease.assets | Where-Object { $_.name -eq 'docker-compose-windows-x86_64.exe' }) | Select-Object -First 1
    if (-not $composeAsset) { throw 'Could not find docker-compose-windows-x86_64.exe in latest docker/compose release.' }
    New-Item -ItemType Directory -Path 'C:\Program Files\Docker\cli-plugins' -Force | Out-Null
    Invoke-WebRequest -UseBasicParsing -Uri $composeAsset.browser_download_url -OutFile $composePluginPath
}

$null = Invoke-BootstrapStep -Step 'Install Git' -WarnOnError -Action {
    $gitRelease = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest' -UseBasicParsing
    $gitAsset = @($gitRelease.assets | Where-Object { $_.name -match '^Git-[\d.]+-64-bit\.exe$' }) | Select-Object -First 1
    if (-not $gitAsset) { throw 'Could not find Git x64 installer in release assets.' }
    Write-Host "Downloading Git $($gitRelease.tag_name)..."
    $gitInstaller = 'C:\Setup\git-installer.exe'
    Invoke-WebRequest -UseBasicParsing -Uri $gitAsset.browser_download_url -OutFile $gitInstaller
    $r = Start-Process -FilePath $gitInstaller -ArgumentList '/VERYSILENT /NORESTART /SP- /COMPONENTS="assoc,assoc_sh"' -Wait -PassThru
    if ($r.ExitCode -ne 0) { throw "Git installer exited with code $($r.ExitCode)." }
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + $env:PATH
}

$null = Invoke-BootstrapStep -Step 'Install GitHub CLI' -WarnOnError -Action {
    $ghRelease = Invoke-RestMethod 'https://api.github.com/repos/cli/cli/releases/latest' -UseBasicParsing
    $ghAsset = @($ghRelease.assets | Where-Object { $_.name -match '^gh_[\d.]+_windows_amd64\.msi$' }) | Select-Object -First 1
    if (-not $ghAsset) { throw 'Could not find gh CLI MSI in release assets.' }
    Write-Host "Downloading gh $($ghRelease.tag_name)..."
    $ghMsi = 'C:\Setup\gh-cli.msi'
    Invoke-WebRequest -UseBasicParsing -Uri $ghAsset.browser_download_url -OutFile $ghMsi
    $r = Start-Process msiexec -ArgumentList "/i `"$ghMsi`" /qn /norestart" -Wait -PassThru
    if ($r.ExitCode -ne 0) { throw "gh CLI MSI installer exited with code $($r.ExitCode)." }
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + $env:PATH
}

$null = Invoke-BootstrapStep -Step 'Install gh copilot extension' -WarnOnError -Action {
    $ghExe = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $ghExe) { throw 'gh CLI not found; cannot install copilot extension.' }
    & gh extension install github/gh-copilot --force 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "gh extension install failed (exit $LASTEXITCODE)." }
}

__DISM_CONVERSION_BLOCK__
Write-BootstrapStatus -Step 'finalize' -State 'complete'
Write-Host "Bootstrap complete: $($script:bootstrapWarnings) warnings, $($script:bootstrapFailures) failures."
Write-Host "Bootstrap finished: $(Get-Date)"
Stop-Transcript | Out-Null

