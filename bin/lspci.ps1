<#
.SYNOPSIS
  lspci for Windows. Reads Windows' PnP/PCI enumeration; no kernel driver.

.DESCRIPTION
  Accepts lspci's flags where they map onto data Windows exposes. Flags that
  would require configuration-space reads (-x, -xxx, capability decoding) are
  rejected with an explanation rather than silently ignored -- a tool that
  quietly does less than you asked is worse than one that says it cannot.

.EXAMPLE
  lspci
  lspci -nn
  lspci -d 11f8:
  lspci -vv -d ::0108
  lspci -s 01:00.0 -v
  lspci -Json
#>
[CmdletBinding()]
param(
    [Alias('d')][string]$Device = '',
    [Alias('s')][string]$Slot = '',
    [Alias('v')][switch]$Verbose1,
    [Alias('vv')][switch]$Verbose2,
    [Alias('vvv')][switch]$Verbose3,
    [Alias('t')][switch]$Tree,
    # No 'D' alias: PowerShell matches parameter aliases CASE-INSENSITIVELY,
    # so -D would collide with -d (Device) and the script refuses to load.
    # lspci's -D therefore has to be spelled -Domain here.
    [switch]$Domain,
    [string[]]$Attribute,
    [string]$Match,
    [switch]$PresentOnly,
    [switch]$ListAttributes,
    [switch]$Csv,
    # No '-p' alias: in real lspci, -p names a custom ID file. Reusing it
    # for something unrelated would mislead precisely the Linux users
    # this output format exists for.
    [switch]$Delimited,
    [string]$Delimiter = '|',
    [switch]$Header,
    [Alias('n')][switch]$Numeric,
    [Alias('nn')][switch]$NumericAndNames,
    [Alias('k')][switch]$ShowDriver,
    [switch]$Json,
    [switch]$Downtrained,
    [switch]$Version,
    [Parameter(ValueFromRemainingArguments)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\winlspci.psd1') -Force

if ($Version) {
    $m = Get-Module winlspci
    Write-Output "winlspci $($m.Version)"
    $ids = Join-Path $PSScriptRoot '..\data\pci.ids'
    if (Test-Path $ids) {
        $stamp = (Select-String -Path $ids -Pattern '^#\s+Version:' -List).Line
        Write-Output "pci.ids  $($stamp -replace '^#\s+Version:\s*', '')"
    }
    exit 0
}

# Reject what we cannot honestly do, rather than ignoring it.
if ($Rest) {
    foreach ($arg in $Rest) {
        if ($arg -match '^-x+$') {
            # [Console]::Error, not Write-Error: this script sets
            # $ErrorActionPreference = 'Stop', which makes Write-Error
            # TERMINATING -- the script would die with exit 1 and never reach
            # the `exit 2` below. The message looked right while the exit code
            # was wrong, so a caller could not tell "impossible request" from
            # any other failure.
            [Console]::Error.WriteLine(
                "lspci: cannot dump configuration space ($arg). Windows " +
                "exposes no userland path to PCI config space; that needs a " +
                "signed kernel-mode driver. Everything this tool reports comes " +
                "from the PnP database the PCI bus driver populates."
            )
            exit 2
        }
        Write-Warning "ignoring unrecognised argument: $arg"
    }
}

$verbosity = 0
if ($Verbose1) { $verbosity = 1 }
if ($Verbose2) { $verbosity = 2 }
if ($Verbose3) { $verbosity = 3 }

$numericMode = 0
if ($Numeric) { $numericMode = 1 }
if ($NumericAndNames) { $numericMode = 2 }

# Sorted by slot, as lspci does. Windows enumerates in an order that looks
# arbitrary to a reader scanning for a bus number.
$devices = @(Get-PciDevice -Device $Device -Slot $Slot | Sort-Object Slot)

if ($Downtrained) {
    # The question people actually open lspci to answer.
    $devices = @($devices | Where-Object {
        $_.LinkStateReported -and (
            ($null -ne $_.MaxLinkSpeedRaw -and $_.LinkSpeedRaw -lt $_.MaxLinkSpeedRaw) -or
            ($null -ne $_.MaxLinkWidth -and $_.LinkWidth -lt $_.MaxLinkWidth)
        )
    })
}

if ($Domain) {
    # lspci -D prints the domain. Windows' PnP data carries no PCI segment
    # number, so this is 0000 for every device -- correct on a single-segment
    # machine, and stated rather than silently assumed.
    $devices = @($devices | ForEach-Object {
        $_ | Add-Member -NotePropertyName Slot -NotePropertyValue "0000:$($_.Slot)" -Force -PassThru
    })
}

if ($ListAttributes) {
    Get-PciAttributeName
    exit 0
}

if ($Attribute -or $Match -or $PresentOnly) {
    $args2 = @{}
    if ($Attribute)   { $args2['Attribute'] = $Attribute }
    if ($Match)       { $args2['Match'] = $Match }
    if ($PresentOnly) { $args2['PresentOnly'] = $true }
    $records = @($devices | ConvertTo-PciAttributeRecord @args2)

    if ($Json) {
        $records | ConvertTo-Json -Depth 5
    } elseif ($Csv) {
        $records | ConvertTo-Csv -NoTypeInformation
    } elseif ($Delimited) {
        $records | Format-PciDelimited -Delimiter $Delimiter -Header:$Header
    } else {
        $records | Format-Table -AutoSize
    }
    # An attribute query that matches nothing is a real answer, but it must not
    # be mistaken for success by a script.
    if ($records.Count -eq 0) { exit 1 }
    exit 0
}

if ($Tree) {
    Format-PciTree -Devices $devices -Numeric $numericMode
    if (($Device -or $Slot) -and $devices.Count -eq 0) { exit 1 }
    exit 0
}

if ($Delimited) {
    $devices | Format-PciDelimited -Delimiter $Delimiter -Header:$Header
    if (($Device -or $Slot) -and $devices.Count -eq 0) { exit 1 }
    exit 0
}

if ($Csv) {
    $devices | ConvertTo-Csv -NoTypeInformation
    if (($Device -or $Slot) -and $devices.Count -eq 0) { exit 1 }
    exit 0
}

if ($Json) {
    [pscustomobject]@{
        source  = 'windows-pnp'
        note    = ('Windows PnP/PCI enumeration. No configuration-space access: ' +
                   'no hex dumps, no capability walks, no ASPM or AER detail.')
        filter  = @{ device = $Device; slot = $Slot; downtrained = [bool]$Downtrained }
        count   = $devices.Count
        devices = $devices
    } | ConvertTo-Json -Depth 6
} else {
    if ($devices.Count -eq 0) {
        if ($Device -or $Slot -or $Downtrained) {
            Write-Output 'no matching PCI device'
        } else {
            Write-Output 'no PCI devices enumerated'
        }
    }
    $devices | Format-Lspci -Verbosity $verbosity -Numeric $numericMode
}

# A filter that matches nothing must not look like success -- that is the
# difference between "the card is not there" and "the command worked".
if (($Device -or $Slot) -and $devices.Count -eq 0) { exit 1 }
exit 0
