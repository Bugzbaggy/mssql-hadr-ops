# mssql-hadr-ops

PowerShell tooling for operating SQL Server Always On availability groups:
pre-flight-validated planned failover, rolling secondary patching that
survives a reboot, and cloud platform driver updates for AWS, GCP, and Azure.

[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE)](https://github.com/PowerShell/PowerShell)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows%20Server-0078D6)](#requirements)

---

## Why this exists

Patching an Always On cluster is a sequence where the *order* matters more
than any individual command. Get it wrong and you don't find out during the
maintenance window — you find out when the primary starts timing out, or when
a node comes back from a reboot and SQL Server doesn't.

This module encodes the ordering, the pre-flight checks, and the
resume-after-reboot state machine so the sequence is the same every time.

The one ordering rule worth stating up front:

> **Suspend data movement *before* draining the cluster node.**
> Draining first makes the primary absorb the redo backlog of a secondary
> that is about to disappear. Suspend, then drain.

## What's in the box

| Function | What it does |
|---|---|
| `Invoke-MssqlOpsAgPlannedFailover` | Validates sync state, blocking transactions, and cluster readiness, then fails over |
| `Initialize-MssqlOpsAgSecondaryPatching` | Pre-flight for a secondary: suspends movement, drains the node, records resume state |
| `Install-MssqlOpsAgSecondaryPatch` | Applies Windows updates to a prepared secondary |
| `Resume-MssqlOpsAgSecondaryPatching` | Picks up after the reboot: resumes the node, resumes data movement, waits for `SYNCHRONIZED` |
| `Update-MssqlOpsCloudSystemComponent` | Detects the platform and dispatches to the right driver updater |
| `Update-MssqlOpsAwsSystemComponent` | Updates AWS EC2 drivers (ENA, NVMe, PV) |
| `Update-MssqlOpsGcpSystemComponent` | Updates GCP Compute Engine guest environment packages |
| `Set-MssqlOpsPagerDutyUserApiToken` | Stores a PagerDuty token in SecretManagement for maintenance windows |

## Requirements

- PowerShell **7.0+** (not Windows PowerShell 5.1 — see [gotchas](#gotchas-that-cost-us-time))
- [`dbatools`](https://dbatools.io/)
- `Microsoft.PowerShell.SecretManagement` + `SecretStore`
- `PSWindowsUpdate`
- `FailoverClusters` (ships with the Failover Clustering feature)

```powershell
Install-Module dbatools, Microsoft.PowerShell.SecretManagement,
               Microsoft.PowerShell.SecretStore, PSWindowsUpdate -Scope AllUsers
```

## Install

```powershell
git clone https://github.com/Bugzbaggy/mssql-hadr-ops.git
Import-Module ./mssql-hadr-ops/MssqlHadrOps/MssqlHadrOps.psd1
```

## Quick start

A rolling patch of one secondary, end to end:

```powershell
# 1. Prepare: suspend data movement, drain the node, save resume state
Initialize-MssqlOpsAgSecondaryPatching `
    -SqlInstance  'region1-node1' `
    -AvailabilityGroup 'ag-region1-cluster'

# 2. Patch (this will reboot)
Install-MssqlOpsAgSecondaryPatch -SqlInstance 'region1-node1'

# 3. After reboot: resume the node and wait for SYNCHRONIZED
Resume-MssqlOpsAgSecondaryPatching `
    -SqlInstance 'region1-node1' `
    -AvailabilityGroup 'ag-region1-cluster'
```

Then fail over so the patched node becomes primary and repeat on the other side:

```powershell
Invoke-MssqlOpsAgPlannedFailover `
    -AvailabilityGroup 'ag-region1-cluster' `
    -TargetReplica     'region1-node1'
```

> All hostnames, AG names, and accounts in this repo are **placeholders**
> (`region1-node1`, `ag-region1-cluster`, `AppDb`, `svc_*`). Substitute your own.

## Gotchas that cost us time

These are the failures that actually happened during a Windows Server 2025
in-place upgrade of a production cluster. They're the reason several of the
pre-flight checks exist.

1. **Drained before suspending.** The primary absorbed the redo backlog and
   client calls timed out. Suspend data movement first.
2. **The OS cumulative update silently didn't install.** Always verify the
   build after patching rather than trusting the exit code.
3. **SQL Server didn't auto-start after the OS upgrade.** In-place upgrades
   can reset the service start mode — check it before declaring success.
4. **A background job stalled the failover** and left databases
   un-synchronizing. `Test-MssqlOpsBlockingTransaction` exists because of this.
5. **Build direction matters.** A secondary on a *newer* SQL build than the
   primary cannot be failed over to safely. Check both directions.
6. **A .NET assembly conflict blocked module load** under Windows PowerShell
   5.1. Use PowerShell 7 and load `FailoverClusters` via `WinPSCompatSession`.
7. **The secret store had a forgotten password**, which surfaced only mid-window.
   Test secret retrieval during pre-flight, not during the change.
8. **Maintenance-window API calls are best-effort.** A PagerDuty failure should
   never block a failover — it's suppression, not a gate.

**Leave automatic failover enabled during maintenance.** Disabling it removes
your safety net exactly when the cluster is least stable.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please don't paste real hostnames or
account names into issues — see [SECURITY.md](SECURITY.md).

## Credits

See [AUTHORS.md](AUTHORS.md). This module began as internal tooling and is
published with the original authors' permission.

## License

[MIT](LICENSE)
