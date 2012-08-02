$script:DotNetZipVersionPath = ''

function Set-DotNetZipPath
{
  <#
  .Synopsis
    Sets a global DotNetZipPath for use during this session, so that one
    does not have to be provided every time to New-ZipFile.
  .Description
    By default, the sibling directories will be scanned once the first
    time New-ZipFile is run, to find the Ionic.Zip.dll - but in the event
    that the assemblies are not hosted in a sibling package directory,
    this provides a mechanism for overloading.
  .Parameter Path
    The full path to Ionic.Zip.dll
  .Example
    Set-DotNetZipPath c:\foo\packages\dotnetzip\lib\net20\Ionic.Zip.dll
  #>
  param (
    [Parameter(Mandatory=$true)]
    [IO.FileInfo]
    [ValidateScript(
    {
      (Test-Path $_) -and (!$_.PSIsContainer) -and
      ($_.Name -ieq 'Ionic.Zip.dll')
    })]
    $Path
    )

  $script:DotNetZipVersionPath = $Path
}

function Get-DotNetZipPath
{
  if ($script:DotNetZipVersionPath -ne '')
  {
    return $script:DotNetZipVersionPath
  }

  #assume that the package has been restored in a sibling directory
  $directory = [IO.Path]::GetDirectoryName((Get-Content function:Get-DotNetZipPath).File)
  $parentDirectory = Split-Path (Split-Path $directory)

  $script:DotNetZipVersionPath =
    Get-ChildItem -Path $parentDirectory -Filter 'Ionic.Zip.dll' -Recurse |
    ? { $_.DirectoryName.EndsWith('net20') } | Select -First 1 -ExpandProperty FullName

  return $script:DotNetZipVersionPath
}

function Invoke-AuthenticodeSignTool
{
  <#
  .Synopsis
    Code signs a given binary or binaries using signtool.exe and
    specified cert.
  .Description
    Determines the location of signtool.exe by examining standard
    installation locations, then applies to each given path.
  .Parameter Path
    Complete path to binary to sign. Input accepted from Pipeline to sign
    multiple assemblies at once. Passed to the /v parameter of
    signtool.exe
  .Parameter CertFile
    The certificate file.  Value passed to the /f parameter of
    signtool.exe
  .Parameter Password
    The certificate password. Value passed to the /p parameter of
    signtool.exe
  .Parameter TimeStampUrl
    The timestamp server to use. Valued passed to the /t parameter of
    signtool.exe
  .Link
    http://msdn.microsoft.com/en-us/library/8s9b9yaz(v=vs.80).aspx
  .Example
    Invoke-AuthenticodeSignTool -Path .\foo.exe -CertFile c:\foo.cert `
      -Password baz `
      -TimeStamp http://timestamp.verisign.com/scripts/timstamp.dll

    Description
    -----------
    Will sign foo.exe with the given cert and cert password, using the
    Verisign time server

  .Example
    'foo.exe','bar.exe' | Invoke-AuthenticodeSignTool `
      -CertFile c:\foo.cert -Password baz `
      -TimeStamp http://timestamp.verisign.com/scripts/timstamp.dll

    Description
    -----------
    Will sign foo.exe and bar.exe with the given cert and cert password,
    using the Verisign time server
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
    [string]
    [ValidateScript({ (Test-Path $_) -and (-not (Get-Item $_).PSIsContainer) })]
    $Path,

    [Parameter(Mandatory=$true)]
    [string]
    [ValidateScript({ (Test-Path $_) -and (-not (Get-Item $_).PSIsContainer) })]
    $CertFile,

    [Parameter(Mandatory=$true)]
    [string]
    $Password,

    [Parameter(Mandatory=$true)]
    [string]
    $TimeStampUrl
  )

  begin
  {
    #concepts borrowed from from http://stackoverflow.com/questions/1347075/sign-every-executable-with-authenticode-certificate-through-msbuild
    $ProgramFiles = "${Env:ProgramFiles}"
    $ProgramFiles32 = @("${Env:ProgramFiles(x86)}","${Env:ProgramFiles}") |
        ? { (! ([string]::IsNullOrEmpty($_))) -and (Test-Path $_) } | Select -First 1

    #TODO is there a way to pull _SignToolSdkPath from MSBuild variables first?
    #as that should be the default - $(_SignToolSdkPath)bin\signtool.exe
    $SignToolPath = @((Join-Path $ProgramFiles32 'Microsoft SDKs\Windows\v7.1\Bin\signtool.exe'),
      (Join-Path $ProgramFiles 'Microsoft SDKs\Windows\v7.1\Bin\signtool.exe'),
      (Join-Path $ProgramFiles32 'Microsoft SDKs\Windows\v7.0A\Bin\signtool.exe'),
      (Join-Path $ProgramFiles 'Microsoft SDKs\Windows\v7.0A\Bin\signtool.exe')) |
        ? { (! ([string]::IsNullOrEmpty($_))) -and (Test-Path $_) } | Select -First 1
  }
  process
  {
    &"$SignToolPath" sign /f "`"$CertFile`"" /p "`"$Password`"" /t "`"$TimeStampUrl`"" /v "`"$_`""
    if ($LASTEXITCODE -ne 0)
    {
        throw "Invoke-AuthenticodeSignTool failed to execute $SignToolPath"
    }
  }
}

function New-ZipFile
{
  <#
  .Synopsis
    Zips together a set of files into a given file name.
  .Description
    Will create a new zip file or add to an existing one given a specific
    name.

    If the DotNetZipPath is not specified, it will be resolved by
    searching sibling directories.
  .Parameter Path
    The file name to write out.
  .Parameter SourceFiles
    A list of FileInfo objects to include in the zip.
  .Parameter Root
    If specified, will update the path of the files stored in the zip.
  .Parameter DotNetZipPath
    The optional directory from which DotNetZip will be loaded.

    If left unspecified, the sibling directories of the Midori package
    will be scanned for anything matching net20\Ionic.Zip.dll, and the
    first matching file will be used if multiple versions are found.
    DotNetZip should be package restored by a scripted bootstrap process.
  .Example
    New-ZipFile -Path c:\foo.zip -Root c:\foo `
      -SourceFiles (Get-ChildItem c:\foo) `
      -DotNetZipPath ..\src\packages\dotnetzip\tools\net20\Ionic.Zip.dll

    Description
    -----------
    Will create foo.zip adding all files from the c:\foo directory, but
    renaming them to the root of the zip file.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]
    $Path,

    [Parameter(Mandatory=$true)]
    [IO.FileInfo[]]
    $SourceFiles,

    [Parameter(Mandatory=$false)]
    [string]
    $Root,

    [Parameter(Mandatory=$false)]
    [IO.FileInfo]
    [ValidateScript({
      (Test-Path $_) -and (!$_.PSIsContainer) -and
      ($_.Name -ieq 'Ionic.Zip.dll')
    })]
    $DotNetZipPath = (Get-DotNetZipPath)
  )

  #TODO - this is quite yucky for now
  #unnecessary reloads occur for instance
  if (! (Test-Path $DotNetZipPath))
    { throw "Could not find DotNetZip!  Restore with Nuget. "}
  Add-Type -Path $DotNetZipPath
  $rewritePath = ![string]::IsNullOrEmpty($Root)
  #zip internals store / instead of \
  #if ($rewritePath) { $Root = $Root.Replace('\','/')}

  $zip = New-Object Ionic.Zip.ZipFile
  if (Test-Path $Path)
    { $zip = [Ionic.Zip.ZipFile]::Read($Path) }

  "Adding $($SourceFiles.Length) files to archive $Path"
  $SourceFiles |
  % {
    $destination = $_.DirectoryName
    if ($rewritePath)
    {
      $foundIndex = $destination.IndexOf($Root,
        [StringComparison]::CurrentCultureIgnoreCase)
      if ($foundIndex -eq -0)
      {
        $destination = $destination.Substring($Root.Length)
      }
    }
    [Void]$zip.AddFile($_.FullName, $destination)
    "Added File $_"
  }
  $zip.Save($Path)
  $zip.Dispose()
  "Wrote $($SourceFiles.Length) files to archive $Path"
}

Export-ModuleMember -Function New-ZipFile, Invoke-AuthenticodeSignTool,
Set-DotNetZipPath