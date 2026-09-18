<#
.SYNOPSIS
    Pre-flight gate for planned AG operations: verifies cluster + AG + witness
    health beyond what the per-AG sync checks cover.
.DESCRIPTION
    Returns a [pscustomobject] with .Healthy, .Failures, .Warnings. With
    -EnableException, throws on the first failure.

    Closes a class of gaps exposed by the ID 2026-06-08 incident, where
    ag-region2-cluster on region2-node5 stayed in RESOLVING for ~18 min while WSFC
    retried witness arbitration. Root cause is not confirmed, but the
    existing AG-only preflights wouldn't have caught the precursor in any
    of the plausible scenarios. The gate adds the missing checks:

      1. Every cluster peer is Up. Refuses to proceed if any peer is
         Paused/Drained (another operator or CAU is already mid-patch).
      2. The file-share witness resource is Online AND its share path is
         actually reachable over SMB from THIS node. Get-ClusterResource
         only reflects the cluster's last successful arbitration; the gate
         performs a direct SMB reachability test from this node, which can
         fail while the resource still reports Online (any cause: witness
         host down, network path broken, Kerberos, etc.).
      3. No availability group visible from the local SQL instance is in
         the Resolving role.
      4. No Cluster-Aware Updating run is currently in progress. Best-effort
         (the ClusterAwareUpdating module is optional).
#>
function Test-MssqlOpsClusterReadiness {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$LocalInstance = $env:COMPUTERNAME,
        [switch]$EnableException
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    # 1. Cluster peers Up (no concurrent patching)
    try {
        $nodes    = Get-ClusterNode -ErrorAction Stop
        $peers    = $nodes | Where-Object { $_.Name -ine $env:COMPUTERNAME }
        $badPeers = $peers | Where-Object { $_.State -ne 'Up' }
        if ($badPeers) {
            $list = ($badPeers | ForEach-Object { "$($_.Name)=$($_.State)" }) -join ', '
            $failures.Add("Cluster peer(s) not Up: $list. Another operator or CAU may be mid-patch; refusing to add a second paused node.")
        }
    } catch {
        $failures.Add("Get-ClusterNode failed: $($_.Exception.Message)")
    }

    # 2. Witness Online AND SMB-reachable from this node
    try {
        $quorum = Get-ClusterQuorum -ErrorAction Stop

        # Read the witness resource name defensively. If the cluster object is
        # deserialized (WinPSCompat), the nested .Name can be empty - degrade to
        # a warning rather than passing $null to Get-ClusterResource (which would
        # throw and raise a phantom witness failure).
        $witnessName = if ($quorum.QuorumResource) { [string]$quorum.QuorumResource.Name } else { $null }

        if (-not $quorum.QuorumResource) {
            $warnings.Add("Cluster has no witness resource configured.")
        }
        elseif ([string]::IsNullOrWhiteSpace($witnessName)) {
            $warnings.Add("Could not read the quorum witness resource name (cluster object may be deserialized); skipped the witness SMB reachability check.")
        }
        else {
            $witnessRes = Get-ClusterResource -Name $witnessName -ErrorAction Stop

            if ($witnessRes.State -ne 'Online') {
                $failures.Add("Quorum witness '$($witnessRes.Name)' is $($witnessRes.State).")
            } else {
                # Read the file-share path from the resource and test it from THIS node.
                # The resource State is the cluster's view (last successful arbitration);
                # a direct Test-Path catches a current reachability gap from this node
                # regardless of cause (witness host down, network path, Kerberos, etc.).
                $sharePath = $null
                try {
                    $sharePath = (Get-ClusterParameter -InputObject $witnessRes -Name 'SharePath' -ErrorAction Stop).Value
                } catch {
                    $warnings.Add("Could not read witness SharePath; resource may not be a file-share witness ($($_.Exception.Message)).")
                }

                if ($sharePath) {
                    try {
                        $reachable = Test-Path -LiteralPath $sharePath -ErrorAction Stop
                        if (-not $reachable) {
                            $failures.Add("Witness share '$sharePath' is not reachable over SMB from ${env:COMPUTERNAME} (Test-Path returned false). The cluster resource still reports Online, but this node currently cannot reach the share. Refusing to proceed.")
                        }
                    } catch {
                        $failures.Add("Witness share '$sharePath' could not be tested from ${env:COMPUTERNAME} ($($_.Exception.Message)). Treating as unreachable.")
                    }
                }
            }
        }
    } catch {
        $failures.Add("Quorum/witness check failed: $($_.Exception.Message)")
    }

    # 3. No AG in Resolving role
    try {
        $resolving = Get-DbaAgReplica -SqlInstance $LocalInstance -EnableException -WarningAction SilentlyContinue |
                     Where-Object { $_.Role -eq 'Resolving' }
        if ($resolving) {
            $list = ($resolving | ForEach-Object { "$($_.AvailabilityGroup) on $($_.Name)" }) -join ', '
            $failures.Add("Availability group(s) currently in Resolving role: $list. Resolve before running planned ops.")
        }
    } catch {
        $warnings.Add("Could not enumerate AG replicas: $($_.Exception.Message)")
    }

    # 4. No CAU run in progress (best-effort)
    if (Get-Command -Name Get-CauRun -ErrorAction SilentlyContinue) {
        try {
            $cau = Get-CauRun -ErrorAction Stop -WarningAction SilentlyContinue
            # Require a non-empty RunId: when no run is active Get-CauRun may return
            # a truthy-but-empty object (notably under WinPSCompat) rather than
            # throwing, so `if ($cau)` alone raised a phantom "run in progress".
            if ($cau -and $cau.RunId) {
                $failures.Add("Cluster-Aware Updating run in progress (RunId=$($cau.RunId)). Wait for CAU to finish before manual patching/failover.")
            }
        } catch {
            # Get-CauRun throws when no run is active on some platforms; that's the good case.
        }
    }

    $healthy = ($failures.Count -eq 0)

    if (-not $healthy -and $EnableException) {
        throw "Cluster readiness gate failed: $($failures -join ' | ')"
    }

    [pscustomobject]@{
        Healthy  = $healthy
        Failures = $failures.ToArray()
        Warnings = $warnings.ToArray()
    }
}
