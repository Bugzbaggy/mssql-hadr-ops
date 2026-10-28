<#
.SYNOPSIS
    Returns $true only when the local machine is an Azure VM.
.DESCRIPTION
    Companion to Test-MssqlOpsIsEc2 / Test-MssqlOpsIsGce. Azure is detected but
    has NO component updater in this module - the fleet is AWS + GCP only.
    Identifying it explicitly (instead of lumping it into 'Other') lets the
    dispatcher give an accurate, actionable refusal rather than a vague one.

    Two-stage check, same shape as the other detectors:

      1. Cheap local SMBIOS read. Azure stamps a well-known chassis asset tag
         on every VM. This is the reliable discriminator - the manufacturer
         string ('Microsoft Corporation' / 'Virtual Machine') is NOT, because
         on-prem Hyper-V reports the same thing.
      2. Authoritative Azure IMDS probe, which requires the 'Metadata: true'
         header and refuses proxies.
#>
function Test-MssqlOpsIsAzure {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [int]$TimeoutSeconds = 3
    )

    # Well-known Azure chassis asset tag, identical on every Azure VM.
    $azureAssetTag = '7783-7084-3265-9085-8269-3286-77'

    # 1. Local SMBIOS asset tag.
    try {
        $enclosure = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop
        foreach ($e in $enclosure) {
            if ($e.SMBIOSAssetTag -and $e.SMBIOSAssetTag.Trim() -eq $azureAssetTag) { return $true }
        }
    } catch {
        # fall through to the IMDS probe
    }

    # 2. Azure Instance Metadata Service.
    try {
        $vm = Invoke-RestMethod -Method Get `
            -Uri 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01' `
            -Headers @{ Metadata = 'true' } `
            -TimeoutSec $TimeoutSeconds -NoProxy -ErrorAction Stop
        return [bool]$vm.vmId
    } catch {
        # not reachable / not Azure
    }

    return $false
}
