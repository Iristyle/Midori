function Add-AnnotatedContent
{
  <#
  .Synopsis
    Concatenates files from a given folder into another file, annotating the
    source folder and filenames in C# / SQL compatible comments.
  .Description
    Will accept a folder or list of folder via the pipeline.  Always appends
    to an existing file should it exist.
  .Parameter Path
    Complete folder path for a set of files.  All files are read.
  .Parameter Destination
    The actual file to contactenate results to.
  .Parameter Encoding
    Optional parameter that specifies the Encoding to use for files.
    Default is UTF8.  Other options are Unicode, UTF7, UTF32, ASCII, Default,
    OEM and BigEndianUnicode.
  .Example
    Add-AnnotatedContent -Path c:\test -Destination c:\bar\test.txt

    Description
    -----------
    Finds all files in c:\test, and concatenates them to c:\bar\test.txt, 
    adding annotations for each directory and each file into the resulting
    file.  Uses default encoding of UTF8.
  .Example
    'c:\foo', 'c:\bar' | Add-AnnotatedContent -Destination c:\baz.txt

    Description
    -----------
    Finds all files in c:\foo and c:\bar, and concatenates them to 
    c:\baz.txt, adding annotations for each directory and each file into the
    resulting file.  Uses default encoding of UTF8.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
    [string]
    [ValidateScript({ (Test-Path $_) -and (Get-Item $_).PSIsContainer })]
    $Path,

    [Parameter(Mandatory=$true)]
    [string]
    $Destination,

    [Parameter(Mandatory=$false)]
    [string]
    [ValidateSet('Unicode', 'UTF7', 'UTF8', 'UTF32', 'ASCII',
      'BigEndianUnicode', 'Default', 'OEM')]
    $Encoding = 'UTF8'
  )
  process
  {
@"
/**************************************************
* Folder: $_
***************************************************/

"@ | Out-File $Destination -Append -Encoding $Encoding

    $files = @()
    Get-ChildItem $_ -Recurse |
      % {
        $files += $_.Name
@"
--File Name: $($_.Name)

$([System.IO.File]::ReadAllText($_.FullName))

"@ | Out-File $Destination -Append -Encoding $Encoding
      }

    "Added files $($files -join ' ') from $_ to $Destination" 
  }
}

Export-ModuleMember -Function Add-AnnotatedContent