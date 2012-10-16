#Requires -Version 3

# NTP Times are all UTC and are relative to midnight on 1/1/1900
#http:#stackoverflow.com/questions/1193955/how-to-query-an-ntp-server-using-c
#http://www.codeproject.com/Articles/38276/An-SNTP-Client-for-C-and-VB-NET
$script:Epoch = New-Object DateTime(1900, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)

function OffsetToLocal($Offset)
{
  # Convert milliseconds since midnight on 1/1/1900 to local time
  $script:Epoch.AddMilliseconds($Offset).ToLocalTime()
}

function GetMillisecondsSinceEpoch
{
  ([TimeZoneInfo]::ConvertTimeToUtc((Get-Date)) - $script:Epoch).TotalMilliseconds
}

function GetNtpMilliseconds
{
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [byte[]]
    $Bytes
  )

  # NTP time is number of seconds since the epoch and is split into an integer
  # part (top 32 bits) and fractional part (bottom 32 bits), multipled by 2^32

  # assume that the bytes have been passed exactly as they appear in packet
  # so that reverse ordering flips endian-ness
  $intPart = [BitConverter]::ToUInt32($Bytes[3..0], 0)
  $fracPart = [BitConverter]::ToUInt32($Bytes[7..4], 0)

  return $intPart * 1000 + ($fracPart * 1000 / 0x100000000)
}

function ParseNtpData
{
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [byte[]]
    $NtpData,

    [Parameter(Mandatory=$true)]
    [double]
    $OriginateTimeStamp,

    [Parameter(Mandatory=$true)]
    [double]
    $DestinationTimeStamp
  )

  # Parse (64-bit) 'Transmit Timsestamp' - time response packet left server
  # Note we don't send 'Originate Timestamp' (t1) so this will be 0 in response
  $TransmitTimestamp = GetNtpMilliseconds $NtpData[40..47]

  # Parse (64-bit) 'Receive Timsestamp' - time request packet arrived at server
  $ReceiveTimeStamp = GetNtpMilliseconds $NtpData[32..39]

  # This is the difference between the server clock and the local clock taking
  # into account the network latency.  If both server and client clocks have the
  # same absolute time then clock difference minus network latency will be 0.
  # Adding the offset to the local clock will give the correct time.
  # Assuming symetric send/receive delays, the average of the out and return
  # times will equal the offset.
  #   Offset = (OutTime+ReturnTime)/2
  #   Offset = ((t2 - t1) + (t3 - t4))/2
  $offset = (($ReceiveTimeStamp - $OriginateTimeStamp) +
    ($TransmitTimestamp - $DestinationTimeStamp)) / 2

  # Total transaction time (between t1..t4) minus the server 'processing time'
  #  (between t2..t3) = time spent on network

  # Useful because the most accurate offset values will be obtained from
  # responses with the lowest network delays.
  $delay = ($DestinationTimeStamp - $OriginateTimeStamp) -
    ($TransmitTimestamp - $ReceiveTimeStamp)

  $leapIndicator = ($NtpData[0] -band 0xC0) / 64
  $leapIndicator_text =
  switch ($leapIndicator)
  {
    0 {'no warning'}
    1 {'last minute has 61 seconds'}
    2 {'last minute has 59 seconds'}
    3 {'alarm condition (clock not synchronized)'}
  }

  $mode = ($NtpData[0] -band 0x07)     # Server mode (probably 'server'!)
  $mode_text = Switch ($mode)
  {
    0 {'reserved'}
    1 {'symmetric active'}
    2 {'symmetric passive'}
    3 {'client'}
    4 {'server'}
    5 {'broadcast'}
    6 {'reserved for NTP control message'}
    7 {'reserved for private use'}
  }

  # Actually [UInt8] but we don't have one of those...
  $stratum = [UInt16]$NtpData[1]
  $stratum_text = Switch ($stratum)
  {
    0                           {'unspecified or unavailable'}
    1                           {'primary reference (e.g., radio clock)'}
    {$_ -ge 2 -and $_ -le 15}   {'secondary reference (via NTP or SNTP)'}
    {$_ -ge 16}                 {'reserved'}
  }

  # Poll interval - to neareast power of 2
  $pollInterval = $NtpData[2]
  $pollIntervalSeconds = [Math]::Pow(2, $pollInterval)

  # Precision in seconds to nearest power of 2
  $precisionBits = $NtpData[3]
  # ...this is a signed 8-bit int
  if ($precisionBits -band 0x80)
  {
    # ? negative (top bit set)
    $precision = [int]($precisionBits -bor 0xFFFFFFE0) # Sign extend
  }
  else
  {
    # ..this is unlikely - indicates a precision of less than 1 second
    $precision = [int]$precisionBits   # top bit clear - just use positive value
  }
  $precisionSeconds = [Math]::Pow(2, $precision)

  # Create Output object and return
  $ntpTime = [PSCustomObject]@{
    NtpTime = OffsetToLocal($DestinationTimeStamp + $offset)
    Offset = $offset
    OffsetSeconds = [Math]::Round($offset / 1000, 2)
    Delay = $delay
    t1ms = $OriginateTimeStamp
    t2ms = $ReceiveTimeStamp
    t3ms = $TransmitTimestamp
    t4ms = $DestinationTimeStamp
    t1 = OffsetToLocal($OriginateTimeStamp)
    t2 = OffsetToLocal($ReceiveTimeStamp)
    t3 = OffsetToLocal($TransmitTimestamp)
    t4 = OffsetToLocal($DestinationTimeStamp)
    LI = $leapIndicator
    LI_text = $leapIndicator_text
    NtpVersionNumber = ($NtpData[0] -band 0x38) / 8
    Mode = $mode
    Mode_text = $mode_text
    Stratum = $stratum
    Stratum_text = $stratum_text
    PollIntervalRaw = $pollInterval
    PollInterval = New-Object TimeSpan(0, 0, $pollIntervalSeconds)
    Precision = $precision
    PrecisionSeconds = $precisionSeconds
    Raw = $NtpData
  }

  $defaultProperties = 'NtpTime', 'OffsetSeconds', 'NtpVersionNumber',
    'Mode_text', 'Stratum', 'PollInterval', 'PrecisionSeconds'

  # Attach default display property set and output object
  $params = @{
    MemberType = 'MemberSet';
    Name = 'PSStandardMembers';
    Value = [Management.Automation.PSMemberInfo[]] `
      (New-Object Management.Automation.PSPropertySet(
      'DefaultDisplayPropertySet', [string[]]$defaultProperties));
    PassThru = $true;
  }
  return $ntpTime | Add-Member @params
}

function Get-NetworkTime
{
<#
.Synopsis
  Gets (Simple) Network Time Protocol time (SNTP/NTP, rfc-1305, rfc-2030) from
  a specified NTP server.

  Original code heavily modified from
  Chris Warwick, @cjwarwickps, August 2012
  chrisjwarwick.wordpress.com
  http://chrisjwarwick.wordpress.com/2012/09/16/getting-sntp-network-time-with-powershell-improved/
.Description
  Cconnects to an NTP server on UDP port 123 and retrieves the current NTP time.

  Selected components of the returned time information are decoded and returned
  in a PSObject.

  This uses NTP RFC-1305: http://www.faqs.org/rfcs/rfc1305.html
  Because only a single call is made to a single server this is strictly a SNTP
  client RFC-2030: http://www.faqs.org/rfcs/rfc2030.html

  The SNTP protocol data is similar (and can be identical) and the clients and
  servers are often unable to distinguish the difference.  Where SNTP differs is
  that is does not accumulate historical data for statistical
  averaging and does not retain a session between client and server.

  An alternative to NTP or SNTP is to use Daytime (rfc-867) on TCP port 13 -
  although this is an old protocol and is not supported by all NTP servers.

  This approach is more accurate than Daytime as it takes network delays into
  account, but the result is only ever based on a single sample. Depending on
  the source server and network conditions the actual returned time may not be
  as accurate as required.
.Parameter Server
  The NTP Server to contact.

  Uses pool.ntp.org by default.

  Other options that could be specified:

  time-a.nist.gov 129.6.15.28 NIST, Gaithersburg, Maryland
  time-b.nist.gov 129.6.15.29 NIST, Gaithersburg, Maryland
  time-a.timefreq.bldrdoc.gov 132.163.4.101 NIST, Boulder, Colorado
  time-b.timefreq.bldrdoc.gov 132.163.4.102 NIST, Boulder, Colorado
  time-c.timefreq.bldrdoc.gov 132.163.4.103 NIST, Boulder, Colorado
  utcnist.colorado.edu  128.138.140.44  University of Colorado, Boulder
  time.nist.gov 192.43.244.18 NCAR, Boulder, Colorado
  time-nw.nist.gov  131.107.1.10  Microsoft, Redmond, Washington
  nist1.datum.com 209.0.72.7  Datum, San Jose, California
  nist1.dc.certifiedtime.com  216.200.93.8  Abovnet, Virginia
  nist1.nyc.certifiedtime.com 208.184.49.9  Abovnet, New York City
  nist1.sjc.certifiedtime.com 208.185.146.41  Abovnet, San Jose, California
.Parameter MaxOffset
  Throw if the network time offset is larger than this number of ms.
.Example
  Get-NetworkTime time.windows.com

  Gets time from the specified server.
.Example
  Get-NetworkTime | Format-List *

  Get time from default server (pool.ntp.org) and displays all output object
  attributes.
.Example
  Get-NetworkTime -MaxOffSet ([TimeSpan]::FromSeconds(15))

  Get time from default server (pool.ntp.org), and will throw if the time server
  returns a valid outside the given maximum allowed offset.
.Outputs
  A PSObject containing decoded values from the NTP server.  Pipe to Format-List
  * to see all attributes.
.Functionality
  Gets NTP time from a specified server.
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false)]
    [string]
    $Server = 'pool.ntp.org',

    [Parameter(Mandatory=$false)]
    [TimeSpan]
    $MaxOffset
  )

  $ntpData = New-Object byte[] 48
  # NTP Request header in first byte
  # [00=No Leap Warning; 011=Version 3; 011=Client Mode]; 00011011 = 0x1B
  $ntpData[0] = 0x1B

  try
  {
    $addresses = [Net.Dns]::GetHostEntry($Server).AddressList
    $ipEndPoint = New-Object Net.IPEndPoint($addresses[0], 123) #NTP port 123

    $socket = New-Object Net.Sockets.Socket(
      [Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Dgram,
      [Net.Sockets.ProtocolType]::Udp)

    $socket.Connect($ipEndPoint)

    # Start of transaction in local time - 'Originate Timestamp'
    $originateTimeStamp = GetMillisecondsSinceEpoch

    [Void]$socket.Send($ntpData)
    [Void]$socket.Receive($ntpData)
  }
  finally
  {
    if ($socket -ne $null) { $socket.Close() }
    #End of transaction in local time
    $destinationTimeStamp = GetMillisecondsSinceEpoch
  }

  $parsed = ParseNtpData $ntpData $originateTimeStamp $destinationTimeStamp

  if ($parsed.LeapIndicator -eq 3)
    { throw 'Alarm condition from server (clock not synchronized)' }

  if ($PsBoundParameters.MaxOffset -and `
    ([Math]::Abs($parsed.Offset) -gt ($MaxOffset.TotalMilliseconds)))
  {
    throw ("Network time offset exceeds maximum allowed - ($($MaxOffset)) " +
      "actual - $([TimeSpan]::FromMilliseconds($parsed.Offset))")
  }

  return $parsed
}

Export-ModuleMember -Function Get-NetworkTime
