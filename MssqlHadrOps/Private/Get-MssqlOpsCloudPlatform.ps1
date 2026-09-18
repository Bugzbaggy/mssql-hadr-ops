<#
.SYNOPSIS
    Resolves the platform of the local machine: 'AWS', 'GCP', 'Azure', or 'Other'.
.DESCRIPTION
    Single detection point used by Update-MssqlOpsCloudSystemComponent to
    dispatch to the correct per-cloud updater. AWS is checked first (EC2
    IMDSv2), then GCP (GCE metadata), then Azure (IMDS / chassis asset tag).

    Only AWS and GCP have implemented component updaters - that is the fleet
    (SG + US = AWS EC2; ID + UK = GCP GCE). Azure is detected purely so the
    dispatcher can refuse a hard gate with an accurate reason instead of
    silently treating it as an unmanaged host.

    IMPORTANT: 'Other' means "could not identify", which is NOT the same as
    "nothing to do". A blocked or throttled metadata service on a real EC2/GCE
    node also lands here, so callers asking for a hard gate
    (Update-MssqlOpsCloudSystemComponent -RequireSuccess) must fail closed
    rather than treat 'Other' as success.
#>
function Get-MssqlOpsCloudPlatform {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (Test-MssqlOpsIsEc2)   { return 'AWS' }
    if (Test-MssqlOpsIsGce)   { return 'GCP' }
    if (Test-MssqlOpsIsAzure) { return 'Azure' }
    return 'Other'
}
