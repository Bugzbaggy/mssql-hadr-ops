<#
.SYNOPSIS
    Detects in-flight transaction states that will STALL a planned AG state
    change (suspend / drain / failover): stuck KILLED/ROLLBACK sessions,
    long-running open transactions, and sustained blocking chains.
.DESCRIPTION
    Returns a [pscustomobject] with .Risky (bool), .Sessions (offending rows),
    and .ProbeError (string or $null). Reads ONLY server-scoped DMVs
    (sys.dm_exec_requests / sys.dm_exec_sessions), so it never touches an
    availability database and is safe to run even while a replica database is
    transitioning / inaccessible.

    Why this exists: on 2026-09-10 the weekly stats job
    'AppDb_Data: job_MessageLog_CalculateStats_DW' was mid-run on AppDb_Data when
    the AG failed over. Its in-flight transaction became the blocker the AG
    state change repeatedly killed (ABORT_AFTER_WAIT = BLOCKERS) and rolled back
    at 0%, so AppDb_Data and three sibling DBs would not synchronize on the new
    secondary. Detecting this BEFORE the suspend/drain lets the operator quiesce
    the owning job first instead of discovering the stall mid-maintenance.
.PARAMETER SqlInstance
    Target instance. Default: local machine (default instance).
.PARAMETER LongRunningSeconds
    Threshold (seconds) above which an open transaction or a sustained block is
    treated as a risk. KILLED/ROLLBACK is always a risk regardless of duration.
    Default 60.
#>
function Test-MssqlOpsBlockingTransaction {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$SqlInstance = $env:COMPUTERNAME,
        [int]$LongRunningSeconds = 60
    )

    $ms = $LongRunningSeconds * 1000

    # Server-scoped DMVs only; select database_id (int) rather than DB_NAME() so
    # we never resolve/open a transitioning availability database. The OUTER
    # APPLY reads the open transaction's written-log size so the long-running
    # branch fires only for WRITERS (which stall on rollback during the AG state
    # change) and not for benign long-running readers on a readable secondary.
    $query = @"
SELECT  r.session_id                                       AS SessionId,
        r.database_id                                      AS DatabaseId,
        r.command                                          AS Command,
        r.status                                           AS Status,
        r.blocking_session_id                              AS BlockedBy,
        CAST(r.total_elapsed_time / 1000.0 AS decimal(12,1)) AS ElapsedSeconds,
        ISNULL(w.LogBytesUsed, 0)                          AS LogBytesUsed,
        ISNULL(s.login_name, '')                           AS LoginName,
        ISNULL(s.program_name, '')                         AS ProgramName,
        CASE
            WHEN r.command LIKE 'KILLED%'                                    THEN 'StuckRollback'
            WHEN r.blocking_session_id <> 0 AND r.total_elapsed_time > $ms   THEN 'SustainedBlock'
            ELSE 'LongWriteTransaction'
        END                                                AS Risk
FROM    sys.dm_exec_requests r
JOIN    sys.dm_exec_sessions s ON s.session_id = r.session_id
OUTER APPLY (
    SELECT MAX(dt.database_transaction_log_bytes_used) AS LogBytesUsed
    FROM   sys.dm_tran_session_transactions st
    JOIN   sys.dm_tran_database_transactions dt ON dt.transaction_id = st.transaction_id
    WHERE  st.session_id = r.session_id
) w
WHERE   r.command LIKE 'KILLED%'
   OR  (r.blocking_session_id <> 0 AND r.total_elapsed_time > $ms)
   OR  (s.open_transaction_count > 0 AND r.total_elapsed_time > $ms AND s.is_user_process = 1 AND ISNULL(w.LogBytesUsed, 0) > 0);
"@

    try {
        $rows = @(Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $query -QueryTimeout 30 -ErrorAction Stop)
    } catch {
        # Never hard-block prep on an inability to run the probe itself; the
        # caller surfaces ProbeError as a (non-blocking) warning.
        return [pscustomobject]@{ Risky = $false; Sessions = @(); ProbeError = $_.Exception.Message }
    }

    [pscustomobject]@{
        Risky      = ($rows.Count -gt 0)
        Sessions   = $rows
        ProbeError = $null
    }
}
