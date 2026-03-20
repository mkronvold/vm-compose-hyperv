# Quickstart

Get from zero to a running Windows Server VM with Docker in a few steps.

---

## Requirements

| Requirement | Notes |
|-------------|-------|
| **Windows host** | Windows 10/11 Pro/Enterprise or Windows Server 2019+ |
| **Hyper-V enabled** | `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All` |
| **PowerShell 7+** | [Download](https://github.com/PowerShell/PowerShell/releases) — required for `ConvertFrom-Yaml` |
| **Run as Administrator** | Most commands require Hyper-V API access |
| **Windows Server ISO** | Server 2022 or 2025 recommended — [Evaluation Center](https://www.microsoft.com/en-us/evalcenter/) |
| **Pode module** | Auto-installed by `vm-dashboard.ps1` on first run |

---

## Install

**1. Clone the repo**

```powershell
git clone https://github.com/mkronvold/vm-compose-hyperv.git
cd vm-compose-hyperv
```

**2. Copy the example config**

```powershell
Copy-Item vmstack-example.yaml vmstack.yaml
```

**3. Edit `vmstack.yaml`**

At minimum, set the `iso:` path for each VM to your Windows Server ISO:

```yaml
vms:
  myvm:
    iso: "D:/ISO/WindowsServer2022.iso"
    memory_gb: 4
    cpus: 2
    os_disk_gb: 60
    persistent_disk_gb: 30
    network: natnet
```

Run `./vm-compose.ps1 validate` to check for errors before proceeding.

---

## First Boot

```powershell
# Preview what will be created
./vm-compose.ps1 up -DryRun

# Build and start all VMs
./vm-compose.ps1 up
```

This will:
1. Create a NAT network switch (if missing)
2. Create the OS VHDX and persistent VHDX
3. Generate `Autounattend.xml` and `bootstrap.ps1`
4. Create and start the VM
5. Windows Server installs unattended (~5–15 min depending on hardware)
6. Bootstrap runs: installs the Containers feature, reboots, then installs Docker Engine

The first boot takes **15–30 minutes** total. Track progress with:

```powershell
# Watch the VM state
./vm-compose.ps1 status

# Full health check (shows bootstrap completion timestamp when done)
./vm-compose.ps1 health myvm
```

---

## Sanity Tests

Once `health` shows **Bootstrap complete**, run these quick checks:

```powershell
# 1. Confirm VM is running and has an IP
./vm-compose.ps1 status

# 2. Full health check — Docker Engine version, volumes, bootstrap time
./vm-compose.ps1 health myvm

# 3. Run a hello-world Windows container
./vm-compose.ps1 docker-test myvm

# 4. Confirm docker ps works
./vm-compose.ps1 docker myvm ps

# 5. Check Docker images
./vm-compose.ps1 docker myvm images

# 6. Open a shell and poke around
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

## Install the Web Dashboard (Optional)

The dashboard provides a browser UI at `http://localhost:8080`.

```powershell
# Install as a Windows service (persists across reboots)
./vm-dashboard-install.ps1

# Check status
./vm-compose.ps1 web
```

Open http://localhost:8080 in your browser.

---

## Install the Metrics Exporter (Optional)

Exposes Prometheus metrics at `http://localhost:9090/metrics`.

```powershell
./vm-metrics-install.ps1

# Check status
./vm-compose.ps1 metrics
```

---

## Common First-Run Issues

**VM stuck at "Not Created" after `up`**
- Run as Administrator: `./vm-compose.ps1 up`
- Check Hyper-V is enabled: `Get-WindowsFeature Hyper-V`

**Bootstrap never completes**
- Check the bootstrap log: `./vm-compose.ps1 getlog bootstrap myvm`
- Ensure the VM has internet access (needed to download Docker Engine)
- Confirm the ISO path in `vmstack.yaml` is correct

**`health` shows Docker Engine NOT RUNNING**
- The Docker service may still be starting: wait 30s and retry
- Check the Docker install log: `./vm-compose.ps1 getlog docker myvm`

**Commands fail with "not recognized as Administrator"**
- Re-run your PowerShell terminal as Administrator
- Or prefix: `Start-Process pwsh -Verb RunAs`

---

## Next Steps

- See [EXAMPLES.md](EXAMPLES.md) for a full command reference with examples
- See [README.md](README.md) for detailed documentation
- See [REPO.md](REPO.md) for file layout and `.gitignore` reference
