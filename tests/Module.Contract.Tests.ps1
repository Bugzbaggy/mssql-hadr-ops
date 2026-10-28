# tests/Module.Contract.Tests.ps1
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
#
# Repo-wide invariants that apply to every version of the module. These are the
# checks that catch the mistakes a per-function unit test cannot: a new Public
# file that was never added to FunctionsToExport (so it silently does not ship),
# a Private helper accidentally exported, a syntax error in a file nothing
# imports yet, or a manifest that no longer parses.

BeforeAll {
    $script:Root       = Join-Path $PSScriptRoot '..'
    $script:ModuleDir  = Join-Path $script:Root 'MssqlHadrOps'
    $script:ManifestPath = Join-Path $script:ModuleDir 'MssqlHadrOps.psd1'
    $script:PublicDir  = Join-Path $script:ModuleDir 'Public'
    $script:PrivateDir = Join-Path $script:ModuleDir 'Private'

    $script:Manifest   = Import-PowerShellDataFile -Path $script:ManifestPath
    $script:PublicFiles  = @(Get-ChildItem $script:PublicDir  -Filter *.ps1)
    $script:PrivateFiles = @(Get-ChildItem $script:PrivateDir -Filter *.ps1)
    $script:AllFiles     = @($script:PublicFiles + $script:PrivateFiles)
}

Describe 'Manifest' {

    It 'parses as a valid data file' {
        $script:Manifest | Should -Not -BeNullOrEmpty
    }

    It 'declares a well-formed three-part version' {
        { [version]$script:Manifest.ModuleVersion } | Should -Not -Throw
        ([version]$script:Manifest.ModuleVersion).Build | Should -BeGreaterOrEqual 0
    }

    It 'is at or beyond 1.2.8 (the fail-closed cloud gate)' {
        [version]$script:Manifest.ModuleVersion | Should -BeGreaterOrEqual ([version]'1.2.8')
    }

    It 'points RootModule at a file that exists' {
        Join-Path $script:ModuleDir $script:Manifest.RootModule | Should -Exist
    }

    It 'passes Test-ModuleManifest' {
        # Dependency modules may be absent on a build agent, so only assert that
        # the manifest itself is structurally valid.
        $errs = $null
        try { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop | Out-Null }
        catch { $errs = $_ }
        if ($errs) {
            $msg = $errs.Exception.Message
            # PowerShell 7 reports an absent dependency as "The specified
            # RequiredModules entry 'X' ... is invalid". Tolerate that only when X
            # really is declared AND really is absent - anything else is a defect.
            $declared = @($script:Manifest.RequiredModules | ForEach-Object {
                if ($_ -is [hashtable]) { $_.ModuleName } else { $_ } })
            $absentDependency = $msg -match "RequiredModules entry '([^']+)'" -and
                                $declared -contains $Matches[1] -and
                                -not (Get-Module -ListAvailable -Name $Matches[1])
            if (-not $absentDependency -and $msg -notmatch 'required module|was not loaded|not installed') {
                throw $errs
            }
        }
    }

    It 'exports no wildcards (explicit export list)' {
        $script:Manifest.FunctionsToExport | Should -Not -Contain '*'
        $script:Manifest.CmdletsToExport   | Should -BeNullOrEmpty
        $script:Manifest.AliasesToExport   | Should -BeNullOrEmpty
    }
}

Describe 'Export surface' {

    It 'exports exactly the set of Public functions, no more and no fewer' {
        $declared = @($script:Manifest.FunctionsToExport) | Sort-Object
        $onDisk   = @($script:PublicFiles.BaseName)       | Sort-Object
        ($declared -join ',') | Should -Be ($onDisk -join ',')
    }

    It 'does not export any Private helper' {
        foreach ($p in $script:PrivateFiles.BaseName) {
            $script:Manifest.FunctionsToExport | Should -Not -Contain $p
        }
    }

    It 'names each Public file after the function it defines' {
        foreach ($f in $script:PublicFiles) {
            $errs = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
            $names = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
                       ForEach-Object Name)
            $names | Should -Contain $f.BaseName -Because "$($f.Name) should define $($f.BaseName)"
        }
    }
}

Describe 'Source files' {

    It 'every .ps1 in the module parses without error' {
        $bad = @()
        foreach ($f in $script:AllFiles) {
            $errs = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
            if ($errs) { $bad += "$($f.Name): $($errs[0].Message)" }
        }
        $bad -join ' | ' | Should -BeNullOrEmpty
    }

    It 'every Public function carries comment-based help with a .SYNOPSIS' {
        $missing = @()
        foreach ($f in $script:PublicFiles) {
            $text = Get-Content $f.FullName -Raw
            if ($text -notmatch '(?ms)^\s*<#.*?\.SYNOPSIS.*?#>') { $missing += $f.Name }
        }
        $missing -join ', ' | Should -BeNullOrEmpty
    }

    It 'has no PSScriptAnalyzer findings of Error severity' {
        if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
            Set-ItResult -Skipped -Because 'PSScriptAnalyzer is not installed'
            return
        }
        # A settings file, when one is added, declares its own Severity and wins
        # over -Severity, so filter the results rather than passing the parameter.
        $settings = Join-Path $script:Root 'PSScriptAnalyzerSettings.psd1'
        $params = @{ Path = $script:ModuleDir; Recurse = $true }
        if (Test-Path $settings) { $params.Settings = $settings }
        $findings = @(Invoke-ScriptAnalyzer @params | Where-Object { $_.Severity -eq 'Error' })
        ($findings | ForEach-Object { "$($_.ScriptName):$($_.Line) $($_.RuleName)" }) -join ' | ' |
            Should -BeNullOrEmpty
    }

    It 'never loads FailoverClusters with -SkipEditionCheck' {
        # Documented in MssqlHadrOps.psm1: a native PS7 load makes the cluster
        # cmdlets fail at runtime on a missing .NET Framework type. Assert
        # against the AST, not the raw text - the loader's own comment says
        # "Do NOT add -SkipEditionCheck", which a text match would flag.
        $psm1Path = Join-Path $script:ModuleDir 'MssqlHadrOps.psm1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($psm1Path, [ref]$null, [ref]$null)
        $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)

        $offenders = @($commands | Where-Object {
            $_.GetCommandName() -eq 'Import-Module' -and
            @($_.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                $_.ParameterName -like 'SkipEditionCheck*'
            }).Count -gt 0
        })

        $offenders.Count | Should -Be 0
    }
}
