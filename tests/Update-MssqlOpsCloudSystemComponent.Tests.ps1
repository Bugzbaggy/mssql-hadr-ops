# tests/Update-MssqlOpsCloudSystemComponent.Tests.ps1
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
#
# Covers the v1.2.8 change: -RequireSuccess must FAIL CLOSED on a platform with
# no implemented updater. Before 1.2.8 that path returned Managed=$false, which
# Initialize-MssqlOpsAgSecondaryPatching read as a satisfied gate - so an
# unverified node could walk into an in-place OS upgrade on stale ENA/NVMe or
# gVNIC/vioscsi drivers and come back with no NIC or no boot disk.

BeforeAll {
    function Get-MssqlOpsCloudPlatform { }

    # The stubs must mirror the real backends' parameter blocks. A bare
    # `function Foo { }` stub binds nothing, so $PSBoundParameters inside the
    # mock comes back empty and a passthrough assertion silently proves nothing.
    function Update-MssqlOpsAwsSystemComponent {
        [CmdletBinding(SupportsShouldProcess)]
        param(
            [ValidateSet('Agents', 'Drivers', 'All')][string]$Scope = 'All',
            [string]$Source,
            [switch]$RequireSuccess,
            [switch]$Force,
            [string]$WorkDir = 'C:\ProgramData\MssqlHadrOps\aws-components',
            [switch]$SkipSignatureCheck
        )
    }
    function Update-MssqlOpsGcpSystemComponent {
        [CmdletBinding(SupportsShouldProcess)]
        param(
            [ValidateSet('Agents', 'Drivers', 'All')][string]$Scope = 'All',
            [string]$Source,
            [switch]$RequireSuccess,
            [switch]$Force,
            [string]$GoogetPath
        )
    }

    . $PSScriptRoot/../MssqlHadrOps/Public/Update-MssqlOpsCloudSystemComponent.ps1

    $script:AwsResult = [pscustomobject]@{
        IsEc2 = $true; RebootRequired = $true
        Results = @([pscustomobject]@{ Name = 'AWS NVMe'; Action = 'Installed'; FromVersion = '1.4.0'; ToVersion = '1.5.0'; Error = $null })
    }
    $script:GcpResult = [pscustomobject]@{
        IsGce = $true; RebootRequired = $false
        Results = @([pscustomobject]@{ Name = 'gVNIC'; Action = 'Current'; FromVersion = '1.0.0'; ToVersion = '1.0.0'; Error = $null })
    }
}

Describe 'Update-MssqlOpsCloudSystemComponent' {

    Context 'dispatch on an implemented platform' {

        It 'routes an AWS host to the AWS backend and normalizes the result' {
            Mock Get-MssqlOpsCloudPlatform         { 'AWS' }
            Mock Update-MssqlOpsAwsSystemComponent { $script:AwsResult }
            Mock Update-MssqlOpsGcpSystemComponent { throw 'GCP backend must not run on AWS' }

            $r = Update-MssqlOpsCloudSystemComponent -Scope All -Confirm:$false
            $r.Platform       | Should -Be 'AWS'
            $r.Managed        | Should -BeTrue
            $r.RebootRequired | Should -BeTrue
            $r.Results.Count  | Should -Be 1
            Should -Invoke Update-MssqlOpsAwsSystemComponent -Times 1 -Exactly
        }

        It 'routes a GCP host to the GCP backend' {
            Mock Get-MssqlOpsCloudPlatform         { 'GCP' }
            Mock Update-MssqlOpsGcpSystemComponent { $script:GcpResult }
            Mock Update-MssqlOpsAwsSystemComponent { throw 'AWS backend must not run on GCP' }

            $r = Update-MssqlOpsCloudSystemComponent -Scope Agents -Confirm:$false
            $r.Platform       | Should -Be 'GCP'
            $r.Managed        | Should -BeTrue
            $r.RebootRequired | Should -BeFalse
            Should -Invoke Update-MssqlOpsGcpSystemComponent -Times 1 -Exactly
        }

        # Assert passthrough with Pester's own -ParameterFilter. Capturing
        # $PSBoundParameters into a $script: variable inside a mock body does NOT
        # work - the mock runs in Pester's scope, so the variable reads back
        # $null and every ContainsKey assertion trivially "passes".
        It 'forwards Scope, Source, Force and RequireSuccess to the backend' {
            Mock Get-MssqlOpsCloudPlatform         { 'AWS' }
            Mock Update-MssqlOpsAwsSystemComponent { $script:AwsResult }

            Update-MssqlOpsCloudSystemComponent -Scope Drivers -Source 'D:\staged' -Force -RequireSuccess -Confirm:$false | Out-Null

            Should -Invoke Update-MssqlOpsAwsSystemComponent -Times 1 -Exactly -ParameterFilter {
                $Scope -eq 'Drivers' -and $Source -eq 'D:\staged' -and $Force -and $RequireSuccess
            }
        }

        It 'does not pass Source, Force or RequireSuccess when they were not supplied' {
            Mock Get-MssqlOpsCloudPlatform         { 'AWS' }
            Mock Update-MssqlOpsAwsSystemComponent { $script:AwsResult }

            Update-MssqlOpsCloudSystemComponent -Confirm:$false | Out-Null

            Should -Invoke Update-MssqlOpsAwsSystemComponent -Times 1 -Exactly -ParameterFilter {
                -not $PSBoundParameters.ContainsKey('Source')  -and
                -not $PSBoundParameters.ContainsKey('Force')   -and
                -not $PSBoundParameters.ContainsKey('RequireSuccess') -and
                $Scope -eq 'All'
            }
        }
    }

    Context 'fail-closed behaviour (the v1.2.8 fix)' {

        It 'THROWS on an unidentified platform when -RequireSuccess is used' {
            Mock Get-MssqlOpsCloudPlatform { 'Other' }

            { Update-MssqlOpsCloudSystemComponent -RequireSuccess -Confirm:$false } |
                Should -Throw -ExpectedMessage '*no implemented component updater*'
        }

        It 'THROWS on Azure when -RequireSuccess is used, and names the platform' {
            Mock Get-MssqlOpsCloudPlatform { 'Azure' }

            { Update-MssqlOpsCloudSystemComponent -RequireSuccess -Confirm:$false } |
                Should -Throw -ExpectedMessage "*'Azure'*"
        }

        It 'tells the operator how to proceed deliberately' {
            Mock Get-MssqlOpsCloudPlatform { 'Other' }

            { Update-MssqlOpsCloudSystemComponent -RequireSuccess -Confirm:$false } |
                Should -Throw -ExpectedMessage '*-SkipCloudComponentUpdate*'
        }

        It 'never invokes a backend when the platform is unimplemented' {
            Mock Get-MssqlOpsCloudPlatform         { 'Other' }
            Mock Update-MssqlOpsAwsSystemComponent { }
            Mock Update-MssqlOpsGcpSystemComponent { }

            Update-MssqlOpsCloudSystemComponent -Confirm:$false | Out-Null

            Should -Invoke Update-MssqlOpsAwsSystemComponent -Times 0 -Exactly
            Should -Invoke Update-MssqlOpsGcpSystemComponent -Times 0 -Exactly
        }
    }

    Context 'non-gated and rehearsal paths stay non-fatal' {

        It 'is a clean, non-throwing skip on an unimplemented platform without -RequireSuccess' {
            Mock Get-MssqlOpsCloudPlatform { 'Other' }

            $r = Update-MssqlOpsCloudSystemComponent -Confirm:$false
            $r.Platform      | Should -Be 'Other'
            $r.Managed       | Should -BeFalse
            $r.Results.Count | Should -Be 0
        }

        It 'warns but does NOT throw under -WhatIf, honouring rehearsal semantics' {
            Mock Get-MssqlOpsCloudPlatform { 'Other' }

            $warnings = @()
            $r = Update-MssqlOpsCloudSystemComponent -RequireSuccess -WhatIf -WarningVariable warnings -WarningAction SilentlyContinue
            $r.Managed  | Should -BeFalse
            ($warnings -join ' ') | Should -Match 'WOULD ABORT'
        }

        It 'does not dispatch to a backend under -WhatIf on a real cloud platform' {
            Mock Get-MssqlOpsCloudPlatform         { 'AWS' }
            Mock Update-MssqlOpsAwsSystemComponent { $script:AwsResult }

            Update-MssqlOpsCloudSystemComponent -WhatIf | Out-Null
            Should -Invoke Update-MssqlOpsAwsSystemComponent -Times 0 -Exactly
        }
    }
}
