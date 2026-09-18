<#
.SYNOPSIS
    Waits for a WSFC node to fully rejoin the cluster after Resume-ClusterNode.
.DESCRIPTION
    Resume-ClusterNode returns as soon as the node is no longer Paused, but
    that does not mean the cluster service has finished joining and stabilised.
    The ID 2026-06-08 incident showed a multi-minute service Up/Down cycle
    while WSFC retried witness arbitration. A fixed Start-Sleep mistakes a
    transient Up reading for a stable join.

    This poll loop returns only after Get-ClusterNode reports State='Up' for
    N consecutive polls (default 3 x 5s = 15s of stability), or throws when
    the timeout elapses.
#>
function Wait-MssqlOpsClusterNodeReady {
    [CmdletBinding()]
    [OutputType('Microsoft.FailoverClusters.PowerShell.ClusterNode')]
    param(
        [string]$NodeName = $env:COMPUTERNAME,
        [int]$TimeoutSeconds = 600,
        [int]$PollIntervalSeconds = 5,
        [int]$StablePolls = 3
    )

    $deadline       = (Get-Date).AddSeconds($TimeoutSeconds)
    $consecutiveUp  = 0
    $lastState      = $null

    while ((Get-Date) -lt $deadline) {
        try {
            $node = Get-ClusterNode -Name $NodeName -ErrorAction Stop
            $lastState = $node.State
            if ($node.State -eq 'Up') {
                $consecutiveUp++
                if ($consecutiveUp -ge $StablePolls) {
                    return $node
                }
            } else {
                $consecutiveUp = 0
            }
        } catch {
            $consecutiveUp = 0
            $lastState     = "query-failed: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Cluster node '$NodeName' did not reach a stable State='Up' (required $StablePolls consecutive Up readings) within $TimeoutSeconds seconds. Last observed state: $lastState. Investigate WSFC service health (C:\Windows\Cluster\Reports\Cluster.log around this window)."
}
