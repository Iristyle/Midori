$moduleToSessionremoteScript = {
  Param(
    $Computername,
    $Modules
  )

  Write-Host "Creating Temp Session On Originating Computer: $Computername"

  $Local = @{
    Session = New-PSSession -Computername $Computername;
    Modules = $Modules | Select -ExpandProperty Name;
  }

  if (-not ($Local.Session))
    { throw "Could not establish connection to $Computername"}

  $Modules |
    % {
      $modulePath = if ($_.ModuleType -ne 'Binary') { $_.Path }
        else { Join-Path (Split-Path $_.Path) "$($_.Name).psd1" }

      $params = @{
        ScriptBlock = {
          Param($Path)
          Set-ExecutionPolicy Unrestricted
          Write-Host "Importing Module To Temp Session: $Path"
          Import-Module $Path
          Remove-Item $Path
        };
        Session = $Local.Session;
        ArgumentList = $modulePath;
      }

       Invoke-Command @params
       Write-Host "Exporting Module: $($_.Name)"
    }

  Import-PSSession @Local | Out-Null
}

function Export-ModuleToSession
{
<#
.Synopsis
  Extracts modules by name from localhost, and injects them into the
  external session.
.Description
  For this to work, a number of assumptions are made.
  - There is an established remote session
  - The remote session has the ability to connect back into the current
  machine by name. This assumes that WinRM is listening AND that the
  current host is reachable over the appropriate port (5985 for HTTP /
  5986 for HTTPS).  Might not be possible in secured environments.
  - The given module names can all be resolved locally.
  If none of these criteria are met, and all the modules are avaiable in
  source form, then prefer to use Export-SourceModulesToSession

  Concepts from http://stackoverflow.com/q/2830827/
.Parameter Session
  An established PSSession to a remote host.
.Parameter Modules
  A set of module objects that are installed in the current session.
.Example
  $foo = New-PSSession 'foo'
  Export-ModuleToSession -Session $foo -Modules (Get-Module 'baz','bar')

  Description
  -----------
  Will export modules 'baz' and 'bar' from the current session (typically
  localhost) to the session to remote computer 'foo'.
#>

  Param(
    [Management.Automation.Runspaces.PSSession]
    [ValidateNotNull()]
    $Session,
    [ValidateNotNull()]
    $Modules
   )

  $params = @{
    Session = $Session;
    ScriptBlock = $moduleToSessionremoteScript;
    Argumentlist = @($Env:COMPUTERNAME, (Get-Module -name $Modules));
  }

  Invoke-Command @params
}

function Export-SourceModuleToSession
{
  <#
  .Synopsis
    Reads modules at given paths and exports them into the given session.
  .Description
    The pre-requisite for maknig this work is that the modules must be in
    source form.  The files will be read / copied to the remote machine,
    stashed in a temporary location, and loaded within the given session.

    Caveats - Only handles ps1 and psm1 files - does not have a mechanism
    for using psd1 manifests or ps1xml metadata files (yet).
  .Parameter Session
    An established PSSession to a remote host.
  .Parameter ModulePaths
    A set of module paths that can be found on the current machine.
  .Example
    $foo = New-PSSession 'foo'
    Export-SourceModuleToSession -Session $foo `
      -Modules .\Sql.psm1,.\Files.psm1

    Description
    -----------
    Will export modules Sql and Files to the remote computer 'foo'.
  #>
  Param(
    [Management.Automation.Runspaces.PSSession]
    [ValidateNotNull()]
    $Session,

    [IO.FileInfo[]]
    [ValidateNotNull()]
    [ValidateScript(
    {
      (Test-Path $_) -and (!$_.PSIsContainer) -and
      ('.ps1','.psm1' -contains $_.Extension)
    })]
    $ModulePaths
  )

   $remoteModuleImportScript = {
     Param($Modules)

     Write-Host "Writing $($Modules.Count) modules to temporary disk location"

     $Modules |
       % {
         $basePath = [IO.Path]::GetTempFileName()
         $path = "$basePath-$($_.Name)$($_.Extension)"
         $_.Contents | Out-File -FilePath $path -Force
         "Importing module [$($_.Name)] from [$path]"
         Import-Module $path
         Remove-Item $basePath, $path -ErrorAction SilentlyContinue
       }
   }

  $modules = $ModulePaths |
    % { @{Name = $_.Name; Contents = Get-Content $_; Extension = $_.Extension} }

  $params = @{
    Session = $Session;
    ScriptBlock = $remoteModuleImportScript;
    Argumentlist = @(,$modules);
  }

  Invoke-Command @params
}

Export-ModuleMember -Function Export-ModuleToSession,
Export-SourceModuleToSession