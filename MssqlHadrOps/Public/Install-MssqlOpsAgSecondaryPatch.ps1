<#
.SYNOPSIS
    Prep an AG secondary node and install updates, in the correct order.
.DESCRIPTION
    Windows mode (OS patching) - the node is drained, then updates are applied
    in this order so the OS cumulative update is guaranteed to install BEFORE
    any reboot, and the node reboots exactly once:

      1. Initialize-MssqlOpsAgSecondaryPatching -Mode Windows
         (readiness + blocking-transaction gates -> suspend AG -> move cluster
         group -> drain). The cloud refresh is DEFERRED (this function runs it
         at step 3, after the OS update).
      2. Install Windows Updates from the WINDOWS UPDATE channel only
         (Install-WindowsUpdate -WindowsUpdate -AcceptAll -IgnoreReboot):
         OS / .NET / servicing content, never a SQL Server CU, and NO reboot yet.
      3. Refresh cloud system components (AWS ENA/NVMe + agents, or GCP
         gVNIC/vioscsi + agents) now that the OS update is staged.
      4. ONE reboot at the end (only if something staged needs it) to finalize
         the OS update and any driver install. The session ends there; run
         Resume-MssqlOpsAgSecondaryPatching after the node returns.

    This ordering fixes two field problems:
      * The cloud DRIVER install used to run during prep (inside Initialize) and
        set a pending reboot; the subsequent Install-WindowsUpdate -AutoReboot
        then rebooted for that pending state - sometimes before/without actually
        installing the OS CU. OS update first, drivers second, single reboot
        last removes that race.
      * Install-WindowsUpdate was called on the box's DEFAULT service; after the
        Microsoft Update opt-in is removed the default path can install nothing.
        Pinning -WindowsUpdate makes the OS install reliable AND inherently
        excludes SQL Server CUs (they arrive via Microsoft Update) - so SQL
        stays on its current build with no separate Remove-WUServiceManager step.

    SqlCU mode (SQL Server CU patching) - the cluster node stays ONLINE:
    Initialize suspends AG data movement and refreshes cloud AGENTS only, then
    Install-WindowsUpdate -MicrosoftUpdate installs the SQL CU (+ other MU
    content) and auto-reboots if required.
.PARAMETER Mode
    'Windows' for OS patches (node drained, WU channel only, single reboot at
    the end). 'SqlCU' for SQL Server CUs (cluster online, Microsoft Update
    channel). Required; no safe default.
.PARAMETER PagerDutyApiKey
    Forwarded to Initialize-MssqlOpsAgSecondaryPatching. See that function for
    resolution order.
.PARAMETER PagerDutyServiceId
    Forwarded to Initialize-MssqlOpsAgSecondaryPatching.
.PARAMETER MaintenanceDurationMinutes
    Forwarded to Initialize-MssqlOpsAgSecondaryPatching. Default: 30.
.PARAMETER SkipBlockingTransactionCheck
    Forwarded to Initialize-MssqlOpsAgSecondaryPatching. Overrides the
    blocking/stuck-transaction gate (rare).
.PARAMETER SkipCloudComponentUpdate
    Skip the cloud component refresh (no-op off AWS/GCP anyway).
.PARAMETER CloudComponentSource
    Per-cloud source (AWS pre-staged file directory / GCP GooGet repo) for
    firewalled hosts. Applied to this function's cloud refresh in Windows mode,
    or forwarded to Initialize in SqlCU mode.
.PARAMETER RequireCloudComponentUpdate
    Make the cloud component refresh a HARD GATE (abort on failure on an AWS/GCP
    host). In Windows mode the gate runs AFTER the OS update install and BEFORE
    the final reboot; if it fails, the OS update is already staged and the node
    is still drained - fix the component and re-run, or reboot + Resume.
.NOTES
    Version:        1.2
    Last Modified:  2026-09-10
    Author:         original module author
    Changes:        1.2 - Windows mode REORDERED: install the OS update from the
                          WINDOWS UPDATE channel (no reboot) BEFORE refreshing
                          cloud drivers, then reboot once at the end. Pinning
                          -WindowsUpdate makes the OS install reliable and never
                          pulls a SQL CU (fixes the field case where the driver
                          install rebooted before the OS CU was applied, and the
                          default-service install applied nothing after the
                          Microsoft Update opt-in was removed). Forwards
                          -SkipBlockingTransactionCheck.
                    1.1 - Forward cloud component-update options to
                          Initialize-MssqlOpsAgSecondaryPatching (v2.3).
    Errors:         If Initialize throws (incl. the blocking-transaction gate),
                    the function aborts before any update activity and the
                    original exception propagates. In Windows mode, if
                    Install-WindowsUpdate or the cloud refresh throws, the node is
                    left drained/suspended and NOT rebooted; fix the cause and
                    re-run, or reboot manually then run
                    Resume-MssqlOpsAgSecondaryPatching.
#>
function Install-MssqlOpsAgSecondaryPatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Windows', 'SqlCU')]
        [string]$Mode,

        [string]$PagerDutyApiKey,
        [string]$PagerDutyServiceId      = $script:PagerDutyServiceId,
        [int]$MaintenanceDurationMinutes = 30,
        [switch]$SkipBlockingTransactionCheck,
        [switch]$SkipCloudComponentUpdate,
        [string]$CloudComponentSource,
        [switch]$RequireCloudComponentUpdate
    )

    $ErrorActionPreference = 'Stop'

    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host " MssqlHadrOps  |  Install-MssqlOpsAgSecondaryPatch  |  Mode: $Mode" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan

    if ($Mode -eq 'Windows') {

        # ---- Step 1/4: prep (cloud refresh deferred to step 3) --------------
        Write-Host "`n Step 1/4: Pre-patch prep (gates -> suspend AG -> drain; cloud refresh deferred)" -ForegroundColor Cyan
        $initializeParams = @{
            Mode                       = 'Windows'
            PagerDutyServiceId         = $PagerDutyServiceId
            MaintenanceDurationMinutes = $MaintenanceDurationMinutes
            SkipCloudComponentUpdate   = $true      # defer: this function refreshes cloud at step 3, AFTER the OS update
        }
        if ($PagerDutyApiKey)               { $initializeParams.PagerDutyApiKey = $PagerDutyApiKey }
        if ($SkipBlockingTransactionCheck)  { $initializeParams.SkipBlockingTransactionCheck = $true }
        Initialize-MssqlOpsAgSecondaryPatching @initializeParams

        # ---- Step 2/4: OS updates FIRST, WU channel only, NO reboot ---------
        Write-Host "`n Step 2/4: Install Windows Updates (Windows Update channel only; no SQL CU; no reboot yet)" -ForegroundColor Cyan
        Install-WindowsUpdate -WindowsUpdate -AcceptAll -IgnoreReboot

        # ---- Step 3/4: refresh cloud drivers/agents now ---------------------
        Write-Host "`n Step 3/4: Refresh cloud system components (drivers + agents)" -ForegroundColor Cyan
        $cloudRebootRequired = $false
        if ($SkipCloudComponentUpdate) {
            Write-Host " -> SKIPPED by -SkipCloudComponentUpdate." -ForegroundColor Yellow
        } else {
            $cloudParams = @{ Scope = 'All' }
            if ($CloudComponentSource)        { $cloudParams.Source = $CloudComponentSource }
            if ($RequireCloudComponentUpdate) { $cloudParams.RequireSuccess = $true }
            $cloud = Update-MssqlOpsCloudSystemComponent @cloudParams
            if ($cloud.Managed) {
                foreach ($r in $cloud.Results) {
                    Write-Host ("    {0,-45} {1,-9} {2} -> {3}" -f $r.Name, $r.Action, ($r.FromVersion ?? 'n/a'), ($r.ToVersion ?? 'n/a'))
                }
                if ($cloud.RebootRequired) { $cloudRebootRequired = $true }
            }
        }

        # ---- Step 4/4: single reboot at the end (only if needed) ------------
        $pendingReboot = $true   # default to rebooting if we cannot determine (OS patching expects it)
        try { $pendingReboot = [bool](Test-MssqlOpsPendingReboot) } catch { $pendingReboot = $true }

        if ($cloudRebootRequired -or $pendingReboot) {
            Write-Host "`n Step 4/4: Rebooting to finalize the OS update + drivers." -ForegroundColor Cyan
            Write-Host "           After the node returns, run Resume-MssqlOpsAgSecondaryPatching." -ForegroundColor Cyan
            Restart-Computer -Force
        } else {
            Write-Host "`n Step 4/4: No reboot required (nothing staged needs one)." -ForegroundColor Green
            Write-Host "           Run Resume-MssqlOpsAgSecondaryPatching to resume AG data movement and lift the cluster pause." -ForegroundColor Green
        }

    } else {

        # ---- SqlCU: cluster node stays ONLINE -------------------------------
        Write-Host "`n Step 1/2: Pre-patch prep (gates -> suspend AG -> agents-only cloud refresh; node stays online)" -ForegroundColor Cyan
        $initializeParams = @{
            Mode                       = 'SqlCU'
            PagerDutyServiceId         = $PagerDutyServiceId
            MaintenanceDurationMinutes = $MaintenanceDurationMinutes
        }
        if ($PagerDutyApiKey)               { $initializeParams.PagerDutyApiKey = $PagerDutyApiKey }
        if ($SkipBlockingTransactionCheck)  { $initializeParams.SkipBlockingTransactionCheck = $true }
        if ($SkipCloudComponentUpdate)      { $initializeParams.SkipCloudComponentUpdate = $true }
        if ($CloudComponentSource)          { $initializeParams.CloudComponentSource = $CloudComponentSource }
        if ($RequireCloudComponentUpdate)   { $initializeParams.RequireCloudComponentUpdate = $true }
        Initialize-MssqlOpsAgSecondaryPatching @initializeParams

        Write-Host "`n Step 2/2: Install SQL CU + updates (Microsoft Update channel; auto-reboot if required)" -ForegroundColor Cyan
        Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -AutoReboot
    }
}
