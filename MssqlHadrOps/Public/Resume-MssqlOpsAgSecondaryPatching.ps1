<#
.SYNOPSIS
    Resumes a SQL Server Always On Secondary Node after Windows Updates.
.DESCRIPTION
    1. Resumes the Windows Cluster node from its paused/drained state.
    2. Waits for AG initialization.
    3. Resumes SQL Server data movement for all local AG databases individually
       (with retry logic).
    4. Verifies the synchronization health of the databases.
    5. Closes the PagerDuty maintenance window opened by
       Initialize-MssqlOpsAgSecondaryPatching, if any DBs are healthy.
.PARAMETER PagerDutyApiKey
    PagerDuty REST API key. Resolved at runtime in this order:
      1) explicit -PagerDutyApiKey value, 2) Get-Secret -Name PAGERDUTY_USER_API_TOKEN
      from the per-Windows-user SecretStore vault (recommended), 3) $env:PAGERDUTY_USER_API_TOKEN.
    Used in the final step to close the maintenance window opened by
    Initialize-MssqlOpsAgSecondaryPatching. If no key is found, the close
    step is skipped and the window expires on its own.
    Run Set-MssqlOpsPagerDutyUserApiToken once per server to populate the vault.
.PARAMETER PagerDutyServiceId
    PagerDuty service id whose maintenance window should be closed. Defaults to
    the module-level value set in MssqlHadrOps.psm1 ('PDSERVICE' - AppDb
    Messaging Database). Override only when targeting a different service.
.PARAMETER ClusterRejoinTimeoutSeconds
    How long to wait for the WSFC node to reach a stable State='Up' before
    giving up. Default 600 (10 min). The ID 2026-06-08 incident showed a
    ~6-minute service Up/Down cycle during witness arbitration retries; a
    fixed Start-Sleep masked that. This wait uses a "stable for N consecutive
    polls" guard to ensure we only proceed once the node has actually settled.
.NOTES
    Version:        2.1
    Last Modified:  2026-06-11
    Author:         original module author
    Changes:        2.1 - Replaced the fixed 5s post-Resume-ClusterNode sleep
                          with Wait-MssqlOpsClusterNodeReady (poll for N
                          consecutive Up readings). Addresses the ID
                          2026-06-08 failure mode where the node oscillated
                          Up/Down during witness arbitration retries and a
                          fixed sleep would have falsely declared "ready".
                    2.0 - Refactored from script to function inside MssqlHadrOps module.
                    1.3 - Close PagerDuty maintenance window after sync verified.
                    1.2 - Added versioning, converted to individual database loop,
                          added stabilization delay, and added a 3-attempt retry
                          loop for resuming.
#>
function Resume-MssqlOpsAgSecondaryPatching {
    [CmdletBinding()]
    param(
        [string]$PagerDutyApiKey,
        [string]$PagerDutyServiceId       = $script:PagerDutyServiceId,
        [int]$ClusterRejoinTimeoutSeconds = 600
    )

    $FunctionVersion = "2.1"

    $NodeName    = $env:COMPUTERNAME
    $SqlInstance = $NodeName # Change to "$NodeName\InstanceName" if using a named instance

    $PagerDutyApiKey = Resolve-PagerDutyApiKey -Initial $PagerDutyApiKey

    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host " MssqlHadrOps v$FunctionVersion" -ForegroundColor Cyan
    Write-Host " Starting Post-Update Resume for Secondary Node: $NodeName" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan

    # -------------------------------------------------------------------------
    # STEP 1: Un-pause the WSFC Node
    # -------------------------------------------------------------------------
    Write-Host "`n[1/5] Resuming Windows Cluster node..." -ForegroundColor Yellow
    $ClusterNode = Get-ClusterNode -Name $NodeName
    if ($ClusterNode.State -eq 'Paused') {
        try {
            Resume-ClusterNode -Name $NodeName | Out-Null
            Write-Host " -> Success: Node is active in the cluster again." -ForegroundColor Green
        } catch {
            Write-Host " -> Failed to resume cluster node. Check WSFC service." -ForegroundColor Red
            throw
        }
    } else {
        Write-Host " -> Node is already active (State: $($ClusterNode.State)). Skipping resume." -ForegroundColor Green
    }

    # -------------------------------------------------------------------------
    # STEP 2: Wait for the node to reach a STABLE State='Up'
    #   The ID 2026-06-08 incident showed db5 oscillating Up/Down for ~6 min
    #   while WSFC retried witness arbitration. A fixed Start-Sleep would have
    #   returned during a transient Up window and let the rest of resume run
    #   while the cluster was still arbitrating. Wait-MssqlOpsClusterNodeReady
    #   requires N consecutive Up readings (default 3 x 5s = 15s of stability).
    # -------------------------------------------------------------------------
    Write-Host "`n[2/5] Waiting for cluster node to reach stable State='Up'..." -ForegroundColor Yellow
    try {
        $stableNode = Wait-MssqlOpsClusterNodeReady -NodeName $NodeName -TimeoutSeconds $ClusterRejoinTimeoutSeconds
        Write-Host " -> Node '$NodeName' stable (State=$($stableNode.State), NodeWeight=$($stableNode.NodeWeight))." -ForegroundColor Green
    } catch {
        Write-Host " -> CRITICAL: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }

    # -------------------------------------------------------------------------
    # STEP 3: Resume AG Data Movement (Individual Loop with Retries)
    # -------------------------------------------------------------------------
    Write-Host "`n[3/5] Resuming SQL Server AG Data Movement locally..." -ForegroundColor Yellow

    try {
        $Databases = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "SELECT database_name FROM sys.availability_databases_cluster;" -ErrorAction Stop

        foreach ($db in $Databases) {
            $dbName = $db.database_name
            $ResumeQuery = "ALTER DATABASE [$dbName] SET HADR RESUME;"

            $RetryCount = 0
            $MaxRetries = 3
            $Success = $false

            while (-not $Success -and $RetryCount -lt $MaxRetries) {
                try {
                    Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $ResumeQuery -QueryTimeout 30 -ErrorAction Stop
                    Write-Host " -> Success: Resumed data movement for $dbName" -ForegroundColor Green
                    $Success = $true
                } catch {
                    $RetryCount++
                    if ($RetryCount -lt $MaxRetries) {
                        Write-Host " -> Attempt $RetryCount failed for $dbName. Database may be starting. Retrying in 5 seconds..." -ForegroundColor DarkYellow
                        Start-Sleep -Seconds 5
                    } else {
                        Write-Host " -> WARNING: Could not resume $dbName after $MaxRetries attempts." -ForegroundColor Red
                        Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor DarkGray
                    }
                }
            }
        }
    } catch {
        Write-Host " -> CRITICAL: Failed to query availability databases. Is SQL Server running?" -ForegroundColor Red
        throw
    }

    # -------------------------------------------------------------------------
    # STEP 4: Verify Health State
    # -------------------------------------------------------------------------
    Write-Host "`n[4/5] Verifying Database Synchronization State..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10 # Give SQL a few seconds to process the resumes

    $VerifyQuery = @"
SELECT
    db_name(database_id) AS DatabaseName,
    synchronization_state_desc AS SyncState,
    suspend_reason_desc AS SuspendReason
FROM sys.dm_hadr_database_replica_states
WHERE is_local = 1;
"@

    $ReplicaStates = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $VerifyQuery

    $AllHealthy = $true
    foreach ($Db in $ReplicaStates) {
        if ($Db.SyncState -match "SYNCHRONIZING|SYNCHRONIZED") {
            Write-Host " -> $($Db.DatabaseName): $($Db.SyncState)" -ForegroundColor Green
        } else {
            Write-Host " -> WARNING: $($Db.DatabaseName) is $($Db.SyncState) (Reason: $($Db.SuspendReason))" -ForegroundColor Red
            $AllHealthy = $false
        }
    }

    # -------------------------------------------------------------------------
    # STEP 5: Close PagerDuty maintenance window opened for this server
    # -------------------------------------------------------------------------
    Write-Host "`n[5/5] Closing PagerDuty maintenance window for $NodeName..." -ForegroundColor Yellow

    if (-not $PagerDutyApiKey) {
        Write-PagerDutyKeyHint
    } elseif (-not $AllHealthy) {
        Write-Host " -> SKIP: One or more databases not healthy. Leaving the maintenance" -ForegroundColor Yellow
        Write-Host "    window open so alerts stay suppressed while you investigate." -ForegroundColor Yellow
    } else {
        try {
            $PdHeaders = @{
                "Authorization" = "Token token=$PagerDutyApiKey"
                "Accept"        = "application/json"
                "Content-Type"  = "application/json"
                "From"          = "opensource@example.com"
            }

            # Filter to maintenance windows currently in progress for this service.
            $listUri  = "https://api.pagerduty.com/maintenance_windows?service_ids%5B%5D=$PagerDutyServiceId&filter=ongoing"
            $listResp = Invoke-RestMethod -Uri $listUri -Method Get -Headers $PdHeaders -ErrorAction Stop

            # Scope to windows whose description names this server (Initialize- writes "$NodeName" into it).
            $mine = $listResp.maintenance_windows | Where-Object { $_.description -like "*$NodeName*" }

            if (-not $mine) {
                Write-Host " -> No active maintenance window found for $NodeName. Nothing to close." -ForegroundColor Green
            } else {
                $w = $mine | Sort-Object -Property start_time -Descending | Select-Object -First 1

                $endNow = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                $body   = @{
                    maintenance_window = @{
                        type     = "maintenance_window"
                        end_time = $endNow
                    }
                } | ConvertTo-Json -Depth 5

                Invoke-RestMethod -Uri "https://api.pagerduty.com/maintenance_windows/$($w.id)" `
                    -Method Put -Headers $PdHeaders -Body $body -ErrorAction Stop | Out-Null
                Write-Host " -> Success: Maintenance window $($w.id) ended early at $endNow UTC." -ForegroundColor Green
            }
        } catch {
            Write-Host " -> WARNING: Failed to close PagerDuty maintenance window (non-blocking): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    Write-Host "`n=========================================================" -ForegroundColor Cyan
    if ($AllHealthy) {
        Write-Host " RESUME COMPLETE: Node is healthy and catching up." -ForegroundColor Green
    } else {
        Write-Host " RESUME FINISHED WITH WARNINGS: Check SSMS for database states." -ForegroundColor Yellow
    }
    Write-Host "=========================================================`n" -ForegroundColor Cyan
}
