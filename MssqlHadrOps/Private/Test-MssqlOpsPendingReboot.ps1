<#
.SYNOPSIS
    Returns $true when Windows has a pending reboot flagged.
.DESCRIPTION
    Shared by the AWS and GCP component updaters to fold an OS-level
    pending-reboot signal into their RebootRequired result. Checks the
    Component Based Servicing and Windows Update flags plus any queued
    PendingFileRenameOperations.
#>
function Test-MssqlOpsPendingReboot {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }

    $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
        -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    return [bool]$pfro
}
