$script:DotNetZipVersionPath = ''

function Set-7ZipPath
{
  <#
  .Synopsis
    Sets a global 7ZipPath for use during this session, so that one
    does not have to be provided every time to New-ZipFile.
  .Description
    By default, the sibling directories will be scanned once the first
    time New-ZipFile is run, to find 7za.exe or 7z.exe - but in the event
    that the binaries are not hosted in a sibling package directory,
    this provides a mechanism for overloading.
  .Parameter Path
    The full path to 7z.exe or 7za.exe
  .Example
    Set-7ZipPath c:\foo\packages\7Zip\7za.exe
  #>
  param (
    [Parameter(Mandatory=$true)]
    [IO.FileInfo]
    [ValidateScript(
    {
      (Test-Path $_) -and (!$_.PSIsContainer) -and
      ('7z.exe','7za.exe' -contains $_.Name)
    })]
    $Path
    )

  $script:7ZipVersionPath = $Path
}

function Get-7ZipPath
{
  if ($script:7ZipVersionPath -ne '')
  {
    return $script:7ZipVersionPath
  }

  #assume that the package has been restored in a sibling directory
  $directory = [IO.Path]::GetDirectoryName((Get-Content function:Get-7ZipPath).File)
  $parentDirectory = Split-Path (Split-Path $directory)

  $script:7ZipVersionPath =
    Get-ChildItem -Path $parentDirectory -Include '7z.exe','7za.exe' -Recurse |
    Select -First 1 -ExpandProperty FullName

  return $script:7ZipVersionPath
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

    If the 7ZipPath is not specified, it will be resolved by
    searching sibling directories.
  .Parameter Path
    The file name to write out.
  .Parameter SourceFiles
    A list of FileInfo objects to include in the zip.
  .Parameter Type
    7zip supports output archive formats of 7z, zip, gzip, bzip2 or tar

    If left unspecified, defaults to 7z
  .Parameter Root
    If specified, will update the path of the files stored in the zip,
    removing this root value.
  .Parameter 7ZipPath
    The optional directory from which 7Zip will be loaded.

    If left unspecified, the sibling directories of the Midori package
    will be scanned for anything matching 7z.exe or 7za.exe, and the
    first matching file will be used if multiple versions are found.
    7Zip should be package restored by a scripted bootstrap process.
  .Example
    New-ZipFile -Path c:\foo.zip -Root c:\foo `
      -SourceFiles (Get-ChildItem c:\foo) `
      -7ZipPath ..\src\packages\7Zip\7za.exe

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
    [ValidateSet('7z', 'zip', 'gzip', 'bzip2', 'tar')]
    $Type = '7z',

    [Parameter(Mandatory=$false)]
    [string]
    [ValidateScript({ (Test-Path $_) -and (Get-Item $_).PSIsContainer })]
    $Root,

    [Parameter(Mandatory=$false)]
    [IO.FileInfo]
    [ValidateScript({
      (Test-Path $_) -and (!$_.PSIsContainer) -and
      ('7z.exe','7za.exe' -contains $_.Name)
    })]
    $7ZipPath = (Get-7ZipPath)
  )

  if (! (Test-Path $7ZipPath))
    { throw "Could not find 7Zip at [$7ZipPath]! Restore with build bootstrap. "}

  $rewritePath = ![string]::IsNullOrEmpty($Root)

  try
  {
    #7z automatically roots paths based on where the working directory is
    if ($rewritePath) { Push-Location $Root }

    "Adding $($SourceFiles.Length) files to archive $Path"

    #7zip has a bug where including files via a .lst file doesn't work when
    #multiple paths have the same file name, so we have to tweak the list
    #http://sourceforge.net/projects/sevenzip/forums/forum/45797/topic/2857100
    $SourceFiles | Select -ExpandProperty FullName |
      % {
        if (-not $rewritePath) { return $_ }

        $foundIndex = $_.IndexOf($Root,
          [StringComparison]::CurrentCultureIgnoreCase)
        if ($foundIndex -eq 0)
        {
          $stripped = $_.Substring($Root.Length)
          if ($stripped.StartsWith([IO.Path]::DirectorySeparatorChar))
          {
            return $stripped.Substring(1)
          }

          return $stripped
        }

        return $_
      } |
      Out-File 'include.lst' -Encoding UTF8 -Force

    $params = @('a', "-t$Type", '-ir@include.lst', $Path)
    &$7ZipPath $params
  }
  finally
  {
    if (Test-Path 'include.lst') { Remove-item 'include.lst' }
    if ($rewritePath) { Pop-Location }
  }

  "Wrote $($SourceFiles.Length) files to archive $Path"
}

Export-ModuleMember -Function New-ZipFile, Invoke-AuthenticodeSignTool,
Set-7ZipPath