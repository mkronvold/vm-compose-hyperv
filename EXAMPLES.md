# Examples

Commonly used `vm-compose.ps1` commands with real-world examples.

> Most commands require running as **Administrator**.
> 
> Commands follow **noun-verb** ordering: `./vm-compose.ps1 <vm> <command>`.  
> Both orderings are supported: `./vm-compose.ps1 solr restart` and `./vm-compose.ps1 restart solr` are equivalent.

---

## VM Lifecycle

```powershell
# Start all VMs defined in vmstack.yaml
./vm-compose.ps1 up

# Start a single VM
./vm-compose.ps1 up solr

# Preview what `up` would do without making changes
./vm-compose.ps1 up -DryRun

# Stop all VMs
./vm-compose.ps1 down

# Restart a single VM
./vm-compose.ps1 solr restart

# Destroy all VM definitions (VHDXes are preserved)
./vm-compose.ps1 destroy

# Destroy a single VM
./vm-compose.ps1 solr destroy
```

---

## Status & Inspection

```powershell
# Show status table for all VMs
./vm-compose.ps1 status

# Show detailed info for a single VM (aliases: describe, show)
./vm-compose.ps1 solr inspect

# Print just the IP address
./vm-compose.ps1 solr ip

# Live CPU / memory loop (Ctrl+C to exit)
./vm-compose.ps1 solr top
```

---

## Health Checks

```powershell
# Health check all VMs
./vm-compose.ps1 health

# Health check a single VM
./vm-compose.ps1 solr health
```

Output includes: VM state, IP, Containers feature, Docker Engine version, persistent volume status, shared volume mounts, and bootstrap completion timestamp.

---

## Exec & Shell

```powershell
# Run a command inside a VM
./vm-compose.ps1 solr exec "ipconfig"

# Run a multi-part command (quote the whole thing)
./vm-compose.ps1 solr exec "Get-Service docker | Select Name, Status"

# Open an interactive PowerShell shell inside a VM
./vm-compose.ps1 solr ssh

# List top processes by CPU
./vm-compose.ps1 solr ps
```

---

## Docker Inside a VM

```powershell
# List running containers
./vm-compose.ps1 solr docker ps

# List all containers (including stopped)
./vm-compose.ps1 solr docker ps -a

# List images
./vm-compose.ps1 solr docker images

# Pull an image
./vm-compose.ps1 solr docker pull mcr.microsoft.com/windows/nanoserver:ltsc2022

# Run a one-off container
./vm-compose.ps1 solr docker run --rm mcr.microsoft.com/windows/nanoserver:ltsc2022 cmd /c echo hello

# Run a nanoserver hello-world smoke test (auto-detects OS build)
./vm-compose.ps1 solr docker-test

# Check disk usage
./vm-compose.ps1 solr docker system df
```

---

## Docker Compose Inside a VM

```powershell
# Using raw flags (always works)
./vm-compose.ps1 solr docker-compose --project-directory P:\enshrouded-docker -f P:\enshrouded-docker\docker-compose.yml build

# Using a project shortcut defined in vmstack.yaml projects: section
./vm-compose.ps1 solr docker-compose -Project enshrouded build

# VM is inferred from the project definition (project_vm) — no need to specify
./vm-compose.ps1 docker-compose -Project enshrouded up -d

# Show running compose services
./vm-compose.ps1 solr docker-compose -Project enshrouded ps

# View compose logs
./vm-compose.ps1 solr docker-compose -Project enshrouded logs --tail 50
```

Define projects in `vmstack.yaml`:
```yaml
projects:
  enshrouded:
    project_vm: solr
    project_folder: P:\enshrouded-docker
    project_type: docker-compose
```

---

## Logs

```powershell
# Show recent Application event log from a VM
./vm-compose.ps1 solr eventlog

# List available logs inside a VM
./vm-compose.ps1 solr getlog

# Fetch the bootstrap log
./vm-compose.ps1 solr getlog bootstrap

# Fetch the Docker event log
./vm-compose.ps1 solr getlog docker
```

---

## File Copy

```powershell
# Copy a file from host to VM
./vm-compose.ps1 cp C:\configs\solr.xml solr:C:\Setup\

# Copy a directory from host to VM
./vm-compose.ps1 cp C:\data\ solr:C:\data\

# Copy a host Docker project folder into a VM persistent volume (P:)
./vm-compose.ps1 cp C:\docker\enshrouded-docker\ solr:P:\enshrouded-docker\

# Copy a file from VM to host (prompts for credentials inside the VM)
./vm-compose.ps1 cp solr:C:\Setup\bootstrap.log .
```

---

## VM Notes

```powershell
# Show the notes for a VM
./vm-compose.ps1 solr note show

# Append a note
./vm-compose.ps1 solr note add

# Open notes in Notepad for full editing
./vm-compose.ps1 solr note edit
```

---

## Named Persistent Volumes (per-VM application data)

Add to `storage:` section in vmstack.yaml using `pv-<vmname>` naming:

```yaml
storage:
  pv-solr:
    path: "storage/pv-solr.vhdx"
    size_gb: 100

vms:
  solr:
    mount:
      - pv-solr
```

Then use the same `storage shared` commands (they appear with type `named-pv` in `ls`):

```powershell
# List all storage including named PVs
./vm-compose.ps1 storage shared ls

# Mount a named PV on the host for direct access
./vm-compose.ps1 storage shared localmount pv-solr

# Dismount
./vm-compose.ps1 storage shared localunmount pv-solr

# Health check
./vm-compose.ps1 storage shared health pv-solr
```

---

## Shared Storage

```powershell
# List all shared volumes
./vm-compose.ps1 storage shared ls

# Mount a shared VHDX on the host (default drive: S:)
./vm-compose.ps1 storage shared localmount shareddata

# Mount at a specific drive letter
./vm-compose.ps1 storage shared localmount shareddata T

# Dismount from host
./vm-compose.ps1 storage shared localunmount shareddata

# Hot-add a shared disk to a running VM
./vm-compose.ps1 solr mount shareddata

# Remove a shared disk from a VM
./vm-compose.ps1 solr unmount shareddata

# Health check all shared volumes
./vm-compose.ps1 storage shared health

# Health check a specific volume
./vm-compose.ps1 storage shared health shareddata
```

---

## Persistent Volumes (PVs)

```powershell
# List all persistent volumes
./vm-compose.ps1 storage pv ls

# Mount a VM's persistent disk on the host (default drive: P:)
./vm-compose.ps1 storage pv localmount solr

# Mount at a specific drive letter
./vm-compose.ps1 storage pv localmount solr Q

# Dismount from host
./vm-compose.ps1 storage pv localunmount solr

# Health check all PVs
./vm-compose.ps1 storage pv health

# Create a PV VHDX for a VM (if it doesn't exist)
./vm-compose.ps1 storage pv create solr
```

---

## Dashboard & Metrics Services

```powershell
# Show web dashboard status
./vm-compose.ps1 web

# Install the dashboard as a Windows service
./vm-dashboard-install.ps1

# Restart the dashboard service
./vm-compose.ps1 web restart

# Show Prometheus metrics exporter status
./vm-compose.ps1 metrics

# Install the metrics exporter as a Windows service
./vm-metrics-install.ps1
```

Dashboard: http://localhost:8080  
Metrics:   http://localhost:9090/metrics

---

## Config & Validation

```powershell
# Lint vmstack.yaml for errors before running
./vm-compose.ps1 validate

# Show version info
./vm-compose.ps1 version

# Use a different config file
./vm-compose.ps1 status -ConfigFile vmstack-staging.yaml

# Use a different VM root path
./vm-compose.ps1 up -VmRoot D:\HyperV\VMs
```

---

## Per-Command Help

```powershell
# Show all commands
./vm-compose.ps1 help

# Show help for a specific command
./vm-compose.ps1 help storage
./vm-compose.ps1 help docker
./vm-compose.ps1 help cp
```
