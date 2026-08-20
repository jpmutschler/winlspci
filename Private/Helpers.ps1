function Get-LinkDowntrainReason {
    <#
    .SYNOPSIS
      Which of speed / width is below its maximum, as a list of words.
    .DESCRIPTION
      The single most useful thing this tool can point at, so the comparison
      lives in ONE place. Every operand is null-guarded: PowerShell coerces
      $null to 0 in `-lt`, so an unguarded `$null -lt 4` once reported a
      device with no link width at all as DOWNTRAINED (width) -- a fault that
      did not exist, from the tool whose job is to not invent faults.
    #>
    param($SpeedRaw, $MaxSpeedRaw, $Width, $MaxWidth)
    $reasons = @()
    if ($null -ne $SpeedRaw -and $null -ne $MaxSpeedRaw -and [int]$SpeedRaw -lt [int]$MaxSpeedRaw) {
        $reasons += 'speed'
    }
    if ($null -ne $Width -and $null -ne $MaxWidth -and [int]$Width -lt [int]$MaxWidth) {
        $reasons += 'width'
    }
    return ,$reasons
}


function ConvertTo-SafeText {
    <#
    .SYNOPSIS
      Fold control characters (including ESC) to spaces before a string
      reaches the console.
    .DESCRIPTION
      FriendlyName comes from driver INF files and vendor/device names from
      pci.ids, which Update-PciIds downloads; neither is under our control, and
      Windows Terminal processes VT sequences by default, so an ESC-bearing
      name could clear and rewrite the line it is printed on. Text form only;
      the object model keeps the raw value.
    #>
    param($Value)
    if ($null -eq $Value) { return $null }
    return ("$Value" -replace '[\x00-\x1f\x7f]', ' ')
}


function Get-Field {
    <#
    .SYNOPSIS
      A property's value, or $null if the object does not carry it.
    .DESCRIPTION
      The module runs under Set-StrictMode 2.0, where reading a property that
      does not exist is a terminating error. The formatters are public and
      take pipeline input, and `Get-PciDevice | Select-Object Slot,DeviceName |
      Format-Lspci` is an idiom people reach for, so a trimmed object must
      render with gaps rather than crash.
    #>
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}
