<#
.SYNOPSIS
    Keeps the AWS EC2 system components (SSM Agent, EC2Launch v2, NVMe driver,
    ENA driver) current on this node. No-op on non-EC2 hosts.
.DESCRIPTION
    Wraps the raw AWS driver/agent install steps with the safety and security
    the fleet needs:

      * EC2-only. Test-MssqlOpsIsEc2 gates everything, so the function is a
        clean no-op on the GCP-hosted UK nodes (returns IsEc2=$false).
      * Version-aware. Each component's installed version is compared against
        the package version; a component is installed only when the package is
        newer, or when -Force is passed. Nothing is reinstalled needlessly, so
        an already-current node produces no reboot.
      * Signature-verified. Agent installers must carry a Valid Authenticode
        signature from an Amazon signer; driver catalogs must be Valid
        (WHQL). Unsigned/tampered payloads are refused before execution.
      * Offline-capable. -Source <dir> uses pre-staged files from a share
        instead of reaching s3.amazonaws.com - required on firewalled prod
        hosts. Without it, the AWS 'Latest' URLs are used.
      * Reboot-signalling, not reboot-forcing. Driver installs set
        RebootRequired on the returned object; the caller (an OS upgrade, or
        Install-WindowsUpdate -AutoReboot) owns the actual reboot.

    Ordering is fixed by Get-MssqlOpsAwsComponentSpec: SSM Agent, EC2Launch
    (safe), then NVMe, then ENA last (ENA momentarily drops the NIC).

    SAFETY: the ENA and NVMe drivers are 'disruptive' (NIC drop / reboot).
    Only refresh them when the node can tolerate it - i.e. drained
    (Initialize-MssqlOpsAgSecondaryPatching -Mode Windows) or immediately
    before an OS upgrade. In SqlCU mode the node stays online, so pass
    -Scope Agents.
.PARAMETER Scope
    'Agents'  - SSM Agent + EC2Launch only (safe on an online node).
    'Drivers' - NVMe + ENA only (disruptive; node must be drained).
    'All'     - everything (default). Use only when the node is drained or
                about to be upgraded.
.PARAMETER Source
    Optional directory holding pre-staged component files (same file names as
    the manifest: AmazonSSMAgentSetup.exe, AmazonEC2Launch.msi, AWSNVMe.zip,
    AwsEnaNetworkDriver.zip). When supplied and present, files are copied from
    here instead of downloaded - the supported path for firewalled hosts. A
    UNC share (e.g. the SqlOpsShare) works.
.PARAMETER RequireSuccess
    Throw if this is an EC2 host and any in-scope component fails to acquire,
    verify, or install. This is the HARD GATE used before a WS2025 in-place
    upgrade: booting the new OS on stale ENA/NVMe drivers yields a node with
    no network or no EBS disks. Default off (best-effort) so routine patching
    is not blocked by a transient S3 hiccup.
.PARAMETER Force
    (Re)install every in-scope component even when already current.
.PARAMETER WorkDir
    Scratch directory for downloads/extraction.
    Default: C:\ProgramData\MssqlHadrOps\aws-components.
.PARAMETER SkipSignatureCheck
    Bypass Authenticode verification. Strongly discouraged; intended only for
    an air-gapped mirror whose integrity is already assured out of band.
.OUTPUTS
    [pscustomobject] with:
      IsEc2          [bool]
      RebootRequired [bool]
      Results        [pscustomobject[]] - Name, Action (Installed|Skipped|
                     Failed|UpToDate), FromVersion, ToVersion, Error
.EXAMPLE
    Update-MssqlOpsAwsSystemComponent -Scope All -RequireSuccess
    Hard-gate refresh of every component immediately before a WS2025 upgrade.
.EXAMPLE
    Update-MssqlOpsAwsSystemComponent -Scope Agents
    Keep SSM/EC2Launch current on an online node (no reboot, no NIC drop).
.EXAMPLE
    Update-MssqlOpsAwsSystemComponent -Scope All -Source '\\share\aws-components' -RequireSuccess
    Firewalled host: install from pre-staged files, hard-gate.
.NOTES
    Version:        1.1
    Last Modified:  2026-08-27
    Author:         Renz Bagasbas
    Changes:        1.1 - Resolve agent version from the Windows service binary
                          path (ServiceName in the spec) before the hard-coded
                          InstalledExe. Fixes a false 'not installed' for SSM
                          Agent when installed to a non-default path, which
                          caused a needless reinstall on every gate run.
#>
function Update-MssqlOpsAwsSystemComponent {
    [CmdletBinding(SupportsShouldProcess)]
    # -Force and -SkipSignatureCheck are consumed inside the nested Install-*/
    # Assert-TrustedSignature helpers via PowerShell dynamic scope; PSSA's
    # unused-parameter rule cannot trace nested-function usage.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Force', Justification = 'Used in nested Install-DriverPackage/Install-AgentPackage')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SkipSignatureCheck', Justification = 'Used in nested Assert-TrustedSignature')]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('Agents', 'Drivers', 'All')]
        [string]$Scope = 'All',
        [string]$Source,
        [switch]$RequireSuccess,
        [switch]$Force,
        [string]$WorkDir = 'C:\ProgramData\MssqlHadrOps\aws-components',
        [switch]$SkipSignatureCheck
    )

    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    # -------------------------------------------------------------------------
    # EC2 gate - clean no-op everywhere else.
    # -------------------------------------------------------------------------
    if (-not (Test-MssqlOpsIsEc2)) {
        Write-Host " -> Not an EC2 instance; AWS component update skipped." -ForegroundColor Green
        return [pscustomobject]@{ IsEc2 = $false; RebootRequired = $false; Results = @() }
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Force -Path $WorkDir -ErrorAction Stop | Out-Null

    $useOffline = $Source -and (Test-Path -LiteralPath $Source)
    if ($Source -and -not $useOffline) {
        Write-Host " -> WARNING: -Source '$Source' not reachable; falling back to AWS download URLs." -ForegroundColor Yellow
    }

    # ---- local helpers ------------------------------------------------------

    function Assert-TrustedSignature {
        param([string]$Path, [string]$Kind)
        if ($SkipSignatureCheck) { return }
        $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
        if ($ext -notin '.exe', '.msi', '.ps1', '.sys', '.cat', '.dll') { return }
        $sig = Get-AuthenticodeSignature -LiteralPath $Path
        if ($sig.Status -ne 'Valid') {
            throw "Signature invalid for '$Path' (Status=$($sig.Status)). Refusing to execute."
        }
        # Agent installers must be Amazon-signed; driver catalogs may be WHQL
        # (Microsoft Windows Hardware Compatibility Publisher).
        if ($Kind -eq 'Agent' -and $sig.SignerCertificate.Subject -notmatch 'Amazon') {
            throw "Unexpected signer for '$Path': $($sig.SignerCertificate.Subject). Expected an Amazon signer."
        }
    }

    function Get-InstalledVersion {
        param([pscustomobject]$Component)
        try {
            switch ($Component.Kind) {
                'Agent' {
                    # Resolve the agent binary from its Windows service first - the
                    # install location can vary (e.g. SSM Agent), so a hard-coded
                    # path yields a false 'not installed' and a needless reinstall.
                    # Fall back to the well-known InstalledExe path.
                    $exe = $Component.InstalledExe
                    if ($Component.PSObject.Properties['ServiceName'] -and $Component.ServiceName) {
                        try {
                            $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($Component.ServiceName)'" -ErrorAction Stop
                            if ($svc -and $svc.PathName) {
                                $svcExe = $svc.PathName -replace '^"([^"]+)".*', '$1' -replace '^([^\s"]+)\s.*', '$1'
                                if (Test-Path -LiteralPath $svcExe) { $exe = $svcExe }
                            }
                        } catch { }
                    }
                    if ($exe -and (Test-Path -LiteralPath $exe)) {
                        return [version]((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion -replace '[^\d\.].*$')
                    }
                    return $null
                }
                'Driver' {
                    $drv = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop |
                           Where-Object { $_.DeviceName -match $Component.DeviceMatch } |
                           Sort-Object { [version]($_.DriverVersion) } -Descending |
                           Select-Object -First 1
                    if ($drv) { return [version]$drv.DriverVersion }
                    return $null
                }
            }
        } catch { return $null }
    }

    function Get-MsiProductVersion {
        param([string]$MsiPath)
        try {
            $installer = New-Object -ComObject WindowsInstaller.Installer
            $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($MsiPath, 0))
            $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db,
                @("SELECT Value FROM Property WHERE Property='ProductVersion'"))
            $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
            $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            $val = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(1))
            return [version]($val -replace '[^\d\.].*$')
        } catch { return $null }
    }

    function Get-Payload {
        param([pscustomobject]$Component)
        $dest = Join-Path $WorkDir $Component.FileName
        if ($useOffline) {
            $src = Join-Path $Source $Component.FileName
            if (-not (Test-Path -LiteralPath $src)) { throw "Pre-staged file not found: $src" }
            Copy-Item -LiteralPath $src -Destination $dest -Force
        } else {
            Invoke-WebRequest -Uri $Component.Url -OutFile $dest -UseBasicParsing -TimeoutSec 180
        }
        return $dest
    }

    # ---- driver install (returns $true if a newer driver was applied) -------

    function Install-DriverPackage {
        param([pscustomobject]$Component, [string]$ZipPath)
        $extractDir = Join-Path $WorkDir $Component.Name
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractDir -Force

        # Package version from the .inf DriverVer line.
        $inf = Get-ChildItem $extractDir -Recurse -Filter *.inf -ErrorAction SilentlyContinue | Select-Object -First 1
        $pkgVersion = $null
        if ($inf) {
            $m = Select-String -Path $inf.FullName -Pattern 'DriverVer\s*=\s*[\d/]+\s*,\s*([\d\.]+)' -ErrorAction SilentlyContinue |
                 Select-Object -First 1
            if ($m) { $pkgVersion = [version]$m.Matches[0].Groups[1].Value }
        }

        $installed = Get-InstalledVersion -Component $Component
        if (-not $Force -and $installed -and $pkgVersion -and $installed -ge $pkgVersion) {
            return [pscustomobject]@{ Changed = $false; From = $installed; To = $installed }
        }

        # Verify catalogs before letting Windows stage the driver.
        Get-ChildItem $extractDir -Recurse -Include *.cat, *.sys -ErrorAction SilentlyContinue |
            ForEach-Object { Assert-TrustedSignature -Path $_.FullName -Kind 'Driver' }

        if ($PSCmdlet.ShouldProcess("$($Component.Name) driver", 'Install')) {
            $installPs1 = Get-ChildItem $extractDir -Recurse -Filter install.ps1 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($installPs1) {
                Assert-TrustedSignature -Path $installPs1.FullName -Kind 'Driver'
                & $installPs1.FullName
            } else {
                $dpinst = Get-ChildItem $extractDir -Recurse -Filter dpinst.exe -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($dpinst) {
                    & $dpinst.FullName /sw | Out-Null
                } elseif ($inf) {
                    pnputil.exe /add-driver $inf.FullName /install | Out-Null
                } else {
                    throw "No installer (install.ps1 / dpinst.exe / .inf) found in $($Component.FileName)."
                }
            }
        }
        [pscustomobject]@{ Changed = $true; From = $installed; To = ($pkgVersion ? $pkgVersion : $installed) }
    }

    # ---- agent install ------------------------------------------------------

    function Install-AgentPackage {
        param([pscustomobject]$Component, [string]$FilePath)
        $installed = Get-InstalledVersion -Component $Component
        $pkgVersion = if ([IO.Path]::GetExtension($FilePath) -ieq '.msi') {
            Get-MsiProductVersion -MsiPath $FilePath
        } else {
            try { [version]((Get-Item -LiteralPath $FilePath).VersionInfo.ProductVersion -replace '[^\d\.].*$') } catch { $null }
        }

        if (-not $Force -and $installed -and $pkgVersion -and $installed -ge $pkgVersion) {
            return [pscustomobject]@{ Changed = $false; From = $installed; To = $installed }
        }

        if ($PSCmdlet.ShouldProcess("$($Component.Name) agent", 'Install')) {
            if ([IO.Path]::GetExtension($FilePath) -ieq '.msi') {
                $p = Start-Process msiexec.exe -ArgumentList "/i `"$FilePath`" /qn /norestart" -Wait -PassThru
                if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "msiexec exited $($p.ExitCode)." }
            } else {
                $p = Start-Process $FilePath -ArgumentList '/S' -Wait -PassThru
                if ($p.ExitCode -ne 0) { throw "$($Component.FileName) exited $($p.ExitCode)." }
            }
        }
        [pscustomobject]@{ Changed = $true; From = $installed; To = ($pkgVersion ? $pkgVersion : $installed) }
    }

    # -------------------------------------------------------------------------
    # Drive the selected components.
    # -------------------------------------------------------------------------
    $all = Get-MssqlOpsAwsComponentSpec
    $components = switch ($Scope) {
        'Agents'  { $all | Where-Object Kind -eq 'Agent' }
        'Drivers' { $all | Where-Object Kind -eq 'Driver' }
        default   { $all }
    }

    $rebootRequired = $false

    foreach ($c in $components) {
        try {
            $file = Get-Payload -Component $c
            if ($c.Kind -eq 'Agent') { Assert-TrustedSignature -Path $file -Kind 'Agent' }

            $outcome = if ($c.Kind -eq 'Driver') {
                Install-DriverPackage -Component $c -ZipPath $file
            } else {
                Install-AgentPackage -Component $c -FilePath $file
            }

            if ($outcome.Changed) {
                if ($c.Disruptive) { $rebootRequired = $true }
                $results.Add([pscustomobject]@{
                    Name = $c.Name; Action = 'Installed'; FromVersion = $outcome.From; ToVersion = $outcome.To; Error = $null
                })
            } else {
                $results.Add([pscustomobject]@{
                    Name = $c.Name; Action = 'UpToDate'; FromVersion = $outcome.From; ToVersion = $outcome.To; Error = $null
                })
            }
        } catch {
            $results.Add([pscustomobject]@{
                Name = $c.Name; Action = 'Failed'; FromVersion = $null; ToVersion = $null; Error = $_.Exception.Message
            })
        }
    }

    if (Test-MssqlOpsPendingReboot) { $rebootRequired = $true }

    $failed = @($results | Where-Object Action -eq 'Failed')
    if ($RequireSuccess -and $failed) {
        throw "AWS component update failed for: $(( $failed | ForEach-Object { "$($_.Name) ($($_.Error))" } ) -join '; ')"
    }

    [pscustomobject]@{
        IsEc2          = $true
        RebootRequired = $rebootRequired
        Results        = $results.ToArray()
    }
}