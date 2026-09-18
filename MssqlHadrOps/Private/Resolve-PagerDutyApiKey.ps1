function Resolve-PagerDutyApiKey {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Initial
    )

    if ($Initial) { return $Initial }

    if (Get-Command -Name Get-Secret -ErrorAction SilentlyContinue) {
        try {
            $secret = Get-Secret -Name 'PAGERDUTY_USER_API_TOKEN' -AsPlainText -ErrorAction Stop
            if ($secret) { return $secret }
        } catch {
            # Secret not present in any registered vault; fall through to env var.
        }
    }

    if ($env:PAGERDUTY_USER_API_TOKEN) { return $env:PAGERDUTY_USER_API_TOKEN }

    return $null
}
