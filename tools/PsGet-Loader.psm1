function Install-PsGet
{
<#
.Synopsis
  Installs PsGet, the Powershell Package Manager, enabling the ability to
  acquire other useful Powershell packages.
.Description
  Will install PsGet if it is not already installed.
.Example
  Install-PsGet

  Description
  -----------
  Installs PsGet from GitHub and then imports it into the current session
#>

  Write-Host "Ensuring PsGet is installed"
  $client = new-object Net.WebClient

  if (!(Get-Module -Name 'PsGet' -ListAvailable))
  {
    Write-Host "Installing PsGet"
    $client.DownloadString("http://psget.net/GetPsGet.ps1") |
      Invoke-Expression
  }

  Import-Module PsGet

  #Fixed in https://github.com/psget/psget/pull/30
  #clean out extraneous errors for PsGetDirectoryUrl
  $toRemove = for ($i = 0; $i -lt $global:Error.Count; $i++)
  {
    if (($global:Error[$i].TargetObject -eq 'PsGetDirectoryUrl') `
      -and ($global:Error[$i].Exception -is [Management.Automation.ItemNotFoundException]))
    { ,$i }
  }
  $toRemove | Sort-Object -Descending | % { $global:Error.RemoveAt($_) }
}

function Install-CommunityExtensions
{
<#
.Synopsis
  Installs PsCx, the Powershell community extensions by first installing
  PsGet - the Powershell package manager.
.Description
  There are a number of useful cmdlets in these extensions, including
  Expand-Archive for extracting zip files.
.Example
  Install-CommunityExtensions

  Description
  -----------
  This will install PsGet if it doesn't exist, then will install and
  Import-Module PsCx.
#>

  Install-PsGet

  Write-Host "Ensuring PsCx is installed"
  $params = @{
    ModuleName = 'Pscx';
    ModuleUrl = 'https://github.com/Iristyle/psget_repository/raw/pscx-updates/Modules/PSCX/Pscx-2.1.0-RC.zip';
    Type = 'zip';
    Update = $true;
  }
  Install-Module @params
  Import-Module PsCx
}

Export-ModuleMember -Function Install-PsGet, Install-CommunityExtensions
