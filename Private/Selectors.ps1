function ConvertTo-SlotFilter {
    <#
    .SYNOPSIS
      Parse an lspci-style -s selector into its numeric fields.
    .DESCRIPTION
      lspci's grammar is [[[[<domain>]:]<bus>]:][<device>][.[<func>]]. Every
      field is optional and unspecified fields match anything, so:

          -s 01:        bus 01
          -s 01:00.0    bus 01, device 00, function 0
          -s 1          device 01 on ANY bus        (not bus 01)
          -s .0         function 0 of everything
          -s :00.0      device 00 function 0 on any bus
          -s 0000:01:   domain 0000, bus 01

      An earlier version compared padded strings with StartsWith, which made
      the last four silently match nothing or the wrong thing -- a filter that
      returns an empty list when the device is right there is the worst answer
      a diagnostic tool can give. Fields are therefore parsed to numbers and
      compared field-by-field, and anything that is not hex is rejected with
      one clear error rather than a .NET exception per device.

      Returns $null for an empty selector (match everything), otherwise an
      object with Domain/Bus/Device/Function, each $null when unspecified.
    #>
    param([string]$Slot)
    if (-not $Slot -or -not $Slot.Trim()) { return $null }

    $bad = "invalid slot filter '$Slot': expected [[<domain>]:]<bus>:]<device>[.<function>] in hex, e.g. 01:00.0, 1:, .0"
    $s = $Slot.Trim().ToLower()

    $func = $null
    $dot = $s.IndexOf('.')
    if ($dot -ge 0) {
        $f = $s.Substring($dot + 1)
        $s = $s.Substring(0, $dot)
        if ($f -ne '') {
            if ($f -notmatch '^[0-7]$') { throw $bad }
            $func = [int]$f
        }
    }

    $parts = $s.Split(':')
    if ($parts.Length -gt 3) { throw $bad }

    $domain = $null; $bus = $null; $device = $null
    $devText = $parts[$parts.Length - 1]
    $busText = $null
    $domText = $null
    if ($parts.Length -ge 2) { $busText = $parts[$parts.Length - 2] }
    if ($parts.Length -eq 3) { $domText = $parts[0] }

    if ($domText) {
        if ($domText -notmatch '^[0-9a-f]{1,4}$') { throw $bad }
        $domain = [Convert]::ToInt32($domText, 16)
    }
    if ($busText) {
        if ($busText -notmatch '^[0-9a-f]{1,2}$') { throw $bad }
        $bus = [Convert]::ToInt32($busText, 16)
    }
    if ($devText) {
        if ($devText -notmatch '^[0-9a-f]{1,2}$') { throw $bad }
        $device = [Convert]::ToInt32($devText, 16)
        if ($device -gt 0x1f) { throw $bad }
    }

    return [pscustomobject]@{ Domain = $domain; Bus = $bus; Device = $device; Function = $func }
}


function Test-SlotMatch {
    <#
    .SYNOPSIS
      Does a device's bus:device.function satisfy a parsed -s filter?
    .DESCRIPTION
      The slot is "[dddd:]bb:dd.f"; a missing domain is 0. An unspecified
      filter field matches anything, so `-s 00:02.0` finds the device in every
      domain and `-s 556f:00:02.0` only in that one -- as lspci.
    #>
    param([string]$Bdf, $Filter)
    if ($null -eq $Filter) { return $true }
    if ($Bdf -notmatch '^(?:([0-9a-f]{4}):)?([0-9a-f]{2}):([0-9a-f]{2})\.(\d)$') { return $false }
    $domain = 0
    if ($Matches[1]) { $domain = [Convert]::ToInt32($Matches[1], 16) }
    $bus = [Convert]::ToInt32($Matches[2], 16)
    $dev = [Convert]::ToInt32($Matches[3], 16)
    $fun = [int]$Matches[4]
    if ($null -ne $Filter.Domain -and $Filter.Domain -ne $domain) { return $false }
    if ($null -ne $Filter.Bus -and $Filter.Bus -ne $bus) { return $false }
    if ($null -ne $Filter.Device -and $Filter.Device -ne $dev) { return $false }
    if ($null -ne $Filter.Function -and $Filter.Function -ne $fun) { return $false }
    return $true
}


function ConvertTo-DeviceFilter {
    <#
    .SYNOPSIS
      Parse an lspci-style -d selector: [<vendor>]:[<device>][:<class>].
    .DESCRIPTION
      Vendor and device are hex NUMBERS, compared for equality as lspci does:
      `-d 80:` means vendor 0x0080, not "vendors starting with 80". An earlier
      version used a wildcard prefix, so `-d 8:` quietly returned every Intel
      device and `-d '*:'` returned the machine. Class keeps prefix semantics
      (`::01` is every mass-storage class), because that is how the README has
      always documented it and it is the useful reading.

      Anything that is not hex is rejected with one clear error.
    #>
    param([string]$Device)
    $filter = @{ Vendor = ''; Device = ''; Class = '' }
    if (-not $Device -or -not $Device.Trim()) { return $filter }

    $bad = "invalid device filter '$Device': expected [<vendor>]:[<device>][:<class>] in hex, e.g. 11f8:, :174a, ::0108"
    $parts = $Device.Trim().Split(':')
    if ($parts.Length -gt 3) { throw $bad }

    $fields = @()
    foreach ($p in $parts) {
        $t = ($p -replace '^0[xX]', '').Trim().ToLower()
        if ($t -ne '' -and $t -notmatch '^[0-9a-f]{1,4}$') { throw $bad }
        $fields += $t
    }
    if ($fields[0]) { $filter.Vendor = '{0:x4}' -f [Convert]::ToInt32($fields[0], 16) }
    if ($fields.Length -ge 2 -and $fields[1]) { $filter.Device = '{0:x4}' -f [Convert]::ToInt32($fields[1], 16) }
    if ($fields.Length -ge 3 -and $fields[2]) { $filter.Class = $fields[2] }
    return $filter
}
