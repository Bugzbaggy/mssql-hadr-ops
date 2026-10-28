# mssql-hadr-ops

PowerShell tooling for operating SQL Server Always On availability groups:
pre-flight-validated planned failover, rolling secondary patching that
survives a reboot, and cloud driver and agent updates for AWS and GCP.

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
resume-after-reboot steps so the sequence is the same every time.

The one ordering rule worth stating up front:

> **Suspend data movement *before* draining the cluster node.**
> Draining first makes the primary absorb the redo backlog of a secondary
> that is about to disappear. Suspend, then drain.

## What's in the box

| Function | What it does |
|---|---|
| `Invoke-MssqlOpsAgPlannedFailover` | Run on the primary. Validates the AG role, a single synchronized synchronous-commit target, cluster readiness, the listener network, `DB_CHAINING` parity, and queue depth; with `-Failover`, then fails over to that target |
| `Test-MssqlOpsAgListenerNetwork` | Read-only audit of the WSFC networks behind each AG listener (dangling network, subnet mismatch, duplicate interface, AWS ENI membership, probe-port parity); the planned failover runs it as a gate |
| `Initialize-MssqlOpsAgSecondaryPatching` | Prepares a secondary: readiness and blocking-transaction gates, PagerDuty window, suspends data movement, then (Windows mode) drains the node and refreshes cloud components |
| `Install-MssqlOpsAgSecondaryPatch` | Runs `Initialize-MssqlOpsAgSecondaryPatching`, then installs updates: Windows mode uses the Windows Update channel, refreshes cloud drivers, and reboots once; SqlCU mode uses Microsoft Update |
| `Resume-MssqlOpsAgSecondaryPatching` | After the reboot: resumes the cluster node, waits for it to stay `Up`, resumes data movement, checks each database is `SYNCHRONIZING` or `SYNCHRONIZED`, and closes the PagerDuty window |
| `Update-MssqlOpsCloudSystemComponent` | Detects the platform and dispatches to the AWS or GCP updater; a no-op elsewhere, or an error under `-RequireSuccess` |
| `Update-MssqlOpsAwsSystemComponent` | Updates AWS EC2 components: SSM Agent, EC2Launch v2, and the NVMe and ENA drivers |
| `Update-MssqlOpsGcpSystemComponent` | Updates GCP Compute Engine guest environment packages and paravirtual drivers via GooGet |
| `Set-MssqlOpsPagerDutyUserApiToken` | Stores a PagerDuty token in SecretManagement for maintenance windows |

## Requirements

- PowerShell **7.0+** (not Windows PowerShell 5.1 — see [gotchas](#gotchas-that-cost-us-time))
- [`dbatools`](https://dbatools.io/)
- `Microsoft.PowerShell.SecretManagement` + `SecretStore`
- `PSWindowsUpdate`
- `SqlServer`, for `Invoke-Sqlcmd`, which the functions call directly. It is
  not in the manifest's `RequiredModules`, so importing the module does not
  check for it.
- `FailoverClusters` (ships with the Failover Clustering feature)

```powershell
Install-Module dbatools, Microsoft.PowerShell.SecretManagement,
               Microsoft.PowerShell.SecretStore, PSWindowsUpdate,
               SqlServer -Scope AllUsers
```

## Install

```powershell
git clone https://github.com/Bugzbaggy/mssql-hadr-ops.git
Import-Module ./mssql-hadr-ops/MssqlHadrOps/MssqlHadrOps.psd1
```

## Quick start

Every function acts on the node it runs on: the local default instance
(`$env:COMPUTERNAME`). None of them takes a server or AG name. For a named
instance, edit the `$SqlInstance` / `$LocalInstance` line near the top of the
function.

A rolling patch of one secondary, end to end. Run this on the secondary:

```powershell
# 1. Prepare and patch in one call: gates, PagerDuty window, suspend data
#    movement, drain the node, Windows Update channel, cloud driver refresh,
#    then a single reboot if anything staged needs one
Install-MssqlOpsAgSecondaryPatch -Mode Windows

# 2. After the reboot: resume the node, resume data movement, check sync
#    state, close the PagerDuty window
Resume-MssqlOpsAgSecondaryPatching
```

To prepare without installing anything (to patch by hand), run
`Initialize-MssqlOpsAgSecondaryPatching -Mode Windows` instead of step 1.
For a SQL Server CU, use `-Mode SqlCU`: the cluster node stays online and the
updates come from the Microsoft Update channel.

Then fail over so the patched node becomes primary, and repeat on the other
side. Run this on the current primary. The target is selected automatically:
it must be the only synchronous-commit secondary in `SYNCHRONIZED` state.

```powershell
# Validation only, no side effects
Invoke-MssqlOpsAgPlannedFailover

# Validate, then fail over (asks for confirmation; -Confirm:$false skips it)
Invoke-MssqlOpsAgPlannedFailover -Failover
```

> All hostnames, AG names, database names, and service ids in this repo are
> **placeholders** (`STAGING-NODE2`, `ag-staging1`, `AppDb`, `PDSERVICE`).
> Substitute your own. In particular, set `$script:PagerDutyServiceId` in
> `MssqlHadrOps.psm1` to your PagerDuty service id, or pass
> `-PagerDutyServiceId` on each call.

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
   un-synchronizing. That is why `Initialize-MssqlOpsAgSecondaryPatching`
   runs a blocking-transaction gate before it suspends data movement.
5. **Build direction matters.** Upgrade the secondaries first, then fail over
   *to* an upgraded one. Once a database runs on the newer build, a replica
   still on the older build can no longer synchronize it or take it back, so
   there is no failing back until every replica is upgraded. Check the build
   on both sides before you fail over.
6. **A .NET assembly conflict blocked module load** under Windows PowerShell
   5.1. Use PowerShell 7 and load `FailoverClusters` via `WinPSCompatSession`.
7. **The secret store had a forgotten password**, which surfaced only mid-window.
   Test secret retrieval during pre-flight, not during the change.
8. **Maintenance-window API calls are best-effort.** A PagerDuty failure should
   never block a failover — it's suppression, not a gate.

**Leave automatic failover enabled while you patch the OS.** Disabling it
removes your safety net exactly when the cluster is least stable. A SQL Server
CU or version upgrade (`-Mode SqlCU`) is the exception: Microsoft's
[rolling-upgrade guidance](https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/upgrading-always-on-availability-group-replica-instances)
is to set the synchronous-commit replicas to manual failover before you start,
so an automatic failover cannot land on a replica that has not been upgraded.
This module never changes the failover mode, so do that step yourself.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please don't paste real hostnames or
account names into issues — see [SECURITY.md](SECURITY.md).

## Credits

See [AUTHORS.md](AUTHORS.md). This module began as internal tooling and is
published with the original authors' permission.

## License

[MIT](LICENSE)
