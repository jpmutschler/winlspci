<#
.SYNOPSIS
  Record this machine's PCI enumeration as a test fixture.

.DESCRIPTION
  Writes a JSON array of entities -- PNPDeviceID, Name, Service, Status,
  ConfigManagerErrorCode, HardwareID -- each with a Bag of every DEVPKEY the
  module asks for. A fixture replays through Get-PciDevice in place of the CIM
  calls (see Set-PciFixture), so the suite can test a machine it does not have.

  Nothing is stripped: a fixture is a faithful recording, and the values are
  not secrets. Review one before committing it from a machine that is not
  yours.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tests\Export-PciFixture.ps1 -Path tests\fixtures\my-box.json
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Path)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'winlspci.psd1') -Force
$m = Get-Module winlspci

$entities = & $m { Get-PciEntity }
$out = foreach ($e in $entities) {
    $bag = & $m { param($x) Get-DevicePropertyBag $x } $e
    # Hashtable -> ordered object so the JSON is stable and diffable.
    $bagObj = [ordered]@{}
    foreach ($k in ($bag.Keys | Sort-Object)) { $bagObj[$k] = $bag[$k] }
    [ordered]@{
        PNPDeviceID            = $e.PNPDeviceID
        Name                   = $e.Name
        Service                = $e.Service
        Status                 = $e.Status
        ConfigManagerErrorCode = $e.ConfigManagerErrorCode
        HardwareID             = @($e.HardwareID)
        Bag                    = $bagObj
    }
}

$json = ConvertTo-Json -InputObject @($out) -Depth 6
# ConvertTo-Json escapes & ' < > as \uXXXX; plain characters diff better.
$json = $json -replace '\\u0026', '&' -replace '\\u0027', "'" -replace '\\u003c', '<' -replace '\\u003e', '>'
$target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
[IO.File]::WriteAllText($target, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "wrote $(@($out).Count) entities to $Path"
