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
  $key = if ([intptr]::size -eq 8)
    { "HKLM:SOFTWARE\Wow6432Node\Microsoft\VisualStudio\$version" }
  else
    { "HKLM:SOFTWARE\Microsoft\VisualStudio\$version" }

  $VsKey = Get-ItemProperty $key
  $VsInstallPath = [IO.Path]::GetDirectoryName($VsKey.InstallDir)
  $VsToolsDir = Join-Path ([IO.Path]::GetDirectoryName($VsInstallPath)) 'Tools'
  $BatchFile = Join-Path $VsToolsDir 'vsvars32.bat'
  Get-Batchfile $BatchFile
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
$buildPackageDir = Join-Path (Get-CurrentDirectory) 'packages'
$sourcePackageDir = Join-Path (Get-CurrentDirectory) '..\src\Packages'

@(@{Id = 'psake'; Version='4.2.0.1'; Dir = $buildPackageDir; NoVersion = $true },
  @{Id = 'Midori'; Version='0.2.0.0'; Dir = $buildPackageDir; NoVersion = $true },
  @{Id = 'DotNetZip'; Version='1.9.1.8'; Dir = $buildPackageDir; NoVersion = $true }) |
  % {
    $versionSwitch = if ($_.NoVersion) {'-ExcludeVersion'} else { '' }
    &.\nuget install "$($_.Id)" -v "$($_.Version)" -o `""$($_.Dir)"`" "$versionSwitch"
  }

Remove-Module psake -erroraction silentlycontinue
Import-Module (Join-Path $buildPackageDir 'psake\tools\psake.psm1')
$bufferSize = $host.UI.RawUI.BufferSize
$newBufferSize = New-Object Management.Automation.Host.Size(512,
  $bufferSize.Height)
$host.UI.RawUI.BufferSize = $newBufferSize
Invoke-psake default
$host.UI.RawUI.BufferSize = $bufferSize