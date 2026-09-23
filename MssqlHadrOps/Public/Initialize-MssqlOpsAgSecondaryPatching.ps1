<#
.SYNOPSIS
    Prepares a SQL Server Always On Secondary Node for patching.
.DESCRIPTION
    Windows mode (default) - for OS patches that require a reboot:
      1. Validates that the local node is NOT the Primary replica.
      2. Cluster readiness gate (peers Up, witness Online + SMB-reachable from
         this node, no AG in Resolving, no CAU run in progress).
      3. Blocking/stuck-transaction gate (no KILLED/ROLLBACK session, long-running
         open transaction, or sustained block that would stall the AG suspend).
      4. Opens a PagerDuty maintenance window for the appdb-databases service.
      5. Suspends SQL Server AG data movement FIRST (decouples the primary).
      6. Moves the Core Cluster Group off this node if it owns it.
      7. Pauses and drains the Windows Cluster node.
      8. Refreshes cloud system components while drained (AWS ENA/NVMe + agents,
         or GCP gVNIC/vioscsi + agents).

    SqlCU mode - for SQL Server Cumulative Updates:
      1. Validates that the local node is NOT the Primary replica.
      2. Cluster readiness gate.
      3. Blocking/stuck-transaction gate.
      4. Opens a PagerDuty maintenance window for the appdb-databases service.
      5. Suspends SQL Server AG data movement (cluster node stays online).
      6. Refreshes cloud agents only (no disruptive drivers while online).
      7. Confirms the node is ready; the cluster node must remain online
         during CU setup.
.PARAMETER Mode
    Patching mode. 'Windows' pauses the cluster node and suspends AG data
    movement - required before OS updates. 'SqlCU' keeps the cluster node
    online (required by the SQL Server CU installer) but still suspends AG
    data movement explicitly. If omitted, the user is prompted to choose
    interactively.
.PARAMETER PagerDutyApiKey
    PagerDuty REST API key. Resolved at runtime in this order:
      1) explicit -PagerDutyApiKey value, 2) Get-Secret -Name PAGERDUTY_USER_API_TOKEN
      from the per-Windows-user SecretStore vault (recommended), 3) $env:PAGERDUTY_USER_API_TOKEN.
    Run Set-MssqlOpsPagerDutyUserApiToken once per server to populate the vault.
.PARAMETER PagerDutyServiceId
    PagerDuty service id used for the maintenance window. Defaults to the
    module-level value set in MssqlHadrOps.psm1 ('PDSERVICE' - AppDb Messaging
    Database). Override only when targeting a different service.
.PARAMETER MaintenanceDurationMinutes
    Length of the PagerDuty maintenance window in minutes. Default: 30.
.PARAMETER SkipClusterReadinessGate
    Bypass the WSFC + witness + AG readiness gate added in 2.2. Use only when
    you have a documented reason to override (e.g. an already-degraded cluster
    that you intend to patch out of). Default off.
.PARAMETER SkipBlockingTransactionCheck
    Bypass the blocking/stuck-transaction gate added in 2.5. That gate aborts
    prep when a KILLED/ROLLBACK session, a long-running open transaction, or a
    sustained block is present on this node, because those stall the AG
    suspend/drain (the AG kills the blocker and loops on rollback). Use only
    after you have assessed the sessions and accept the risk. Default off.
.PARAMETER SkipCloudComponentUpdate
    Skip the cloud system-component refresh added in 2.3 (AWS: SSM Agent,
    EC2Launch, and - in Windows mode - NVMe/ENA drivers; GCP: guest agent and,
    in Windows mode, the gVNIC/netkvm/vioscsi drivers via GooGet). The refresh
    is already a clean no-op off AWS/GCP, so this is only for deliberately
    deferring it on a cloud node. Default off.
.PARAMETER CloudComponentSource
    Optional per-cloud source passed through to Update-MssqlOpsCloudSystemComponent
    -Source: on AWS a directory of pre-staged installer files; on GCP a GooGet
    repository URL/path. Use on firewalled hosts. Ignored by the non-matching
    cloud.
.PARAMETER RequireCloudComponentUpdate
    Turn the cloud component refresh into a HARD GATE: on an AWS/GCP host, abort
    the whole prep if any component fails. Use this before a WS2025 in-place OS
    upgrade - booting the new OS on stale network/storage drivers (ENA/NVMe on
    AWS, gVNIC/vioscsi on GCP) yields a node with no network or no boot disk.
    Default off (best-effort) so routine monthly patching is not blocked by a
    transient repo/S3 hiccup.
.NOTES
    Version:        2.5
    Last Modified:  2026-09-10
    Author:         original module author
    Changes:        2.5 - Added a blocking / stuck-transaction gate
                          (Test-MssqlOpsBlockingTransaction) BEFORE the suspend.
                          A KILLED/ROLLBACK session, a long-running open
                          transaction, or a sustained block on this node stalls
                          the ALTER DATABASE ... SET HADR change - the AG kills
                          the blocker (ABORT_AFTER_WAIT=BLOCKERS) and loops on
                          rollback, leaving databases NOT SYNCHRONIZING (observed
                          2026-09-10 when a stats job was mid-run on AppDb_Data
                          during a failover). Aborts unless
                          -SkipBlockingTransactionCheck.
                    2.4 - PRIMARY-SAFE ORDERING (Windows mode): suspend AG data
                          movement FIRST (decouple the primary) before moving the
                          core cluster group and draining the node. The prior
                          order drained the node while the AG was still
                          synchronous, exposing the primary's writes during the
                          drain window (observed as a DB-call-failure spike on
                          2026-08-18). SqlCU mode already suspended before any
                          disruptive step, so it was unaffected.
                    2.3 - Refresh cloud system components as part of prep
                          (Update-MssqlOpsCloudSystemComponent - dispatches to
                          the AWS or GCP updater by platform). Windows mode
                          refreshes drivers + agents while the node is drained;
                          SqlCU mode refreshes agents only (node stays online -
                          never drop the NIC). No-op off AWS/GCP.
                          -RequireCloudComponentUpdate makes it a hard gate for
                          major OS upgrades.
                    2.2 - Added cluster readiness gate (Test-MssqlOpsClusterReadiness)
                          BEFORE the PagerDuty window/node pause. Closes a gap
                          exposed by the ID 2026-06-08 RESOLVING incident: the
                          existing AG-only preflights do not test SMB
                          reachability of the witness share from this node, do
                          not interlock against a peer already Paused/Drained,
                          and do not surface another AG in Resolving role.
                    2.1 - SqlCU mode now also suspends AG data movement (the
                          cluster node still stays online for the CU installer).
                    2.0 - Refactored from script to function inside MssqlHadrOps module.
                    1.4 - Resolve PagerDuty API key via shared PagerDutyHelpers.ps1
                          (SecretStore PAGERDUTY_USER_API_TOKEN first, then env-var fallback).
                    1.3 - Added -Mode parameter (Windows / SqlCU) to support both OS
                          and SQL Server CU patching workflows.
#>
function Initialize-MssqlOpsAgSecondaryPatching {
    [CmdletBinding()]
    param(
        [string]$Mode,
        [string]$PagerDutyApiKey,
        [string]$PagerDutyServiceId      = $script:PagerDutyServiceId,
        [int]$MaintenanceDurationMinutes = 30,
        [switch]$SkipClusterReadinessGate,
        [switch]$SkipBlockingTransactionCheck,
        [switch]$SkipCloudComponentUpdate,
        [string]$CloudComponentSource,
        [switch]$RequireCloudComponentUpdate
    )

    $FunctionVersion = "2.5"

    $PagerDutyApiKey = Resolve-PagerDutyApiKey -Initial $PagerDutyApiKey

    if (-not $Mode) {
        Write-Host "`nSelect patching mode:" -ForegroundColor Cyan
        Write-Host "  [1] Windows  - OS updates: pauses cluster node, suspends AG data movement" -ForegroundColor White
        Write-Host "  [2] SqlCU    - SQL Server CU: cluster stays online, installer manages AG"  -ForegroundColor White
        $choice = Read-Host "Enter 1 or 2"
        $Mode = switch ($choice) {
            '1' { 'Windows' }
            '2' { 'SqlCU' }
            default {
                Write-Host " -> Invalid choice. Aborting." -ForegroundColor Red
                throw "Invalid mode choice; expected 1 or 2."
            }
        }
    }

    if ($Mode -notin @('Windows', 'SqlCU')) {
        Write-Host " -> Invalid -Mode value '$Mode'. Use 'Windows' or 'SqlCU'." -ForegroundColor Red
        throw "Invalid -Mode '$Mode'. Use 'Windows' or 'SqlCU'."
    }

    $TotalSteps = if ($Mode -eq 'SqlCU') { 7 } else { 8 }

    $NodeName    = $env:COMPUTERNAME
    $SqlInstance = $NodeName # Change to "$NodeName\InstanceName" if using a named instance

    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host " MssqlHadrOps v$FunctionVersion  |  Mode: $Mode" -ForegroundColor Cyan
    Write-Host " Starting Pre-Patch Prep for Secondary Node: $NodeName" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan

    # Nested helper: run the cloud component refresh with this call's options
    # and render a compact per-component result. Dispatches AWS/GCP by platform.
    # Values are passed in explicitly (not captured from parent scope) so the
    # data flow is clear and statically analyzable. No-op off AWS/GCP.
    function Invoke-MssqlOpsCloudUpdateStep {
        param(
            [ValidateSet('Agents', 'Drivers', 'All')][string]$Scope,
            [bool]$Skip,
            [string]$Source,
            [bool]$Require
        )

        if ($Skip) {
            Write-Host " -> SKIPPED by -SkipCloudComponentUpdate." -ForegroundColor Yellow
            return
        }

        $cloudParams = @{ Scope = $Scope }
        if ($Source)  { $cloudParams.Source = $Source }
        if ($Require) { $cloudParams.RequireSuccess = $true }

        # -RequireCloudComponentUpdate must abort prep on failure, so let it throw.
        # Otherwise the refresh is best-effort and non-blocking.
        if ($Require) {
            $cloud = Update-MssqlOpsCloudSystemComponent @cloudParams
        } else {
            try {
                $cloud = Update-MssqlOpsCloudSystemComponent @cloudParams
            } catch {
                Write-Host " -> WARNING: cloud component update error (non-blocking): $($_.Exception.Message)" -ForegroundColor Yellow
                return
            }
        }

        if (-not $cloud.Managed) { return }   # non-cloud message already emitted by the updater

        foreach ($r in $cloud.Results) {
            $col = switch ($r.Action) { 'Failed' { 'Red' } 'Installed' { 'Green' } default { 'DarkGray' } }
            Write-Host ("    {0,-45} {1,-9} {2} -> {3}" -f $r.Name, $r.Action, ($r.FromVersion ?? 'n/a'), ($r.ToVersion ?? 'n/a')) -ForegroundColor $col
        }

        if ($Scope -eq 'Agents') {
            Write-Host "    NOTE: disruptive network/storage driver refresh is skipped in SqlCU mode (NIC drop / reboot). Use a Windows-mode maintenance to update them." -ForegroundColor DarkYellow
        } elseif ($cloud.RebootRequired) {
            Write-Host " -> $($cloud.Platform) drivers updated; a reboot is required (the upcoming OS / Windows Update reboot will satisfy it)." -ForegroundColor Green
        } else {
            Write-Host " -> $($cloud.Platform) components already current." -ForegroundColor Green
        }
    }

    # -------------------------------------------------------------------------
    # STEP 1: Validate Node Role (Must NOT be Primary)
    # -------------------------------------------------------------------------
    Write-Host "`n[1/$TotalSteps] Validating local Availability Group role..." -ForegroundColor Yellow

    $RoleQuery = "SELECT role_desc FROM sys.dm_hadr_availability_replica_states WHERE is_local = 1;"

    try {
        $ReplicaRoles = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $RoleQuery -ErrorAction Stop

        $IsPrimary = $false
        if ($ReplicaRoles) {
            foreach ($Role in $ReplicaRoles) {
                if ($Role.role_desc -eq 'PRIMARY') { $IsPrimary = $true }
            }
        }

        if ($IsPrimary) {
            Write-Host " -> DANGER: This node is currently the PRIMARY replica!" -ForegroundColor Red
            Write-Host " -> ABORTING. Failover the Availability Group before patching." -ForegroundColor Red
            throw "Local node is PRIMARY; failover before patching."
        } else {
            Write-Host " -> Safe: This node is acting as a SECONDARY replica." -ForegroundColor Green
        }
    } catch {
        Write-Host " -> Error checking AG role. Ensure SQL Server is running and accessible." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        throw
    }

    # -------------------------------------------------------------------------
    # STEP 2: Cluster readiness gate
    #   Refuses to begin a patch when the witness share isn't SMB-reachable
    #   from this node, another peer is already Paused/Drained, any AG is in
    #   Resolving role, or a CAU run is mid-flight. The cluster.log on
    #   region2-node5 during the 2026-06-08 RESOLVING incident shows these are
    #   the precursor signals worth blocking on before adding another paused
    #   node to the topology.
    # -------------------------------------------------------------------------
    Write-Host "`n[2/$TotalSteps] Running cluster readiness gate..." -ForegroundColor Yellow

    if ($SkipClusterReadinessGate) {
        Write-Host " -> SKIPPED by -SkipClusterReadinessGate (operator override)." -ForegroundColor Yellow
    } else {
        $gate = Test-MssqlOpsClusterReadiness -LocalInstance $SqlInstance
        foreach ($w in $gate.Warnings) {
            Write-Host "    WARN: $w" -ForegroundColor DarkYellow
        }
        if (-not $gate.Healthy) {
            Write-Host " -> FAIL: Cluster is not ready for patching:" -ForegroundColor Red
            foreach ($f in $gate.Failures) {
                Write-Host "    - $f" -ForegroundColor Red
            }
            throw "Cluster readiness gate failed; refusing to patch. Pass -SkipClusterReadinessGate to override (rare)."
        }
        Write-Host " -> PASS: Cluster, witness, and AGs are healthy." -ForegroundColor Green
    }

    # -------------------------------------------------------------------------
    # STEP 3: Blocking / stuck-transaction gate
    #   A KILLED/ROLLBACK session, a long-running open transaction, or a
    #   sustained block on this node will stall the ALTER DATABASE ... SET HADR
    #   suspend below: the AG state change kills the blocker (ABORT_AFTER_WAIT=
    #   BLOCKERS) and loops on rollback, leaving databases NOT SYNCHRONIZING.
    #   Catch it here so the operator can quiesce the owner (e.g. stop the SQL
    #   Agent job) before we touch AG/cluster state. Server-scoped DMVs only, so
    #   it is safe even while a replica database is transitioning.
    # -------------------------------------------------------------------------
    Write-Host "`n[3/$TotalSteps] Checking for blocking / stuck transactions..." -ForegroundColor Yellow

    if ($SkipBlockingTransactionCheck) {
        Write-Host " -> SKIPPED by -SkipBlockingTransactionCheck (operator override)." -ForegroundColor Yellow
    } else {
        $txn = Test-MssqlOpsBlockingTransaction -SqlInstance $SqlInstance
        if ($txn.ProbeError) {
            Write-Host " -> WARNING: could not run the blocking-transaction probe (non-blocking): $($txn.ProbeError)" -ForegroundColor DarkYellow
        } elseif ($txn.Risky) {
            Write-Host " -> DANGER: transaction state that WILL stall the AG suspend/drain:" -ForegroundColor Red
            foreach ($r in $txn.Sessions) {
                Write-Host ("    spid {0}  {1,-19} elapsed {2}s  db_id {3}  {4} {5}" -f `
                    $r.SessionId, $r.Risk, $r.ElapsedSeconds, $r.DatabaseId, $r.LoginName, $r.ProgramName) -ForegroundColor Red
            }
            Write-Host " -> The ALTER DATABASE ... SET HADR change will kill these (ABORT_AFTER_WAIT=BLOCKERS) and loop on rollback." -ForegroundColor Red
            Write-Host "    Quiesce them first (stop the owning SQL Agent job, or let the rollback finish), then re-run." -ForegroundColor Red
            throw "Blocking/stuck transactions present; refusing to start patch prep. Resolve them, or pass -SkipBlockingTransactionCheck to override (rare)."
        } else {
            Write-Host " -> PASS: no stuck rollbacks, long-running transactions, or sustained blocks." -ForegroundColor Green
        }
    }

    # -------------------------------------------------------------------------
    # STEP 4: Create PagerDuty Maintenance Window
    # -------------------------------------------------------------------------
    Write-Host "`n[4/$TotalSteps] Creating PagerDuty maintenance window..." -ForegroundColor Yellow

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
                    description = "DB patching ($Mode) - $NodeName"
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
            $PdWindowId = $PdResponse.maintenance_window.id
            Write-Host " -> Success: Maintenance window created (ID: $PdWindowId)." -ForegroundColor Green
            Write-Host "    Active $PdStartTime -> $PdEndTime UTC." -ForegroundColor Green
        } catch {
            Write-Host " -> WARNING: PagerDuty maintenance window call failed (non-blocking): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # -------------------------------------------------------------------------
    # MODE BRANCH
    # -------------------------------------------------------------------------
    if ($Mode -eq 'SqlCU') {

        # ---------------------------------------------------------------------
        # STEP 5 (SqlCU): Suspend AG Data Movement
        # ---------------------------------------------------------------------
        Write-Host "`n[5/$TotalSteps] Suspending SQL Server AG Data Movement locally..." -ForegroundColor Yellow

        $SuspendQuery = @"
DECLARE @dbName NVARCHAR(128);
DECLARE db_cursor CURSOR FOR
    SELECT database_name FROM sys.availability_databases_cluster;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @dbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE @sql NVARCHAR(MAX) = 'ALTER DATABASE [' + @dbName + '] SET HADR SUSPEND;';
    EXEC sp_executesql @sql;
    PRINT 'Suspended data movement for: ' + @dbName;
    FETCH NEXT FROM db_cursor INTO @dbName;
END;

CLOSE db_cursor;
DEALLOCATE db_cursor;
"@

        try {
            Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $SuspendQuery -QueryTimeout 120 -ErrorAction Stop
            Write-Host " -> Success: All Availability Group databases suspended." -ForegroundColor Green
        } catch {
            Write-Host " -> Error suspending databases. Please verify manually in SSMS." -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red
        }

        # ---------------------------------------------------------------------
        # STEP 6 (SqlCU): Keep cloud agents current (safe; no reboot / no NIC drop)
        #   Disruptive drivers (AWS ENA/NVMe, GCP gVNIC/vioscsi) are deliberately
        #   NOT touched here: the cluster node stays online in SqlCU mode and a
        #   network-driver reinstall drops the NIC. Refresh drivers in a
        #   Windows-mode maintenance (node drained). No-op off AWS/GCP.
        # ---------------------------------------------------------------------
        Write-Host "`n[6/$TotalSteps] Updating cloud system components (agents only)..." -ForegroundColor Yellow
        Invoke-MssqlOpsCloudUpdateStep -Scope 'Agents' -Skip $SkipCloudComponentUpdate -Source $CloudComponentSource -Require $RequireCloudComponentUpdate

        # ---------------------------------------------------------------------
        # STEP 7 (SqlCU): Node is ready for CU installation
        # ---------------------------------------------------------------------
        Write-Host "`n[7/$TotalSteps] Node is ready for SQL Server CU installation." -ForegroundColor Yellow
        Write-Host " -> The cluster node must remain ONLINE during CU setup." -ForegroundColor Green

        Write-Host "`n=========================================================" -ForegroundColor Cyan
        Write-Host " PREPARATION COMPLETE (SqlCU mode)." -ForegroundColor Green
        Write-Host " Run the SQL Server CU installer now." -ForegroundColor Green
        Write-Host " Do NOT pause or drain the cluster node before running setup." -ForegroundColor Green
        Write-Host "=========================================================`n" -ForegroundColor Cyan

    } else {

        # ---------------------------------------------------------------------
        # STEP 5 (Windows): Suspend AG Data Movement FIRST (decouple the primary)
        #   This MUST happen before any cluster-level operation. Suspending data
        #   movement makes the primary stop synchronizing with / waiting on this
        #   replica, so the subsequent core-group move and node drain cannot
        #   disrupt the primary's commits. The previous order drained the node
        #   while the AG was still synchronous, leaving a window where operations
        #   on this (secondary) node could stall the primary's writes.
        # ---------------------------------------------------------------------
        Write-Host "`n[5/$TotalSteps] Suspending SQL Server AG Data Movement locally (decoupling the primary)..." -ForegroundColor Yellow

        $SuspendQuery = @"
DECLARE @dbName NVARCHAR(128);
DECLARE db_cursor CURSOR FOR
    SELECT database_name FROM sys.availability_databases_cluster;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @dbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE @sql NVARCHAR(MAX) = 'ALTER DATABASE [' + @dbName + '] SET HADR SUSPEND;';
    EXEC sp_executesql @sql;
    PRINT 'Suspended data movement for: ' + @dbName;
    FETCH NEXT FROM db_cursor INTO @dbName;
END;

CLOSE db_cursor;
DEALLOCATE db_cursor;
"@

        try {
            Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $SuspendQuery -QueryTimeout 120 -ErrorAction Stop
            Write-Host " -> Success: All Availability Group databases suspended; primary is decoupled from this node." -ForegroundColor Green
        } catch {
            Write-Host " -> Error suspending databases. Please verify manually in SSMS." -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red
        }

        # ---------------------------------------------------------------------
        # STEP 6 (Windows): Safeguard the File Share Witness (Move Cluster Group)
        # ---------------------------------------------------------------------
        Write-Host "`n[6/$TotalSteps] Verifying Cluster Core Resources ownership..." -ForegroundColor Yellow
        $ClusterGroup = Get-ClusterGroup -Name "Cluster Group"

        if ($ClusterGroup.OwnerNode.Name -eq $NodeName) {
            Write-Host " -> Moving Core Cluster Group to a surviving node safely..." -ForegroundColor Yellow
            Move-ClusterGroup -Name "Cluster Group" | Out-Null
            Write-Host " -> Success: Cluster Group safely moved." -ForegroundColor Green
        } else {
            Write-Host " -> Safe: Core Cluster Group is already owned by $($ClusterGroup.OwnerNode.Name)." -ForegroundColor Green
        }

        # ---------------------------------------------------------------------
        # STEP 7 (Windows): Pause and Drain the WSFC Node
        #   Safe now that the primary is already decoupled (STEP 5): the drain
        #   can no longer affect the primary's commits.
        # ---------------------------------------------------------------------
        Write-Host "`n[7/$TotalSteps] Pausing node and draining remaining cluster roles..." -ForegroundColor Yellow
        Suspend-ClusterNode -Name $NodeName -Drain -Wait | Out-Null
        Write-Host " -> Success: Node is paused. No failovers will attempt to route here." -ForegroundColor Green

        # ---------------------------------------------------------------------
        # STEP 8 (Windows): Refresh cloud components while the node is drained
        #   This is the safe point for the disruptive drivers: AG data movement
        #   is already suspended (STEP 5) and no cluster roles are hosted here,
        #   so the network-driver NIC drop and the storage-driver reboot are
        #   harmless. Dispatches AWS (ENA/NVMe) or GCP (gVNIC/vioscsi) by
        #   platform. MANDATORY before a WS2025 in-place upgrade (pass
        #   -RequireCloudComponentUpdate to make it a hard gate). No-op off cloud.
        # ---------------------------------------------------------------------
        Write-Host "`n[8/$TotalSteps] Updating cloud system components (drivers + agents)..." -ForegroundColor Yellow
        Invoke-MssqlOpsCloudUpdateStep -Scope 'All' -Skip $SkipCloudComponentUpdate -Source $CloudComponentSource -Require $RequireCloudComponentUpdate

        Write-Host "`n=========================================================" -ForegroundColor Cyan
        Write-Host " PREPARATION COMPLETE (Windows mode)." -ForegroundColor Green
        Write-Host " You may now safely install Windows Updates and reboot." -ForegroundColor Green
        Write-Host "=========================================================`n" -ForegroundColor Cyan
    }
}
