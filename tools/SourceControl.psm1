function Get-BranchName
{
<#
.Synopsis
  Will return the current branch name if the current directory is a Git
  or Mercurial repository.

  Returns null otherwise.
.Description
  For Git, uses rev-parse command, and for Mercurial uses the branch
  command.
.Example
  Get-BranchName

  Description
  -----------
  Will execute against the local directory, returning the branch name if
  there is one.  Returns null otherwise.
#>

  $branch = git rev-parse --symbolic-full-name --abbrev-ref HEAD 2> $null
  if (!$branch)
  {
    $branch = hg branch 2> $null
  }

  return $branch
}

Export-ModuleMember -Function Get-BranchName
