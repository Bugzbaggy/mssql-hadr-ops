# Module loader for MssqlHadrOps.
# Imports OS-only dependencies, then dot-sources every Public and Private function file.

# FailoverClusters is a Desktop-edition module. In PowerShell 7 it MUST load via
# the Windows PowerShell compatibility session (WinPSCompat): loading it natively
# with -SkipEditionCheck makes its cmdlets fail at runtime with "Could not load
# type 'System.Diagnostics.Eventing.EventDescriptor'" (a .NET Framework type
# absent in .NET). The trade-off is that WinPSCompat returns DESERIALIZED cluster
# objects, where nested props like Get-ClusterQuorum's .QuorumResource.Name come
# back empty and Get-CauRun returns a truthy-but-empty object. The module's
# cluster-touching code (Test-MssqlOpsClusterReadiness and the planned-failover
# quorum math) is therefore written defensively against those deserialized
# objects rather than forcing a native load. Do NOT add -SkipEditionCheck.
Import-Module FailoverClusters -ErrorAction Stop

# Default PagerDuty service id used by functions that open/close maintenance
# windows. Public functions accept -PagerDutyServiceId to override per-call;
# this is just the central default so the value lives in one place.
$script:PagerDutyServiceId = 'PYZ6V1U'   # AppDb Messaging Database

$public  = @(Get-ChildItem -Path "$PSScriptRoot\Public"  -Filter '*.ps1' -ErrorAction SilentlyContinue)
$private = @(Get-ChildItem -Path "$PSScriptRoot\Private" -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($f in $public + $private) {
    . $f.FullName
}

Export-ModuleMember -Function $public.BaseName
