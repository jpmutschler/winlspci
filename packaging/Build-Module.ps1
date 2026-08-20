<#
.SYNOPSIS
  Build a release copy of the module with ONE concatenated winlspci.psm1.

.DESCRIPTION
  The source tree keeps Public\ and Private\ as separate files because that
  is a better layout to work in. Importing them costs ~13ms per dot-sourced
  file -- ~160ms per invocation for the 12 files, paid by every `lspci` run
  and every test child. Measured: import 378ms from 12 files, 217ms from one.

  This writes <OutputDirectory>\winlspci\ containing the manifest, a single
  psm1 (the loader's prologue, then every Private\ and Public\ file in the
  same order the loader dot-sources them, then the same Export-ModuleMember),
  bin\, data\, LICENSE, README and CHANGELOG. Behaviour is identical; the
  test suite can be pointed at the built copy to prove it.

.EXAMPLE
  .\packaging\Build-Module.ps1 -OutputDirectory .\dist
  Import-Module .\dist\winlspci\winlspci.psd1
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)) 'winlspci'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out | Out-Null

$loader = [IO.File]::ReadAllText((Join-Path $root 'winlspci.psm1'))
# Prologue: everything before the dot-sourcing loop. Epilogue: Export-ModuleMember on.
$loopStart = $loader.IndexOf('foreach ($dir in')
$exportStart = $loader.IndexOf('Export-ModuleMember')
if ($loopStart -lt 0 -or $exportStart -lt 0) { throw 'Build-Module: winlspci.psm1 does not have the expected loader shape' }
$prologue = $loader.Substring(0, $loopStart)
$epilogue = $loader.Substring($exportStart)

$parts = @($prologue.TrimEnd(), '', '# ---- concatenated from Private\ and Public\ by packaging\Build-Module.ps1 ----', '')
foreach ($dir in 'Private', 'Public') {
    foreach ($file in (Get-ChildItem -Path (Join-Path $root $dir) -Filter '*.ps1' | Sort-Object Name)) {
        $parts += "# ---- $dir\$($file.Name) ----"
        $parts += [IO.File]::ReadAllText($file.FullName).TrimEnd()
        $parts += ''
    }
}
$parts += $epilogue.TrimEnd()
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $out 'winlspci.psm1'), (($parts -join "`n") + "`n"), $enc)

foreach ($item in 'winlspci.psd1', 'LICENSE', 'README.md', 'CHANGELOG.md') {
    Copy-Item (Join-Path $root $item) $out
}
foreach ($dir in 'bin', 'data') {
    Copy-Item (Join-Path $root $dir) (Join-Path $out $dir) -Recurse
}
# The .bak an Update-PciIds may have left is not part of a release.
Remove-Item (Join-Path $out 'data\pci.ids.bak') -ErrorAction SilentlyContinue

$built = Get-Item (Join-Path $out 'winlspci.psm1')
Write-Host "built $out ($([int]($built.Length / 1KB)) KB psm1); verify with: Import-Module $out\winlspci.psd1; Get-Command -Module winlspci"
