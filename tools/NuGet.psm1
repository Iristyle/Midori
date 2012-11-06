$script:nuget = $null

function Get-CurrentDirectory
{
  $thisName = $MyInvocation.MyCommand.Name
  [IO.Path]::GetDirectoryName((Get-Content function:$thisName).File)
}

function Get-NugetPath
{
  if ($script:nuget -and (Test-Path -IsValid $script:nuget) -and `
    (Test-Path $script:nuget))
  {
    return $script:nuget
  }

  $params = @{
    Path = Get-CurrentDirectory;
    Include = 'nuget.exe';
    Recurse = $true;
  }

  $script:nuget = Get-ChildItem @params |
    Select -ExpandProperty FullName -First 1
  return $script:nuget
}

function Restore-Nuget
{
  Write-Verbose 'Restore-Nuget'
  $firstTime = $script:nuget -eq $null
  $nuget = Get-NugetPath

  if ($firstTime -and ($nuget -ne $null))
  {
    &"$nuget" update -Self | Write-Host
    return
  }

  $nugetPath = Join-Path (Get-CurrentDirectory) 'nuget.exe'
  (New-Object Net.WebClient).DownloadFile('http://nuget.org/NuGet.exe', $nugetPath)

  $script:nuget = $nugetPath
}

function Find-NuGetPackages
{
<#
.Synopsis
  Will use the NuGet 'list' command to search for packages of the given
  Name at the given Source (if specified).
.Description
  Nothing fancy here, aside from a light wrapper around Nuget list
  that properly handles generating a search and parsing the results into
  a Hashtable.

  Special treatment is currently given to MyGet feeds specified as a
  source as there is a bug preventing multiple search terms from being
  properly processed on the server.  For a specified MyGet feed, the
  full list is generated by the server, and filtered client-side.

  Note that the MyGet work-around only applies when MyGet is specified
  as the source, not when it is queried implictly based on being
  configured in local sources.

  The client-side is filtered to ensure that the packages returned
  contain the Name(s) specified.
.Parameter Name
  The list of package names to search for in the remote feed.

  Note that the Name is not considered exact, but a substring value.
.Parameter Source
  The remote feed to search against instead of the defaults.

  Note that MyGet is given special treatment if more than one Name is
  specified.
.Example
  Find-NuGetPackages -Name 'CroMagVersion', 'Midori'

  Description
  -----------
  Will search the default Nuget feeds, returning a Hashtable with the
  latest versions of CroMagVersion and Midori.

  May return additional packages based on how the server executes the
  search.
.Example
  Find-NuGetPackages -Name 'CroMagVersion', 'Midori' `
    - 'https://www.myget.org/F/YOURGUID/'

  Description
  -----------
  Will search the given MyGet feed, returning a Hashtable with the
  latest versions of CroMagVersion and Midori should they exist.

  May return additional packages based on how the server executes the
  search.
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string[]]
    $Name,

    [Parameter(Mandatory = $false)]
    [string]
    [ValidateNotNullOrEmpty()]
    $Source = 'default sources'
  )

  Write-Verbose "Find-NuGetPackages retrieving packages $Name from $Source..."

  Restore-Nuget

  # TODO: handle -Prerelease
  $listArgs = @()
  if ($PsBoundParameters.Source) { $listArgs += '-Source', $Source }

  # HACK: myget bug doesn't return search results for multiple pkgs
  # TODO: remove the myget check once they fix their bug
  if ($Name -and ($Name.Length -gt 1) -and ($Source -notmatch 'myget\.org'))
    { $listArgs += ($Name -join ', ') }

  $listArgs += '-NonInteractive'

  $list = &$script:nuget list $listArgs
  $packages = @{}
  $list |
    ? { ($_ -notmatch '^(Using credentials)|(No packages)') } |
    % {
      $packageDef = $_ -split '\s'
      $id = $packageDef[0]
      if ($Name)
      {
        $match = $false
        $Name |
          % { if (!$match) { $match = $id -match $_ } }

        if ($match) { $packages.$id = $packageDef[1] }
      }
    }

  Write-Host "Found $($packages.Count) packages at $Source"
  return $packages
}

function Get-NuGetPackageSpecs
{
<#
.Synopsis
  Will find all the specified Nuspec files recursively within a
  particular given Path, and will load their Xml specs into a Hashtable.
.Description
  The Nuspec files are read as Xml, and the 'id' of the package is used
  as the key in the Hashtable.

  There are a couple of caveats here.

  If the metadata id field of the package is set to resolve at build
  time based on a local csproj using the '$id$' identifier, then the
  NuGet 'pack' command is run against the csproj to produce a .nupkg
  file.  This file is then used to determine the id and version fields
  and the loaded Xml is modified accordingly.

  This requires that the project has been previously built once.  If it
  has not, then the 'pack' command cannot be run, and the given .nuspec
  will *not* be added to the returned Hashtable.
.Parameter Path
  The optional path fed to Get-ChildItem, that will be used to recurse a given
  directory structure.

  If left unspecified, the current directory is searched.
.Example
  Get-NuGetPackageSpecs

  Description
  -----------
  Assuming there are .nuspec files found recursively, the resulting
  Hashtable will be similar to the following

  Name                           Value
  ----                           -----
  Midori                         {Path, Definition}

.Example
  Get-NuGetPackageSpecs -Path c:\source

  Description
  -----------
  Will search c:\source recursively for .nuspec files, building a
  Hashtable with any found .nuspec files.
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false)]
    [string]
    [ValidateScript({ (Get-Item $_).PSIsContainer })]
    $Path = (Get-Item .),

    [Parameter(Mandatory = $false)]
    [string[]]
    [ValidateNotNullOrEmpty()]
    $Include = '*.nuspec'
  )
  Write-Verbose "Get-NuGetPackageSpecs running against $Path for $Include"

  $specs = @{}

  Get-ChildItem -Path $Path -Include $Include -Recurse |
    ? { (Split-Path $_.DirectoryName -Leaf) -ne 'packages' } |
    % {
      Write-Verbose "Found package file $_"
      $spec = [Xml](Get-Content $_)
      $id = $spec.package.metadata.id
      # we need the csproj for the metadata *sigh*
      if ($id -eq '$id$')
      {
        Restore-Nuget
        Push-Location $_.DirectoryName
        $csproj = $_.Name -replace '\.nuspec$', '.csproj'
        # HACK: for this to work, the csproj must have been built already
        Write-Verbose "Building $csproj to retrieve metadata"
        &$script:nuget pack $csproj | Out-Null
        Get-Item *.nupkg |
          Select -ExpandProperty Name -First 1 |
          Select-String -Pattern '^(.*?)\.(\d+.*)\.nupkg$' -AllMatches |
          % {
            $caps = $_.Matches.Captures
            $id = $caps.Groups[1].Value
            $spec.package.metadata.id = $id
            $spec.package.metadata.id = $caps.Groups[2].Value
          }
        Pop-Location
      }
      if ($id -eq '$id$')
      {
        Write-Warning "Could not find id / version for file $_"
        return
      }
      $specs[$id] = @{
        Path = $_
        Definition = $spec
      }
    }

  return $specs
}

function Test-IsVersionNewer([string]$base, [string]$new)
{
  # no base version - let this go through
  if (!$base) { return $true }

  if ([string]::IsNullOrEmpty($new))
  {
    Write-Error 'New version cannot be empty'
    return $false
  }

  # TODO: naive impl of SemVer handling since its the exception
  # always let new SemVers go through
  if ($new -match '\-.*$') { return $true }

  return [Version]$new -gt [Version]$base
}

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

function Invoke-Pack([Hashtable]$specs, [Hashtable]$existingPackages = @{})
{
  Write-Verbose "Invoke-Pack processing $($specs.Count) specs"

  $specs.GetEnumerator() |
    % {
      $id = $_.Key
      $path = $_.Value.Path
      $definition = $_.Value.Definition
      $baseVersion = $existingPackages.$id #doesn't always exist
      $version = $definition.package.metadata.version
      $csproj = Join-Path $path.DirectoryName ($path.BaseName + '.csproj')

      if (Test-Path $csproj)
      {
        Write-Verbose "Packing csproj file $csproj for package $id"
        &$script:nuget pack "$csproj" -Prop Configuration=Release -Exclude '**\*.CodeAnalysisLog.xml'
      }
      else
      {
        if ($existingPackages -and $baseVersion)
        {
          Write-Verbose "Local package $id - version $version / remote $baseVersion"
          if (!(Test-IsVersionNewer $baseVersion $version))
          {
            Write-Host "[SKIP] : Package $id matches server $version"
            return
          }
        }
        &$script:nuget pack $path
      }
    }
}

function Publish-NuGetPackage
{
<#
.Synopsis
  Will find all .nuspec files recursively within a specified path, will
  call nuget pack against each of them, and will publish to the default
  source, or one specified.
.Description
  This can be used to automatically update a Nuget feed from a build
  server.

  In it's simplest form, it requires no parameters, but allows for a
  number of configuration switches to customize the process.

  This cmdlet will attemp to determine server package versions for all
  local packages, and will not push packages that are newer on the
  server.  This is of particular use to utility repositories with many
  packages where it may be expensive to pack and push packages
  unnecessarily.

  The path can be specified, as can a list of specific nuspec ids.

  A package source and api key may be specified to push to a private
  feed.
.Parameter Include
  Optional list of .nuspec file names to use.  The names may end in
  .nuspec or no extension.  If any of the includes are not found an
  error is generated.
.Parameter Path
  The optional path fed to Get-ChildItem, that will be used to recurse
  a given directory structure.
.Parameter Source
  The optional Nuget source to push the package to.  If not specified,
  the NUGET_SOURCE environment variable is used, should it exist.

  Otherwise, the default local configuration of 'nuget sources' is used
.Parameter ApiKey
  The optional Nuget API Key to use for the package source.  If not
  specified, the NUGET_API_KEY environment variable is used, should it
  exist.

  Otherwise, the default local configuration of 'nuget sources' is used.
.Parameter KeepPackages
  Optional switch to prevent deletion of packages after a push.
.Parameter Force
  Optional swith to ignores heuristics used to compare local to remote
  versions of packages, and will attempt to force the package up anyway.

  Chances are good that this will fail.

  The default algorithm tries to prevent packing and pushing
  unnecessarily, so as to save CPU time and bandwidth.
.Example
  Publish-NuGetPackage

  Description
  -----------
  Will recursively examine the local working directory, looking for
  NuGet .nuspec files.

  Employs an algorithm to determine if packages need to be pushed and
  built.

  For those found next to .csproj files that use $id$, 'nuget pack'
  will be called to determine ids and versions.
.Example
  Publish-NuGetPackage -Include 'Foo', 'Bar'

  Description
  -----------
  Will recursively examine the local working directory, looking for
  NuGet .nuspec files 'Foo.nuspec' and 'Bar.nuspec'.

  If these files cannot be found, an error is generated.

  Employs an algorithm to determine if packages need to be pushed and
  built.
.Example
  Publish-NuGetPackage -Path 'c:\source\myproject' -KeepPackages -Force

  Description
  -----------
  Will recursively examine c:\source\myproject, looking for NuGet
  .nuspec files to push and pack.

  Disables the algorithm used to determine if packages should be pushed.

  Keeps .nupkg files on disk after a push instead of deleting them.
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string[]]
    $Include,

    [Parameter(Mandatory = $false)]
    [string]
    [ValidateScript({ (Get-Item $_).PSIsContainer })]
    $Path = (Get-Item .),

    [Parameter(Mandatory = $false)]
    [string]
    $Source = $Env:NUGET_SOURCE,

    [Parameter(Mandatory = $false)]
    [string]
    $ApiKey = $Env:NUGET_API_KEY,

    [Parameter()]
    [Switch]
    $KeepPackages,

    [Parameter()]
    [Switch]
    $Force
  )

  if ($Include)
  {
    $Include = $Include |
      % {
        if ($Include.EndsWith('.nuspec')) { return $_ }
        return "$($_).nuspec"
      }
  }

  Write-Verbose "Publish-NuGetPackage Searching $Path for $Include"

  $specParams = @{ Path = $Path }
  if ($PsBoundParameters.Include) { $specParams.Include = $Include }
  $specFiles = Get-NuGetPackageSpecs @specParams

  if ($PsBoundParameters.Include)
  {
    $foundFiles = $specFiles.GetEnumerator() | % { $_.Value.Path.Name }
    $notFound = $Include |
      ? { $foundFiles -notcontains $_ }
    if ($notFound.Length -gt 0)
    {
      throw "Could not find specs $($notFound -join ',')"
    }
  }

  #nothing to do here
  if ($specFiles.Length -eq 0) { return }

  Write-Verbose "Removing all .nupkg files within $Path"
  Get-ChildItem -Path $Path -Recurse -Filter *.nupkg |
    Remove-Item -Force -ErrorAction SilentlyContinue

  $packParams = @{ Specs = $specFiles }
  if (!$Force)
  {
    # use the ids found in our .nuspecs to query with
    $findParams = @{ Name = $specFiles.Keys }
    if ($PsBoundParameters.Source) { $findParams.Source = $Source }
    $packParams.ExistingPackages = Find-NuGetPackages @findParams
  }

  Restore-Nuget
  Invoke-Pack @packParams

  Get-ChildItem -Path $Path -Recurse -Filter *.nupkg |
    % {
      $pushParams = @($_)
      # Use ENV params or whatever has been specified
      if (![string]::IsNullOrEmpty($source))
        { $pushParams += '-Source', $source}
      if (![string]::IsNullOrEmpty($apikey))
        { $pushParams += '-ApiKey', $apikey}

      #TODO: change to Verbose
      Write-Verbose "Pushing $_ $(if ($source) { "to source $source " })with params: $pushParams"

      &$script:nuget push $pushParams
      if (!$KeepPackages)
        { Remove-Item $_ -Force -ErrorAction SilentlyContinue}
    }
}

Export-ModuleMember Test-NuGetDependencyPackageVersions,
  Get-NuGetDependencyPackageVersions, Find-NuGetPackages,
  Get-NuGetPackageSpecs, Publish-NuGetPackage
