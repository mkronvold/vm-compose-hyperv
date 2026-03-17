# Hyper‑V Compose

Hyper‑V Compose is a **docker‑compose‑like orchestrator** for building and managing Windows Server VMs on Hyper‑V using a declarative YAML file (`vmstack.yml`).

It gives you a clean, predictable workflow:

```
./vm-compose.ps1 up [-DryRun]
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
```

Each VM is fully automated:

- Windows Server installs via `Autounattend.xml`
- Mirantis Container Runtime installs automatically
- Docker is configured to use a **persistent VHDX**
- Networks are auto‑created if missing
- Shared storage disks can be attached to multiple VMs
- PowerShell Direct provides logs, exec, ps, ssh, and health checks

---

# Example `vmstack.yml`

```yaml
version: "1"

networks:
  internal:
    type: internal
    switch_name: "hv-int"

  external:
    type: external
    switch_name: "Default Switch"

  natnet:
    type: nat
    switch_name: "hv-nat"
    subnet: "192.168.200.0/24"
    gateway: "192.168.200.1"

storage:
  shareddata:
    path: "storage/shareddata.vhdx"
    size_gb: 100

vms:
  winhost1:
    iso: "D:/ISO/WindowsServer2022.iso"
    memory_gb: 8
    cpus: 4
    os_disk_gb: 80
    persistent_disk_gb: 50
    network: natnet
    attach:
      - shareddata

  winhost2:
    iso: "D:/ISO/WindowsServer2025.iso"
    memory_gb: 4
    cpus: 2
    os_disk_gb: 60
    persistent_disk_gb: 30
    network: internal
```

---

# Commands

## Start / build all VMs
```
./vm-compose.ps1 up
```

Creates:

- OS VHDX  
- Persistent Docker VHDX  
- Autounattend.xml  
- bootstrap.ps1  
- VM with attached disks  
- Automated Windows Server install  
- Automated Docker install  
- Auto‑created networks (if missing)  

## Stop all VMs
```
./vm-compose.ps1 down
```

## Restart all VMs
```
./vm-compose.ps1 restart
```

## Destroy VMs (persistent disks preserved)
```
./vm-compose.ps1 destroy
```

Deletes VM definitions but **keeps**:

```
persistent-storage.vhdx
```

So Docker images, containers, and volumes survive.

---

# Dry Run Mode

Add `-DryRun` to any mutating command to preview what would happen without making changes:

```
./vm-compose.ps1 up -DryRun
./vm-compose.ps1 destroy -DryRun
```

---

# Validate

Lint your `vmstack.yml` before running:

```
./vm-compose.ps1 validate
```

Checks required fields, network references, storage references, and NAT subnet config.

---

# Version

```
./vm-compose.ps1 version
```

---

# Inspection & Monitoring

## Show cluster status
```
./vm-compose.ps1 status
```

Displays:

- VM state  
- CPU count  
- Assigned memory  
- IP address  
- Uptime  

## Inspect a single VM
```
./vm-compose.ps1 inspect winhost1
```

Shows:

- CPU, memory, uptime  
- All IP addresses  
- All attached disks  
- Virtual switches  
- Checkpoints  
- Generation  
- Notes  

---

# Logs & Execution

## View logs from a VM
```
./vm-compose.ps1 logs winhost1
```

## Execute a command inside a VM
```
./vm-compose.ps1 exec winhost1 "ipconfig"
```

---

# PowerShell Direct Tools

## Process list inside a VM
```
./vm-compose.ps1 ps winhost1
```

## Open an interactive shell inside a VM
```
./vm-compose.ps1 ssh winhost1
```

## Print only the VM’s IP address
```
./vm-compose.ps1 ip winhost1
```

## Live CPU/memory usage
```
./vm-compose.ps1 top winhost1
```

## Cluster-wide health check
```
./vm-compose.ps1 health
```

Checks:

- VM state  
- IP assignment  
- Docker responsiveness  
- Docker version  

---

# Storage

Hyper‑V Compose supports shared disks and named volumes via a `storage:` section.

### Example

```yaml
storage:
  shareddata:
    path: "storage/shareddata.vhdx"
    size_gb: 100
```

Mount storage on VMs via the `mount:` key:

```yaml
vms:
  winhost1:
    mount:
      - shareddata
```

Shared VHDXes are **auto-created** during `up` if they don't exist.

### Runtime mount / unmount

Hot-add or remove a storage disk from a running VM:

```
./vm-compose.ps1 mount winhost1 shareddata
./vm-compose.ps1 unmount winhost1 shareddata
```

---

# Networks

Hyper‑V Compose supports a `networks:` section similar to Docker Compose.

### Supported network types

| Type      | Description |
|-----------|-------------|
| internal  | VM‑only network, no host access |
| external  | Bridge to host NIC (internet access) |
| nat       | NAT network with custom subnet + gateway |

### Example

```yaml
networks:
  natnet:
    type: nat
    switch_name: "hv-nat"
    subnet: "192.168.200.0/24"
    gateway: "192.168.200.1"
```

Networks are **auto‑created** if they do not exist.

Assign a VM to a network:

```yaml
vms:
  winhost1:
    network: natnet
```

---

# Storage

Hyper-V Compose supports shared disks and named volumes via a `storage:` section.

### Example

```yaml
storage:
  shareddata:
    path: "storage/shareddata.vhdx"
    size_gb: 100
```

Mount storage on VMs via the `mount:` key:

```yaml
vms:
  winhost1:
    mount:
      - shareddata
```

This mirrors Docker Compose's `volumes:` section and supports:

- shared datasets  
- cluster state  
- SQL Server data disks  
- Windows container registries  

---

# Persistent Docker Storage

Each VM gets a dedicated persistent VHDX:

```
persistent-storage.vhdx
```

This contains:

- Docker images  
- Docker containers  
- Docker volumes  

You can delete and recreate VMs without losing container data.

---

# Prometheus Metrics

A standalone metrics exporter (`vm-metrics.ps1`) exposes per-VM metrics on `:9090/metrics`.

```
./vm-compose.ps1 metrics       # Show service status
```

**Install as a Windows service (run as Administrator):**

```
./vm-metrics-install.ps1
./vm-metrics-uninstall.ps1
```

**Metrics exported:**

| Metric | Description |
|--------|-------------|
| `hyperv_vm_state` | 1 = Running, 0 = other |
| `hyperv_vm_cpu_usage_percent` | CPU usage % |
| `hyperv_vm_memory_assigned_bytes` | Assigned memory |
| `hyperv_vm_uptime_seconds` | Uptime |
| `hyperv_vm_ip_assigned` | 1 = has IPv4 |
| `hyperv_vm_docker_running` | 1 = Docker service running |

---

# Web Dashboard

A [Pode](https://badgerati.github.io/Pode/)-based web dashboard at `http://localhost:8080`.

```
./vm-compose.ps1 web           # Show service status / URL
./vm-dashboard.ps1             # Run directly
```

**Install as a Windows service (run as Administrator):**

```
./vm-dashboard-install.ps1
./vm-dashboard-uninstall.ps1
```

Features:
- Live VM table with auto-refresh (every 10s)
- Per-VM detail page (disks, adapters, checkpoints)
- Start / Stop / Restart buttons
- JSON API: `GET /api/vms`, `GET /api/vms/:name`

---

# Requirements

- Windows 11 with Hyper-V enabled  
- PowerShell 7+  
- Windows Server ISO (2022 or 2025 recommended)  
- [Pode](https://github.com/Badgerati/Pode) module (auto-installed by `vm-dashboard.ps1`)  

---

# Why this exists

Windows 10/11 cannot run real Windows containers.  
Windows Server can.  
This system gives you:

- reproducible VM builds  
- persistent container storage  
- a compose-like workflow  
- fully automated provisioning  
- disposable compute, durable storage  

---

# License

MIT