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
- **Fully automated provisioning** — OS install via `Autounattend.xml`, Docker Engine from static binaries, no Mirantis license required
- **Persistent Docker storage** — each VM gets a dedicated VHDX (`P:\docker-data`) that survives `destroy`
- **Shared storage** — attach a single VHDX to multiple VMs simultaneously
- **Named persistent volumes** — per-VM app data VHDXes with a `pv-<name>` convention
- **`docker` / `docker-compose` pass-through** — run any docker command inside a VM without quoting tricks
- **Web dashboard** — live VM table with start/stop/restart buttons at `http://localhost:8080`
- **Prometheus metrics** — per-VM CPU, memory, Docker state, container counts, storage sizes on `:9090/metrics`
- **PowerShell Direct** — `exec`, `ps`, `ssh`, `cp`, `logs`, `health` with no SSH keys required

> **Note:** Most VM-interaction commands require running as **Administrator** (Hyper-V API requires it). The CLI will tell you if you need to elevate.



# Example `vmstack.yaml`

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

## Run a docker command inside a VM
```
./vm-compose.ps1 docker winhost1 ps
./vm-compose.ps1 docker winhost1 images
./vm-compose.ps1 docker winhost1 run --rm mcr.microsoft.com/windows/nanoserver:ltsc2022 cmd /c echo hello
```

`docker-compose` is an alias for the same pass-through:
```
./vm-compose.ps1 docker-compose winhost1 ps
```

Passes all arguments directly to `docker` inside the VM via PowerShell Direct.

> **Tip:** args that match PowerShell parameter names (e.g. `-Force`) should be quoted: `'-Force'`

## Run a hello-world container test
```
./vm-compose.ps1 docker-test winhost1
```

Pulls and runs a nanoserver container, auto-detecting the correct image tag (ltsc2022/ltsc2025). Starts the Docker service if it's stopped.

## Fetch a specific log from a VM
```
./vm-compose.ps1 getlog winhost1              # list available logs
./vm-compose.ps1 getlog bootstrap winhost1    # fetch bootstrap log
./vm-compose.ps1 getlog docker winhost1       # fetch docker install log
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

## Print only the VM's IP address
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
./vm-compose.ps1 note show winhost1    # print notes
./vm-compose.ps1 note add winhost1     # append text
./vm-compose.ps1 note edit winhost1    # open in Notepad
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

## Docker Persistent Volumes (auto)

Each VM automatically gets a dedicated VHDX for Docker data (mounted as `P:` inside the VM, configured as Docker's `data-root`). Sized via `persistent_disk_gb` in vmstack.yaml. No configuration needed — created and attached during `up`.

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
./vm-compose.ps1 mount winhost1 shareddata           # hot-add to a running VM
./vm-compose.ps1 unmount winhost1 shareddata         # remove from a running VM
```

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
- Storage table: all shared volumes and persistent volumes with mount/detach actions
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
