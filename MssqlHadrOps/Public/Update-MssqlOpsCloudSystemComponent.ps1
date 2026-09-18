<#
.SYNOPSIS
    Cloud-aware entry point that keeps this node's cloud system components
    (drivers + agents) current, dispatching to the AWS or GCP updater.
.DESCRIPTION
    Detects the platform (Get-MssqlOpsCloudPlatform) and forwards to
    Update-MssqlOpsAwsSystemComponent (SG/US EC2) or
    Update-MssqlOpsGcpSystemComponent (ID/UK GCE). On anything else it is a
    clean no-op. This is what Initialize-MssqlOpsAgSecondaryPatching calls, so
    the same prep works fleet-wide without the operator having to know which
    cloud a node runs on.

    The two backends share a result shape, so the normalized return is uniform:
      Platform ('AWS'|'GCP'|'Azure'|'Other'), Managed (bool), RebootRequired (bool),
      and Results (Name/Action/FromVersion/ToVersion/Error).
.PARAMETER Scope
    'Agents', 'Drivers', or 'All' (default). Passed through unchanged. Use
    'Agents' when the node must stay online (SqlCU mode); 'All' only when the
    node is drained or immediately before an OS upgrade.
.PARAMETER Source
    Optional per-cloud source, forwarded to whichever backend matches this
    node: an AWS pre-staged file directory, or a GooGet repository URL/path on
    GCP. Ignored by the non-matching cloud.
.PARAMETER RequireSuccess
    Hard gate: throw if any in-scope component fails, AND throw if the platform
    cannot be verified at all. Use before an in-place OS upgrade (stale
    network/storage drivers => no NIC / no boot disk on first boot).

    FAIL-CLOSED: a host that resolves to 'Azure' or 'Other' has no implemented
    updater, so nothing is verified. Under -RequireSuccess that is an ERROR, not
    a pass - a false-negative detection (metadata service blocked/throttled on a
    real EC2/GCE node) must not be reported as a satisfied gate. Without
    -RequireSuccess it stays a non-blocking, clearly-labelled skip.
.PARAMETER Force
    Reinstall each in-scope component even when already current.
.OUTPUTS
    [pscustomobject] with Platform, Managed, RebootRequired, Results.
.EXAMPLE
    Update-MssqlOpsCloudSystemComponent -Scope All -RequireSuccess
    Hard-gate refresh regardless of whether this node is AWS or GCP.
.NOTES
    Version:        1.1
    Last Modified:  2026-09-14
    Author:         Renz Bagasbas
    Changes:        1.1 - Fail closed. -RequireSuccess now throws when the
                          platform has no implemented updater ('Azure'/'Other')
                          instead of returning Managed=$false, which callers
                          (Initialize-MssqlOpsAgSecondaryPatching) treated as a
                          satisfied gate. Adds explicit Azure detection so the
                          refusal names the real platform.
#>
function Update-MssqlOpsCloudSystemComponent {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('Agents', 'Drivers', 'All')]
        [string]$Scope = 'All',
        [string]$Source,
        [switch]$RequireSuccess,
        [switch]$Force
    )

    $common = @{ Scope = $Scope }
    if ($RequireSuccess) { $common.RequireSuccess = $true }
    if ($Force)          { $common.Force = $true }
    if ($Source)         { $common.Source = $Source }

    $platform = Get-MssqlOpsCloudPlatform

    # Platforms that actually have an implemented component updater.
    $implemented = @('AWS', 'GCP')

    if ($platform -notin $implemented) {
        # FAIL CLOSED. "Could not verify" is not the same as "verified fine".
        # A false-negative detection (metadata service blocked, throttled, or
        # timing out on a genuine EC2/GCE node) also lands here - and silently
        # returning success would let an UNVERIFIED node walk into an in-place
        # OS upgrade on stale network/storage drivers, which is the exact
        # failure this gate exists to prevent.
        if ($RequireSuccess) {
            $msg = ("Cloud component hard gate requested (-RequireSuccess) but this host resolved to platform " +
                    "'$platform', which has no implemented component updater - nothing was verified. " +
                    "If this node IS AWS or GCP, platform detection failed (instance metadata service blocked, " +
                    "throttled, or timing out): fix that and re-run. If the platform is genuinely unmanaged, update " +
                    "its network/storage drivers and guest agent by hand, then re-run with " +
                    "-SkipCloudComponentUpdate to record that decision explicitly.")

            # -WhatIf is a rehearsal: say loudly that the gate WOULD abort, but honour
            # -WhatIf semantics and do not raise a terminating error on a dry run.
            if ($WhatIfPreference) {
                Write-Warning "WhatIf: the hard gate WOULD ABORT here. $msg"
                return [pscustomobject]@{ Platform = $platform; Managed = $false; RebootRequired = $false; Results = @() }
            }

            throw $msg
        }

        Write-Host " -> Platform '$platform' has no component updater; cloud component update skipped." -ForegroundColor Yellow
        Write-Host "    (Not a hard gate - pass -RequireSuccess to make an unverifiable platform abort instead.)" -ForegroundColor DarkGray
        return [pscustomobject]@{ Platform = $platform; Managed = $false; RebootRequired = $false; Results = @() }
    }

    # -WhatIf short-circuits the whole dispatch; the AWS/GCP backends also gate
    # their individual installs, so a non-WhatIf call proceeds normally.
    if (-not $PSCmdlet.ShouldProcess("$platform system components", "Update ($Scope)")) {
        return [pscustomobject]@{ Platform = $platform; Managed = $false; RebootRequired = $false; Results = @() }
    }

    switch ($platform) {
        'AWS' {
            $r = Update-MssqlOpsAwsSystemComponent @common
            [pscustomobject]@{ Platform = 'AWS'; Managed = $r.IsEc2; RebootRequired = $r.RebootRequired; Results = $r.Results }
        }
        'GCP' {
            $r = Update-MssqlOpsGcpSystemComponent @common
            [pscustomobject]@{ Platform = 'GCP'; Managed = $r.IsGce; RebootRequired = $r.RebootRequired; Results = $r.Results }
        }
    }
}
