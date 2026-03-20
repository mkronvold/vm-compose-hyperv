# Metrics Reference

`vm-metrics.ps1` exposes a Prometheus-compatible `/metrics` endpoint on port 9090.

Metrics are cached and refreshed every 15 seconds (configurable via `-RefreshSeconds`).

---

## VM Metrics

Labels: `vm="<vmname>"` on all VM metrics.

### Existence & State

| Metric | Type | Description |
|--------|------|-------------|
| `hyperv_vm_exists` | gauge | `1` if the VM exists in Hyper-V, `0` if not found |
| `hyperv_vm_state` | gauge | `1` = Running, `0` = any other state |
| `hyperv_vm_uptime_seconds` | gauge | VM uptime in seconds; `0` if stopped |

### Compute

| Metric | Type | Description |
|--------|------|-------------|
| `hyperv_vm_vcpu_count` | gauge | Number of virtual CPUs assigned to the VM |
| `hyperv_vm_cpu_usage_percent` | gauge | Current CPU usage % as reported by Hyper-V |
| `hyperv_vm_memory_assigned_bytes` | gauge | Memory currently assigned (bytes) |
| `hyperv_vm_memory_startup_bytes` | gauge | Configured startup memory (bytes) |

### Checkpoints

| Metric | Type | Description |
|--------|------|-------------|
| `hyperv_vm_checkpoint_count` | gauge | Number of checkpoints (snapshots) on the VM |

### Network

| Metric | Type | Description |
|--------|------|-------------|
| `hyperv_vm_ip_assigned` | gauge | `1` if the VM has at least one IPv4 address, `0` otherwise |

### Docker

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `hyperv_vm_docker_running` | gauge | `vm` | `1` if the Docker service is running inside the VM |
| `hyperv_vm_docker_version_info` | gauge | `vm`, `version` | Always `1`; read the `version` label for the Docker Engine version string (e.g. `29.3.0`) |
| `hyperv_vm_docker_container_count` | gauge | `vm` | Total containers (running + stopped); `-1` if Docker not running |
| `hyperv_vm_docker_running_count` | gauge | `vm` | Running containers only; `-1` if Docker not running |

### Persistent Volume (P: drive inside VM)

| Metric | Type | Description |
|--------|------|-------------|
| `hyperv_vm_pv_bytes_total` | gauge | Total bytes on `P:` (Docker data volume); `-1` if not mounted |
| `hyperv_vm_pv_bytes_free` | gauge | Free bytes on `P:`; `-1` if not mounted |

### Licensing

| Metric | Type | Description |
|--------|------|-------------|
| `hyperv_vm_eval_days_remaining` | gauge | Days left on Windows evaluation license; `-1` if fully licensed or unknown |

---

## Container Metrics

Labels: `vm="<vmname>"`, `container="<name>"`. One set of metrics per container per VM.

| Metric | Type | Description |
|--------|------|-------------|
| `hyperv_container_running` | gauge | `1` = running, `0` = stopped |
| `hyperv_container_cpu_percent` | gauge | CPU usage % (running containers only) |
| `hyperv_container_mem_usage_bytes` | gauge | Memory used by the container (bytes) |
| `hyperv_container_mem_limit_bytes` | gauge | Memory limit for the container (bytes) |

---

## Storage Metrics

Host-side metrics for all volumes defined in the `storage:` section of `vmstack.yaml`. No VM connection required.

Labels: `name="<storageName>"`, `type="shared"` or `type="named-pv"`.

| Metric | Type | Description |
|--------|------|-------------|
| `hyperv_storage_bytes_used` | gauge | Actual VHDX file size on disk (bytes); `-1` if the file does not exist |
| `hyperv_storage_bytes_total` | gauge | Configured maximum size (bytes) from `size_gb` in vmstack.yaml |

> **Note:** `hyperv_storage_bytes_used` reflects the VHDX file size (sparse/dynamic), not the used space inside the filesystem. To monitor filesystem fill level inside the VM, use `hyperv_vm_pv_bytes_free` for the `P:` drive.

---

## Sentinel Values

| Value | Meaning |
|-------|---------|
| `-1` | Metric not available (VM stopped, Docker not running, volume not mounted, etc.) |
| `0` | VM/service does not exist or is not running |
| `1` | Exists / running / true |

---

## Configuration

```powershell
./vm-metrics.ps1 [-Port 9090] [-ConfigFile vmstack.yaml] [-RefreshSeconds 15]
```

Install as a Windows service:

```powershell
./vm-metrics-install.ps1
./vm-metrics-uninstall.ps1
```

Check status:

```powershell
./vm-compose.ps1 metrics
```

---

## Example Prometheus Scrape Config

```yaml
scrape_configs:
  - job_name: hyperv
    static_configs:
      - targets: ['localhost:9090']
    scrape_interval: 30s
```

---

## Example PromQL Queries

```promql
# VMs currently running
hyperv_vm_state == 1

# VMs with Docker not running
hyperv_vm_exists == 1 and hyperv_vm_docker_running == 0

# Storage volumes using more than 80% of configured size
hyperv_storage_bytes_used / hyperv_storage_bytes_total > 0.8

# Docker persistent volume (P:) less than 10 GB free
hyperv_vm_pv_bytes_free < 10 * 1024 * 1024 * 1024

# VMs with checkpoints (snapshot sprawl)
hyperv_vm_checkpoint_count > 0

# Docker versions across fleet
hyperv_vm_docker_version_info

# Eval licenses expiring within 30 days
hyperv_vm_eval_days_remaining > 0 and hyperv_vm_eval_days_remaining < 30
```
