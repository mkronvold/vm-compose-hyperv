# Examples

Commonly used `vm-compose.ps1` commands with real-world examples.

> Most commands require running as **Administrator**.

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
./vm-compose.ps1 restart solr

# Destroy all VM definitions (VHDXes are preserved)
./vm-compose.ps1 destroy

# Destroy a single VM
./vm-compose.ps1 destroy solr
```

---

## Status & Inspection

```powershell
# Show status table for all VMs
./vm-compose.ps1 status

# Show detailed info for a single VM (aliases: describe, show)
./vm-compose.ps1 inspect solr

# Print just the IP address
./vm-compose.ps1 ip solr

# Live CPU / memory loop (Ctrl+C to exit)
./vm-compose.ps1 top solr
```

---

## Health Checks

```powershell
# Health check all VMs
./vm-compose.ps1 health

# Health check a single VM
./vm-compose.ps1 health solr
```

Output includes: VM state, IP, Containers feature, Docker Engine version, persistent volume status, shared volume mounts, and bootstrap completion timestamp.

---

## Exec & Shell

```powershell
# Run a command inside a VM
./vm-compose.ps1 exec solr "ipconfig"

# Run a multi-part command (quote the whole thing)
./vm-compose.ps1 exec solr "Get-Service docker | Select Name, Status"

# Open an interactive PowerShell shell inside a VM
./vm-compose.ps1 ssh solr

# List top processes by CPU
./vm-compose.ps1 ps solr
```

---

## Docker Inside a VM

```powershell
# List running containers
./vm-compose.ps1 docker solr ps

# List all containers (including stopped)
./vm-compose.ps1 docker solr ps -a

# List images
./vm-compose.ps1 docker solr images

# Pull an image
./vm-compose.ps1 docker solr pull mcr.microsoft.com/windows/nanoserver:ltsc2022

# Run a one-off container
./vm-compose.ps1 docker solr run --rm mcr.microsoft.com/windows/nanoserver:ltsc2022 cmd /c echo hello

# Run a nanoserver hello-world smoke test (auto-detects OS build)
./vm-compose.ps1 docker-test solr

# Check disk usage
./vm-compose.ps1 docker solr system df
```

---

## Logs

```powershell
# Show recent Application event log from a VM
./vm-compose.ps1 logs solr

# List available logs inside a VM
./vm-compose.ps1 getlog solr

# Fetch the bootstrap log
./vm-compose.ps1 getlog bootstrap solr

# Fetch the Docker install log
./vm-compose.ps1 getlog docker solr
```

---

## File Copy

```powershell
# Copy a file from host to VM
./vm-compose.ps1 cp C:\configs\solr.xml solr:C:\Setup\

# Copy a directory from host to VM
./vm-compose.ps1 cp C:\data\ solr:C:\data\

# Copy a file from VM to host (prompts for credentials inside the VM)
./vm-compose.ps1 cp solr:C:\Setup\bootstrap.log .
```

---

## VM Notes

```powershell
# Show the notes for a VM
./vm-compose.ps1 note show solr

# Append a note
./vm-compose.ps1 note add solr

# Open notes in Notepad for full editing
./vm-compose.ps1 note edit solr
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
./vm-compose.ps1 mount solr shareddata

# Remove a shared disk from a VM
./vm-compose.ps1 unmount solr shareddata

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
