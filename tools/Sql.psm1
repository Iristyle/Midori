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
    ('Microsoft.SqlServer.ConnectionInfo, Version=10.0.0.0, Culture=neutral, ' +
      'PublicKeyToken=89845dcd8080cc91'),
    ('Microsoft.SqlServer.Smo, Version=10.0.0.0, Culture=neutral, ' +
      'PublicKeyToken=89845dcd8080cc91'),
    ('Microsoft.SqlServer.Management.Sdk.Sfc, Version=10.0.0.0, Culture=neutral,' +
      ' PublicKeyToken=89845dcd8080cc91'),
    ('Microsoft.SqlServer.SqlEnum, Version=10.0.0.0, Culture=neutral, ' +
      'PublicKeyToken=89845dcd8080cc91'),
    ('Microsoft.SqlServer.SmoExtended, Version=10.0.0.0, Culture=neutral, ' +
      'PublicKeyToken=89845dcd8080cc91')

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
.Description
  Any additional customization may be performed by providing a
  ScriptBlock to the CustomizationCallback.

  The given service is checked to ensure it's running and then the script
  is executed.  If the database already exists, an error occurs.

  After initial creation, the database is set into single user mode to
  lock the database from additional access, and restored to multiple user
  access (configurable) after shrinking and running user customizations.

  The database is shrunk and detached after the cmdlet is run, but the
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
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]
    [ValidateScript({ Test-Path $_ })]
    $CreateScriptPath,

    [Parameter(Mandatory=$true)]
    [string]
    [ValidateScript({ (Test-Path $_) -and (Get-Item $_).PSIsContainer })]
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
    $database = New-Object Microsoft.SqlServer.Management.Smo.Database($server,
      $DatabaseName)
    $database.FileGroups.Add(
      (New-Object Microsoft.SqlServer.Management.Smo.FileGroup(
        $database, 'PRIMARY')))

    $primaryFileGroup = $dataBase.FileGroups['PRIMARY']
    $datafile = New-Object Microsoft.SqlServer.Management.Smo.Datafile(
      $primaryFileGroup, $DatabaseName, $dbFile)
    $datafile.Size = 4096
    $datafile.Growth = 1024
    $datafile.GrowthType = [Microsoft.SqlServer.Management.Smo.FileGrowthType]::KB

    $options = $database.DatabaseOptions
    #set single user mode so that we have exclusive access while we build db
    $options.UserAccess =
      [Microsoft.SqlServer.Management.Smo.DatabaseUserAccess]::Single

    $primaryFileGroup.Files.Add($datafile)

    Write-Host "Added PRIMARY filegroup [$dbFile] to database..."

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

    Write-Host "Shrinking [$DatabaseName]..."

    #DBCC SHRINKFILE / DBCC SHRINKDATABASE
    $database.Shrink(0,
      [Microsoft.SqlServer.Management.Smo.ShrinkMethod]::TruncateOnly)

    #restore multiuser access
    $options.UserAccess = $UserAccess
  }
  finally
  {
    if ($server)
    {
      if ($DatabaseName -and (-not $NoDetach))
      {
        #$database.TruncateLog() -- only works on 2005 or earlier
        $server.DetachDatabase($DatabaseName, $true)
      }
      $server.ConnectionContext.Disconnect()
    }
  }
}

#http://stackoverflow.com/questions/5123423/error-restoring-database-backup-to-new-database-with-smo-and-powershell
function Backup-SqlDatabase
{
  <#
  .Synopsis
    Will generate a copy of an existing SQL server database using the SMO
    backup methods.
  .Description
    The given service is checked to ensure it's running.

    The given database name is copied to a backup file using the SMO
    Backup class.  This will work on a live database; what is generated
    is considered a snapshot appropriate for a restore.

    The backup mechanism is much faster than Transfer, but may be less
    appropriate for a live database.

    The written file is named $DatabaseName.bak and is written to the
    given BackupPath.

    Requires that SMO and some SQL server be installed on the local machine
  .Parameter DatabaseName
    The original name of the database.
  .Parameter BackupPath
    The directory to write the backup file to, not including file name.
  .Parameter ServiceName
    The name of the SQL Server service name - will default to
    MSSQL$SQLEXPRESS if left unspecified.
  .Parameter InstanceName
    The name of the SQL server instance. By default, .\SQLEXPRESS
  .Outputs
    A string containing the backup filename.
  .Example
    Backup-SqlDatabase -DatabaseName MyDatabase -BackupPath c:\db

    Description
    -----------
    Will use the default localhost SQLEXPRESS instance and will create a
    backup file named c:\db\MyDatabase.bak

    Outputs c:\db\MyDatabase.bak
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]
    $DatabaseName,

    [Parameter(Mandatory=$true)]
    [string]
    [ValidateScript({ (Test-Path $_) -and (Get-Item $_).PSIsContainer })]
    $BackupPath,

    [Parameter(Mandatory=$false)]
    [string]
    $ServiceName = 'MSSQL$SQLEXPRESS',

    [Parameter(Mandatory=$false)]
    [string]
    $InstanceName = '.\SQLEXPRESS'
  )

  try
  {
    $backupFilePath = "$BackupPath\$DatabaseName.bak"

    $server = New-Object Microsoft.SqlServer.Management.Smo.Server($InstanceName)
    $smoBackup = New-Object Microsoft.SqlServer.Management.Smo.Backup

    $smoBackup.Action =
      [Microsoft.SqlServer.Management.Smo.BackupActionType]::Database
    $smoBackup.BackupSetDescription = "Full Backup of $DatabaseName"
    $smoBackup.BackupSetName = "$DatabaseName Backup"
    $smoBackup.Database = $DatabaseName
    $smoBackup.Incremental = $false
    $smoBackup.LogTruncation =
      [Microsoft.SqlServer.Management.Smo.BackupTruncateLogType]::Truncate
    $smoBackup.Devices.AddDevice($backupFilePath,
      [Microsoft.SqlServer.Management.Smo.DeviceType]::File)
    Write-Host "Generating [$backupFilePath] for [$DatabaseName]"
    $smoBackup.SqlBackup($server)

    return $backupFilePath
  }
  finally
  {
    if ($server) { $server.ConnectionContext.Disconnect() }
  }
}

function Restore-SqlDatabase
{
<#
.Synopsis
  Will restore a given SQL backup file to a new database using SMO, and
  a backup file generated by Backup-SqlDatabase.
.Description
  The given service is checked to ensure it's running and then a new
  database is created with the given destination name, as restored from
  the backup file.  If the database already exists, an error occurs.

  This is not allowed to replace an existing database of the same name.

  The database is detached after the cmdlet is run, unless -NoDetach is
  specified.

  Requires that SMO and some SQL server be installed on the local machine
.Parameter BackupPath
  The complete path to the SQL backup file.
.Parameter DestinationDatabasePath
  The final output database path, not including the file name.
.Parameter DestinationDatabaseName
  The final output database filename.  Both MDF and LDF will assume this
  name.
.Parameter NoDetach
  Will disable the database from being detached after creation. This will
  allow the database to be used in, for instance, integration tests.

  Default is to detach the database.
.Parameter KillAllProcesses
  Will instruct the SQL Server instance to kill all the processes
  associated with the DestinationDatabaseName, should there be any.  In
  build scenarios, this is not typically needed.

  Default is to not kill all processes
.Parameter ServiceName
  The name of the SQL Server service name - will default to
  MSSQL$SQLEXPRESS if left unspecified.
.Parameter InstanceName
  The name of the SQL server instance. By default, .\SQLEXPRESS
.Example
  Restore-SqlDatabase -BackupPath c:\db\foo.bak `
    -DestinationDatabasePath c:\db -DestinationDatabaseName MyDatabase2

  Description
  -----------
  Will use the default localhost SQLEXPRESS instance and setup a new
  SQL MDF on disk, based on a restore from the given .bak file.
  The database files will be placed into c:\db\MyDatabase2.mdf
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]
    [ValidateScript({ (Test-Path $_) -and (!(Get-Item $_).PSIsContainer) })]
    $BackupPath,

    [Parameter(Mandatory=$true)]
    [string]
    [ValidateScript({ (Test-Path $_) -and (Get-Item $_).PSIsContainer })]
    $DestinationDatabasePath,

    [Parameter(Mandatory=$true)]
    [string]
    $DestinationDatabaseName,

    [Parameter(Mandatory=$false)]
    [Switch]
    $NoDetach = $false,

    [Parameter(Mandatory=$false)]
    [Switch]
    $KillAllProcesses = $false,

    [Parameter(Mandatory=$false)]
    [string]
    $ServiceName = 'MSSQL$SQLEXPRESS',

    [Parameter(Mandatory=$false)]
    [string]
    $InstanceName = '.\SQLEXPRESS'
  )

  try
  {
    $dbFilePath = Join-Path $DestinationDatabasePath "$DestinationDatabaseName.mdf"
    $logFilePath = Join-Path $DestinationDatabasePath "$($DestinationDatabaseName)_Log.ldf"

    if (Test-Path $dbFilePath) { throw "$dbFilePath already exists!" }

    $server = New-Object Microsoft.SqlServer.Management.Smo.Server($InstanceName)

    # http://www.sqlmusings.com/2009/06/01/how-to-restore-sql-server-databases-using-smo-and-powershell/
    #http://stackoverflow.com/questions/1466651/how-to-restore-a-database-from-c-sharp
    $backupDevice = New-Object Microsoft.SqlServer.Management.Smo.BackupDeviceItem(
      $BackupPath, 'File')
    $smoRestore = New-Object Microsoft.SqlServer.Management.Smo.Restore

    $smoRestore.Database = $DestinationDatabaseName
    $smoRestore.NoRecovery = $false
    $smoRestore.ReplaceDatabase = $true
    $smoRestore.Action =
      [Microsoft.SqlServer.Management.Smo.RestoreActionType]::Database
    $smoRestore.Devices.Add($backupDevice)

    # Get the details from the backup device for the database name
    $smoRestoreDetails = $smoRestore.ReadBackupHeader($server)

    #must use logical file name stored in backup - can't construct on the fly
    $existingDatabaseName = $smoRestoreDetails.Rows[0]["DatabaseName"]
    @(@($existingDatabaseName, $dbFilePath),
      @("$($existingDatabaseName)_Log", $logFilePath)) |
    % {
      [Void]$smoRestore.RelocateFiles.Add(
        (New-Object Microsoft.SqlServer.Management.Smo.RelocateFile(
          $_[0], $_[1])))
    }

    if ($server.Databases.Contains($DestinationDatabaseName))
    {
      throw "Database $DestinationDatabaseName already exists!"
    }

    if ($KillAllProcesses) { $server.KillAllProcesses() }
    Write-Host ("Restoring [$BackupPath] to [$DestinationDatabaseName]" +
      "at [$dbFilePath]")
    $smoRestore.SqlRestore($server)
  }
  finally
  {
    if ($server)
    {
      if ($DestinationDatabaseName -and (-not $NoDetach))
      {
        $server.DetachDatabase($DestinationDatabaseName, $true)
      }
      $server.ConnectionContext.Disconnect()
    }
  }
}

function Transfer-SqlDatabase
{
<#
.Synopsis
  Will generate a copy of an existing SQL server database using the SMO
  Transfer class.
.Description
  The given service is checked to ensure it's running and then a new
  database is created with the given destination name.  If the database
  already exists, an error occurs.

  The given database name is copied using the SMO Transfer object to a
  new database.  This will work on a live database, and is therefore
  slower than a simple backup / restore.

  The database is shrunk and detached after the cmdlet is run.

  Requires that SMO and some SQL server be installed on the local machine
.Parameter DatabaseName
  The original name of the database.
.Parameter DestinationDatabasePath
  The final output database path, not including the file name.
.Parameter DestinationDatabaseName
  The final output database filename.  Both MDF and LDF will assume this
  name.
.Parameter NoDetach
  Will disable the database from being detached after creation. This will
  allow the database to be used in, for instance, integration tests.
.Parameter ServiceName
  The name of the SQL Server service name - will default to
  MSSQL$SQLEXPRESS if left unspecified.
.Parameter InstanceName
  The name of the SQL server instance. By default, .\SQLEXPRESS
.Example
  Transfer-SqlDatabase -DatabaseName MyDatabase `
    -DestinationDatabasePath c:\db -DestinationDatabaseName MyDatabase2

  Description
  -----------
  Will use the default localhost SQLEXPRESS instance and setup a new
  SQL MDF on disk, copying the given database name into a new name.
  The database files will be placed into c:\db\newdb.mdf
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]
    $DatabaseName,

    [Parameter(Mandatory=$true)]
    [string]
    [ValidateScript({ (Test-Path $_) -and (Get-Item $_).PSIsContainer })]
    $DestinationDatabasePath,

    [Parameter(Mandatory=$true)]
    [string]
    $DestinationDatabaseName,

    [Parameter(Mandatory=$false)]
    [Switch]
    $NoDetach = $false,

    [Parameter(Mandatory=$false)]
    [string]
    $ServiceName = 'MSSQL$SQLEXPRESS',

    [Parameter(Mandatory=$false)]
    [string]
    $InstanceName = '.\SQLEXPRESS'
  )

  Load-Types

  Start-ServiceAndWait $ServiceName

  $dbFilePath = Join-Path $DestinationDatabasePath "$DestinationDatabaseName.mdf"
  if (Test-Path $dbFilePath) { throw "$dbFilePath already exists!" }

  Write-Host "Copying [$DatabaseName] to [$dbFilePath] with service [$serviceName]"

  try
  {
    #http://msdn.microsoft.com/en-us/library/microsoft.sqlserver.management.smo.transfer_members(v=sql.100)
    $server = New-Object Microsoft.SqlServer.Management.Smo.Server($InstanceName)
    $server.SetDefaultInitFields($true)

    #SMO is a real PITA, since Transfer.CreateTargetDatabase doesn't accept a
    #filename, but only a root path, so we have to create a new db by hand
    #otherwise the original db can't be backed up to same directory and the
    #internal filenames in the MDF get totally bungled
    $database = New-Object Microsoft.SqlServer.Management.Smo.Database($server,
      $DestinationDatabaseName)
    $database.FileGroups.Add(
      (New-Object Microsoft.SqlServer.Management.Smo.FileGroup(
        $database, 'PRIMARY')))

    $primaryFileGroup = $dataBase.FileGroups['PRIMARY']
    $datafile = New-Object Microsoft.SqlServer.Management.Smo.Datafile(
      $primaryFileGroup, $DatabaseName, $dbFilePath)
    $datafile.Size = 4096
    $datafile.Growth = 1024
    $datafile.GrowthType = [Microsoft.SqlServer.Management.Smo.FileGrowthType]::KB
    $primaryFileGroup.Files.Add($datafile)

    Write-Host "Added PRIMARY filegroup [$dbFilePath] to database..."
    $database.Create()

    $transfer = New-Object Microsoft.SqlServer.Management.Smo.Transfer(
      $server.Databases[$DatabaseName])

    $transfer.CopyAllObjects = $false #this is a *very* misleading property...

    $transfer.CopyAllDatabaseTriggers = $true
    $transfer.CopyAllDefaults = $true
    $transfer.CopyAllFullTextCatalogs = $true
    $transfer.CopyAllFullTextStopLists = $true
    #weird errors if this is enabled -- service principal already exists
    $transfer.CopyAllLogins = $true
    $transfer.CopyAllPartitionFunctions = $true
    $transfer.CopyAllPartitionSchemes = $true
    $transfer.CopyAllPlanGuides = $true
    $transfer.CopyAllRoles = $true
    $transfer.CopyAllRules = $true
    $transfer.CopyAllSchemas = $true
    #not available in 2008
    #$transfer.CopyAllSearchPropertyLists = $true
    #$transfer.CopyAllSequences = $true
    $transfer.CopyAllSqlAssemblies = $true
    $transfer.CopyAllStoredProcedures = $true
    $transfer.CopyAllSynonyms = $true
    $transfer.CopyAllTables = $true
    $transfer.CopyAllUserDefinedAggregates = $true
    $transfer.CopyAllUserDefinedDataTypes = $true
    $transfer.CopyAllUserDefinedFunctions = $true
    $transfer.CopyAllUserDefinedTableTypes = $true
    $transfer.CopyAllUserDefinedTypes = $true
    $transfer.CopyAllUsers = $true
    $transfer.CopyAllViews = $true
    $transfer.CopyAllXmlSchemaCollections = $true
    $transfer.CopyData = $true
    $transfer.CopySchema = $true

    #this cannot be set to true per a bug in TransferData()
    #http://stackoverflow.com/questions/6227305/sql-server-copy-database-issue
    #$transfer.Options.IncludeDatabaseRoleMemberships = $true
    $transfer.Options.Indexes = $true
    $transfer.Options.DriAll = $true
    $transfer.Options.Permissions = $true
    $transfer.Options.SchemaQualify = $true
    $transfer.Options.SchemaQualifyForeignKeysReferences = $true
    $transfer.Options.Statistics = $true
    #$transfer.Options.TargetServerVersion =
    #  [SqlServer.Management.Smo.SqlServerVersion]::Version90
    $transfer.Options.WithDependencies = $true
    $transfer.Options.IncludeIfNotExists = $true
    $transfer.Options.FullTextIndexes = $true
    $transfer.Options.ExtendedProperties = $true

    $transfer.DestinationDatabase = $DestinationDatabaseName
    $transfer.DestinationServer = $server.Name

    #TODO: consider surfacing DestinationLogin / DestinationPassword
    #if those are specified, then DestinationLoginSecure is $false
    $transfer.DestinationLoginSecure = $true
    $transfer.PreserveLogins = $true
    $transfer.PreserveDbo  = $true
    $transfer.Options.ContinueScriptingOnError = $true

    Write-Host "Initiating transfer from [$DatabaseName]..."
    $transfer.TransferData()

    #DBCC SHRINKFILE / DBCC SHRINKDATABASE
    Write-Host "Shrinking [$DestinationDatabaseName]..."
    $database.Shrink(0,
      [Microsoft.SqlServer.Management.Smo.ShrinkMethod]::TruncateOnly)
  }
  finally
  {
    if ($server)
    {
      if ($DestinationDatabaseName -and (-not $NoDetach))
      {
        $server.DetachDatabase($DestinationDatabaseName, $true)
      }
      $server.ConnectionContext.Disconnect()
    }
  }
}

function Copy-SqlDatabase
{
<#
.Synopsis
  Will generate a copy of an existing SQL server database using either a
  SMO backup/restore, or by using the SMO Transfer class.
.Description
  The given service is checked to ensure it's running and then a new
  database is created with the given destination name.  If the database
  already exists, an error occurs.

  The given database name is copied using the SMO Transfer object to a
  new database.  This will work on a live database, and is therefore
  slower than a simple backup / restore.

  The database is shrunk and detached after the cmdlet is run.

  Requires that SMO and some SQL server be installed on the local machine
.Parameter DatabaseName
  The original name of the database.
.Parameter DestinationDatabasePath
  The final output database path, not including the file name.
.Parameter DestinationDatabaseName
  The final output database filename.  Both MDF and LDF will assume this
  name.
.Parameter CopyMethod
  The SMO technique used to copy the database.

  * BackupRestore generates a .bak file, then restores to a new database
  This is most suitable in a build scenario, where there are no users
  attached to the database / executing queries
  * Transfer uses the SMO Transfer object, which is much slower, but can
  be used against live databases
.Parameter ServiceName
  The name of the SQL Server service name - will default to
  MSSQL$SQLEXPRESS if left unspecified.
.Parameter InstanceName
  The name of the SQL server instance. By default, .\SQLEXPRESS
.Example
  Copy-SqlDatabase -DatabaseName MyDatabase `
    -DestinationDatabasePath c:\db -DestinationDatabaseName MyDatabase2

  Description
  -----------
  Will use the default localhost SQLEXPRESS instance and setup a new
  SQL MDF on disk, copying the given database name into a new name.
  The database files will be placed into c:\db\newdb.mdf
  By default, the copy will be made with the faster Backup / Restore.
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]
    $DatabaseName,

    [Parameter(Mandatory=$true)]
    [string]
    [ValidateScript({ (Test-Path $_) -and (Get-Item $_).PSIsContainer })]
    $DestinationDatabasePath,

    [Parameter(Mandatory=$true)]
    [string]
    $DestinationDatabaseName,

    [Parameter(Mandatory=$false)]
    [string]
    [ValidateSet('BackupRestore', 'Transfer')]
    $CopyMethod = 'BackupRestore',

    [Parameter(Mandatory=$false)]
    [string]
    $ServiceName = 'MSSQL$SQLEXPRESS',

    [Parameter(Mandatory=$false)]
    [string]
    $InstanceName = '.\SQLEXPRESS'
  )


  switch ($CopyMethod)
  {
    'BackupRestore'
    {
      $BackupPath = Backup-SqlDatabase -DatabaseName $DatabaseName `
        -BackupPath $DestinationDatabasePath -ServiceName $ServiceName `
        -InstanceName $InstanceName
      Restore-SqlDatabase -BackupPath $BackupPath `
        -DestinationDatabasePath $DestinationDatabasePath `
        -DestinationDatabaseName $DestinationDatabaseName `
        -ServiceName $ServiceName -InstanceName $InstanceName
      Remove-Item $BackupPath
    }
    'Transfer'
    {
      $params = @{
        DatabaseName = $DatabaseName;
        DestinationDatabasePath = $DestinationDatabasePath;
        DestinationDatabaseName = $DestinationDatabaseName;
        ServiceName = $ServiceName;
        InstanceName  = $InstanceName;
      }

      Transfer-SqlDatabase @params
    }
  }
}

function Remove-SqlDatabase
{
<#
.Synopsis
  Will detach an existing SQL server database using SMO.
.Description
  The given service is checked to ensure it's running and then the script
  is executed.  If the database already exists, an error occurs.

  The database is detached using the DetachDatabase SMO Api call.

  Requires that SMO and some SQL server be installed on the local machine
.Parameter DatabaseName
  The name of the database to detach.
.Parameter ServiceName
  The name of the SQL Server service name - will default to
  MSSQL$SQLEXPRESS if left unspecified.
.Parameter InstanceName
  The name of the SQL server instance. By default, .\SQLEXPRESS
.Example
  Remove-SqlDatabase -DatabaseName MyDatabase

  Description
  -----------
  Will use the default localhost SQLEXPRESS instance and will detach
  MyDatabase.
#>
  param(
    [Parameter(Mandatory=$true)]
    [string]
    $DatabaseName,

    [Parameter(Mandatory=$false)]
    [string]
    $ServiceName = 'MSSQL$SQLEXPRESS',

    [Parameter(Mandatory=$false)]
    [string]
    $InstanceName = '.\SQLEXPRESS'
  )

  Load-Types
  Start-ServiceAndWait $ServiceName

  Write-Host "Detaching $DatabaseName from $InstanceName"
  try
  {
    $server = New-Object Microsoft.SqlServer.Management.Smo.Server($InstanceName)
    $server.DetachDatabase($DatabaseName, $true)
  }
  finally
  {
    if ($server) { $server.ConnectionContext.Disconnect() }
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
    [ValidateScript({ (Test-Path $_) -and (!(Get-Item $_).PSIsContainer) })]
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
      { $Host.UI.RawUI.BufferSize.Width } else { 80 }},

    [string]
    $InstanceName = 'Blarf'
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
    if ($server) { $server.ConnectionContext.Disconnect() }
  }
}

Export-ModuleMember -Function New-SqlDatabase, Invoke-SqlFileSmo,
  Remove-SqlDatabase, Copy-SqlDatabase, Transfer-SqlDatabase, Backup-SqlDatabase,
  Restore-SqlDatabase
