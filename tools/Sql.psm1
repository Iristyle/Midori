function Get-CurrentDirectory
{
    $thisName = $MyInvocation.MyCommand.Name
    [IO.Path]::GetDirectoryName((Get-Content function:$thisName).File)
}

$script:typesLoaded = $false
function Load-Types
{
  if ($script:typesLoaded) { return }

  #Requires SQL SMO goop - http://www.microsoft.com/download/en/details.aspx?displaylang=en&id=16177
  #requires MSXML 6, SQL CLR types and SQL Native Client
  #9.0 needed for 2005, 10.0 needed for 2008
  Add-Type -AssemblyName 'System.Data',
    'Microsoft.SqlServer.ConnectionInfo, Version=10.0.0.0, Culture=neutral, ' +
      'PublicKeyToken=89845dcd8080cc91',
    'Microsoft.SqlServer.Smo, Version=10.0.0.0, Culture=neutral, ' +
      'PublicKeyToken=89845dcd8080cc91',
    'Microsoft.SqlServer.Management.Sdk.Sfc, Version=10.0.0.0, Culture=neutral,' +
      ' PublicKeyToken=89845dcd8080cc91',
    'Microsoft.SqlServer.SqlEnum, Version=10.0.0.0, Culture=neutral, ' +
      'PublicKeyToken=89845dcd8080cc91'

    $script:typesLoaded = $true
}

function Start-ServiceAndWait
{
  param
  (
    [Parameter(Mandatory=$true)]
    [string]
    [ValidateScript({Get-Service | ? { $_.Name -eq $serviceName }})]
    $ServiceName,

    [Parameter(Mandatory=$false)]
    [int]
    [ValidateRange(1, 30)]
    $MaximumWaitSeconds = 15
  )

  $service = Get-Service | ? { $_.Name -eq $serviceName }
  if (-not $service) { throw "Service $ServiceName does not exist" }

  if ($service.Status -ne 'Running')
  {
    $identity = [Security.Principal.WindowsPrincipal] `
      ([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $identity.IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (! $isAdmin) { throw "Must be in Administrator role to start service" }
    $service | Start-Service
    $seconds = 0
    while (($seconds -lt $MaximumWaitSeconds) -and `
      ((Get-Service $serviceName).Status -ne 'Running'))
    {
      Write-Host "Waiting on [$serviceName] to start..."
      sleep 1
      $seconds++
    }
    if ((Get-Service $serviceName).Status -ne 'Running')
    {
      throw { "Failed to start service in $seconds seconds" }
    }
  }

  Write-Host -ForeGroundColor Magenta `
    "Service [$serviceName] is running"
}

function New-SqlDatabase
{
<#
.Synopsis
  Will generate a new SQL server database using SMO and a given script.
  The file will be initially attached to a random GUID naming convention
  before being moved to the final specified destination / name.
.Description
  Any additional customization may be performed by providing a
  ScriptBlock to the CustomizationCallback.

  The given service is checked to ensure it's running and then the script
  is executed.  If the database already exists, an exception occurs.

  After initial creation, the database is set into single user mode to
  lock the database from additional access, and restored to multiple user
  access (configurable) after shrinking and running user customizations.

  The database is detached and shrunk after the script is run, but the
  detachment can be disabled with the use of a switch.

  Requires that SMO and some SQL server be installed on the local machine
.Parameter CreateScriptPath
  The path of the SQL creation script.

  Note that the script should only generally execute against the given
  DatabaseName.  Only the database named DatabaseName will be detached
  from the server.
.Parameter DatabasePath
  The final output database path.
.Parameter DatabaseName
  The final output database filename.  Both MDF and LDF will assume this
  name.
.Parameter ServiceName
  The name of the SQL Server service name - will default to
  MSSQL$SQLEXPRESS if left unspecified.
.Parameter InstanceName
  The name of the SQL server instance. By default, .\SQLEXPRESS
.Parameter CustomizationCallback
  A ScriptBlock that will be given the instance of the database for the
  explicit purpose of additional customization before the database is
  created.  The instance is of type
  Microsoft.SqlServer.Management.Smo.Database.
.Parameter UserAccess
  An enumeration value that determines whether the database should be put
  into Single, Restricted or Multiple user access.  As the database is
  built, single user mode is configured to prevent additional concurrent
  access from other build processes, and it is restored to multiple just
  before detaching from the SQL service.
.Parameter NoDetach
  Will disable the database from being detached after creation. This will
  allow the database to be used in, for instance, integration tests.
.Example
  New-SqlDatabase -CreateScriptPath .\foo.sql `
    -DatabasePath c:\db -DatabaseName 'newdb'

  Description
  -----------
  Will use the default localhost SQLEXPRESS instance and setup a new
  SQL MDF on disk, running foo.sql against the given database.
  After the script completes, the database files will be placed into
  c:\db\newdb.mdf
#>
  param(
    [Parameter(Mandatory=$true)]
    [string]
    [ValidateScript({ Test-Path $_ })]
    $CreateScriptPath,

    [Parameter(Mandatory=$true)]
    [string]
    $DatabasePath,

    [Parameter(Mandatory=$true)]
    [string]
    $DatabaseName,

    [Parameter(Mandatory=$false)]
    [string]
    $ServiceName = 'MSSQL$SQLEXPRESS',

    [Parameter(Mandatory=$false)]
    [string]
    $InstanceName = '.\SQLEXPRESS',

    [Parameter(Mandatory=$false)]
    [ScriptBlock]
    $CustomizationCallback,

    [Parameter(Mandatory=$false)]
    #[Microsoft.SqlServer.Management.Smo.DatabaseUserAccess]
    $UserAccess = 0,

    [Parameter(Mandatory=$false)]
    [Switch]
    $NoDetach = $false
  )

  Load-Types
  if (($UserAccess -eq $null) -or (@(0,1,2) -notcontains [int]$UserAccess))
    { throw '$UserAccess must be a valid DatabaseUserAccess value' }

  Start-ServiceAndWait $ServiceName

  $dbFile = Join-Path $DatabasePath "$DatabaseName.mdf"

  if (Test-Path $dbFile) { throw "$dbFile already exists!" }

  Write-Host "Creating database [$dbFile] with service [$serviceName]"

  try
  {
    $server = New-Object Microsoft.SqlServer.Management.Smo.Server($InstanceName)
    $database = New-Object Microsoft.SqlServer.Management.Smo.Database($server, $DatabaseName)
    $database.FileGroups.Add((New-Object Microsoft.SqlServer.Management.Smo.FileGroup($database, 'PRIMARY')))

    $primaryFileGroup = $dataBase.FileGroups['PRIMARY']
    $datafile = New-Object Microsoft.SqlServer.Management.Smo.Datafile($primaryFileGroup, $DatabaseName, $dbFile)
    $datafile.Size = 2048
    $datafile.Growth = 1024
    $datafile.GrowthType = [Microsoft.SqlServer.Management.Smo.FileGrowthType]::KB

    $options = $database.DatabaseOptions
    #set single user mode so that we have exclusive access while we build db
    $options.UserAccess = [Microsoft.SqlServer.Management.Smo.DatabaseUserAccess]::Single

    $primaryFileGroup.Files.Add($datafile)

    Write-Host 'Added PRIMARY filegroup to database...'

    if ($CustomizationCallback)
    {
      &$CustomizationCallback $database
      Write-Host 'Customized database using callback'
    }
    $database.Create()

    Write-Host 'Created database, executing SQL to setup tables and friends...'

    #$server.ConnectionContext.StatementTimeout = $TimeoutSeconds
    $commands = [IO.File]::ReadAllText($CreateScriptPath)
    [Void]$database.ExecuteNonQuery($commands)

    Write-Host 'Shrinking database...'

    #DBCC SHRINKFILE (N'DBFC001_log' , 0, TRUNCATEONLY) / DBCC SHRINKDATABASE(N'DBFC001' )
    $database.Shrink(0,
      [Microsoft.SqlServer.Management.Smo.ShrinkMethod]::TruncateOnly)

    #restore multiuser access
    $options.UserAccess = $UserAccess
  }
  finally
  {
    if ($server -and $DatabaseName -and (-not $NoDetach))
    {
      #$database.TruncateLog() -- only works on 2005 or earlier
      $server.DetachDatabase($DatabaseName, $true)
    }
  }
}

function Invoke-SqlFileSmo
{
<#
.Synopsis
  Will run a given SQL script via SMO against a given database.  Output
  from the ServerMessage and InfoMessage events are automatically sent to
  Write-Host and Write-Verbose respectively.  If the ServerMessage events
  represent errors, their output is sent to Write-Error.
.Description
  ExecuteNonQuery is used against the database to execute the SQL script.

  Requires that SMO be installed on the local machine.
.Parameter Path
  The name of the script file to run.
.Parameter Database
  The name of the database to connect to.
.Parameter UserName
  The username used to connect to the database.
.Parameter Password
  The password used to connect ot the database.
.Parameter TimeoutSeconds
  Defaults to 30 seconds.  The timeout of the given script.
.Parameter UseTransaction
  Defaults to false.  Whether to wrap script execution in a transaction.
.Parameter Width
  Defaults to the current $Host.UI.RawUI.BufferSize.Width if available,
  otherwise 80

  Optional width of output strings.
.Example
  Invoke-SqlFileSmo -Path .\foo.sql -Database FC0001 -UserName sa `
    -Password secret -UseTransaction

  Description
  -----------
  Will execute foo.sql against the given database, wrapping it in a
  transaction.
#>
  param(
    [Parameter(Mandatory=$true)]
    [string]
    [ValidateScript({ Test-Path $_ })]
    $Path,

    [Parameter(Mandatory=$true)]
    [string]
    $Database,

    [Parameter(Mandatory=$true)]
    [string]
    $UserName,

    [Parameter(Mandatory=$true)]
    [string]
    $Password,

    [Parameter(Mandatory=$false)]
    [int]
    $TimeoutSeconds = 30,

    [Parameter(Mandatory=$false)]
    [switch]
    $UseTransaction = $false,

    [Parameter(Mandatory=$false)]
    $Width = { if ($Host -and $Host.UI -and $Host.UI.RawUI)
      { $Host.UI.RawUI.BufferSize.Width } else { 80 }}
  )

  Load-Types

  $Width = if ($Width -is [ScriptBlock]) { [int](&$Width) }
    else { [int]$Width }

  Write-Host -ForeGroundColor Magenta `
    "`n`n[START] - Running $Path against $Database $(if ($UseTransaction) { 'with transactions' } )"

  $eventIds = @()
  $serverConnection = $null

  try
  {
    $serverConnection = New-Object Microsoft.SqlServer.Management.Common.ServerConnection($Database, $UserName, $Password)
    $server = New-Object Microsoft.SqlServer.Management.SMO.Server($serverConnection)

    #3 potential events to hook - InfoMessage, ServerMessage and StatementExecuted
    #StatementExecuted is extremely verbose and contains all SQL executed
    #InfoMessage returns same content as ServerMessage, except only for class 0 error
    $params = @{
      InputObject = $serverConnection;
      EventName = 'ServerMessage';
      Action = {
        $lastError = $Event.SourceEventArgs.Error

        if (-not $lastError)
        {
          Write-Error "[ERROR]: $($Event | Select * | Out-String -Width $Width)"
        }

        switch ($lastError.Class)
        {
          0 {
            Write-Host "[INFO]: $($lastError.Message)" -ForeGroundColor Yellow
          }
          default {
            Write-Error "[ERROR]: $($lastError | Select * | Out-String -Width $Width)"
          }
        }
      }
    }

    $eventIds += (Register-ObjectEvent @params).Id

    #extremely verbose
    $params.EventName = 'InfoMessage'
    $params.Action = { Write-Verbose "$($Event.SourceEventArgs)" }
    $eventIds += (Register-ObjectEvent @params).Id

    if ($UseTransaction)
    {
      Write-Host 'Starting transaction...'
      $serverConnection.BeginTransaction()
    }

    $errors = $global:Error.Count

    $server.ConnectionContext.StatementTimeout = $TimeoutSeconds
    $affected = $server.ConnectionContext.ExecuteNonQuery([IO.File]::ReadAllText($Path))

    Write-Host "[INFO] : Invoke-SqlFileSmo affected [$affected] total records..."

    if ($global:Error.Count -gt $errors)
    {
      #TODO: this should be a throw or similar, otherwise the msg / info about rolling back never shows up
      Write-Error "`n`n[FATAL] : $($global:Error.Count - $errors) Errors in $Path"
      return
    }

    if ($UseTransaction)
    {
      Write-Host 'Committing transaction...'
      $serverConnection.CommitTransaction()
    }

    Write-Host -ForeGroundColor Magenta `
      "`n`n[SUCCESS] : 0 Errors executing $Path."
  }
  catch [Exception]
  {
    if ($UseTransaction -and ($serverConnection -ne $null))
    {
      Write-Host 'Rolling back transaction...'
      $serverConnection.RollBackTransaction()
    }
  }
  finally
  {
    if ($serverConnection -ne $null)
    {
      $uniqueId = "Closed$([Guid]::NewGuid().ToString())"
      #connection close
      $eventIds += (Register-ObjectEvent -InputObject $serverConnection `
        -SourceIdentifier $uniqueId -EventName 'StateChange').Id

      #Start-Sleep -m 1500 #allow events to propagate?
      $serverConnection.Disconnect()
      Wait-Event -SourceIdentifier $uniqueId -Timeout 5

      $eventIds |
        ? { $_ -ne $null } |
        % { Unregister-Event -SubscriptionId $_ }
    }
  }
}

Export-ModuleMember -Function New-SqlDatabase, Invoke-SqlFileSmo