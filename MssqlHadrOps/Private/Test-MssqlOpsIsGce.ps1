<#
.SYNOPSIS
    Returns $true only when the local machine is a Google Compute Engine VM.
.DESCRIPTION
    Companion to Test-MssqlOpsIsEc2, used to route the cloud component updater
    to the GCP path on the ID/UK nodes. Two-stage check:

      1. Cheap local SMBIOS read. GCE reports the system manufacturer as
         'Google' (typically 'Google' / 'Google Compute Engine'); AWS reports
         'Amazon EC2'. A positive/negative match here avoids any network call.
      2. Authoritative GCE metadata probe. A GET to the metadata server with
         the mandatory 'Metadata-Flavor: Google' header only succeeds on GCE.
#>
function Test-MssqlOpsIsGce {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [int]$TimeoutSeconds = 3
    )

    # 1. Local SMBIOS manufacturer.
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs.Manufacturer -match 'Google') { return $true }
        if ($cs.Manufacturer -match 'Amazon|Microsoft Corporation|VMware|QEMU|innotek|Xen') { return $false }
    } catch {
        # fall through to the metadata probe
    }

    # 2. GCE metadata server - requires the Metadata-Flavor: Google header.
    try {
        $id = Invoke-RestMethod -Method Get `
            -Uri 'http://metadata.google.internal/computeMetadata/v1/instance/id' `
            -Headers @{ 'Metadata-Flavor' = 'Google' } `
            -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        return [bool]$id
    } catch {
        # not reachable / not GCE
    }

    return $false
}
