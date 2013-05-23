# adapted from
# http://www.tavaresstudios.com/Blog/post/The-last-vsvars32ps1-Ill-ever-need.aspx
$script:rootVsKey = if ([IntPtr]::size -eq 8)
  { "HKLM:SOFTWARE\Wow6432Node\Microsoft\VisualStudio" }
else
  { "HKLM:SOFTWARE\Microsoft\VisualStudio" }

function Get-Batchfile ($file)
{
  if (!(Test-Path $file))
  {
    throw "Could not find batch file $file"
  }

  Write-Verbose "Executing batch file $file in separate shell"
  $cmd = "`"$file`" & set"
  $environment = @{}
  cmd /c $cmd | % {
    $p, $v = $_.split('=')
    $environment.$p = $v
  }

  return $environment
}

function FilterDuplicatePaths
{
  [CmdletBinding()]
  param(
    [string]
    $Path
  )

  # with PATH, order is important, so can't use Get-Unique
  $uniquePaths = @{}

  $filtered = $Path -split ';' |
    ? {
      if (!$uniquePaths.ContainsKey($_))
      {
        $uniquePaths.Add($_, '')
        return $true
      }

      return $false
    }

  return $filtered -join ';'
}

function Get-LatestVsVersion
{
  $version = Get-ChildItem $script:rootVsKey |
    ? { $_.PSChildName -match '^\d+\.\d+$' } |
    Sort-Object -Property @{ Expression = { $_.PSChildName -as [int] } } |
    Select -ExpandProperty PSChildName -Last 1

  if (!$version)
  {
    throw "Could not find a Visual Studio version based on registry keys..."
  }

  Write-Verbose "Found latest Visual Studio Version $Version"
  return $version
}

function Get-VsVars
{
<#
.Synopsis
  Will find and load the vsvars32.bat file for the given Visual Studio
  version, extrapolating it's environment information into a Hash.
.Description
  Will examine the registry to find the location of Visual Studio on
  disk, and will in turn find the location of the batch file that should
  be run to setup the local environment for command line build and
  tooling support.
.Parameter Version
  A Visual Studio version id string such as:

   8.0      Visual Studio 2005
   9.0      Visual Studio 2008
  10.0      Visual Studio 2010
  11.0      Visual Studio 2012
  latest    Finds the latest version installed automatically (default)
.Outputs
  Returns a [Hashtable]
.Example
  Get-VsVars -Version '10.0'

  Description
  -----------
  Will find the batch file for Visual Studio 10.0, execute it in a
  subshell, and return the environment settings in a hash.

  If the Visual Studio version specified is not found, will throw an
  error.
.Example
  Get-VsVars

  Description
  -----------
  Will find the batch file for the latest Visual Studio, execute it in
  a subshell, and return the environment settings in a hash.

  If no Visual Studio version is found, will throw an error.
#>
  [CmdletBinding()]
  param(
    [string]
    [ValidateSet('7.1', '8.0', '9.0', '10.0', '11.0', 'latest')]
    $Version = 'latest'
  )

  if ($version -eq 'latest') { $version = Get-LatestVsVersion }

  Write-Verbose "Reading VSVars for $version"

  $VsKey = Get-ItemProperty "$script:rootVsKey\$version" -ErrorAction SilentlyContinue
  if (!$VsKey -or !$VsKey.InstallDir)
  {
    Write-Warning "Could not find Visual Studio $version in registry"
    return
  }

  $VsRootDir = Split-Path $VsKey.InstallDir
  $BatchFile = Join-Path (Join-Path $VsRootDir 'Tools') 'vsvars32.bat'
  if (!(Test-Path $BatchFile))
  {
    Write-Warning "Could not find Visual Studio $version batch file $BatchFile"
    return
  }
  return Get-Batchfile $BatchFile
}

function Set-VsVars
{
<#
.Synopsis
  Will find and load the vsvars32.bat file for the given Visual Studio
  version, and extract it's environment into the current shell, for
  command line build and tooling support.
.Description
  This function uses Get-VsVars to return the environment for the
  given Visual Studio version, then copies it into the current shell
  session.

  Use the -Verbose switch to see which current environment variables
  are overwritten and which are added.

  NOTE:

  - The PROMPT environment variable is excluded from being overwritten
  - A global variable in the current session ensures that the same
  environment variables haven't been loaded multiple times.
  - PATH has duplicate entries removed in an effort to prevent it from
  exceeding the length allowed by the shell (generally 2048 characters)
.Parameter Version
  A Visual Studio version id string such as:

   8.0      Visual Studio 2005
   9.0      Visual Studio 2008
  10.0      Visual Studio 2010
  11.0      Visual Studio 2012
  latest    Will find the latest version installed automatically (default)
.Example
  Set-VsVars -Version '10.0'

  Description
  -----------
  Will find the batch file for Visual Studio 10.0, execute it in a
  subshell, and import environment settings into the current shell.

  If the Visual Studio version specified is not found, will throw an
  error.
.Example
  Set-VsVars

  Description
  -----------
  Will find the batch file for the latest Visual Studio, execute it in
  a subshell, and import environment settings into the current shell.

  If no Visual Studio version is found, will throw an error.
#>
  [CmdletBinding()]
  param(
    [string]
    [ValidateSet('8.0', '9.0', '10.0', '11.0', 'latest')]
    $Version = 'latest'
  )

  if ($Version -eq 'latest') { $Version = Get-LatestVsVersion }

  #continually jamming stuff into PATH is *not* cool ;0
  $name = "Posh-VsVars-Set-$Version"
  $setVersion = Get-Variable -Scope Global -Name $name `
    -ErrorAction SilentlyContinue

  if ($setVersion) { return }

  (Get-VsVars -Version $Version).GetEnumerator() |
    ? { $_.Key -ne 'PROMPT' } |
    % {
      $name = $_.Key
      $path = "Env:$name"
      if (Test-Path -Path $path)
      {
        $existing = Get-Item -Path $path | Select -ExpandProperty Value
        if ($existing -ne $_.Value)
        {
          # Treat PATH specially to prevent duplicates
          if ($name -eq 'PATH')
          {
            $_.Value = FilterDuplicatePaths -Path $_.Value
          }

          Write-Verbose "Overwriting $name with $($_.Value)`n      was:`n$existing`n`n"
          Set-Item -Path $path -Value $_.Value
        }
      }
      else
      {
        Write-Verbose "Setting $name to $($_.Value)`n`n"
        Set-Item -Path $path -Value $_.Value
      }
    }

  Set-Variable -Scope Global -Name $name -Value $true

  if (!(Test-Path 'Env:\VSToolsPath'))
  {
    $progFiles = $Env:ProgramFiles
    if (${env:ProgramFiles(x86)}) { $progFiles = ${env:ProgramFiles(x86)} }
    $tools = Join-Path $progFiles "MSBuild\Microsoft\VisualStudio\v$Version"
    $ENV:VSToolsPath = $tools

    Write-Verbose "SDK (non-VS) install found - setting VSToolsPath to $tools`n`n"
  }
}

Export-ModuleMember -Function Get-VsVars, Set-VsVars
