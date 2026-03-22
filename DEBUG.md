# Debugging vm-compose

## Enabling Debug Logging

Set the `VMCOMPOSE_DEBUG` environment variable before running any `vm-compose.ps1` command:

```powershell
$env:VMCOMPOSE_DEBUG = '1'
```

Accepted values: `1`, `true`, `yes` (case-insensitive). Any other value (or unset) disables logging.

The log is written to `vm-compose-debug.log` in the same directory as `vm-compose.ps1`. It is append-only — each run adds to the end of the file.

## Disabling Debug Logging

```powershell
$env:VMCOMPOSE_DEBUG = ''
# or remove it entirely:
Remove-Item Env:VMCOMPOSE_DEBUG
```

## Log Format

Each line is structured as:

```
[YYYY-MM-DD HH:mm:ss.fff] [LEVEL] message
```

### Log Levels

| Level   | Color  | Meaning |
|---------|--------|---------|
| `INFO`  | Gray   | Command invocation and overall pass/fail |
| `STEP`  | Green  | Individual `Invoke-IfLive` steps — BEGIN, OK, FAIL with elapsed ms |
| `BUILD` | Cyan   | `build` command detail — config values, disk plan, resolved paths, outcome |
| `WARN`  | Yellow | Non-fatal warnings |
| `ERROR` | Red    | Failures — also written before the exception is re-thrown |

### Example Output

```
[2026-03-22 15:17:43.919] [INFO]  Invoked: Command=build VmName=solr ExecCommand= Project= DryRun=False Force=False args=[-Command build -VmName solr]
[2026-03-22 15:17:44.001] [BUILD] BUILD START: vmName=solr AutoStart=False Rebuild=False
[2026-03-22 15:17:44.002] [BUILD]   memory_gb=10  cpus=3  os_disk_gb=80  persistent_disk_gb=
[2026-03-22 15:17:44.003] [BUILD]   Paths: VmPath=C:\HyperV\VMs\solr  VhdPath=C:\HyperV\VMs\solr\osdisk.vhdx
[2026-03-22 15:17:44.004] [BUILD]   Disks: osDisk=80GB  persistentDisk=none
[2026-03-22 15:17:44.100] [STEP]  BEGIN:  New-VM solr (10 GB RAM, 3 CPUs) 
[2026-03-22 15:17:46.500] [STEP]  OK:     New-VM solr (10 GB RAM, 3 CPUs) (2400ms)
[2026-03-22 15:17:46.900] [BUILD] BUILD COMPLETE: solr — created  memory=10GB cpus=3 osDisk=80GB
[2026-03-22 15:17:46.901] [INFO]  COMMAND OK: build (2.98s)
```

## Viewing Logs

Use the `log` command to view the debug log without opening the file directly:

```powershell
# Show last 100 lines
./vm-compose.ps1 log

# Show last N lines
./vm-compose.ps1 log 200

# Filter to a specific VM
./vm-compose.ps1 solr log

# Filter by project (resolves project_vm from vmstack.yaml)
./vm-compose.ps1 log -Project enshrouded
```

You can also read the file directly:

```powershell
Get-Content vm-compose-debug.log | Select-Object -Last 50
Get-Content vm-compose-debug.log | Select-String "solr"
Get-Content vm-compose-debug.log | Select-String "ERROR|WARN"
```

## Clearing the Log

The log is never automatically rotated. Clear it manually when needed:

```powershell
Clear-Content vm-compose-debug.log
# or delete it:
Remove-Item vm-compose-debug.log
```

## Notes

- The log file is excluded from git (it is a local runtime artifact).
- If the log file cannot be written (e.g. permissions), the error is silently ignored — it will never crash a running command.
- Debug logging has no effect on command behavior; it is purely observational.
