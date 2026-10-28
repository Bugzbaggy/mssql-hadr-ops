# tests/Get-MssqlOpsCloudPlatform.Tests.ps1
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
#
# Covers the v1.2.8 platform resolver. The detection order matters: it is what
# decides which component updater runs, and 'Other' is the value that makes the
# hard gate fail closed.

BeforeAll {
    # Stubs so Mock has something to bind to (the real detectors do CIM + IMDS).
    function Test-MssqlOpsIsEc2   { }
    function Test-MssqlOpsIsGce   { }
    function Test-MssqlOpsIsAzure { }

    . $PSScriptRoot/../MssqlHadrOps/Private/Get-MssqlOpsCloudPlatform.ps1
}

Describe 'Get-MssqlOpsCloudPlatform' {

    It 'returns AWS when the EC2 detector fires' {
        Mock Test-MssqlOpsIsEc2   { $true }
        Mock Test-MssqlOpsIsGce   { $false }
        Mock Test-MssqlOpsIsAzure { $false }

        Get-MssqlOpsCloudPlatform | Should -Be 'AWS'
    }

    It 'returns GCP when only the GCE detector fires' {
        Mock Test-MssqlOpsIsEc2   { $false }
        Mock Test-MssqlOpsIsGce   { $true }
        Mock Test-MssqlOpsIsAzure { $false }

        Get-MssqlOpsCloudPlatform | Should -Be 'GCP'
    }

    It 'returns Azure when only the Azure detector fires' {
        Mock Test-MssqlOpsIsEc2   { $false }
        Mock Test-MssqlOpsIsGce   { $false }
        Mock Test-MssqlOpsIsAzure { $true }

        Get-MssqlOpsCloudPlatform | Should -Be 'Azure'
    }

    It "returns Other when nothing identifies the host" {
        Mock Test-MssqlOpsIsEc2   { $false }
        Mock Test-MssqlOpsIsGce   { $false }
        Mock Test-MssqlOpsIsAzure { $false }

        Get-MssqlOpsCloudPlatform | Should -Be 'Other'
    }

    It 'short-circuits on AWS without consulting the slower GCE/Azure probes' {
        Mock Test-MssqlOpsIsEc2   { $true }
        Mock Test-MssqlOpsIsGce   { $true }   # would win if order were wrong
        Mock Test-MssqlOpsIsAzure { $true }

        Get-MssqlOpsCloudPlatform | Should -Be 'AWS'
        Should -Invoke Test-MssqlOpsIsGce   -Times 0 -Exactly
        Should -Invoke Test-MssqlOpsIsAzure -Times 0 -Exactly
    }

    It 'prefers GCP over Azure when both would answer' {
        Mock Test-MssqlOpsIsEc2   { $false }
        Mock Test-MssqlOpsIsGce   { $true }
        Mock Test-MssqlOpsIsAzure { $true }

        Get-MssqlOpsCloudPlatform | Should -Be 'GCP'
        Should -Invoke Test-MssqlOpsIsAzure -Times 0 -Exactly
    }
}
