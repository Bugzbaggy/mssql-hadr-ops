<#
.SYNOPSIS
    Returns the ordered manifest of AWS EC2 system components the module keeps
    current (SSM Agent, EC2Launch v2, NVMe driver, ENA driver).
.DESCRIPTION
    Data-only helper consumed by Update-MssqlOpsAwsSystemComponent. Order is
    significant and intentional:

      1. SSMAgent   (Agent,  non-disruptive)  - no reboot, no NIC drop
      2. EC2Launch  (Agent,  non-disruptive)  - no reboot, no NIC drop
      3. NVMe       (Driver, disruptive)      - boot/EBS disk driver; reboot after
      4. ENA        (Driver, disruptive)      - network driver; drops the NIC briefly

    Agents are refreshed first because they are always safe. ENA is refreshed
    LAST so the earlier downloads/installs still have a working NIC. The
    'Disruptive' flag lets callers refresh only the safe components when the
    node must stay online (SqlCU mode), and the full set only when the node is
    drained (Windows mode) or immediately before an OS upgrade.

    The 'Latest' S3 URLs are the AWS-published redistributables. Callers may
    override with a pre-staged offline directory (firewalled prod hosts) - see
    Update-MssqlOpsAwsSystemComponent -Source.
.NOTES
    Signer subjects: the agent installers (.exe/.msi) are Authenticode-signed
    by 'Amazon.com Services LLC' / 'Amazon Web Services'. The driver payloads
    ship WHQL-signed .sys/.cat catalogs (Microsoft Windows Hardware
    Compatibility Publisher). Update-MssqlOpsAwsSystemComponent enforces an
    Amazon signer on agents and a Valid signature on driver catalogs.
#>
function Get-MssqlOpsAwsComponentSpec {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()

    @(
        [pscustomobject]@{
            Name       = 'SSMAgent'
            Kind       = 'Agent'
            Disruptive = $false
            FileName   = 'AmazonSSMAgentSetup.exe'
            Url        = 'https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/windows_amd64/AmazonSSMAgentSetup.exe'
            ServiceName  = 'AmazonSSMAgent'
            InstalledExe = 'C:\Program Files\Amazon\SSM\amazon-ssm-agent.exe'
        }
        [pscustomobject]@{
            Name       = 'EC2Launch'
            Kind       = 'Agent'
            Disruptive = $false
            FileName   = 'AmazonEC2Launch.msi'
            Url        = 'https://s3.amazonaws.com/amazon-ec2launch-v2/windows/amd64/latest/AmazonEC2Launch.msi'
            InstalledExe = 'C:\Program Files\Amazon\EC2Launch\EC2Launch.exe'
        }
        [pscustomobject]@{
            Name       = 'NVMe'
            Kind       = 'Driver'
            Disruptive = $true
            FileName   = 'AWSNVMe.zip'
            Url        = 'https://s3.amazonaws.com/ec2-windows-drivers-downloads/NVMe/Latest/AWSNVMe.zip'
            DeviceMatch = 'NVMe'
        }
        [pscustomobject]@{
            Name       = 'ENA'
            Kind       = 'Driver'
            Disruptive = $true
            FileName   = 'AwsEnaNetworkDriver.zip'
            Url        = 'https://s3.amazonaws.com/ec2-windows-drivers-downloads/ENA/Latest/AwsEnaNetworkDriver.zip'
            DeviceMatch = 'Elastic Network Adapter|Amazon ENA'
        }
    )
}