function Write-PagerDutyKeyHint {
    [CmdletBinding()]
    param()

    Write-Host " -> SKIP: No PagerDuty API key found - operation continues, but any" -ForegroundColor Yellow
    Write-Host "    resulting PagerDuty alert must be closed manually." -ForegroundColor Yellow
    Write-Host "    To enable automatic maintenance windows next time, run once on this" -ForegroundColor Yellow
    Write-Host "    server as $env:USERDOMAIN\$env:USERNAME (DPAPI-encrypted at rest):" -ForegroundColor Yellow
    Write-Host "      Set-MssqlOpsPagerDutyUserApiToken" -ForegroundColor DarkGray
}
