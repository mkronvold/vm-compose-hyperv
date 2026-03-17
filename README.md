# Hyper‑V Compose

Hyper‑V Compose is a **docker‑compose‑like orchestrator** for building and managing Windows Server VMs on Hyper‑V using a declarative YAML file (`vmstack.yml`).

It gives you a clean, predictable workflow:

```
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

Hyper‑V Compose supports shared disks and named volumes via a `storage:` section.

### Example

```yaml
storage:
  shareddata:
    path: "storage/shareddata.vhdx"
    size_gb: 100
```

Attach storage to VMs:

```yaml
vms:
  winhost1:
    attach:
      - shareddata
```

This mirrors Docker Compose’s `volumes:` section and supports:

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

# Requirements

- Windows 11 with Hyper‑V enabled  
- PowerShell 7+  
- Windows Server ISO (2022 or 2025 recommended)  

---

# Why this exists

Windows 10/11 cannot run real Windows containers.  
Windows Server can.  
This system gives you:

- reproducible VM builds  
- persistent container storage  
- a compose‑like workflow  
- fully automated provisioning  
- disposable compute, durable storage  

---

# License

MIT
