Midori
======

A set of Powershell modules for sweetening [Psake](https://github.com/psake/psake).

Enhances Psake with some commonly needed functionality when using a build server
such as Jenkins.  Useful not only for any build or continuous delivery system,
but also could be useful in other scenarios where PowerShell scripts are used
for maintenance.


Included Modules
====

* BuildTools - A set of helpers for common build related tasks
    * `Invoke-AuthenticodeSignTool` - Will find signtool.exe based on common locations
    and will exeucte it.
    * `New-ZipFile` - Will create or add to an existing zip file with the given 
    list of files, and can re-root the paths.  Depends on DotNetZip (not included),
    but easy enough to restore with Nuget
* Files
    * `Add-AnnotatedContent` - Concatenates files from a given folder into another file, annotating the source folder and filenames in C# / SQL compatible comments.
* HipChat
    * `Send-HipChatNotification` - Given the current HipChat token, can send
    info to a given chat room, including specifying colors, etc.
* Jenkins
    * `Get-JenkinsS3Build` - Will use a Jenkins job name and either a specific
    integer build id or will use the REST api and a given build result, to 
    download the build assets from S3.  Relies on the S3 plugin being installed
    in Jenkins.
* Powershell-Contrib - A number of miscellaneous PowerShell helpers.
    * `Stop-TranscriptSafe` - Safely stops transcription, even in hosts (such as
    WinRM) that do not support it.  Will not add to the global $Error object.
    * `Select-ObjectWithDefault` - This is similar to a safe navigation operator,
    where an error will not be thrown if a property does not exist on a given
    object.  Furthermore, can return a default value if the prop doesn't exist.
    * `Resolve-Error` - Derived from the Jeffrey Snover [original](http://blogs.msdn.com/b/powershell/archive/2006/12/07/resolve-error.aspx), but
    enhanced in a number of ways.  Provides a one-line summary output (with
    special handling of SqlException), can accept pipeline input, etc.
    * `Get-CredentialPlain` - A wrapper around Get-Credential that works around
    the verbosity of newing up credentials from plain text.
    * `Test-TranscriptionSupported` - A means of checking for transcription
    support in the current host.
    * `Test-Transcribing` - A means of checking to see if the host is currently
    in the process of transcribing.
    * `Remove-Error` - Will clear the last X number of errors from the given 
    $Error object.  By default will clear from $global:Error
    * `Start-TempFileTranscriptSafe` - Will start transcribing the current host if
    it is possible, and will return the temp file name of the transcript file.
    * `Get-TimeSpanFormatted` - A simple .NET 2 safe timespan format of HH:MM:SS
    since TimeSpan.Format is a .NET 4 facility.
    * `Get-SimpleErrorRecord` - Will create a Management.Automation.ErrorRecord
    given just a text string (by creating a dummy Exception)
* PsGet-Loader - Some helpers for [PsGet](http://psget.net/)
    * `Install-PsGet` - Will install PsGet to the current user module directory.
    * `Install-CommunityExtensions` - Will install the [PsCx](http://pscx.codeplex.com/), first ensuring that
    PsGet is installed.
* Remoting - Some WinRM helpers
    * `Export-ModuleToSession` - Will take modules out of the current session and
    try to push them to the remote session.  This has a number of caveats,
    including being able to find the psm1 files on disk -- if the simple
    resolution process fails, this won't work.  Prefer to use 
    Export-SourceModuleToSession.
    * `Export-SourceModuleToSession` - This is the magic I could come up with for
    sharing modules across the wire.  The local module files are copied to the
    remote machine by using a PSSession instance and passing the contents of
    the files as strings.  They are rehydrated on the remote machine, written to
    temp and Import-Module is run against them so they become available to the
    session.  This functionality should be built in to PowerShell, but it's not.
    Only remote sessions can be exported to a local session, but not the other
    way around.
* Sql - Some helpers for working with SQL installs.  This can be useful for
setting up integration tests or similar.
    * `New-SqlDatabase` - Creates a new database using SMO.  By default, SMO v10
    is searched for and imported.  The database can be detached afterwards, to
    ship with the build assets for instance, or the -NoDetach flag can be used
    to keep the database around afterwards.  SMO style text files with the `GO`
    delimiter are perfectly acceptable here.
    * `Invoke-SqlFileSmo`

Future Improvements
===

Next in the pipeline - 

* Fleshing out Pester tests in a few spots where applicable - some things are
quite difficult to test easily since they are dependent on external systems

* [XUnit.NET](http://xunit.codeplex.com/) - Find Xunit assemblies based on .Tests convention and run them
* [NCover](http://www.ncover.com/) - Run Xunit tests under NCover to generate coverage reports
* [NDepend](http://www.ndepend.com/) - Run the popular dependency analysis tool
* [Gendarme](http://www.mono-project.com/Gendarme) - Run the Mono static analysis tool (IMHO, better than FxCop)
* [FxCop](http://www.microsoft.com/en-us/download/details.aspx?id=6544) - Run the Microsoft static analsyis tool

Many of these 'runners' I have combined in a set of MSBuild based scripts, and
they just need to be ported over.  The MSBuild scripts became a bit difficult
to share and unwiedly, hence the port to PSake where they can become more modular
and easier to use / share.

Credits
===

* Of course, [James Kovacs](https://github.com/JamesKovacs) needs a big THANK YOU
for creating a reasonable build system for .NET.  I struggled with bending
MSBuild to my will on numerous occasions, and it often felt like jamming a round
peg in a square hole.. yes, many times you can make MSBuild do stuff you didn't
think was possible, but between the batching design / syntax, the verbose xml-
ification of everything, and the various details around targets and their
outputs, you end up with something that no one else on your team can understand.
Builds have a much better mapping to procedural code, and Psake brings sanity to
the .NET world.
* For the icon, 

Contributions
===

If you see something wrong, 