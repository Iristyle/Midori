function Get-Batchfile ($file)
{
  $cmd = "`"$file`" & set"
  cmd /c $cmd | % {
    $p, $v = $_.split('=')
    Set-Item -path env:$p -value $v
  }
}

function VsVars32($version = '10.0')
{
  $name = "Psake-ReadVsVars-$version"
  $readVersion = Get-Variable -Scope Global -Name $name `
    -ErrorAction SilentlyContinue

  #continually jamming stuff into PATH is *not* cool ;0
  if ($readVersion) { return }

  Write-Host "Reading VSVars for $version"
  $key = if ([IntPtr]::size -eq 8)
    { "HKLM:SOFTWARE\Wow6432Node\Microsoft\VisualStudio\$version" }
  else
    { "HKLM:SOFTWARE\Microsoft\VisualStudio\$version" }

  $VsKey = Get-ItemProperty $key
  $VsRootDir = Split-Path $VsKey.InstallDir
  $BatchFile = Join-Path (Join-Path $VsRootDir 'Tools') 'vsvars32.bat'
  Get-Batchfile $BatchFile
  Set-Variable -Scope Global -Name $name -Value $true
}

function Get-CurrentDirectory
{
  $thisName = $MyInvocation.MyCommand.Name
  [IO.Path]::GetDirectoryName((Get-Content function:$thisName).File)
}

Set-Location (Get-CurrentDirectory)

VsVars32
if (Test-Path 'nuget.exe')
{
  &.\nuget update -Self
}
else
{
  $nugetPath = Join-Path (Get-CurrentDirectory) 'nuget.exe'
  (New-Object Net.WebClient).DownloadFile('http://nuget.org/NuGet.exe', $nugetPath)
}

[Environment]::SetEnvironmentVariable('EnableNuGetPackageRestore','true')

Write-Host 'Loaded environment variables'
Get-ChildItem Env: | Format-Table -Wrap

$buildPackageDir = Join-Path (Get-CurrentDirectory) 'packages'
$sourcePackageDir = Join-Path (Get-CurrentDirectory) '..\src\Packages'

@(@{Id = 'psake'; Version='4.2.0.1'; Dir = $buildPackageDir; NoVersion = $true },
  @{Id = 'Midori'; Version='0.7.1.0'; Dir = $buildPackageDir; NoVersion = $true },
  #still require dotnetZip to extract the 7-zip command line, sigh
  @{Id = 'DotNetZip'; Version='1.9.1.8'; Dir = $buildPackageDir; NoVersion = $true },
  @{Id = 'xunit.runners'; Version='1.9.1'; Dir = $buildPackageDir; NoVersion = $true }) |
  % {
    $nuget = @('install', "$($_.Id)", '-Version', "$($_.Version)",
      '-OutputDirectory', "`"$($_.Dir)`"")
    if (-not ([string]::IsNullOrEmpty($_.Source)))
      { $nuget += '-Source', "`"$($_.Source)`"" }
    if ($_.NoVersion) { $nuget += '-ExcludeVersion' }
    &.\nuget $nuget
  }

#Use DotNetZip to Extract 7za.exe, since shell expansion isn't in Server Core
$7zOutputPath = Join-Path $buildPackageDir '7zip'
$7zFilePath = Join-Path $7zOutputPath '7za920.zip'
if (-not (Test-Path $7zFilePath))
{
  $7zUrl = 'http://downloads.sourceforge.net/project/sevenzip/7-Zip/9.20/7za920.zip?use_mirror=autoselect'

  New-Item $7zOutputPath -Type Directory | Out-Null
  (New-Object Net.WebClient).DownloadFile($7zUrl, $7zFilePath)
  $dnZipPath = Get-ChildItem $buildPackageDir -Recurse -Filter 'Ionic.zip.dll' |
    Select -ExpandProperty FullName -First 1
  Add-Type -Path $dnZipPath

  $zip = [Ionic.Zip.ZipFile]::Read($7zFilePath)
  $zip['7za.exe'].Extract($7zOutputPath)
  $zip.Dispose()
}

Remove-Module psake -erroraction silentlycontinue
Import-Module (Join-Path $buildPackageDir 'psake\tools\psake.psm1')
$bufferSize = $host.UI.RawUI.BufferSize
$newBufferSize = New-Object Management.Automation.Host.Size(512,
  $bufferSize.Height)
$host.UI.RawUI.BufferSize = $newBufferSize
Invoke-psake default
$host.UI.RawUI.BufferSize = $bufferSize
