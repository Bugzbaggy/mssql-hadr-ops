# tests/Test-MssqlOpsAgListenerNetwork.Tests.ps1
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
#
# The FailoverClusters cmdlets do not exist on a build agent, so the tests stub
# them first and then mock the stubs. Every fixture is modelled on the real
# ag-staging1 / staging-dbcluster1 topology that produced the 2026-09-14 ->
# 2026-09-22 incident. Addresses below are RFC 5737 documentation placeholders
# from two different ranges so the two real subnets stay visually distinct;
# the relationship that matters - a listener IP inside one network's subnet
# and outside the other's - is preserved by the fixtures, not by the octets
# looking alike:
#     Cluster Network 1  198.51.100.0/21  STAGING-NODE1  Ethernet 3  198.51.100.128
#     Cluster Network 2  192.0.2.0/21     STAGING-NODE2  Ethernet 3  192.0.2.128
#     listener ag-staging1_<addr> -> 198.51.100.130 (net 1) + 192.0.2.130 (net 2)

BeforeAll {
    # Stubs so Mock has something to bind to. The params look unused to
    # PSScriptAnalyzer but are required: Mock matches on -Name / -InputObject.
    function Get-ClusterResource         { param([string]$Name) }
    function Get-ClusterNetwork          { }
    function Get-ClusterNetworkInterface { }
    function Get-ClusterParameter        { param($InputObject, [string]$Name) }
    function Test-MssqlOpsIsEc2          { }

    . $PSScriptRoot/../MssqlHadrOps/Public/Test-MssqlOpsAgListenerNetwork.ps1

    function Get-IpResourceFixture {
        param([string]$Name, [hashtable]$Params, [string]$Group = 'ag-staging1')
        [pscustomobject]@{
            Name = $Name; ResourceType = 'IP Address'; OwnerGroup = $Group
            State = 'Online'; Params = $Params
        }
    }
    function Get-NicFixture {
        param([string]$Node, [string]$Adapter, [string]$Address, [string]$Network)
        [pscustomobject]@{
            Name = "$Node - $Adapter"; Node = $Node; Adapter = $Adapter
            Address = $Address; Network = $Network; State = 'Up'
        }
    }

    $script:AgRes = [pscustomobject]@{
        Name = 'ag-staging1'; ResourceType = 'SQL Server Availability Group'
        OwnerGroup = 'ag-staging1'; State = 'Online'; Params = @{}
    }
    $script:Networks = @(
        [pscustomobject]@{ Name = 'Cluster Network 1'; Address = '198.51.100.0'; AddressMask = '255.255.248.0' }
        [pscustomobject]@{ Name = 'Cluster Network 2'; Address = '192.0.2.0';    AddressMask = '255.255.248.0' }
    )
    $script:HealthyNics = @(
        Get-NicFixture -Node 'STAGING-NODE1' -Adapter 'Ethernet 3' -Address '198.51.100.128' -Network 'Cluster Network 1'
        Get-NicFixture -Node 'STAGING-NODE2' -Adapter 'Ethernet 3' -Address '192.0.2.128'     -Network 'Cluster Network 2'
    )
    $script:HealthyIps = @(
        Get-IpResourceFixture -Name 'ag-staging1_198.51.100.130' -Params @{ Address = '198.51.100.130'; Network = 'Cluster Network 1'; ProbePort = '1444' }
        Get-IpResourceFixture -Name 'ag-staging1_192.0.2.130'    -Params @{ Address = '192.0.2.130';    Network = 'Cluster Network 2'; ProbePort = '1444' }
    )
}

Describe 'Test-MssqlOpsAgListenerNetwork' {

    BeforeEach {
        Mock Get-ClusterResource         { $script:FixRes }
        Mock Get-ClusterNetwork          { $script:FixNets }
        Mock Get-ClusterNetworkInterface { $script:FixNics }
        Mock Get-ClusterParameter {
            if (-not $InputObject.Params.ContainsKey($Name)) { throw "Cluster parameter '$Name' not found." }
            [pscustomobject]@{ Name = $Name; Value = $InputObject.Params[$Name] }
        }
    }

    It 'passes a correctly configured multi-subnet listener' {
        $script:FixRes  = @($script:AgRes) + $script:HealthyIps
        $script:FixNics = $script:HealthyNics
        $script:FixNets = $script:Networks

        $r = Test-MssqlOpsAgListenerNetwork -SkipEniCheck
        $r.Healthy  | Should -BeTrue
        $r.Failures | Should -BeNullOrEmpty
        $r.Checks.Count | Should -Be 2
        ($r.Checks.Verdict | Select-Object -Unique) | Should -Be 'OK'
    }

    It 'fails when a node has two interfaces on one cluster network (the staging-node2 root cause)' {
        $script:FixRes  = @($script:AgRes) + $script:HealthyIps
        # 203.0.113.210 is placed on the SAME cluster network as Ethernet 3 even
        # though its address is drawn from a different documentation range: in
        # the real topology this interface's /21 subnet was the same one
        # Ethernet 3 sat in, so WSFC folded both into Cluster Network 2 - exactly
        # what broke ag-staging1's failover to STAGING-NODE2. The fixture only
        # asserts the fact this function actually checks: both interfaces
        # report the SAME ClusterNetwork name.
        $script:FixNics = $script:HealthyNics + @(
            Get-NicFixture -Node 'STAGING-NODE2' -Adapter 'Ethernet 4' -Address '203.0.113.210' -Network 'Cluster Network 2'
        )
        $script:FixNets = $script:Networks

        $r = Test-MssqlOpsAgListenerNetwork -SkipEniCheck
        $r.Healthy | Should -BeFalse
        ($r.Failures -join ' ') | Should -Match 'DuplicateInterface'
        ($r.Failures -join ' ') | Should -Match 'STAGING-NODE2'
        ($r.Failures -join ' ') | Should -Match 'Ethernet 4'
        ($r.Checks | Where-Object Address -eq '192.0.2.130').Verdict | Should -Be 'DuplicateInterface'
    }

    It 'fails when the IP resource points at a cluster network that no longer exists' {
        $script:FixRes = @($script:AgRes) + @(
            $script:HealthyIps[0]
            Get-IpResourceFixture -Name 'ag-staging1_192.0.2.130' -Params @{
                Address = '192.0.2.130'; Network = '412c8c34-dead-beef-0000-000000000000'; ProbePort = '1444' }
        )
        $script:FixNics = $script:HealthyNics
        $script:FixNets = $script:Networks

        $r = Test-MssqlOpsAgListenerNetwork -SkipEniCheck
        $r.Healthy | Should -BeFalse
        ($r.Failures -join ' ') | Should -Match 'DanglingNetwork'
    }

    It 'fails when the listener IP is outside its cluster network subnet' {
        $script:FixRes = @($script:AgRes) + @(
            $script:HealthyIps[0]
            Get-IpResourceFixture -Name 'ag-staging1_203.0.113.130' -Params @{
                Address = '203.0.113.130'; Network = 'Cluster Network 2'; ProbePort = '1444' }
        )
        $script:FixNics = $script:HealthyNics
        $script:FixNets = $script:Networks

        $r = Test-MssqlOpsAgListenerNetwork -SkipEniCheck
        $r.Healthy | Should -BeFalse
        ($r.Failures -join ' ') | Should -Match 'SubnetMismatch'
    }

    It 'fails when the listener IP resources disagree on ProbePort' {
        $script:FixRes = @($script:AgRes) + @(
            $script:HealthyIps[0]
            Get-IpResourceFixture -Name 'ag-staging1_192.0.2.130' -Params @{
                Address = '192.0.2.130'; Network = 'Cluster Network 2'; ProbePort = '0' }
        )
        $script:FixNics = $script:HealthyNics
        $script:FixNets = $script:Networks

        $r = Test-MssqlOpsAgListenerNetwork -SkipEniCheck
        $r.Healthy | Should -BeFalse
        ($r.Failures -join ' ') | Should -Match 'ProbePortMismatch'
    }

    It 'is a clean no-op on a cluster with no availability group resources' {
        $script:FixRes  = @()
        $script:FixNics = $script:HealthyNics
        $script:FixNets = $script:Networks

        $r = Test-MssqlOpsAgListenerNetwork -SkipEniCheck
        $r.Healthy | Should -BeTrue
        ($r.Warnings -join ' ') | Should -Match 'No availability group cluster resources'
    }

    It 'restricts the audit to the named availability group' {
        $script:FixRes  = @($script:AgRes) + $script:HealthyIps
        $script:FixNics = $script:HealthyNics
        $script:FixNets = $script:Networks

        { Test-MssqlOpsAgListenerNetwork -AvailabilityGroup 'ag-does-not-exist' -SkipEniCheck -EnableException } |
            Should -Throw -ExpectedMessage '*No availability group cluster resource group*'
    }

    It 'throws with -EnableException when a check fails' {
        $script:FixRes  = @($script:AgRes) + $script:HealthyIps
        $script:FixNics = $script:HealthyNics + @(
            Get-NicFixture -Node 'STAGING-NODE2' -Adapter 'Ethernet 4' -Address '203.0.113.210' -Network 'Cluster Network 2'
        )
        $script:FixNets = $script:Networks

        { Test-MssqlOpsAgListenerNetwork -SkipEniCheck -EnableException } |
            Should -Throw -ExpectedMessage '*AG listener network gate failed*'
    }

    Context 'ENI membership check (check 4)' {

        # The nodes are named STAGING-NODE1/NODE2, which never match this
        # machine's $env:COMPUTERNAME, so the function takes its
        # Invoke-Command path for both - which is what makes the probe
        # mockable here.
        BeforeEach {
            $script:FixRes  = @($script:AgRes) + $script:HealthyIps
            $script:FixNics = $script:HealthyNics
            $script:FixNets = $script:Networks
            Mock Test-MssqlOpsIsEc2 { $true }
        }

        It 'passes when each listener IP is present on its node ENI' {
            Mock Invoke-Command {
                switch -Wildcard ($ComputerName) {
                    '*NODE1' { [pscustomobject]@{ Ok = $true; Error = $null
                               IfaceMac = @{ '198.51.100.128' = '02:11:11:11:11:11' }
                               MacIps   = @{ '02:11:11:11:11:11' = @('198.51.100.128','198.51.100.129','198.51.100.130') } } }
                    '*NODE2' { [pscustomobject]@{ Ok = $true; Error = $null
                               IfaceMac = @{ '192.0.2.128' = '02:22:22:22:22:22' }
                               MacIps   = @{ '02:22:22:22:22:22' = @('192.0.2.128','192.0.2.129','192.0.2.130') } } }
                }
            }

            $r = Test-MssqlOpsAgListenerNetwork
            $r.Healthy  | Should -BeTrue
            $r.Failures | Should -BeNullOrEmpty
        }

        It 'fails with IpNotOnEni when the ENI does not carry the listener IP (the staging-node2 .130 gap)' {
            Mock Invoke-Command {
                switch -Wildcard ($ComputerName) {
                    '*NODE1' { [pscustomobject]@{ Ok = $true; Error = $null
                               IfaceMac = @{ '198.51.100.128' = '02:11:11:11:11:11' }
                               MacIps   = @{ '02:11:11:11:11:11' = @('198.51.100.128','198.51.100.129','198.51.100.130') } } }
                    # NODE2's ENI holds only its primary address - .129/.130 were never assigned.
                    '*NODE2' { [pscustomobject]@{ Ok = $true; Error = $null
                               IfaceMac = @{ '192.0.2.128' = '02:22:22:22:22:22' }
                               MacIps   = @{ '02:22:22:22:22:22' = @('192.0.2.128') } } }
                }
            }

            $r = Test-MssqlOpsAgListenerNetwork
            $r.Healthy | Should -BeFalse
            ($r.Failures -join ' ') | Should -Match 'IpNotOnEni'
            ($r.Failures -join ' ') | Should -Match '192\.0\.2\.130'
            ($r.Failures -join ' ') | Should -Match 'STAGING-NODE2'
            ($r.Checks | Where-Object Address -eq '192.0.2.130').Verdict | Should -Be 'IpNotOnEni'
            # NODE1's side is correctly configured and must not be flagged.
            ($r.Checks | Where-Object Address -eq '198.51.100.130').Verdict | Should -Be 'OK'
        }

        It 'degrades to a warning, not a failure, when the peer probe cannot run' {
            Mock Invoke-Command { throw 'WinRM cannot complete the operation' }

            $r = Test-MssqlOpsAgListenerNetwork
            $r.Healthy | Should -BeTrue
            ($r.Warnings -join ' ') | Should -Match 'Could not run the ENI check'
        }

        It 'degrades to a warning when IMDS itself fails on the node' {
            Mock Invoke-Command {
                [pscustomobject]@{ Ok = $false; Error = 'metadata service timed out'; IfaceMac = @{}; MacIps = @{} }
            }

            $r = Test-MssqlOpsAgListenerNetwork
            $r.Healthy | Should -BeTrue
            ($r.Warnings -join ' ') | Should -Match 'IMDSv2 probe'
        }

        It 'skips the ENI probe entirely when -SkipEniCheck is passed' {
            Mock Invoke-Command { throw 'must not be called' }

            $r = Test-MssqlOpsAgListenerNetwork -SkipEniCheck
            $r.Healthy | Should -BeTrue
            Should -Invoke Invoke-Command -Times 0 -Exactly
        }
    }

    It 'warns instead of failing when the host is not EC2 and the ENI check is requested' {
        $script:FixRes  = @($script:AgRes) + $script:HealthyIps
        $script:FixNics = $script:HealthyNics
        $script:FixNets = $script:Networks
        Mock Test-MssqlOpsIsEc2 { $false }

        $r = Test-MssqlOpsAgListenerNetwork
        $r.Healthy | Should -BeTrue
        ($r.Warnings -join ' ') | Should -Match 'Not an EC2 instance'
    }
}
