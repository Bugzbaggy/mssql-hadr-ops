<#
.SYNOPSIS
    Stores a personal PagerDuty User API Token in this Windows user's
    SecretManagement vault for use by the MssqlHadrOps module.
.DESCRIPTION
    Bootstraps Microsoft.PowerShell.SecretManagement + SecretStore on this
    server (idempotent), prompts for your personal PagerDuty User API Token,
    and stores it under the name 'PAGERDUTY_USER_API_TOKEN'. The vault is
    DPAPI-encrypted at rest and accessible only to the same Windows account
    on the same machine.

    Run once per server per DBA. To rotate the token, simply run this command
    again - the existing entry is replaced.

    Once stored, Initialize-MssqlOpsAgSecondaryPatching, Resume-MssqlOpsAgSecondaryPatching,
    and Invoke-MssqlOpsAgPlannedFailover will all pick the token up automatically
    (resolution order: -PagerDutyApiKey parameter -> Get-Secret
    PAGERDUTY_USER_API_TOKEN -> $env:PAGERDUTY_USER_API_TOKEN).

    Get your User API Token at: PagerDuty -> User Profile -> User Settings -> API Access.
.PARAMETER SecretName
    Name under which the token is stored. Default 'PAGERDUTY_USER_API_TOKEN'.
    Change only if you also intend to read it under a different name elsewhere.
.NOTES
    Version:        2.0
    Last Modified:  2026-05-10
    Author:         original module author
    Changes:        2.0 - Refactored from script to function inside MssqlHadrOps module.
                    1.0 - Initial standalone script.
#>
function Set-MssqlOpsPagerDutyUserApiToken {
    [CmdletBinding()]
    param(
        [string]$SecretName = 'PAGERDUTY_USER_API_TOKEN'
    )

    $ErrorActionPreference = 'Stop'

    Write-Host "===============================================================" -ForegroundColor Cyan
    Write-Host " Configure PagerDuty User API Token for MssqlHadrOps"             -ForegroundColor Cyan
    Write-Host " Server:        $env:COMPUTERNAME"                               -ForegroundColor Cyan
    Write-Host " Windows user:  $env:USERDOMAIN\$env:USERNAME"                   -ForegroundColor Cyan
    Write-Host "===============================================================" -ForegroundColor Cyan

    # -------------------------------------------------------------------------
    # STEP 1: Ensure SecretManagement + SecretStore are installed
    # -------------------------------------------------------------------------
    Write-Host "`n[1/4] Verifying SecretManagement modules..." -ForegroundColor Yellow

    $required = 'Microsoft.PowerShell.SecretManagement','Microsoft.PowerShell.SecretStore'
    $missing  = $required | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
    if ($missing) {
        Write-Host " -> Installing for current user: $($missing -join ', ')" -ForegroundColor Yellow
        Install-Module -Name $missing -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module Microsoft.PowerShell.SecretManagement
    Import-Module Microsoft.PowerShell.SecretStore
    Write-Host " -> Modules ready." -ForegroundColor Green

    # -------------------------------------------------------------------------
    # STEP 2: Register SecretStore as the default vault if it isn't already
    # -------------------------------------------------------------------------
    Write-Host "`n[2/4] Registering default SecretStore vault..." -ForegroundColor Yellow

    if (Get-SecretVault -Name SecretStore -ErrorAction SilentlyContinue) {
        Write-Host " -> Vault already registered." -ForegroundColor Green
    } else {
        Register-SecretVault -Name SecretStore -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
        Write-Host " -> Vault registered as default." -ForegroundColor Green
    }

    # -------------------------------------------------------------------------
    # STEP 3: Configure the vault for unattended access (no master password)
    # -------------------------------------------------------------------------
    Write-Host "`n[3/4] Configuring vault for unattended use..." -ForegroundColor Yellow
    Set-SecretStoreConfiguration -Authentication None -Interaction None -Confirm:$false
    Write-Host " -> Authentication=None, Interaction=None (DPAPI still protects data at rest)." -ForegroundColor Green

    # -------------------------------------------------------------------------
    # STEP 4: Prompt for the token and store it
    # -------------------------------------------------------------------------
    Write-Host "`n[4/4] Storing the PagerDuty User API Token under '$SecretName'..." -ForegroundColor Yellow

    if (Get-SecretInfo -Name $SecretName -ErrorAction SilentlyContinue) {
        Write-Host " -> An existing '$SecretName' is stored - it will be replaced." -ForegroundColor Yellow
    }

    $secure = Read-Host -AsSecureString -Prompt "Paste your PagerDuty User API Token"
    if (-not $secure -or $secure.Length -eq 0) {
        Write-Host " -> Nothing entered. Aborted; no changes were made." -ForegroundColor Red
        return
    }

    Set-Secret -Name $SecretName -Secret $secure

    Write-Host "`n===============================================================" -ForegroundColor Cyan
    Write-Host " SUCCESS." -ForegroundColor Green
    Write-Host "   Secret '$SecretName' is stored in vault 'SecretStore'." -ForegroundColor Green
    Write-Host "   MssqlHadrOps functions will now find it on this server" -ForegroundColor Green
    Write-Host "   when launched as $env:USERDOMAIN\$env:USERNAME." -ForegroundColor Green
    Write-Host "===============================================================" -ForegroundColor Cyan
}
