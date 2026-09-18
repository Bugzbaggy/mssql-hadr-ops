<#
.SYNOPSIS
    Keeps the Google Compute Engine guest environment + paravirtual drivers
    current on this node via GooGet. No-op on non-GCE hosts.
.DESCRIPTION
    The GCP counterpart of Update-MssqlOpsAwsSystemComponent, for the ID/UK
    nodes. GCE Windows components are GooGet packages, so this function shells
    out to googet.exe rather than downloading installers:

      * GCE-only. Test-MssqlOpsIsGce gates everything (returns IsGce=$false
        off GCE).
      * Version-aware and signed by construction. 'googet update <pkg>' only
        moves a package when the repository has a newer version, and GooGet
        verifies package signatures against its configured repos - so there is
        no manual download/verify step and an already-current node produces no
        reboot.
      * Installed-only. Only packages actually present (per 'googet installed')
        are touched; machine types differ (gVNIC vs VirtIO), so the manifest is
        intersected with the installed set.
      * Reboot-signalling, not reboot-forcing. A driver package version change
        sets RebootRequired; the caller owns the reboot.

    SAFETY: the driver packages (gVNIC/netkvm network, vioscsi storage, etc.)
    are disruptive. Refresh them only when the node is drained
    (Initialize-MssqlOpsAgSecondaryPatching -Mode Windows) or immediately
    before an OS upgrade. In SqlCU mode the node stays online - pass
    -Scope Agents.
.PARAMETER Scope
    'Agents'  - guest agent / metadata-scripts / sysprep / VSS / osconfig /
                auto-updater only (safe on an online node).
    'Drivers' - paravirtual drivers only (disruptive; node must be drained).
    'All'     - everything (default). Use only when drained or pre-upgrade.
.PARAMETER Source
    Optional GooGet repository URL/path passed through as 'googet -sources'.
    Use to pin an internal mirror for firewalled hosts. When omitted, the
    node's configured GooGet repos are used.
.PARAMETER RequireSuccess
    Throw if this is a GCE host and any in-scope package fails to update (or
    googet.exe cannot be located). This is the HARD GATE before a WS2025
    in-place upgrade: booting the new OS on stale gVNIC/vioscsi drivers yields
    a node with no network or no boot disk. Default off (best-effort).
.PARAMETER Force
    Use 'googet install' (reinstall latest) instead of 'googet update' for each
    in-scope package.
.PARAMETER GoogetPath
    Full path to googet.exe. Auto-resolved from %GooGetRoot%,
    C:\ProgramData\GooGet\googet.exe, or PATH when omitted.
.OUTPUTS
    [pscustomobject] with:
      IsGce          [bool]
      RebootRequired [bool]
      Results        [pscustomobject[]] - Name, Action (Installed|UpToDate|
                     Failed), FromVersion, ToVersion, Error
.EXAMPLE
    Update-MssqlOpsGcpSystemComponent -Scope All -RequireSuccess
    Hard-gate refresh of every installed component before a WS2025 upgrade.
.EXAMPLE
    Update-MssqlOpsGcpSystemComponent -Scope Agents
    Keep the guest agent/osconfig current on an online node.
.NOTES
    Version:        1.0
    Last Modified:  2026-08-14
    Author:         Renz Bagasbas
#>
function Update-MssqlOpsGcpSystemComponent {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('Agents', 'Drivers', 'All')]
        [string]$Scope = 'All',
        [string]$Source,
        [switch]$RequireSuccess,
        [switch]$Force,
        [string]$GoogetPath
    )

    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    if (-not (Test-MssqlOpsIsGce)) {
        Write-Host " -> Not a GCE instance; GCP component update skipped." -ForegroundColor Green
        return [pscustomobject]@{ IsGce = $false; RebootRequired = $false; Results = @() }
    }

    # Locate googet.exe.
    if (-not $GoogetPath) {
        $candidates = @()
        if ($env:GooGetRoot) { $candidates += (Join-Path $env:GooGetRoot 'googet.exe') }
        $candidates += 'C:\ProgramData\GooGet\googet.exe'
        $GoogetPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $GoogetPath) {
            $cmd = Get-Command googet.exe -ErrorAction SilentlyContinue
            if ($cmd) { $GoogetPath = $cmd.Source }
        }
    }
    if (-not $GoogetPath -or -not (Test-Path -LiteralPath $GoogetPath)) {
        $msg = "googet.exe not found (looked in %GooGetRoot%, C:\ProgramData\GooGet, and PATH). Cannot manage GCE packages."
        if ($RequireSuccess) { throw $msg }
        Write-Host " -> WARNING: $msg" -ForegroundColor Yellow
        return [pscustomobject]@{ IsGce = $true; RebootRequired = $false; Results = @() }
    }

    # ---- local helper: installed package -> version map ---------------------
    function Get-GoogetInstalled {
        $out = & $GoogetPath installed 2>&1
        $map = @{}
        foreach ($line in $out) {
            if ($line -match '^\s*(\S+?)\.(x86_64|noarch|arm64)\s+(\S+)') {
                $map[$Matches[1]] = $Matches[3]
            }
        }
        return $map
    }

    $sourceArgs = @()
    if ($Source) { $sourceArgs = @('-sources', $Source) }

    $installedBefore = Get-GoogetInstalled

    $all = Get-MssqlOpsGcpComponentSpec
    $components = switch ($Scope) {
        'Agents'  { $all | Where-Object Kind -eq 'Agent' }
        'Drivers' { $all | Where-Object Kind -eq 'Driver' }
        default   { $all }
    }
    # Only act on packages that are actually installed on this VM.
    $components = $components | Where-Object { $installedBefore.ContainsKey($_.Name) }

    $rebootRequired = $false

    foreach ($c in $components) {
        try {
            $before = $installedBefore[$c.Name]
            if ($PSCmdlet.ShouldProcess($c.Name, "googet $(if ($Force) { 'install' } else { 'update' })")) {
                $verb = if ($Force) { 'install' } else { 'update' }
                $ggArgs = @('-noconfirm', $verb) + $sourceArgs + @($c.Name)
                $out = & $GoogetPath @ggArgs 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "googet $verb exited ${LASTEXITCODE}: $(($out | Out-String).Trim())"
                }
            }

            $after = (Get-GoogetInstalled)[$c.Name]
            if ($after -and $before -ne $after) {
                if ($c.Disruptive) { $rebootRequired = $true }
                $results.Add([pscustomobject]@{
                    Name = $c.Name; Action = 'Installed'; FromVersion = $before; ToVersion = $after; Error = $null
                })
            } else {
                $results.Add([pscustomobject]@{
                    Name = $c.Name; Action = 'UpToDate'; FromVersion = $before; ToVersion = $before; Error = $null
                })
            }
        } catch {
            $results.Add([pscustomobject]@{
                Name = $c.Name; Action = 'Failed'; FromVersion = $installedBefore[$c.Name]; ToVersion = $null; Error = $_.Exception.Message
            })
        }
    }

    if (Test-MssqlOpsPendingReboot) { $rebootRequired = $true }

    $failed = @($results | Where-Object Action -eq 'Failed')
    if ($RequireSuccess -and $failed) {
        throw "GCP component update failed for: $(( $failed | ForEach-Object { "$($_.Name) ($($_.Error))" } ) -join '; ')"
    }

    [pscustomobject]@{
        IsGce          = $true
        RebootRequired = $rebootRequired
        Results        = $results.ToArray()
    }
}
