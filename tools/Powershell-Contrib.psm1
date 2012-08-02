function Compare-Hash
{
  <#
  .Synopsis
    Compares two Hashtable objects based on their key / value pairs.

    Does not suport nested Hashtables.
  .Description
    Accepts two Hashtable objects, and returns $true if their k/v pairs
    match, or $false otherwise.
  .Parameter ReferenceObject
    The original object to compare
  .Parameter DifferenceObject
    The second object
  .Example
    Compare-Hash @{A = 1} @{A = 2}

    Returns $false
  .Example
    Compare-Hash @{A = 1; B = 2; } @{B = 2; A = 1;}

    Returns $true
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true, Position=0)]
    [Hashtable]
    [Alias("Ref")]
    [ValidateNotNull()]
    $ReferenceObject,

    [Parameter(Mandatory=$true, Position=1)]
    [Hashtable]
    [Alias("Diff")]
    [ValidateNotNull()]
    $DifferenceObject
  )

  if ($ReferenceObject.Count -ne $DifferenceObject.Count)
  { return $false }

  $params = @{
    ReferenceObject = $ReferenceObject.GetEnumerator() |
      % {$_.Key + " - " + $_.Value};
    DifferenceObject = $DifferenceObject.GetEnumerator() |
      % {$_.Key + " - " + $_.Value};
  }

  $results = Compare-Object @params
  if ($results -eq $null) { $true } else { $false }
}

function Get-TimeSpanFormatted
{
  <#
  .Synopsis
    Converts a TimeSpan into HH:MM:SS format
  .Description
    Uses .NET 2 compatible string building to create a HH:MM:SS string
  .Parameter TimeSpan
    Required TimeSpan value
  .Example
    $elapsedTime = [Diagnostics.Stopwatch]::StartNew()
    $formatted = Get-TimeSpanFormatted $elapsedTime.Elapsed
  #>
  [CmdletBinding()]
  param([TimeSpan]$TimeSpan)

  $d = $TimeSpan
  #yuck, no TimeSpan.Format in .NET < 4
  "$($d.Hours.ToString('00')):" +
    "$($d.Minutes.ToString('00')):$($d.Seconds.ToString('00'))"
}

function Get-SimpleErrorRecord
{
  <#
  .Synopsis
    Generates a Management.Automation.ErrorRecord from a given string,
    but does not throw it
  .Description
    Originally designed to create ErrorRecord instances for addition in
    the $Error object, via $Error.Add.  Intended to take a PSCustomObject
    WinRM serialized from an AutomationRecord, read out the properties
    and rehydrate a legit ErrorRecord.  In effect, this would remote
    errors from another machine locally.

    In reality, it doesn't work well for that purpose since there is no
    way to keep the identities of the original exceptions -- the best
    that can be achieved without a lot of code is to simply create
    generic Exceptions, losing their original typing and CallStack info.

    This was kept in case the need arose to generate basic ErrorRecord
    instances from a message, without throwing anything.  However, this
    documentation is likely of more value than the cmdlet.
  .Parameter ErrorMessage
    The string used to create the Exception
  .Example
    $Error.Add((Get-FauxError 'there was an error'))
  #>
  [CmdletBinding()]
  param([string]$ErrorMessage)

  #http://msdn.microsoft.com/en-us/library/windows/desktop/ms570263(v=vs.85).aspx
  #exception, errorid, errorcategory, targetObject
  return New-Object Management.Automation.ErrorRecord(
    (New-Object Exception($ErrorMessage)), '',
    [Management.Automation.ErrorCategory]::NotSpecified, $null)
}

function Remove-Error
{
  <#
  .Synopsis
    Removes the given number of errors from the given Error object
  .Description
    This helper controls pollution of the $Error object, but providing a
    convenient method of stripping the newest errors from the start of
    the collection
  .Parameter ErrorCollection
    The error collection to remove error instances from.

    If unspecified, this will default to $global:Error
  .Parameter Count
    Will remove up to the given number of errors from the collection. If
    the number specified is greater than the total count of errors, they
    are all removed.
  .Example
    Remove-Error -Count 1

    Removes the last error from the global $Error object, if it exists
  .Example
    Remove-Error $Error -Count 3

    Removes the last 3 recorded errors from the current scoped $Error
    object, should they exist.  Generally this will be $global:Error, but
    depending on module scope, could be $script:Error.
  .Example
    Remove-Error $script:Error -Count 2

    Removes the last 2 recorded errors from the module / script scoped
    $Error object, should they exist.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false)]
    [Collections.ArrayList]
    $ErrorCollection=$global:Error,

    [Parameter(Mandatory=$true)]
    [ValidateRange(0, 2147483647)]
    [int]
    $Count
  )

  if (($ErrorCollection.Count -eq 0) -or ($Count -eq 0)) { return }

  $toStrip = $Count
  if ($toStrip -gt $ErrorCollection.Count)
    { $toStrip = $ErrorCollection.Count }

  1..$toStrip | % { $ErrorCollection.RemoveAt(0) }
}

function Stop-TranscriptSafe
{
  <#
  .Synopsis
    Will call Stop-Transcript in a manner that will not generate output.
  .Description
    Checks to see if the host supports transcription before trying to
    call Stop, disables output, and removes any Error records that may
    have been created.
  .Example
    Stop-TranscriptSafe

    Description
    -----------
    Stops transcription, does not write output to the host and removes
    any Errors from the global Error collection if ones were generated.
  #>

  if (!(Test-Transcribing)) { return }
  #clear errors generated here (envs w/out Transcription)
  $errorCount = $global:Error.Count

  try
  {
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    Stop-Transcript | Out-Null
    $ErrorActionPreference = $previousErrorAction
  } catch {}

  Remove-Error $global:Error -Count $errorCount
}

function Select-ObjectWithDefault
{
  <#
  .Synopsis
    A safe, non-error generating replacement for Select-Object where you
    wish to return the value of a member OR a default value if the member
    does not exist or is $null
  .Description
    Will accept a series of objects from the pipeline. If the member is
    not found on the original class and there is a member available as a
    key in a hashtable, that value will be returned.
  .Parameter InputObject
    The object to examine
  .Parameter Name
    The name of the member on the object
  .Parameter Value
    The default value to use if the member does not exist on the object
  .Example
    @{ Bar = 'baz' } |Select-ObjectWithDefault -Name 'Count' -Value 'Foo'
    #outputs 1

    Description
    -----------
    Retrieves the Count property from the given Hashtable object.
  .Example
    @{ Bar = 'baz' } | Select-ObjectWithDefault -Name 'Bar' -Value 'ABC'
    #outputs baz

    Description
    -----------
    Retrieves the Bar property from the given Hashtable object.
  .Example
    @{ Bar = 'baz'; } | Select-ObjectWithDefault -Name 'Genie' `
      -Value 'Bottle'
    #outputs Bottle

    Description
    -----------
    Since the Genie property does not exist on the Hashtable object, the
    default value of Bottle is returned.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
    [AllowNull()]
    [PSObject]
    $InputObject,

    [Parameter(Mandatory=$true)]
    [string]
    $Name,

    [Parameter(Mandatory=$true)]
    [AllowNull()]
    $Value
  )

  process
  {
    if ($_ -eq $null) { $Value }
    elseif ($_ | Get-Member -Name $Name)
    {
      $_.$Name
    }
    elseif (($_ -is [Hashtable]) -and ($_.Keys -contains $Name))
    {
      $_.$Name
    }
    else { $Value }
  }
}

function Resolve-Error
{
  <#
  .Synopsis
    A means of recursively writing data from the Error object (or a given
    ErrorRecord) instance, to a string.
  .Description
    Will accept a series of objects from the pipeline.  Will default to
    reading the first error from the global $Error object.  ShortView
    treats SQL errors specially.
  .Parameter ErrorRecord
    Optional value that would specify an ErrorRecord instance
  .Parameter ShortView
    A switch that will limit the input to a short version, suitable for
    short notifications such as HipChat.  Special handling is given to
    SqlExceptions where the last InnerException typically contains the
    source line of the error.
  .Parameter Width
    Optional value that determines width of output strings.

    Defaults to the current $Host.UI.RawUI.BufferSize.Width if available,
    otherwise 80
  .Example
    $msg = Resolve-Error

    Description
    -----------
    Reads the single ErrorRecord object at $Error[0] and writes it to the
    string $msg
  .Example
    $msg = $Error | Resolve-Error

    Description
    -----------
    Writes all ErrorRecord objects to the string $msg
  .Example
    $msg = Resolve-Error -ShortView

    Description
    -----------
    Reads all of the $Error objects and writes them to the string $msg in
    a short view.
  .Example
    Write-Host -ForegroundColor -Magenta `
      (Resolve-Error -ErrorRecord $Error[3])

    Description
    -----------
    Will write the 4th ErrorRecord from the global $Error object to the
    host in Magenta colored text.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
    $ErrorRecord=$global:Error[0],

    [Parameter(Mandatory=$false)]
    [Switch]
    $ShortView,

    [Parameter(Mandatory=$false)]
    $Width = { if ($Host -and $Host.UI -and $Host.UI.RawUI)
      { $Host.UI.RawUI.BufferSize.Width } else { 80 }}
  )

  process
  {
    $Width = if ($Width -is [ScriptBlock]) { [int](&$Width) }
      else { [int]$Width }

    if ($_ -eq $null) { $_ = $ErrorRecord }
    $ex = $_.Exception
    $formattedEx = ''

    if (-not $ShortView)
    {
      $i = 0
      while ($ex -ne $null)
      {
        $i++
        $formattedEx += ("$i" * 70) +
          ($ex | Format-List * -Force | Out-String -Width $Width)
        $ex = $ex | Select-ObjectWithDefault -Name 'InnerException' -Value $null
      }

      return "ErrorRecord:$($_ | Format-List * -Force | Out-String -Width $Width)" +
        "ErrorRecord.InvocationInfo: " +
        "$($_.InvocationInfo | Format-List * | Out-String -Width $Width)" +
        "Exception: $formattedEx"
    }

    $lastException = @()
    while ($ex -ne $null)
    {
      $lastMessage = $ex | Select-ObjectWithDefault -Name 'Message' -Value ''
      $lastException += ($lastMessage -replace "`n", '')
      if ($ex -is [Data.SqlClient.SqlException])
      {
        $lastException += "(Line [$($ex.LineNumber)] " +
          "Procedure [$($ex.Procedure)] Class [$($ex.Class)] " +
          " Number [$($ex.Number)] State [$($ex.State)] )"
      }
      $ex = $ex | Select-ObjectWithDefault -Name 'InnerException' -Value $null
    }
    $shortException = $lastException -join ' --> '

    $header = $null
    $current = $_
    $header = (($current.InvocationInfo |
      Select-ObjectWithDefault -Name 'PositionMessage' -Value '') -replace "`n", ' '),
      ($current | Select-ObjectWithDefault -Name 'Message' -Value ''),
      ($current | Select-ObjectWithDefault -Name 'Exception' -Value '') |
        ? { -not [String]::IsNullOrEmpty($_) } |
        Select -First 1

    $delimiter = ''
    if ((-not [String]::IsNullOrEmpty($header)) -and
      (-not [String]::IsNullOrEmpty($shortException)))
      { $delimiter = ' [<<==>>] ' }

    '[ERROR] : ' + $header + $delimiter + $shortException
  }
}

function Get-CredentialPlain
{
  <#
  .Synopsis
    Short-hand for generating PsCredential objects with a plaintext
    password and Get-Credential
  .Description
    Just a more readable shortcut cmdlet.
  .Parameter UserName
    Plaintext username
  .Parameter Password
    Plaintext password
  .Example
    $creds = Get-CredentialPlain 'John' 'password'

    Description
    -----------
    Returns a PowerShell PsCredential to use in remoting /other scenarios
  #>
  [CmdletBinding()]
  param([string]$UserName, [string]$Password)

  New-Object System.Management.Automation.PsCredential($UserName, `
    (ConvertTo-SecureString $Password -AsPlainText -force))
}

function Test-TranscriptionSupported
{
  <#
  .Synopsis
    Tests to see if the current host supports transcription.
  .Description
    Powershell.exe supports transcription, WinRM and ISE do not.
  .Example
    #inside powershell.exe
    Test-Transcription
    #returns true

    Description
    -----------
    Returns a $true if the host supports transcription; $false otherwise
  #>
  #($Host.Name -eq 'ServerRemoteHost')
  $externalHost = $host.gettype().getproperty("ExternalHost",
    [reflection.bindingflags]"NonPublic,Instance").getvalue($host, @())

  try
  {
    [Void]$externalHost.gettype().getproperty("IsTranscribing",
    [Reflection.BindingFlags]"NonPublic,Instance").getvalue($externalHost, @())
    $true
  }
  catch
  {
    $false
  }
}

function Test-Transcribing
{
  <#
  .Synopsis
    Tests to see if the current host is transcribing.
  .Description
    Powershell.exe supports transcription, WinRM and ISE do not.
  .Example
    #inside powershell.exe
    Test-Transcribing
    #returns false (unless a previous call was made to Start-Transcription)

    Description
    -----------
    Returns a $true if the host is transcribing; $false otherwise
  #>
  #($Host.Name -eq 'ServerRemoteHost')
  $externalHost = $host.gettype().getproperty("ExternalHost",
    [reflection.bindingflags]"NonPublic,Instance").getvalue($host, @())

  try
  {
    $externalHost.gettype().getproperty("IsTranscribing",
    [Reflection.BindingFlags]"NonPublic,Instance").getvalue($externalHost, @())
  }
  catch
  {
    $false
  }
}

function Start-TempFileTranscriptSafe
{
  <#
  .Synopsis
    Starts transcribing the current session to a temporary file, if
    the host supports it.  Returns info about the log file created.
  .Description
    Performs a check to see if the host supports transcription.  If it
    does, a new temporary file is created, and transcription is started.

    Returns a hash with two keys:
    Started - $true if transcription was possible, $false otherwise
    LogFile - the location on disk, if transcription was possible, null
    otherwise
  .Parameter ClearErrors
    If set to true, this will clear the $global:Error collection after
    starting transcription.

    Default is true
  .Example
    $logFile = (Start-TempFileTranscriptSafe).LogFile

    Stores the LogFile path in a local $logFile variable
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false)]
    [Switch]
    $ClearErrors = $true
  )

  $IsTranscriptionSupported = Test-TranscriptionSupported
  $LogFile = $null

  if ($IsTranscriptionSupported)
  {
    $LogFile = [IO.Path]::GetTempFileName()

    Stop-TranscriptSafe
    Start-Transcript -Path $LogFile -Append | Write-Host
  }

  if ($ClearErrors) { $global:Error.Clear() }

  @{ Started = $IsTranscriptionSupported; LogFile = $LogFile }
}


Export-ModuleMember -Function Stop-TranscriptSafe, Select-ObjectWithDefault,
  Resolve-Error, Get-CredentialPlain, Test-TranscriptionSupported,
  Test-Transcribing, Remove-Error, Start-TempFileTranscriptSafe,
  Get-TimeSpanFormatted, Get-SimpleErrorRecord, Compare-Hash