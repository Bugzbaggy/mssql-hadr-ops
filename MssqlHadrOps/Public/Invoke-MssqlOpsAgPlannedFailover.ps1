<#
.SYNOPSIS
    Validates HADR readiness on the current primary node and (with -Failover)
    performs a planned no-data-loss Always On Availability Group failover to
    the synchronous-commit secondary.
.DESCRIPTION
    Default mode (no -Failover): runs five validation checks and returns
    silently if they all pass, throws otherwise. No side effects.

    With -Failover: after the same five validations pass, opens a PagerDuty
    maintenance window, issues Invoke-DbaAgFailover against the target
    secondary (planned failover, no data loss), and verifies the role swap.

    Validation steps:
      1. Local node is PRIMARY for exactly one AG.
      2. Exactly one synchronous-commit secondary is currently SYNCHRONIZED.
      3. WSFC quorum is healthy (all nodes Up, witness online, votes >= majority).
      4. Per-database DB_CHAINING flag is identical on both replicas.
      5. Every AG database is SYNCHRONIZED with log_send_queue and redo_queue
         below the configured thresholds.
.PARAMETER Failover
    Switch. Default off. When omitted, only validation runs. When supplied,
    the failover is attempted after validation passes.
.PARAMETER MaxLogSendQueueKB
    Per-database ceiling for log_send_queue_size in KB. Default 1024.
.PARAMETER MaxRedoQueueKB
    Per-database ceiling for redo_queue_size in KB. Default 1024.
.PARAMETER PagerDutyApiKey
    PagerDuty REST API key. Only used with -Failover. Resolution order:
      1. The -PagerDutyApiKey value passed on the command line.
      2. Get-Secret -Name PAGERDUTY_USER_API_TOKEN from Microsoft.PowerShell.SecretManagement
         (DPAPI-encrypted per Windows user; recommended).
      3. $env:PAGERDUTY_USER_API_TOKEN (env-var fallback).

    Run Set-MssqlOpsPagerDutyUserApiToken once per server to populate the vault.
.PARAMETER PagerDutyServiceId
    PagerDuty service id used for the maintenance window. Defaults to the
    module-level value set in MssqlHadrOps.psm1 ('PYZ6V1U' - AppDb Messaging
    Database). Override only when targeting a different service.
.PARAMETER MaintenanceDurationMinutes
    Length of the PagerDuty maintenance window in minutes. Default 30.
    Only used with -Failover.
.PARAMETER SkipClusterReadinessGate
    Bypass the WSFC + witness + AG readiness gate added in 2.1. Use only when
    you have a documented reason to override (e.g. you're failing over BECAUSE
    the cluster is degraded). Default off.
.NOTES
    Version:        2.5
    Last Modified:  2026-08-18
    Author:         original module author
    Changes:        2.5 - Step 5 (per-db sync/queue) now reads the HADR DMVs via
                          Invoke-Sqlcmd instead of the non-existent
                          Get-DbaAgDatabaseReplicaState cmdlet. Query validated
                          against the live SG cluster (returns all 10 AG DBs for
                          the target replica). Threshold columns ISNULL-guarded.
                    2.4 - DB_CHAINING parity (step 4) now reads
                          sys.databases.is_db_chaining_on via Invoke-Sqlcmd
                          instead of the non-existent Get-DbaDbChainingOption
                          cmdlet, which failed regardless of dbatools version.
                    2.3 - Quorum vote math no longer dereferences the witness
                          resource's .Name (empty under the PS7 WinPSCompat
                          session, which threw). Witness health is validated by
                          the readiness gate; this step now only counts the
                          witness vote.
                    2.2 - Step 1 now excludes distributed AGs
                          (IsDistributedAvailabilityGroup) when detecting the
                          local primary AG. On clusters that are the global
                          primary of one or more distributed AGs (e.g. SG, which
                          hosts dag-<region>), the unfiltered query returned
                          multiple AGs and the multi-AG guard aborted every run.
                          A planned failover targets the local AG only; the
                          distributed AGs follow the local primary automatically.
                    2.1 - Added cluster readiness gate (Test-MssqlOpsClusterReadiness)
                          inside step 3, before the existing quorum-vote math.
                          Closes a gap exposed by the ID 2026-06-08 RESOLVING
                          incident: the original vote-math step trusts the
                          cluster's view of the witness, which can report
                          Online while this node currently can't reach the
                          share. The gate adds an SMB reachability test from
                          this node, a peer-Paused interlock, and a
                          Resolving-AG interlock.
                    2.0 - Refactored from script to function inside MssqlHadrOps module.
                    1.0 - Initial standalone script.
#>
function Invoke-MssqlOpsAgPlannedFailover {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [switch]$Failover,
        [int]$MaxLogSendQueueKB           = 1024,
        [int]$MaxRedoQueueKB              = 1024,
        [string]$PagerDutyApiKey,
        [string]$PagerDutyServiceId       = $script:PagerDutyServiceId,
        [int]$MaintenanceDurationMinutes  = 30,
        [switch]$SkipClusterReadinessGate
    )

    $FunctionVersion = "2.5"
    $TotalSteps      = if ($Failover) { 8 } else { 5 }

    $NodeName      = $env:COMPUTERNAME
    $LocalInstance = $NodeName   # Change to "$NodeName\InstanceName" if using a named instance.

    $PagerDutyApiKey = Resolve-PagerDutyApiKey -Initial $PagerDutyApiKey

    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host " MssqlHadrOps v$FunctionVersion  |  Mode: $(if ($Failover) { 'FAILOVER' } else { 'VALIDATE' })" -ForegroundColor Cyan
    Write-Host " Local node: $NodeName" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan

    # -------------------------------------------------------------------------
    # STEP 1: Local node is PRIMARY for exactly one AG
    # -------------------------------------------------------------------------
    Write-Host "`n[1/$TotalSteps] Detecting Availability Group on local node..." -ForegroundColor Yellow

    try {
        # Exclude distributed AGs. On the SG cluster the primary node hosts the
        # local AG PLUS three distributed AGs (dag-<region>) as their global
        # primary, so an unfiltered LocalReplicaRole='Primary' query returns 4
        # AGs and the "multi-AG" guard below would abort every run. A planned
        # failover targets the LOCAL AG only; the distributed AGs follow the
        # local primary automatically. The `-ne $true` form is null-safe on
        # older dbatools/SMO where IsDistributedAvailabilityGroup is absent.
        $primaryAgs = Get-DbaAvailabilityGroup -SqlInstance $LocalInstance -EnableException |
                      Where-Object { $_.LocalReplicaRole -eq 'Primary' -and $_.IsDistributedAvailabilityGroup -ne $true }
    } catch {
        Write-Host " -> Failed to query availability groups: $($_.Exception.Message)" -ForegroundColor Red
        throw "Failed to query availability groups: $($_.Exception.Message)"
    }

    if (-not $primaryAgs) {
        Write-Host " -> FAIL: This node is not PRIMARY for any (non-distributed) availability group." -ForegroundColor Red
        Write-Host "    Run this command on the current primary node." -ForegroundColor Red
        throw "This node is not PRIMARY for any availability group."
    }

    if (@($primaryAgs).Count -gt 1) {
        Write-Host " -> FAIL: Local node is primary for $(@($primaryAgs).Count) local AGs. Multi-AG case is out of scope." -ForegroundColor Red
        @($primaryAgs).Name | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
        throw "Local node is primary for multiple AGs; multi-AG case is out of scope."
    }

    $ag = @($primaryAgs)[0]
    Write-Host " -> PASS: Primary for AG '$($ag.Name)'." -ForegroundColor Green

    # -------------------------------------------------------------------------
    # STEP 2: Auto-detect failover target replica
    # -------------------------------------------------------------------------
    Write-Host "`n[2/$TotalSteps] Selecting failover target replica..." -ForegroundColor Yellow

    try {
        $candidates = Get-DbaAgReplica -SqlInstance $LocalInstance -AvailabilityGroup $ag.Name -EnableException |
                      Where-Object {
                          $_.Role                       -eq 'Secondary'         -and
                          $_.AvailabilityMode           -eq 'SynchronousCommit' -and
                          $_.RollupSynchronizationState -eq 'Synchronized'
                      }
    } catch {
        Write-Host " -> Failed to query AG replicas: $($_.Exception.Message)" -ForegroundColor Red
        throw "Failed to query AG replicas: $($_.Exception.Message)"
    }

    if (-not $candidates) {
        Write-Host " -> FAIL: No synchronous-commit secondary in SYNCHRONIZED state." -ForegroundColor Red
        throw "No synchronous-commit secondary in SYNCHRONIZED state."
    }

    if (@($candidates).Count -gt 1) {
        Write-Host " -> FAIL: Multiple eligible secondaries found. Cannot auto-select target:" -ForegroundColor Red
        @($candidates).Name | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
        throw "Multiple eligible secondaries found; cannot auto-select target."
    }

    $TargetInstance = @($candidates)[0].Name
    Write-Host " -> PASS: Target replica is '$TargetInstance'." -ForegroundColor Green

    # -------------------------------------------------------------------------
    # STEP 3: WSFC + witness + cross-AG readiness, then quorum vote math
    #   The cluster readiness gate (added 2.1) closes the gaps exposed by the
    #   ID 2026-06-08 RESOLVING incident: SMB reachability of the witness
    #   from this node, peer-Paused interlock, and Resolving-AG interlock.
    #   The vote math after it is the original 2.0 check, still useful as a
    #   defense-in-depth quorum-majority audit.
    # -------------------------------------------------------------------------
    Write-Host "`n[3/$TotalSteps] Verifying WSFC quorum..." -ForegroundColor Yellow

    if ($SkipClusterReadinessGate) {
        Write-Host "    Cluster readiness gate SKIPPED by -SkipClusterReadinessGate." -ForegroundColor Yellow
    } else {
        $gate = Test-MssqlOpsClusterReadiness -LocalInstance $LocalInstance
        foreach ($w in $gate.Warnings) {
            Write-Host "    WARN: $w" -ForegroundColor DarkYellow
        }
        if (-not $gate.Healthy) {
            Write-Host " -> FAIL: Cluster readiness gate:" -ForegroundColor Red
            foreach ($f in $gate.Failures) {
                Write-Host "    - $f" -ForegroundColor Red
            }
            throw "Cluster readiness gate failed; refusing planned failover. Pass -SkipClusterReadinessGate to override (rare; only when you're failing over BECAUSE the cluster is degraded)."
        }
    }

    try {
        $clusterNodes = Get-ClusterNode
        $downNodes    = $clusterNodes | Where-Object { $_.State -ne 'Up' }

        if ($downNodes) {
            Write-Host " -> FAIL: Cluster nodes not Up:" -ForegroundColor Red
            $downNodes | ForEach-Object { Write-Host "    - $($_.Name) [$($_.State)]" -ForegroundColor Red }
            throw "Cluster nodes not Up."
        }

        $quorum    = Get-ClusterQuorum
        $witness   = $quorum.QuorumResource
        $witnessVote = 0

        # Count the witness vote for the majority math below. We deliberately do
        # NOT dereference $witness.Name / re-fetch the resource here: under the
        # PS7 WinPSCompat session the nested .Name is empty, which used to throw.
        # The readiness gate above (Test-MssqlOpsClusterReadiness) already
        # validates witness Online state + SMB reachability, so this stays a
        # pure vote-arithmetic step.
        if ($witness) { $witnessVote = 1 }

        $nodeVotes  = ($clusterNodes | Where-Object { $_.State -eq 'Up' } |
                       Measure-Object -Property NodeWeight -Sum).Sum
        $totalVotes = $nodeVotes + $witnessVote
        $configured = ($clusterNodes | Measure-Object -Property NodeWeight -Sum).Sum + $(if ($witness) { 1 } else { 0 })
        $majority   = [math]::Floor($configured / 2) + 1

        if ($totalVotes -lt $majority) {
            Write-Host " -> FAIL: Active votes ($totalVotes) < majority threshold ($majority of $configured)." -ForegroundColor Red
            throw "Active votes ($totalVotes) below majority threshold ($majority of $configured)."
        }

        $witnessText = if ($witness) { 'configured' } else { 'not configured' }
        Write-Host " -> PASS: $($clusterNodes.Count) node(s) Up, witness $witnessText, votes $totalVotes/$configured." -ForegroundColor Green
    } catch {
        Write-Host " -> Failed quorum check: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }

    # -------------------------------------------------------------------------
    # STEP 4: DB_CHAINING parity between replicas
    #   Read directly from sys.databases.is_db_chaining_on via Invoke-Sqlcmd
    #   (already a module dependency). This avoids Get-DbaDbChainingOption, which
    #   is not a reliably-available dbatools command and broke this step.
    # -------------------------------------------------------------------------
    Write-Host "`n[4/$TotalSteps] Comparing per-database DB_CHAINING between replicas..." -ForegroundColor Yellow

    try {
        $agDbNames  = @($ag.AvailabilityDatabases.Name)
        $chainQuery = "SELECT name, is_db_chaining_on FROM sys.databases;"

        $primaryRows = Invoke-Sqlcmd -ServerInstance $LocalInstance  -Query $chainQuery -ErrorAction Stop
        $targetRows  = Invoke-Sqlcmd -ServerInstance $TargetInstance -Query $chainQuery -ErrorAction Stop

        $primaryMap = @{}; $primaryRows | ForEach-Object { $primaryMap[[string]$_.name] = [bool]$_.is_db_chaining_on }
        $targetMap  = @{}; $targetRows  | ForEach-Object { $targetMap[[string]$_.name]  = [bool]$_.is_db_chaining_on }

        $mismatches = @()
        foreach ($name in $agDbNames) {
            $p = if ($primaryMap.ContainsKey($name)) { $primaryMap[$name] } else { $null }
            $t = if ($targetMap.ContainsKey($name))  { $targetMap[$name]  } else { $null }
            if ($p -ne $t) {
                $mismatches += [pscustomobject]@{ Database = $name; Primary = $p; Target = $t }
            }
        }

        if ($mismatches) {
            Write-Host " -> FAIL: DB_CHAINING differs on the following databases:" -ForegroundColor Red
            $mismatches | Format-Table -AutoSize | Out-String | Write-Host -ForegroundColor Red
            throw "DB_CHAINING differs between replicas; see preceding table."
        }

        Write-Host " -> PASS: DB_CHAINING matches on all $($agDbNames.Count) AG database(s)." -ForegroundColor Green
    } catch {
        Write-Host " -> Failed chaining comparison: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }

    # -------------------------------------------------------------------------
    # STEP 5: Per-database sync state and queue depth
    # -------------------------------------------------------------------------
    Write-Host "`n[5/$TotalSteps] Checking per-database sync state and queue depth on target..." -ForegroundColor Yellow

    # Read per-database state for the TARGET replica directly from the HADR DMVs
    # via Invoke-Sqlcmd. There is no Get-DbaAgDatabaseReplicaState cmdlet (the AG
    # database command is Get-DbaAgDatabase); querying the DMV avoids that phantom
    # dependency and any dbatools-version drift. log_send/redo_queue are in KB;
    # ISNULL guards against DBNull for a row that momentarily lacks a value.
    try {
        $stateQuery = @"
SELECT adc.database_name                   AS DatabaseName,
       drs.synchronization_state_desc      AS SyncState,
       ISNULL(drs.log_send_queue_size, 0)  AS LogSendQueueKB,
       ISNULL(drs.redo_queue_size, 0)      AS RedoQueueKB
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar
     ON ar.replica_id = drs.replica_id
JOIN sys.availability_databases_cluster adc
     ON adc.group_id = drs.group_id AND adc.group_database_id = drs.group_database_id
JOIN sys.availability_groups ag
     ON ag.group_id = drs.group_id
WHERE ag.name = N'$($ag.Name)' AND ar.replica_server_name = N'$TargetInstance';
"@
        $dbStates = Invoke-Sqlcmd -ServerInstance $LocalInstance -Query $stateQuery -ErrorAction Stop
    } catch {
        Write-Host " -> Failed to query database replica state: $($_.Exception.Message)" -ForegroundColor Red
        throw "Failed to query database replica state: $($_.Exception.Message)"
    }

    if (-not $dbStates) {
        Write-Host " -> FAIL: No database replica state rows returned for target '$TargetInstance'." -ForegroundColor Red
        throw "No database replica state rows returned for target '$TargetInstance'."
    }

    $report = @()
    $bad    = @()
    foreach ($d in $dbStates) {
        $row = [pscustomobject]@{
            Database       = $d.DatabaseName
            SyncState      = $d.SyncState
            LogSendQueueKB = $d.LogSendQueueKB
            RedoQueueKB    = $d.RedoQueueKB
        }
        $report += $row

        if ($d.SyncState -ne 'Synchronized')          { $bad += "$($row.Database): SyncState=$($row.SyncState)" }
        if ($d.LogSendQueueKB -gt $MaxLogSendQueueKB)  { $bad += "$($row.Database): LogSendQueue=$($row.LogSendQueueKB)KB > $MaxLogSendQueueKB" }
        if ($d.RedoQueueKB    -gt $MaxRedoQueueKB)     { $bad += "$($row.Database): RedoQueue=$($row.RedoQueueKB)KB > $MaxRedoQueueKB" }
    }

    $report | Format-Table -AutoSize | Out-String | Write-Host

    if ($bad) {
        Write-Host " -> FAIL: One or more databases exceeded thresholds or are not synchronized:" -ForegroundColor Red
        $bad | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
        throw "One or more databases exceeded thresholds or are not synchronized."
    }

    Write-Host " -> PASS: All $(@($dbStates).Count) database(s) synchronized within thresholds." -ForegroundColor Green

    # -------------------------------------------------------------------------
    # Validation summary and gate
    # -------------------------------------------------------------------------
    Write-Host "`n=========================================================" -ForegroundColor Cyan
    Write-Host " ALL VALIDATIONS PASSED"                  -ForegroundColor Green
    Write-Host "   AG:           $($ag.Name)"             -ForegroundColor Green
    Write-Host "   Primary:      $LocalInstance"          -ForegroundColor Green
    Write-Host "   Target:       $TargetInstance"         -ForegroundColor Green
    Write-Host "=========================================================" -ForegroundColor Cyan

    if (-not $Failover) {
        Write-Host "`nValidation-only run (no -Failover supplied). Returning." -ForegroundColor Cyan
        return
    }

    # Final confirmation gate. Even with -Failover, the operator gets one last
    # chance to abort. Pass -Confirm:$false to bypass (for scripted automation).
    $target = "AG '$($ag.Name)': planned failover $LocalInstance -> $TargetInstance"
    if (-not $PSCmdlet.ShouldProcess($target, 'Planned failover (no data loss)')) {
        Write-Host "`nAborted by operator. No failover was performed." -ForegroundColor Yellow
        return
    }

    # -------------------------------------------------------------------------
    # STEP 6: Open PagerDuty maintenance window (best-effort)
    # -------------------------------------------------------------------------
    Write-Host "`n[6/$TotalSteps] Opening PagerDuty maintenance window..." -ForegroundColor Yellow

    if (-not $PagerDutyApiKey) {
        Write-PagerDutyKeyHint
    } else {
        try {
            $PdStartTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            $PdEndTime   = (Get-Date).AddMinutes($MaintenanceDurationMinutes).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

            $PdBody = @{
                maintenance_window = @{
                    type        = "maintenance_window"
                    start_time  = $PdStartTime
                    end_time    = $PdEndTime
                    description = "AG planned failover - $($ag.Name) - $LocalInstance -> $TargetInstance"
                    services    = @( @{ id = $PagerDutyServiceId; type = "service_reference" } )
                }
            } | ConvertTo-Json -Depth 5

            $PdHeaders = @{
                "Authorization" = "Token token=$PagerDutyApiKey"
                "Accept"        = "application/json"
                "Content-Type"  = "application/json"
                "From"          = "opensource@example.com"
            }

            $PdResponse = Invoke-RestMethod -Uri "https://api.pagerduty.com/maintenance_windows" `
                -Method Post -Headers $PdHeaders -Body $PdBody -ErrorAction Stop
            Write-Host " -> Success: Maintenance window created (ID: $($PdResponse.maintenance_window.id))." -ForegroundColor Green
            Write-Host "    Active $PdStartTime -> $PdEndTime UTC." -ForegroundColor Green
        } catch {
            Write-Host " -> WARNING: PagerDuty maintenance window call failed (non-blocking): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # -------------------------------------------------------------------------
    # STEP 7: Issue planned failover from the target replica
    # -------------------------------------------------------------------------
    Write-Host "`n[7/$TotalSteps] Issuing planned failover (no data loss) on '$TargetInstance'..." -ForegroundColor Yellow

    try {
        Invoke-DbaAgFailover -SqlInstance $TargetInstance `
                             -AvailabilityGroup $ag.Name `
                             -Confirm:$false `
                             -EnableException
        Write-Host " -> Success: Failover issued." -ForegroundColor Green
    } catch {
        Write-Host " -> CRITICAL: Failover command failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "    Inspect cluster state with SSMS or Get-DbaAgReplica before retrying." -ForegroundColor Red
        throw "Failover command failed: $($_.Exception.Message)"
    }

    # -------------------------------------------------------------------------
    # STEP 8: Post-failover verification
    # -------------------------------------------------------------------------
    Write-Host "`n[8/$TotalSteps] Waiting 10 seconds for AG state to settle..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10

    try {
        $postRoles = Get-DbaAgReplica -SqlInstance $TargetInstance -AvailabilityGroup $ag.Name -EnableException |
                     Select-Object Name, Role
    } catch {
        Write-Host " -> Failed to verify post-failover state: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "    Inspect cluster state manually." -ForegroundColor Red
        throw "Failed to verify post-failover state: $($_.Exception.Message)"
    }

    $postRoles | Format-Table -AutoSize | Out-String | Write-Host

    $newPrimary   = ($postRoles | Where-Object { $_.Role -eq 'Primary'   }).Name
    $newSecondary = ($postRoles | Where-Object { $_.Role -eq 'Secondary' }).Name
    $expectedSwap = ($newPrimary -eq $TargetInstance) -and ($newSecondary -contains $LocalInstance)

    Write-Host "`n=========================================================" -ForegroundColor Cyan
    if ($expectedSwap) {
        Write-Host " FAILOVER COMPLETE."                  -ForegroundColor Green
        Write-Host "   New Primary:   $TargetInstance"    -ForegroundColor Green
        Write-Host "   New Secondary: $LocalInstance"     -ForegroundColor Green
        Write-Host "=========================================================" -ForegroundColor Cyan
        return
    } else {
        Write-Host " FAILOVER FINISHED WITH UNEXPECTED ROLES." -ForegroundColor Red
        Write-Host "   Inspect the cluster manually before continuing."  -ForegroundColor Red
        Write-Host "=========================================================" -ForegroundColor Cyan
        throw "Failover finished with unexpected role assignments. Inspect cluster manually."
    }
}
