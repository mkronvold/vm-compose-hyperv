All items below have been implemented. See commit history for details.

## Completed

1. ✅ `vm-compose.ps1 --dry-run` — preview mode; wraps all mutating ops, prints `[DRY RUN] Would: <action>`
2. ✅ `vm-compose.ps1 validate` — lints `vmstack.yaml` for required fields, broken network/storage refs, NAT config
3. ✅ `vm-compose.ps1 version` — prints version, PowerShell version, and config path
4. ✅ `vm-compose.ps1 mount/unmount` — hot-add/remove shared storage disks on running VMs; build-time `mount:` support in `vmstack.yaml`
5. ✅ `vm-metrics.ps1` — Prometheus metrics exporter as a Windows service (`:9090/metrics`)
6. ✅ `vm-dashboard.ps1` — Pode-based web UI dashboard as a Windows service (`http://localhost:8080`)
