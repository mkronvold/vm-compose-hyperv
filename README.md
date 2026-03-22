# Hyper‑V Compose

Run **Windows containers** on your Windows 11 machine — using the same familiar `docker` and `docker-compose` commands you already know — without hand-building Windows Server VMs.

**The problem:** Windows 10/11 cannot run real Windows containers. Docker Desktop on Windows 11 requires Hyper‑V isolation, which breaks CPU/memory limits and is unreliable for production workloads. Windows Server runs Windows containers natively, honors resource limits correctly, and is the platform containers are designed for.

**The solution:** Hyper‑V Compose spins up fully-configured Windows Server VMs on your Hyper‑V host with a single command. Docker Engine installs automatically. You get a clean `docker`-like CLI — `up`, `down`, `restart`, `health`, `exec`, `docker` pass-through — without ever opening Hyper‑V Manager or editing an XML file.

```
./vm-compose.ps1 up
./vm-compose.ps1 docker solr run --rm mcr.microsoft.com/windows/nanoserver:ltsc2022 cmd /c echo hello
./vm-compose.ps1 health
```

### Key features

- **Declarative YAML config** (`vmstack.yaml`) — define VMs, networks, and storage like Docker Compose
- **Fully automated provisioning** — OS install via `Autounattend.xml`, Docker Engine from static binaries, Docker Compose plugin (`docker compose`), no Mirantis license required
- **Optional persistent Docker storage** — set `persistent_disk_gb` to give a VM a dedicated VHDX (`P:\docker-data`) that survives `destroy`
- **Shared storage** — attach a single VHDX to multiple VMs simultaneously
- **Named persistent volumes** — per-VM app data VHDXes with a `pv-<name>` convention
- **`docker` / `docker-compose` pass-through** — run any docker command inside a VM without quoting tricks
- **Web dashboard** — live VM table with start/stop/restart buttons at `http://localhost:8080`
- **Prometheus metrics** — per-VM CPU, memory, Docker state, container counts, storage sizes on `:9090/metrics`
- **PowerShell Direct** — `exec`, `ps`, `ssh`, `cp`, `eventlog`, `health` with no SSH keys required

> **Note:** Most VM-interaction commands require running as **Administrator** (Hyper-V API requires it). The CLI will tell you if you need to elevate.



# Example `vmstack.yaml`

```yaml
version: "1"

networks:
  natnet:
    switch_name: "Default Switch"   # built-in NAT/DHCP on Windows 10/11/Server

storage:
  # Shared VHDX — can be mounted in multiple VMs simultaneously
  shareddata:
    path: "storage/shareddata.vhdx"
    size_gb: 100

  # Named persistent volumes — per-VM application data (pv-<vmname> convention)
  # Auto-created on `up`; labeled "named-pv" in `storage shared ls`
  pv-winhost1:
    path: "storage/pv-winhost1.vhdx"
    size_gb: 50
  pv-winhost2:
    path: "storage/pv-winhost2.vhdx"
    size_gb: 30

vms:
  winhost1:
    iso: "C:/ISOs/WindowsServer2022.iso"
    memory_gb: 8
    cpus: 4
    os_disk_gb: 80
    persistent_disk_gb: 50   # optional legacy Docker PV → P:\docker-data inside VM
    network: natnet
    mount:
      - shareddata
      - pv-winhost1

  winhost2:
    iso: "C:/ISOs/WindowsServer2022.iso"
    memory_gb: 4
    cpus: 2
    os_disk_gb: 60
    # persistent_disk_gb: 30  # optional
    network: natnet
    mount:
      - shareddata
      - pv-winhost2
```

---

# Usage

Commands follow a **noun-verb** ordering: `./vm-compose.ps1 <vm> <command>`.  
VM-targeting commands accept both orderings for backward compatibility:

```
./vm-compose.ps1 solr restart         # preferred: noun-verb
./vm-compose.ps1 restart solr         # also works (legacy verb-noun)
./vm-compose.ps1 restart -Vm solr     # explicit -Vm flag (most portable in scripts)
```

Commands with no VM target (acting on all VMs or the service layer) are unchanged:
```
./vm-compose.ps1 up
./vm-compose.ps1 down
./vm-compose.ps1 health
./vm-compose.ps1 web restart
./vm-compose.ps1 metrics
```

---

# Commands

## Start / build all VMs
```
./vm-compose.ps1 up
```

Creates:

- OS VHDX  
- Optional persistent Docker VHDX (`persistent_disk_gb` > 0)  
- Autounattend.xml  
- bootstrap.ps1 (rendered from `unattends/bootstrap.template.ps1`)  
- VM with attached disks  
- Automated Windows Server install  
- Automated Docker install  (Docker Engine static binaries — no Mirantis license required)
- Auto‑created networks (if missing)  

## Stop all VMs
```
./vm-compose.ps1 down
```

## Restart all VMs
```
./vm-compose.ps1 restart
```

## Restart a single VM
```
./vm-compose.ps1 solr restart
```

## Destroy VMs (persistent disks preserved when present)
```
./vm-compose.ps1 destroy
```

Deletes VM definitions but **keeps**:

```
persistent-storage.vhdx
```

So Docker images, containers, and volumes survive (for VMs where `persistent_disk_gb` is enabled).

---

# Dry Run Mode

Add `-DryRun` to any mutating command to preview what would happen without making changes:

```
./vm-compose.ps1 up -DryRun
./vm-compose.ps1 destroy -DryRun
```

---

# Validate

Lint your `vmstack.yaml` before running:

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
./vm-compose.ps1 winhost1 inspect
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

## View Windows event log from a VM
```
./vm-compose.ps1 winhost1 eventlog
```

## Execute a command inside a VM
```
./vm-compose.ps1 winhost1 exec "ipconfig"
```

## Run a docker command inside a VM
```
./vm-compose.ps1 winhost1 docker ps
./vm-compose.ps1 winhost1 docker images
./vm-compose.ps1 winhost1 docker run --rm mcr.microsoft.com/windows/nanoserver:ltsc2022 cmd /c echo hello
```

`docker-compose` runs `docker compose` inside the VM:
```
./vm-compose.ps1 winhost1 docker-compose ps
./vm-compose.ps1 winhost1 docker-compose --project-directory P:\myapp -f P:\myapp\docker-compose.yml build
```

With a project shortcut defined in `vmstack.yaml` under `projects:`:
```
./vm-compose.ps1 winhost1 docker-compose -Project myapp build
./vm-compose.ps1 docker-compose -Project myapp build   # VM derived from project definition
```

## Run a hello-world container test
```
./vm-compose.ps1 winhost1 docker-test
```

Pulls and runs a nanoserver container, auto-detecting the correct image tag (ltsc2022/ltsc2025). Starts the Docker service if it's stopped.

## Fetch a specific log from a VM
```
./vm-compose.ps1 winhost1 getlog              # list available logs
./vm-compose.ps1 winhost1 getlog bootstrap    # fetch bootstrap log
./vm-compose.ps1 winhost1 getlog docker       # fetch docker event log
./vm-compose.ps1 winhost1 bootlogs            # bootstrap summary + latest 200 lines
./vm-compose.ps1 winhost1 bootlogs 500        # same, custom tail size
```

---

# PowerShell Direct Tools

## Process list inside a VM
```
./vm-compose.ps1 winhost1 ps
```

## Open an interactive shell inside a VM
```
./vm-compose.ps1 winhost1 ssh
```

## Print only the VM's IP address
```
./vm-compose.ps1 winhost1 ip
```

## Live CPU/memory usage
```
./vm-compose.ps1 winhost1 top
```

## Cluster-wide health check
```
./vm-compose.ps1 health
```

Checks:

- VM state  
- IP assignment  
- Docker readiness (only after bootstrap completes)  
- Bootstrap progress with warning/failure counters  
- Docker version  

---

# File Copy

Copy files between the host and a running VM:

```
./vm-compose.ps1 cp C:\local\file.txt winhost1:C:\dest\
./vm-compose.ps1 cp winhost1:C:\path\file.txt .
```

Prefix VM paths with `vmname:` (colon). VM-to-host copy prompts for Administrator credentials inside the VM.

---

# VM Notes

Attach freeform notes to any VM:

```
./vm-compose.ps1 winhost1 note show    # print notes
./vm-compose.ps1 winhost1 note add     # append text
./vm-compose.ps1 winhost1 note edit    # open in Notepad
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

Hyper‑V Compose supports three types of storage.

## Docker Persistent Volumes (optional legacy)

If `persistent_disk_gb` is set to a value greater than 0, the VM gets a dedicated legacy VHDX for Docker data (mounted as `P:` inside the VM and configured as Docker's `data-root`). If omitted, the VM is built without this legacy disk.

```
./vm-compose.ps1 storage pv ls [vm]                  # list all Docker PVs
./vm-compose.ps1 storage pv create <vm>              # create VHDX
./vm-compose.ps1 storage pv destroy <vm>             # delete VHDX
./vm-compose.ps1 storage pv localmount <vm> [P]      # mount on host
./vm-compose.ps1 storage pv localunmount <vm>        # dismount from host
./vm-compose.ps1 storage pv health [vm]              # health check
```

## Named Persistent Volumes (per-VM data)

For application data that belongs to a single VM, define named volumes in the `storage:` section using the `pv-<vmname>` naming convention, then reference them in `mount:`:

```yaml
storage:
  pv-solr:
    path: "storage/pv-solr.vhdx"
    size_gb: 100
  pv-nnta:
    path: "storage/pv-nnta.vhdx"
    size_gb: 50

vms:
  solr:
    mount:
      - pv-solr
  nnta:
    mount:
      - pv-nnta
```

VHDXes are **auto-created** during `up`. The `pv-` prefix causes them to be labeled **named-pv** (vs **shared**) in `storage shared ls`.

### Named PV commands

```
./vm-compose.ps1 storage shared ls                   # lists named-pv entries alongside shared
./vm-compose.ps1 storage shared localmount pv-solr   # mount on host (default S:)
./vm-compose.ps1 storage shared localunmount pv-solr # dismount from host
./vm-compose.ps1 storage shared health pv-solr       # health check
```

## Shared Storage

Shared VHDXes can be attached to **multiple VMs simultaneously**:

```yaml
storage:
  shareddata:
    path: "storage/shareddata.vhdx"
    size_gb: 100

vms:
  winhost1:
    mount:
      - shareddata
  winhost2:
    mount:
      - shareddata
```

### Shared storage commands

```
./vm-compose.ps1 storage shared ls                   # list all volumes (shared + named-pv)
./vm-compose.ps1 storage shared localmount <name>    # mount on host (default S:)
./vm-compose.ps1 storage shared localunmount <name>  # dismount from host
./vm-compose.ps1 storage shared health [name]        # health check
./vm-compose.ps1 winhost1 mount shareddata           # hot-add to a running VM
./vm-compose.ps1 winhost1 unmount shareddata         # remove from a running VM
```

---

# Docker Compose Projects

Define docker compose projects in `vmstack.yaml` to avoid repeating `--project-directory` and `-f` on every command:

```yaml
projects:
  myapp:
    project_vm: winhost1           # which VM hosts this project
    project_folder: P:\myapp-docker  # full path (or relative → resolved from P:\)
    project_type: docker-compose   # docker-compose (default) or docker
```

Then use the `-Project` flag:

```
./vm-compose.ps1 winhost1 docker-compose -Project myapp build
./vm-compose.ps1 winhost1 docker-compose -Project myapp up -d
./vm-compose.ps1 docker-compose -Project myapp ps   # VM from project definition
```

The `-Project` flag expands to `--project-directory <folder> -f <folder>\docker-compose.yml` automatically.

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
- Live VM table with auto-refresh (every 10s): state, CPU, memory, IP, uptime, **Docker status**
- Per-VM detail page with Docker status: disks, adapters, checkpoints
- Start / Stop / Restart buttons
- Storage table: all shared volumes and persistent volumes with mount/detach actions
- **PV-aware Docker lifecycle**: detaching a persistent volume (P:) automatically stops Docker first; re-attaching starts it again
- JSON API: `GET /api/vms`, `GET /api/vms/:name`

---

# Requirements

- Windows 11 with Hyper-V enabled  
- PowerShell 7+  
- Windows Server ISO (2022 or 2025 recommended)  
- [Pode](https://github.com/Badgerati/Pode) module (auto-installed by `vm-dashboard.ps1`)  
- No Docker license required — uses open-source Docker Engine static binaries  

---

# License

MIT
