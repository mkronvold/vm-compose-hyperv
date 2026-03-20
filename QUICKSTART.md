# Quickstart

Get from zero to a running Windows Server VM with Docker in a few steps.

> These scripts run **on the Hyper-V host machine** — the Windows machine that will host the VMs, not inside a VM.

---

## Requirements

| Requirement | Notes |
|-------------|-------|
| **Hyper-V host** | Windows 10/11 Pro/Enterprise or Windows Server 2019+ with Hyper-V enabled |
| **Hyper-V enabled** | `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All` |
| **PowerShell 7+** | [Download](https://github.com/PowerShell/PowerShell/releases) — required for `ConvertFrom-Yaml` |
| **Run as Administrator** | Hyper-V API requires admin rights for most commands |
| **Windows Server ISO** | Server 2022 or 2025 recommended — [Evaluation Center](https://www.microsoft.com/en-us/evalcenter/) |
| **Internet access** | Bootstrap downloads Docker Engine from `download.docker.com` during first boot |
| **Pode module** | Auto-installed by `vm-dashboard.ps1` on first run (dashboard only) |

---

## Setup

**1. Clone the repo onto your Hyper-V host**

```powershell
git clone https://github.com/mkronvold/vm-compose-hyperv.git
cd vm-compose-hyperv
```

**2. Copy the example config**

```powershell
Copy-Item vmstack-example.yaml vmstack.yaml
```

**3. Edit `vmstack.yaml`**

At minimum, point `iso:` at your Windows Server ISO and set `network:` to an existing Hyper-V switch name:

```yaml
networks:
  natnet:
    switch_name: "Default Switch"   # use an existing Hyper-V switch name

vms:
  myvm:
    iso: "D:/ISO/WindowsServer2022.iso"
    memory_gb: 4
    cpus: 2
    os_disk_gb: 60
    persistent_disk_gb: 30
    network: natnet
```

**4. Validate the config**

```powershell
./vm-compose.ps1 validate
```

---

## First Boot

```powershell
# Preview what will be created (no changes made)
./vm-compose.ps1 up -DryRun

# Build and start all VMs (run as Administrator)
./vm-compose.ps1 up
```

What happens:
1. Resolves the Hyper-V switch for each VM's `network:`
2. Creates the OS VHDX and persistent VHDX (`P:` drive inside the VM)
3. Creates any named storage volumes defined in `storage:`
4. Generates `Autounattend.xml` and `bootstrap.ps1`
5. Creates and starts the VM — Windows Server installs unattended (~5–15 min)
6. Bootstrap runs on first login: installs Containers feature, reboots, installs Docker Engine

The full first-boot cycle takes **15–30 minutes**. Track progress:

```powershell
# Poll VM state
./vm-compose.ps1 status

# Full health check — shows bootstrap completion timestamp when done
./vm-compose.ps1 health myvm
```

---

## Sanity Tests

Once `health` shows **Bootstrap complete**, run these checks:

```powershell
# 1. Confirm VM is running with an IP
./vm-compose.ps1 status

# 2. Full health — Docker Engine version, volumes, bootstrap timestamp
./vm-compose.ps1 health myvm

# 3. Run a Windows container hello-world (auto-detects ltsc2022/ltsc2025)
./vm-compose.ps1 docker-test myvm

# 4. Confirm docker commands work
./vm-compose.ps1 docker myvm ps
./vm-compose.ps1 docker myvm images

# 5. Open an interactive shell
./vm-compose.ps1 ssh myvm
```

Expected `health` output:

```
=== VM Health Check ===

VM: myvm
  State : Running
  IP    : 172.x.x.x
  [+] Containers feature     Installed
  [+] Docker Engine          v29.x.x
  [+] DockerData volume      P: (xx GB free)
  [+] daemon.json            data-root=P:\docker-data
  Bootstrap: Bootstrap complete: MM/DD/YYYY HH:MM:SS
```

---

## Optional: Web Dashboard

Browser UI at `http://localhost:8080` — shows VM status, storage table, and mount/detach actions.

```powershell
# Install as a Windows service (auto-starts on reboot)
./vm-dashboard-install.ps1

# Check service status / URL
./vm-compose.ps1 web
```

---

## Optional: Prometheus Metrics

Exposes per-VM metrics at `http://localhost:9090/metrics` for Grafana or any Prometheus-compatible scraper.

```powershell
./vm-metrics-install.ps1

# Check service status
./vm-compose.ps1 metrics
```

---

## Common First-Run Issues

**VM stuck at "Not Created" after `up`**
- Ensure you are running as Administrator
- Check Hyper-V is enabled: `Get-WindowsFeature Hyper-V` (Server) or check in "Turn Windows features on or off"

**Bootstrap never completes**
- Check the bootstrap log: `./vm-compose.ps1 getlog bootstrap myvm`
- Ensure the VM has internet access — Docker Engine is downloaded during bootstrap
- Confirm the ISO path in `vmstack.yaml` is correct

**`health` shows Docker Engine NOT RUNNING**
- Docker service may still be starting — wait 30s and retry
- Check the Docker install log: `./vm-compose.ps1 getlog docker myvm`

**Commands fail with "requires Administrator privileges"**
- Re-open PowerShell as Administrator: `Start-Process pwsh -Verb RunAs`

---

## Next Steps

| Doc | Purpose |
|-----|---------|
| [EXAMPLES.md](EXAMPLES.md) | Full command reference with real-world examples |
| [README.md](README.md) | Detailed feature documentation |
| [REPO.md](REPO.md) | File layout and `.gitignore` reference |
