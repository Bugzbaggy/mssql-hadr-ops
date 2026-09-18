<#
.SYNOPSIS
    Returns $true only when the local machine is an AWS EC2 instance.
.DESCRIPTION
    Used to gate the AWS component updater so it is a clean no-op on the
    non-AWS fleet members (the UK nodes are GCP-hosted). Two-stage check:

      1. Cheap local SMBIOS read. EC2 (Nitro) reports the system manufacturer
         as 'Amazon EC2'; GCP reports 'Google', Hyper-V/Azure report
         'Microsoft Corporation', VMware reports 'VMware'. A positive/negative
         match here avoids any network call.
      2. Authoritative IMDSv2 probe. A PUT to the token endpoint only succeeds
         on EC2. GCP's metadata server sits on the same 169.254.169.254 address
         but does not honour the IMDSv2 token handshake, so this does not
         false-positive on GCP.
#>
function Test-MssqlOpsIsEc2 {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [int]$TimeoutSeconds = 3
    )

    # 1. Local SMBIOS manufacturer - decisive for both AWS and the known peers.
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs.Manufacturer -match 'Amazon') { return $true }
        if ($cs.Manufacturer -match 'Google|Microsoft Corporation|VMware|QEMU|innotek|Xen') { return $false }
    } catch {
        # fall through to the metadata probe
    }

    # 2. IMDSv2 token handshake - EC2-only.
    try {
        $token = Invoke-RestMethod -Method Put `
            -Uri 'http://169.254.169.254/latest/api/token' `
            -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '60' } `
            -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        if ($token) {
            $id = Invoke-RestMethod -Method Get `
                -Uri 'http://169.254.169.254/latest/meta-data/instance-id' `
                -Headers @{ 'X-aws-ec2-metadata-token' = $token } `
                -TimeoutSec $TimeoutSeconds -ErrorAction Stop
            return [bool]$id
        }
    } catch {
        # not reachable / not EC2
    }

    return $false
}