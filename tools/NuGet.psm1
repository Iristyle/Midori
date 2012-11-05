function Test-NuGetDependencyPackageVersions
{
<#
.Synopsis
  Will verify that all NuGet packages.config files within a given root
  directory refer to the same version.
.Description
  Very bad things might happen if different parts of your software to
  refer to different versions of dependencies.

  While some software might be resilient to differences in dependency
  version, and some may even require this by design, it's pragmatic to
  expect a single piece of software to rely on a single version of a
  dependency.

  This test is designed to break a build should mismatches occur.

  Packages are listed, sorted by name.
.Parameter Path
  The path fed to Get-ChildItem, that will be used to recurse a given
  directory structure
.Parameter Exclude
  Optional list of string package names to exclude from being considered
  an error.
.Parameter WarnOnly
  Optional switch to use Write-Warning instead of Write-Error
.Example
  Test-NuGetDependencyPackageVersions -Path 'c:\source\myproject'

  Description
  -----------
  Will recursively examine c:\source\myproject, looking for NuGet
  packages.config files.

  If any configuration files are found, where the package versions are
  inconsistent, an error message will be written using Write-Error.
.Example
  Test-NuGetDependencyPackageVersions -Path 'c:\source\myproject'
    -Exclude 'AutoFac' -WarnOnly

  Description
  -----------
  Will recursively examine c:\source\myproject, looking for NuGet
  packages.config files.

  If any configuration files are found, where the package versions are
  inconsistent, excluding any differences with AutoFac, an error message
  will be written using Write-Warning.
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]
    [ValidateScript({ (Get-Item $_).PSIsContainer })]
    $Path,

    [Parameter(Mandatory = $false)]
    [string[]]
    $Exclude = @(),

    [Parameter]
    [switch]
    $WarnOnly
  )

  $packages = Get-NuGetDependencyPackageVersions -Path $Path
  $msgs = @()
  $packages.GetEnumerator() |
    ? { $_.Value.Count -gt 1 } |
    Sort-Object -Property Key |
    % {
      Write-Verbose "Examining package $($_.Key)"
      if ($Exclude -icontains $_.Key) { return }

      $versions = $_.Value
      $msg = "[$($_.Key)] is using $($versions.Count) different versions:`n"
      $versions.GetEnumerator() |
        % {
          $version = $_.Key
          $msg += "`n$version`n`t$($_.Value -join "`n`t")"
        }

      $msgs += " "
      $msgs += $msg
    }

  if ($msgs.Length -eq 0)
  {
    Write-Verbose "All NuGet packages are versioned consistently"
    return
  }

  $msg = "`n" + ($msgs -join "`n`n")
  if ($WarnOnly) { Write-Warning $msg } else { Write-Error $msg }
}

function Get-NuGetDependencyPackageVersions
{
<#
.Synopsis
  Retrieves a list of NuGet packages from all the packages.config files
  within a specified directory.
.Description
  The packages are returned in an Hashtable.

  The hash key is the package name, and the value is a Hashtable
  of found versions.

  The versions hash contains a list of the full file paths where the
  given version is found.
.Parameter Path
  The path fed to Get-ChildItem, that will be used to recurse a given
  directory structure
.Outputs
  A Hashtable of package names and versions, or an empty Hashtable if
  no packages.config files were found.
.Example
  Get-NuGetDependencyPackageVersions -Path 'c:\source\myproject'

  Description
  -----------
  Will recursively examine c:\source\myproject, looking for NuGet
  packages.config files.

  If any configuration files are found, the list of packages is returned
  in a hash.
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]
    [ValidateScript({ (Get-Item $_).PSIsContainer })]
    $Path
  )

  $packages = @{}
  Get-ChildItem -Path $Path -Recurse -Filter 'packages.config' |
    % {
      $fileName = $_.FullName
      Write-Verbose "Examining $fileName"
      $xml = [Xml](Get-Content $fileName)
      if (!$xml.packages.package) { return }
      $xml.packages.package |
        % {
          if (!$packages.ContainsKey($_.id))
            { $packages[$_.id] = @{} }

          $v = $_.version
          if ([string]::IsNullOrEmpty($v)) { $v = 'latest' }

          $pkg = $packages[$_.id]
          if (!$pkg.ContainsKey($v)) { $pkg[$v] = @() }
          if ($pkg[$v] -notcontains $fileName)
          {
            $pkg[$v] += $fileName
          }
        }
    }

  return $packages
}

Export-ModuleMember Test-NuGetDependencyPackageVersions,
  Get-NuGetDependencyPackageVersions
