$script:typesLoaded = $false
function Load-Types
{
  if ($script:typesLoaded) { return }

  Add-Type -AssemblyName System.Web

  $script:typesLoaded = $true
}

function Get-S3Url
{
  param
  (
    [string] $Server,
    [string] $BucketPath,
    [string] $AccessKey,
    [string] $SecretKey,
    [DateTime] $ExpireDate
  )

  Load-Types

  $s3BaseTime = [DateTime]::Parse("1970-01-01T00:00:00.0000000Z")
  $expires = [Convert]::ToInt32($ExpireDate.Subtract($s3BaseTime).TotalSeconds).ToString()
  $encodedBucketPath = [Web.HttpUtility]::UrlEncode($BucketPath) -replace '%2f', '/'
  $stringToSign = "GET`n`n`n$expires`n$encodedBucketPath"

  $sha = New-Object Security.Cryptography.HMACSHA1
  $sha.Key = [Text.Encoding]::UTF8.Getbytes($SecretKey)
  $seedBytes = [Text.Encoding]::UTF8.GetBytes($stringToSign)
  $digest = $sha.ComputeHash($seedBytes)
  $base64Encoded = [Convert]::ToBase64String($digest)
  $urlEncoded = [Web.HttpUtility]::UrlEncode($base64Encoded)

  "$Server$encodedBucketPath" + `
    "?AWSAccessKeyId=$AccessKey&Expires=$expires&Signature=$urlEncoded"
}

function Get-LatestBuildId
{
  param
  (
    [Parameter(Mandatory=$true)]
    [string]
    $Job,

    [Parameter(Mandatory=$false)]
    [ValidateSet('lastBuild','lastCompletedBuild','lastFailedBuild', `
      'lastStableBuild', 'lastSuccessfulBuild','lastUnstableBuild', `
      'lastUnsuccessfulBuild')]
    [string]
    $JobResult = 'lastStableBuild',

    [Parameter(Mandatory=$true)]
    [string]
    $BuildServerUrl,

    [Parameter(Mandatory=$true)]
    [string]
    $UserName,

    [Parameter(Mandatory=$true)]
    [string]
    $Password
  )

  $creds = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("$UserName`:$Password"))
  $client = New-Object Net.WebClient
  $client.Headers.Add('Authorization', "Basic $creds")
  $id = $client.DownloadString("$buildServerUrl/job/$Job/$JobResult/buildNumber")
  if (-not $Id) { throw 'Could not resolve id for this job type'}

  Write-Host -ForeGroundColor Magenta `
    "Found latest build ID: $id of type $JobResult for $Job"
  $id
}

function Get-JenkinsS3Build
{
<#
.Synopsis
  Will download a given build from the build server, by accepting
  a job name and either a specific id or type of build.  The name and
  type will be used to lookup a given id, and that will then be used to
  generate an S3 download.
.Description
  This function uses standard Jenkins S3 plugin conventions and a few
  environment configuration details to contact Jenkins, and get the
  correct binaries for either a specific job id or for the last job of a
  given result type.

  The generated S3 url is given a valid time window of 15 minutes.  This
  url generation will fail if the system clock is in any way skewed.
  WebClient automatically sets the outgoing HTTP date header, so ensure
  your system is set correctly.

  If a file has already been downloaded to the temp directory, it will
  not be downloaded again.

  Note that this cmdlet does not perform temp directory cleanup at this
  time.
.Parameter BuildServerUrl
  A url such as https://build.server.com - should be prefixed with http
  or https as appropriate
.Parameter BuildServerUser
  The user credentials used to query the Jenkins REST API
.Parameter BuildServerPassword
  The user password used to query the Jenkins REST API
.Parameter Job
  The name of the job in Jenkins to download.
.Parameter JobResult
  The Jenkins result of the job - may be 'lastBuild','lastCompletedBuild'
  'lastFailedBuild', 'lastStableBuild', 'lastSuccessfulBuild',
  'lastUnstableBuild' or 'lastUnsuccessfulBuild'.

  Default is lastStableBuild.
.Parameter Id
  A numerical id of for a job if not using the Jenkins job result type.
.Parameter BucketName
  The S3 bucket to look in for the Jenkins Jobs
.Parameter AccessKey
  This should be an AWS IAM user token for a limited user.  The user
  should be granted access to just this one S3 bucket.
.Parameter SecretKey
  This is effectively the AWS IAM password for the given token.
.Example
  Get-Build -Job 'Foo' -BuildServerUrl http://www.mybuildserver.com
    -BuildServerUser build -BuildServerPassword pass
    -BucketName buildBucket -AccessKey ABCDEFGHIJK -SecretKey AWSSecret
    -JobResult 'lastCompletedBuild'

  Description
  -----------
  Will download the S3 binaries based on the jenkins-Foo-XXXX.zip
  convention based on the given parameters.  XXXX will be determined by
  querying Jenkins REST API for the last id with status lastCompleteBuild
.Example
  Get-Build -Job 'Foo' -BuildServerUrl http://www.mybuildserver.com
    -Id 1234 -BuildServerUser build -BuildServerPassword pass
    -BucketName buildBucket -AccessKey ABCDEFGHIJK -SecretKey AWSSecret
    -JobResult 'lastCompletedBuild'


  Description
  -----------
  Will download the S3 binaries based on the jenkins-Foo-1234.zip
  convention based on the given parameters.
#>
  [CmdletBinding(DefaultParametersetName='type')]
  param
  (
    [Parameter(Mandatory=$true)]
    [string]
    $BuildServerUrl,

    [Parameter(Mandatory=$true)]
    [string]
    $BuildServerUser,

    [Parameter(Mandatory=$true)]
    [string]
    $BuildServerPassword,

    [Parameter(Mandatory=$true)]
    [string]
    $Job,

    [Parameter(ParameterSetName='type', Mandatory=$false)]
    [ValidateSet('lastBuild','lastCompletedBuild','lastFailedBuild', `
      'lastStableBuild', 'lastSuccessfulBuild','lastUnstableBuild', `
      'lastUnsuccessfulBuild')]
    [string]
    $JobResult = 'lastStableBuild',

    [Parameter(ParameterSetName='id', Mandatory=$true)]
    [int]
    $Id,

    [Parameter(Mandatory=$true)]
    [string]
    $BucketName,

    [Parameter(Mandatory=$true)]
    [string]
    $AccessKey,

    [Parameter(Mandatory=$true)]
    [string]
    $SecretKey
  )

  if ($PsCmdlet.ParameterSetName -eq 'type')
  {
    $buildIdParams = @{
      Job = $Job;
      JobResult = $JobResult;
      BuildServerUrl =  $BuildServerUrl;
      UserName = $BuildServerUser;
      Password = $BuildServerPassword;
    }
    Write-Host "Querying Jenkins for $JobResult id of $Job"
    $Id = Get-LatestBuildId @buildIdParams
  }

  $fileName = "jenkins-$Job-$Id.zip"
  $filePath = Join-Path $env:temp $fileName
  if (Test-Path $filePath)
  {
    Write-Verbose '### File already downloaded ###'
  }
  else
  {
    $params = @{
      Server = "https://s3.amazonaws.com"
      BucketPath = "/$BucketName/$fileName"
      AccessKey = $AccessKey
      SecretKey = $SecretKey
      ExpireDate = [DateTime]::Now.AddMinutes(15)
    }

    $url = Get-S3Url @params

    Write-Host -ForeGroundColor Magenta `
      "Downloading build binaries from $url to $filePath"
    (New-Object Net.WebClient).DownloadFile($url, $filePath)
  }

  $filePath
}

Export-ModuleMember -Function Get-JenkinsS3Build