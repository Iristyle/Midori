$script:GendarmePath = ''

function Get-CurrentDirectory
{
    $thisName = $MyInvocation.MyCommand.Name
    [IO.Path]::GetDirectoryName((Get-Content function:$thisName).File)
}

function Set-GendarmePath
{
  <#
  .Synopsis
    Sets a global GendarmePath for use during this session, so that one
    does not have to be provided every time to Invoke-Gendarme.
  .Description
    By default, the sibling directories will be scanned once the first
    time Invoke-Gendarme is run, to find the gendarme.exe - but
    in the event that the assemblies are not hosted in a sibling package
    directory, this provides a mechanism for overloading.
  .Parameter Path
    The full path to gendarme.exe
  .Example
    Set-GendarmePath c:\foo\packages\Gendarme\lib\tools\gendarme.exe
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [IO.FileInfo]
    [ValidateScript(
    {
      (Test-Path $_) -and (!$_.PSIsContainer) -and
      ($_.Name -ieq 'gendarme.exe')
    })]
    $Path
  )

  $script:GendarmePath = $Path
}

function Get-GendarmePath
{
  if ($script:GendarmePath -ne '')
  {
    return $script:GendarmePath
  }

  #assume that the package has been restored in a sibling directory
  $parentDirectory = Split-Path (Split-Path (Get-CurrentDirectory))

  $script:GendarmePath =
    Get-ChildItem -Path $parentDirectory -Filter 'gendarme.exe' -Recurse |
    ? { $_.DirectoryName.EndsWith('tools') } | Select -First 1 -ExpandProperty FullName

  return $script:GendarmePath
}

function Invoke-Gendarme
{
  <#
  .Synopsis
  TODO: rewrite this
    Runs Gendarme over a given set of test assemblies, outputting the
    results to a file next to the original test assembly.
  .Description
  TODO: rewrite this
    For each specified file, the results file is output to a file next
    to the original.  For instance, given an output format of Gendarme:

    Input File - c:\source\foo.tests.dll
    Output File - c:\source\GendarmeResults.foo.tests.dll.xml

    If the output format is nunit, the results will be merged together
    so that they may be imported into a build server like Jenkins. The
    output file will automatically be placed in the first specified path
    and will be named, in the above instance, to the default

    c:\source\GendarmeResults.xml

    If the GendarmePath is not specified, it will be resolved automatically
    by searching sibling directories.
  .Parameter Path
    A list of root paths to search through
  .Parameter AsmSpec
  TODO: rewrite this
    A wildcard specification of files to look for in each of the given
    paths.  This should follow the syntax that the -Include switch of
    Get-ChildItem accepts.

    Defaults to *Tests.dll
  .Parameter ConfigFile
  .Parameter RuleSet
    'default'
  .Parameter LogFile
  .Parameter XmlFile
  .Parameter HtmlFile
  .Parameter IgnoreFile
  .Parameter Limit
    Stop reporting after N defects are found.
  .Parameter Console
    Show defects on the console even if LogFile, XmlFile or HtmlFile are
    specified.
  .Parameter Quiet
    Used to disable progress and other information which is normally
    written to stdout.
  .Parameter Verbose
    When present additional progress information is written to stdout
    (can be used multiple times).
  .Example
    Invoke-Gendarme -Path c:\source\foo, c:\source\bar

    Description
    -----------
    Will execute XUnit against all *Tests.dll assemblies found in
    c:\source\foo and c:\source\bar, outputting in the default nunit
    format.  Each found assembly will have a test results file placed
    next to it on disk. A merge of all the test runs, including summary
    data will be written to c:\source\foo\nunit.TestResults.xml
  .Example
    Invoke-Gendarme -Path c:\src\foo -TestSpec '*Tests*.dll','*Runs*.dll' `
    -IncludeTraits @{Category=Unit} -ExcludeTraits @{Category=Smoke} `
    -SummaryPath c:\src\nunit.xml

    Description
    -----------
    Will execute XUnit against all *Tests*.dll and *Runs*.dll assemblies
    found in c:\src, outputting in the default nunit format. Each found
    assembly will have a test results file placed next to it on disk.
    A merge of all the test runs, including summary data will be written
    to c:\src\nunit.xml
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string[]]
    [ValidateScript({ (Test-Path $_) -and (Get-Item $_).PSIsContainer} )]
    $Path,

    [Parameter(Mandatory=$false)]
    [string[]]
    $AsmSpec = @('*.dll'),

    [Parameter(Mandatory=$false)]
    [string]
    [ValidateScript({ (Test-Path $_) -and (!(Get-Item $_).PSIsContainer) })]
    $ConfigFile,

    [Parameter(Mandatory=$false)]
    [string]
    $RuleSet = 'default',

    [Parameter(Mandatory=$false)]
    [string]
    [ValidateScript({ Test-Path $_ -IsValid })]
    $LogFile,

    [Parameter(Mandatory=$false)]
    [string]
    [ValidateScript({ Test-Path $_ -IsValid })]
    $XmlFile,

    [Parameter(Mandatory=$false)]
    [string]
    [ValidateScript({ Test-Path $_ -IsValid })]
    $HtmlFile,

    [Parameter(Mandatory=$false)]
    [string]
    [ValidateScript({ (Test-Path $_) -and (!(Get-Item $_).PSIsContainer) })]
    $IgnoreFile,

    [Parameter(Mandatory=$false)]
    [int]
    $Limit,

    [Parameter()]
    [switch]
    $Console,

    [Parameter()]
    [switch]
    $Quiet,

    [Parameter(Mandatory=$false)]
    [IO.FileInfo]
    [ValidateScript({
      (Test-Path $_) -and (!$_.PSIsContainer) -and
      ($_.Name -ieq 'gendarme.exe')
    })]
    $GendarmePath = (Get-GendarmePath)
  )

  if (! (Test-Path $GendarmePath))
    { throw "Could not find Gendarme!  Restore with Nuget. "}

  $gendarmeArgs = @()

  if ($PsBoundParameters.ConfigFile) { $listArgs += '--config', $ConfigFile }
  if ($PsBoundParameters.Set) { $listArgs += '--set', $RuleSet }
  if ($PsBoundParameters.LogFile) { $listArgs += '--log', $LogFile }
  if ($PsBoundParameters.XmlFile) { $listArgs += '--xml', $XmlFile }
  if ($PsBoundParameters.HtmlFile) { $listArgs += '--html', $HtmlFile }
  if ($PsBoundParameters.IgnoreFile) { $listArgs += '--ignore', $IgnoreFile }
  if ($PsBoundParameters.Limit) { $listArgs += '--limit', $Limit }
  if ($PsBoundParameters.Console) { $listArgs += '--quiet' }
  if ($PsBoundParameters.Console) { $listArgs += '--console' }
  if ($PsBoundParameters.Verbose) { $listArgs += '--v' }
  # TODO: add support for
  # --severity [all | [[audit | low | medium | high | critical][+|-]]],...
  #                       Filter defects for the specified severity levels.
  #                       Default is 'medium+'
  # --confidence [all | [[low | normal | high | total][+|-]],...
  #                       Filter defects for the specified confidence levels.
  #                       Default is 'normal+'


  if (($SummaryPath -ne $null) -and ($OutputFormat -ne 'nunit'))
    { throw "SummaryPath may only be specified with nunit OutputFormat" }

  $asemblies = Get-ChildItem -Path $Path -Include $AsmSpec -Recurse

  Write-Host "Invoking Gendarme..."
  &"$GendarmePath" $gendarmeArgs
}

Export-ModuleMember -Function Set-GendarmePath, Invoke-Gendarme
