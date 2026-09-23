<#
.SYNOPSIS
    Audits the WSFC network topology behind an Availability Group listener and
    fails when a listener IP resource cannot come online on the node that would
    have to host it.
.DESCRIPTION
    Returns a [pscustomobject] with .Healthy, .Failures, .Warnings and .Checks
    (one row per listener IP resource). With -EnableException, throws instead.

    Why this exists: the staging incident of 2026-09-14 -> 2026-09-22. Failover
    of ag-staging1 to STAGING-NODE2 failed seven times over eight days. Every
    friendly-name view of the configuration looked correct - Get-ClusterResource,
    Get-ClusterOwnerNode, the dependency report, possible owners, the NLB target
    group and the firewall rules all reported a healthy multi-subnet listener.
    The defect was only visible by cross-referencing the raw netinterface GUID in
    the cluster log ("Registered notification for netinterface <guid>")
    against the [=== Network Interfaces ===] table of the same dump.

    STAGING-NODE2 had two NICs that WSFC had folded into ONE cluster network:
        Ethernet 3  192.0.2.128/21    netinterface aaaaaaaa-0000-0000-0000-00000000000a
        Ethernet 4  203.0.113.210/21  netinterface bbbbbbbb-0000-0000-0000-00000000000b
    (The two addresses above are placeholders drawn from different RFC 5737
    documentation ranges so they stay visually distinct in this text. In the
    real topology both interfaces sat inside a single /21: the subnet mask
    rounds the third octet down, so two addresses that look like different
    subnets can still fold together into one WSFC cluster network. What this
    function actually checks is that fold-together fact itself - two
    interfaces reporting the SAME ClusterNetwork name - not whether their
    addresses look alike.)
    A cluster network is defined by SUBNET, so WSFC folded both into
    'Cluster Network 2' and bound the listener IP resource ag-staging1_192.0.2.130
    to Ethernet 4 - whose ENI never carried .130. The resource could not come
    online on STAGING-NODE2, so every failover left the AG in RESOLVING.

    Three separate defects had to be fixed before the AG would move. This
    function detects all three, plus the AWS NLB probe-port variant:

      1. DanglingNetwork    - the IP resource's Network parameter names a cluster
                              network that no longer exists (a stale GUID left by
                              a deleted network object).
      2. SubnetMismatch     - the listener IP is not inside the subnet of the
                              cluster network it is assigned to.
      3. DuplicateInterface - a node has MORE THAN ONE cluster network interface
                              on a cluster network that carries a listener IP.
                              This is the root cause above, and it is not
                              fixable by configuration: there is no supported way
                              to exclude a single interface from a cluster
                              network. The extra NIC must be removed, or moved to
                              a DIFFERENT subnet so it forms its own network.
      4. IpNotOnEni         - (AWS only) the listener IP is not a private IP on
                              the ENI behind the interface WSFC would bind on
                              that node. Read from IMDSv2, deliberately NOT from
                              Get-NetIPAddress: the cluster plumbs the address
                              into Windows only while the resource is Online, so
                              on the standby node Get-NetIPAddress is always
                              empty and would pass a broken configuration.
      5. ProbePortMismatch  - the listener's IP resources disagree on ProbePort.
                              Behind an AWS NLB every listener IP must carry the
                              same ProbePort, or the target for the node holding
                              the odd one out never becomes healthy.

    Read-only, touches no SQL database, and is a clean no-op on a host with no
    availability group cluster resources.
.PARAMETER AvailabilityGroup
    Restrict the audit to one AG's cluster group. Default: every availability
    group resource group on the cluster.
.PARAMETER SkipEniCheck
    Skip check 4 (the IMDSv2 ENI membership probe). Use on a firewalled host, or
    when WinRM to the peer node is unavailable and the warning is just noise.
.PARAMETER EnableException
    Throw on failure instead of returning .Healthy = $false.
.EXAMPLE
    Test-MssqlOpsAgListenerNetwork | Select-Object -ExpandProperty Checks | Format-Table

    Audit every AG listener on this cluster and print the per-resource verdicts.
.NOTES
    Version:        1.0
    Last Modified:  2026-09-22
    Author:         Renz Bagasbas
#>
function Test-MssqlOpsAgListenerNetwork {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$AvailabilityGroup,
        [switch]$SkipEniCheck,
        [switch]$EnableException
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $checks   = [System.Collections.Generic.List[pscustomobject]]::new()

    # Every cluster object below can arrive DESERIALIZED (FailoverClusters loads
    # through WinPSCompat under PS7 - see MssqlHadrOps.psm1). Cast to [string]
    # before comparing, and never pipe into Get-ClusterParameter: a deserialized
    # object does not bind by pipeline, but it does bind to -InputObject.
    function Get-IpResourceParameter {
        param($Resource, [string]$Name)
        try {
            $p = Get-ClusterParameter -InputObject $Resource -Name $Name -ErrorAction Stop
            if ($null -eq $p) { return $null }
            return [string]$p.Value
        } catch {
            return $null
        }
    }

    function Test-Ipv4InSubnet {
        param([string]$Ip, [string]$Network, [string]$Mask)
        try {
            $a = [System.Net.IPAddress]::Parse($Ip).GetAddressBytes()
            $n = [System.Net.IPAddress]::Parse($Network).GetAddressBytes()
            $m = [System.Net.IPAddress]::Parse($Mask).GetAddressBytes()
            if ($a.Length -ne 4 -or $n.Length -ne 4 -or $m.Length -ne 4) { return $null }
            for ($i = 0; $i -lt 4; $i++) {
                if (($a[$i] -band $m[$i]) -ne ($n[$i] -band $m[$i])) { return $false }
            }
            return $true
        } catch {
            return $null
        }
    }

    # -------------------------------------------------------------------------
    # Enumerate cluster objects once
    # -------------------------------------------------------------------------
    try {
        $allRes  = @(Get-ClusterResource -ErrorAction Stop)
        $allNets = @(Get-ClusterNetwork -ErrorAction Stop)
        $allNics = @(Get-ClusterNetworkInterface -ErrorAction Stop)
    } catch {
        $msg = "Could not enumerate cluster objects: $($_.Exception.Message)"
        if ($EnableException) { throw $msg }
        return [pscustomobject]@{ Healthy = $false; Failures = @($msg); Warnings = @(); Checks = @() }
    }

    # An AG's cluster group holds exactly one 'SQL Server Availability Group'
    # resource. Matching on the resource type is more reliable than GroupType,
    # which deserializes to an enum whose string form varies by OS build.
    $agGroups = @(
        $allRes |
            Where-Object { [string]$_.ResourceType -eq 'SQL Server Availability Group' } |
            ForEach-Object { [string]$_.OwnerGroup } |
            Select-Object -Unique
    )

    if ($AvailabilityGroup) {
        $agGroups = @($agGroups | Where-Object { $_ -ieq $AvailabilityGroup })
        if (-not $agGroups) {
            $msg = "No availability group cluster resource group named '$AvailabilityGroup' on this cluster."
            if ($EnableException) { throw $msg }
            return [pscustomobject]@{ Healthy = $false; Failures = @($msg); Warnings = @(); Checks = @() }
        }
    }

    if (-not $agGroups) {
        $warnings.Add("No availability group cluster resources found; listener network audit skipped.")
        return [pscustomobject]@{ Healthy = $true; Failures = @(); Warnings = $warnings.ToArray(); Checks = @() }
    }

    # node -> @{ InterfaceIps = @(); Listeners = @() } queued for the ENI probe
    $eniWanted = @{}

    foreach ($groupName in $agGroups) {

        $ipResources = @(
            $allRes | Where-Object {
                [string]$_.OwnerGroup -eq $groupName -and
                [string]$_.ResourceType -match '^IP(v6)? Address$'
            }
        )

        if (-not $ipResources) {
            $warnings.Add("AG group '$groupName' has no IP address resource (no listener configured?).")
            continue
        }

        $probePorts = @{}

        foreach ($res in $ipResources) {
            $resName   = [string]$res.Name
            $ipAddress = Get-IpResourceParameter -Resource $res -Name 'Address'
            $netName   = Get-IpResourceParameter -Resource $res -Name 'Network'
            $probePort = Get-IpResourceParameter -Resource $res -Name 'ProbePort'

            $row = [pscustomobject]@{
                AvailabilityGroup = $groupName
                Resource          = $resName
                Address           = $ipAddress
                State             = [string]$res.State
                ClusterNetwork    = $netName
                ProbePort         = $probePort
                InterfacesPerNode = ''
                Verdict           = 'OK'
            }

            if (-not $ipAddress) {
                $warnings.Add("[$resName] Could not read the 'Address' parameter; this resource was not audited.")
                $row.Verdict = 'Unreadable'
                $checks.Add($row)
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace($probePort)) { $probePorts[$resName] = $probePort }

            # --- Check 1: the Network parameter resolves to a live cluster network
            if (-not $netName) {
                $warnings.Add("[$resName] Could not read the 'Network' parameter; checks 1-4 were skipped for it.")
                $row.Verdict = 'Unreadable'
                $checks.Add($row)
                continue
            }

            $net = $allNets | Where-Object { [string]$_.Name -ieq $netName } | Select-Object -First 1
            if (-not $net) {
                $failures.Add("[$resName] DanglingNetwork: its Network parameter is '$netName', which is not a live cluster network. The resource points at a deleted network object and cannot come online. Fix: Set-ClusterParameter -InputObject (Get-ClusterResource -Name '$resName') -Name Network -Value '<correct network>', then take the resource offline/online.")
                $row.Verdict = 'DanglingNetwork'
                $checks.Add($row)
                continue
            }

            # --- Check 2: the listener IP sits inside that network's subnet
            $inSubnet = Test-Ipv4InSubnet -Ip $ipAddress -Network ([string]$net.Address) -Mask ([string]$net.AddressMask)
            if ($inSubnet -eq $false) {
                $failures.Add("[$resName] SubnetMismatch: address $ipAddress is not inside cluster network '$netName' ($([string]$net.Address)/$([string]$net.AddressMask)). WSFC will not bind it on any node of that network.")
                $row.Verdict = 'SubnetMismatch'
            } elseif ($null -eq $inSubnet) {
                $warnings.Add("[$resName] Could not evaluate subnet containment for $ipAddress against '$netName' (non-IPv4, or the network address was unreadable).")
            }

            # --- Check 3: no node has more than one interface on this network
            $netNics = @($allNics | Where-Object { [string]$_.Network -ieq $netName })
            $byNode  = @($netNics | Group-Object -Property { [string]$_.Node })
            $row.InterfacesPerNode = (($byNode | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', ')

            foreach ($g in $byNode) {
                if ($g.Count -le 1) { continue }

                $detail = (($g.Group | ForEach-Object {
                    $adapter = if ($_.PSObject.Properties['Adapter']) { [string]$_.Adapter } else { [string]$_.Name }
                    $addr    = if ($_.PSObject.Properties['Address']) { [string]$_.Address } else { '?' }
                    "$adapter ($addr)"
                }) -join ' + ')

                $failures.Add("[$resName] DuplicateInterface: node $($g.Name) has $($g.Count) interfaces on cluster network '$netName': $detail. A cluster network is defined by SUBNET, so both NICs fold into it and WSFC may bind the listener IP $ipAddress to the wrong one - which every friendly-name view reports as healthy. There is no supported way to exclude one interface from a cluster network: remove the extra NIC, or move it to a DIFFERENT subnet so it forms its own cluster network.")
                $row.Verdict = 'DuplicateInterface'
            }

            # --- Queue check 4 (ENI membership) for every node on this network
            if (-not $SkipEniCheck -and $inSubnet -ne $false) {
                foreach ($nic in $netNics) {
                    $node  = [string]$nic.Node
                    $nicIp = if ($nic.PSObject.Properties['Address']) { [string]$nic.Address } else { $null }
                    if (-not $node -or -not $nicIp) { continue }
                    if (-not $eniWanted.ContainsKey($node)) {
                        $eniWanted[$node] = @{ InterfaceIps = @(); Listeners = @() }
                    }
                    $eniWanted[$node].InterfaceIps += $nicIp
                    $eniWanted[$node].Listeners    += [pscustomobject]@{
                        Resource    = $resName
                        ListenerIp  = $ipAddress
                        InterfaceIp = $nicIp
                        Row         = $row
                    }
                }
            }

            $checks.Add($row)
        }

        # --- Check 5: ProbePort parity across this listener's IP resources
        if ($probePorts.Count -gt 1) {
            $distinct = @($probePorts.Values | Select-Object -Unique)
            if ($distinct.Count -gt 1) {
                $detail = (($probePorts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')
                $failures.Add("[$groupName] ProbePortMismatch: the listener's IP resources disagree on ProbePort ($detail). Behind an AWS NLB every listener IP must carry the SAME ProbePort, or the health check for the node holding the odd one out never passes and that target stays permanently unhealthy. Fix with Set-ClusterParameter -Name ProbePort on the outlier, then take the resource offline/online.")
            }
        }
    }

    # -------------------------------------------------------------------------
    # Check 4: AWS ENI membership via IMDSv2.
    #   Deliberately NOT Get-NetIPAddress. The cluster plumbs a listener IP into
    #   Windows only while the resource is Online, so the standby node shows
    #   nothing even when the configuration is perfect - and, worse, an operator
    #   who "tests" by binding the IP manually with New-NetIPAddress leaves NetFT
    #   holding the address, which then fails the NEXT real failover with
    #   5057 ERROR_DUPLICATE_ADDRESS. (That happened on 2026-09-19 and cost an
    #   extra outage; recover with Restart-Service ClusSvc -Force on that node.)
    # -------------------------------------------------------------------------
    if (-not $SkipEniCheck -and $eniWanted.Count -gt 0) {

        if (-not (Test-MssqlOpsIsEc2)) {
            $warnings.Add("Not an EC2 instance; skipped the ENI private-IP check (check 4). The GCP equivalent is an alias IP range on the VM's NIC - verify that manually.")
        } else {
            # Self-contained by design: it runs verbatim on the peer node through
            # Invoke-Command, where none of this module's functions are in scope.
            $eniProbe = {
                param([string[]]$InterfaceIps)

                $out = [pscustomobject]@{ Ok = $false; Error = $null; MacIps = @{}; IfaceMac = @{} }
                try {
                    $token = Invoke-RestMethod -Method Put -TimeoutSec 3 -ErrorAction Stop `
                                -Uri 'http://169.254.169.254/latest/api/token' `
                                -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '60' }
                    $hdr = @{ 'X-aws-ec2-metadata-token' = $token }

                    $macs = @((Invoke-RestMethod -Method Get -TimeoutSec 3 -ErrorAction Stop -Headers $hdr `
                                -Uri 'http://169.254.169.254/latest/meta-data/network/interfaces/macs/') -split "`n" |
                              Where-Object { $_ } | ForEach-Object { $_.Trim().TrimEnd('/') })

                    foreach ($mac in $macs) {
                        $uri = "http://169.254.169.254/latest/meta-data/network/interfaces/macs/$mac/local-ipv4s"
                        $ips = @((Invoke-RestMethod -Method Get -TimeoutSec 3 -ErrorAction Stop -Headers $hdr -Uri $uri) -split "`n" |
                                 Where-Object { $_ } | ForEach-Object { $_.Trim() })
                        $out.MacIps[$mac.ToLower()] = $ips
                    }

                    foreach ($i in ($InterfaceIps | Select-Object -Unique)) {
                        $bound = Get-NetIPAddress -IPAddress $i -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                                 Select-Object -First 1
                        if ($bound) {
                            $ad = Get-NetAdapter -InterfaceIndex $bound.InterfaceIndex -ErrorAction SilentlyContinue
                            if ($ad) { $out.IfaceMac[$i] = ([string]$ad.MacAddress -replace '-', ':').ToLower() }
                        }
                    }
                    $out.Ok = $true
                } catch {
                    $out.Error = $_.Exception.Message
                }
                $out
            }

            foreach ($node in @($eniWanted.Keys)) {
                $ips = @($eniWanted[$node].InterfaceIps | Select-Object -Unique)

                $probe = $null
                try {
                    if ($node -ieq $env:COMPUTERNAME) {
                        $probe = & $eniProbe $ips
                    } else {
                        $probe = Invoke-Command -ComputerName $node -ScriptBlock $eniProbe `
                                    -ArgumentList (, $ips) -ErrorAction Stop
                    }
                } catch {
                    $warnings.Add("Could not run the ENI check on $node ($($_.Exception.Message)). Check 4 was NOT evaluated there - if $node is the failover target, confirm manually that the listener IP is a private IP on the ENI behind its cluster interface.")
                    continue
                }

                if (-not $probe -or -not $probe.Ok) {
                    $err = if ($probe) { [string]$probe.Error } else { 'no result returned' }
                    $warnings.Add("IMDSv2 probe on $node did not complete ($err); check 4 skipped for that node.")
                    continue
                }

                foreach ($want in $eniWanted[$node].Listeners) {
                    $mac = $null
                    try { $mac = [string]$probe.IfaceMac[$want.InterfaceIp] } catch { $mac = $null }

                    if ([string]::IsNullOrWhiteSpace($mac)) {
                        $warnings.Add("On $node, could not map cluster interface address $($want.InterfaceIp) to a NIC MAC; check 4 skipped for $($want.Resource).")
                        continue
                    }

                    $eniIps = @()
                    try { $eniIps = @($probe.MacIps[$mac]) } catch { $eniIps = @() }

                    if ($eniIps -notcontains $want.ListenerIp) {
                        $failures.Add("[$($want.Resource)] IpNotOnEni: listener IP $($want.ListenerIp) is NOT a private IP on the ENI (mac $mac) behind $node's cluster interface $($want.InterfaceIp). That ENI currently holds: $($eniIps -join ', '). WSFC cannot bring the address online there, so a failover to $node leaves the AG in RESOLVING. Fix in AWS: assign $($want.ListenerIp) as a secondary private IP on that ENI (and the cluster core IP for the same subnet alongside it).")
                        if ($want.Row) { $want.Row.Verdict = 'IpNotOnEni' }
                    }
                }
            }
        }
    }

    $healthy = ($failures.Count -eq 0)

    if (-not $healthy -and $EnableException) {
        throw "AG listener network gate failed: $($failures -join ' | ')"
    }

    [pscustomobject]@{
        Healthy  = $healthy
        Failures = $failures.ToArray()
        Warnings = $warnings.ToArray()
        Checks   = $checks.ToArray()
    }
}
