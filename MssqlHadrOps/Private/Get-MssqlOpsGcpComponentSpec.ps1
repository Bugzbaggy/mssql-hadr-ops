<#
.SYNOPSIS
    Returns the GooGet package manifest for the Google Compute Engine guest
    environment + paravirtual drivers that the module keeps current.
.DESCRIPTION
    Data-only helper consumed by Update-MssqlOpsGcpSystemComponent. GCE Windows
    packages are managed by GooGet (C:\ProgramData\GooGet\googet.exe), which is
    itself version-aware and repository-signed - so unlike the AWS path there
    is no manual download/verify; GooGet does both.

    Classification mirrors the AWS spec:
      * Agent  (non-disruptive) - guest agent, metadata scripts, sysprep, VSS,
                osconfig, auto-updater. No reboot / no NIC drop. Safe to refresh
                on an online node (SqlCU mode).
      * Driver (disruptive)     - the VirtIO/gVNIC/graphics/balloon/pvpanic
                paravirtual drivers. gVNIC/netkvm (network) and vioscsi
                (boot/SCSI storage) are the GCP analogues of AWS ENA/NVMe:
                booting WS2025 on stale versions yields a node with no network
                or no boot disk. Refresh only when the node is drained
                (Windows mode) or immediately before an OS upgrade.

    Only packages that are actually installed (per 'googet installed') are
    acted on - not every VM carries every driver (gVNIC vs VirtIO differs by
    machine type), so the updater intersects this list with the installed set.

    Driver order places the network drivers last so earlier package operations
    still have a working NIC.
#>
function Get-MssqlOpsGcpComponentSpec {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()

    @(
        # --- Agents (safe) ---
        [pscustomobject]@{ Name = 'google-compute-engine-windows';          Kind = 'Agent';  Disruptive = $false }
        [pscustomobject]@{ Name = 'google-compute-engine-metadata-scripts'; Kind = 'Agent';  Disruptive = $false }
        [pscustomobject]@{ Name = 'google-compute-engine-sysprep';          Kind = 'Agent';  Disruptive = $false }
        [pscustomobject]@{ Name = 'google-compute-engine-vss';              Kind = 'Agent';  Disruptive = $false }
        [pscustomobject]@{ Name = 'google-osconfig-agent';                  Kind = 'Agent';  Disruptive = $false }
        [pscustomobject]@{ Name = 'google-compute-engine-auto-updater';     Kind = 'Agent';  Disruptive = $false }

        # --- Drivers (disruptive); network drivers last ---
        [pscustomobject]@{ Name = 'google-compute-engine-driver-balloon';   Kind = 'Driver'; Disruptive = $true }
        [pscustomobject]@{ Name = 'google-compute-engine-driver-pvpanic';   Kind = 'Driver'; Disruptive = $true }
        [pscustomobject]@{ Name = 'google-compute-engine-driver-gga';       Kind = 'Driver'; Disruptive = $true }
        [pscustomobject]@{ Name = 'google-compute-engine-driver-vioscsi';   Kind = 'Driver'; Disruptive = $true }   # boot/SCSI storage
        [pscustomobject]@{ Name = 'google-compute-engine-driver-netkvm';    Kind = 'Driver'; Disruptive = $true }   # network (VirtIO)
        [pscustomobject]@{ Name = 'google-compute-engine-driver-gvnic';     Kind = 'Driver'; Disruptive = $true }   # network (gVNIC)
    )
}
