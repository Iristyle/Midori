function Get-CurrentDirectory
{
  $thisName = $MyInvocation.MyCommand.Name
  [IO.Path]::GetDirectoryName((Get-Content function:$thisName).File)
}

Import-Module (Join-Path (Get-CurrentDirectory) 'Powershell-Contrib.psm1')

Describe "Stop-TranscriptSafe" {
  It "does not add to errors collection" {
    $errorCount = $Error.Count
    Stop-TranscriptSafe
    $Error.Count.should.be($errorCount)
  }
}

Describe "Select-ObjectWithDefault" {
  It "selects already defined object values" {
    $output = @{ Bar = 'baz' } |
      Select-ObjectWithDefault -Name 'Count' -Value 'Foo'
      $output.should.be(1)
  }

  It "selects hash key values" {
    $output = @{ Bar = 'baz' } | 
      Select-ObjectWithDefault -Name 'Bar' -Value 'ABC'
    $output.should.be('baz')
  }

  It "uses default values when property does not exist" {
    $output = @{ Bar = 'baz'; } |
      Select-ObjectWithDefault -Name 'Genie' -Value 'Bottle'
    $output.should.be('Bottle')
  }

  It "selects null values without causing errors" {
    $output = @{ Bar = $null } |
      Select-ObjectWithDefault -Name 'Bar' -Value 'String'
    if ($output -ne $null)
    {
      throw New-Object PesterFailure("should not exist")
    }
  }
}

Describe "Resolve-Error" {
  It "should not generate function output" {
    $Error.Clear()
    try { throw "Faux Error" }
    catch {}

    $msg = $Error | Resolve-Error

    if ($msg -ne $null)
    {
      throw New-Object PesterFailure("should not exist as function output")
    }
  }
}

Describe "Get-CredentialPlain" {
  It "returns a credential object with given username and plaintext password" {
    $cred = Get-CredentialPlain -UserName bob -Password secret
    $cred.UserName.should.be('bob')

    $password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
      [Runtime.InteropServices.Marshal]::SecureStringToBSTR(($cred.Password)))
    $password.should.be('secret')
  }
}

Describe "Test-TranscriptionSupported" {
  It "verifies transcription support in standard Powershell host" {
    (Test-TranscriptionSupported).should.be($true)
  }
}

Describe "Test-Transcribing" {
  It "verifies that pester is transcribing" {
    (Test-Transcribing).should.be($true)
  }
}