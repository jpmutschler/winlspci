<#
    winlspci -- lspci for Windows, without a kernel driver.

    Windows has no lspci, and there is no userland path to PCI configuration
    space, so a faithful port is impossible without a signed kernel-mode
    driver. This reads Windows' own PnP/PCI enumeration instead, which the PCI
    bus driver populates from config space at enumeration time.

    That trade is worth stating plainly, because it decides what this tool can
    be trusted for:

      CAN report   presence, vendor/device/subsystem IDs, class codes, BDF,
                   revision, driver + version, negotiated AND maximum link
                   speed/width, MPS, MRRS, AER presence, NUMA node, topology.

      CANNOT report anything requiring live config-space reads: `lspci -x` hex
                   dumps, capability structure walks, ASPM state, AER register
                   detail, or per-capability decoding.

    Requires Windows PowerShell 5.1 or later. Written to 5.1 syntax
    deliberately -- no ternary, no null-coalescing, no -AsHashtable -- because
    5.1 is what ships with Windows and a portable tool should not require an
    install before it can tell you what is in the machine.
#>

Set-StrictMode -Version 2.0

$script:PciIdsPath = Join-Path $PSScriptRoot 'data\pci.ids'
$script:VendorNames = $null
$script:DeviceNames = $null
$script:ClassNames = $null

# PCIe link speed is reported as an enum, not GT/s. Getting this mapping wrong
# would be an easy, invisible error, so it is spelled out rather than computed.
$script:LinkSpeed = @{
    1 = '2.5GT/s'; 2 = '5GT/s'; 3 = '8GT/s'
    4 = '16GT/s';  5 = '32GT/s'; 6 = '64GT/s'
}

# MPS/MRRS are encoded as 0..5 => 128..4096 bytes.
$script:PayloadSize = @{ 0 = 128; 1 = 256; 2 = 512; 3 = 1024; 4 = 2048; 5 = 4096 }


function Read-PciIdsFile {
    <#
    .SYNOPSIS
      Parse a pci.ids file into vendor, device and class lookup tables.
    .DESCRIPTION
      Pure function of the file: returns a hashtable with Vendors, Devices and
      Classes. Import-PciIds uses it to populate the session cache, and
      Update-PciIds uses it to prove a downloaded file actually parses before
      the bundled copy is replaced.
    #>
    param([Parameter(Mandatory)][string]$Path)

    # Resolve against the PowerShell location, not the process CWD (they
    # differ in a normal session), and fail in a sentence rather than a
    # MethodInvocationException.
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Read-PciIdsFile: no such file '$Path'"
    }

    $vendors = @{}
    $devices = @{}
    $classes = @{}

    $currentVendor = $null
    $currentClass = $null
    $inClassSection = $false

    foreach ($line in [System.IO.File]::ReadLines($resolved)) {
        if ($line.Length -eq 0 -or $line[0] -eq '#') { continue }

        if ($line[0] -eq 'C' -and $line.Length -gt 2 -and $line[1] -eq ' ') {
            # "C 03  Display controller" begins the device-class section.
            $inClassSection = $true
            $body = $line.Substring(2)
            $sep = $body.IndexOf('  ')
            if ($sep -gt 0) {
                $currentClass = $body.Substring(0, $sep)
                $classes[$currentClass] = $body.Substring($sep + 2)
            }
            continue
        }

        if ($line[0] -ne "`t") {
            $sep = $line.IndexOf('  ')
            if ($sep -gt 0) {
                $currentVendor = $line.Substring(0, $sep)
                $vendors[$currentVendor] = $line.Substring($sep + 2)
                $inClassSection = $false
            }
            continue
        }

        # Single-tab entries are devices (or subclasses inside the C section).
        # Two-tab entries are subsystems, which we do not index -- they would
        # triple the memory for a field almost nobody reads.
        if ($line.Length -gt 1 -and $line[1] -ne "`t") {
            $body = $line.TrimStart("`t")
            $sep = $body.IndexOf('  ')
            if ($sep -le 0) { continue }
            $id = $body.Substring(0, $sep)
            $name = $body.Substring($sep + 2)
            if ($inClassSection) {
                if ($currentClass) { $classes["$currentClass$id"] = $name }
            } elseif ($currentVendor) {
                $devices["$currentVendor/$id"] = $name
            }
        }
    }

    return @{ Vendors = $vendors; Devices = $devices; Classes = $classes }
}


function Import-PciIds {
    <#
    .SYNOPSIS
      Load and index the PCI ID database. Cached for the session.
    .DESCRIPTION
      A full parse of the ~38k-line database takes about 50ms, which is fine
      once per session but not once per device, hence the module-scope cache.
    #>
    [CmdletBinding()]
    param([switch]$Force)

    if ($null -ne $script:VendorNames -and -not $Force) { return }

    $script:VendorNames = @{}
    $script:DeviceNames = @{}
    $script:ClassNames = @{}

    if (-not (Test-Path $script:PciIdsPath)) {
        Write-Verbose "no pci.ids at $script:PciIdsPath; IDs will render as hex only"
        return
    }

    # Present but unreadable (ACL, lock) degrades to hex-only output, as the
    # missing-file case does, rather than failing the whole listing.
    try {
        $tables = Read-PciIdsFile -Path $script:PciIdsPath
    } catch {
        Write-Warning "could not read $script:PciIdsPath ($($_.Exception.Message)); IDs will render as hex only"
        return
    }
    $script:VendorNames = $tables.Vendors
    $script:DeviceNames = $tables.Devices
    $script:ClassNames = $tables.Classes
}


function Get-PciVendorName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VendorId)
    Import-PciIds
    $key = $VendorId.ToLower()
    if ($script:VendorNames.ContainsKey($key)) { return $script:VendorNames[$key] }
    return $null
}


function Get-PciDeviceName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VendorId,
        [Parameter(Mandatory)][string]$DeviceId
    )
    Import-PciIds
    $key = "$($VendorId.ToLower())/$($DeviceId.ToLower())"
    if ($script:DeviceNames.ContainsKey($key)) { return $script:DeviceNames[$key] }
    return $null
}


function Get-PciClassName {
    <#
    .SYNOPSIS
      Class name from base/sub class bytes, falling back to the base class.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$BaseClass,
        [int]$SubClass = -1
    )
    Import-PciIds
    $base = '{0:x2}' -f $BaseClass
    if ($SubClass -ge 0) {
        $key = "$base{0:x2}" -f $SubClass
        if ($script:ClassNames.ContainsKey($key)) { return $script:ClassNames[$key] }
    }
    if ($script:ClassNames.ContainsKey($base)) { return $script:ClassNames[$base] }
    return 'Unclassified device'
}


# Every property this module reads, fetched in ONE call per device.
#
# Get-PnpDeviceProperty accepts an array of key names, and that matters more
# than it looks: querying these individually is ~15 round trips per device, and
# across a few hundred devices an unfiltered `lspci` took over five minutes.
# Batched, the same enumeration is a couple of seconds.
$script:WantedKeys = @(
    'DEVPKEY_Device_LocationInfo'
    'DEVPKEY_Device_BusNumber'
    'DEVPKEY_Device_Address'
    'DEVPKEY_Device_DriverVersion'
    'DEVPKEY_Device_Numa_Node'
    'DEVPKEY_Device_Parent'
    'DEVPKEY_PciDevice_BaseClass'
    'DEVPKEY_PciDevice_SubClass'
    'DEVPKEY_PciDevice_ProgIf'
    'DEVPKEY_PciDevice_CurrentLinkSpeed'
    'DEVPKEY_PciDevice_CurrentLinkWidth'
    'DEVPKEY_PciDevice_MaxLinkSpeed'
    'DEVPKEY_PciDevice_MaxLinkWidth'
    'DEVPKEY_PciDevice_CurrentPayloadSize'
    'DEVPKEY_PciDevice_MaxPayloadSize'
    'DEVPKEY_PciDevice_MaxReadRequestSize'
    'DEVPKEY_PciDevice_AERCapabilityPresent'
)


function Get-DevicePropertyBag {
    <#
    .SYNOPSIS
      All wanted properties for one device, as a hashtable keyed by KeyName.

    .DESCRIPTION
      Uses the CIM method that ``Get-PnpDeviceProperty`` wraps, rather than the
      cmdlet, because the difference is not marginal:

          Get-PnpDeviceProperty  ~1230 ms per device
          GetDeviceProperties      ~39 ms per device

      Full enumeration of this machine went from ~36s to ~1.5s. The cmdlet
      appears to re-resolve the device on every call; the CIM method takes an
      already-resolved instance.

      (A wildcard `-KeyName '*'` looked twice as fast as naming keys and was
      the first thing tried. It returns ZERO properties -- it does not support
      wildcards, so it was fast because it did nothing. Worth recording: the
      benchmark was measuring a no-op, and the output looked plausible enough
      that only checking the values caught it.)

      Missing properties are simply absent from the bag. Callers use
      Get-BagValue, which returns $null for absent -- keeping "not reported"
      distinct from "reported as zero", which for link width is the difference
      between a device that does not expose link state and a dead link.
    #>
    param($CimInstance)

    $bag = @{}
    try {
        $result = Invoke-CimMethod -InputObject $CimInstance `
            -MethodName GetDeviceProperties `
            -Arguments @{ devicePropertyKeys = $script:WantedKeys } `
            -ErrorAction Stop
    } catch {
        return $bag
    }

    $resultProps = $result.PSObject.Properties
    if (-not $resultProps['deviceProperties']) { return $bag }

    foreach ($p in $resultProps['deviceProperties'].Value) {
        # Under Set-StrictMode 2.0, touching a property that does not exist is
        # a terminating error, and a device missing a given DEVPKEY comes back
        # as an object without usable Data. Probe the property bag rather than
        # the property, so an absent key is a normal outcome and not a crash
        # partway through enumeration.
        $pp = $p.PSObject.Properties
        if (-not $pp['KeyName'] -or -not $pp['Data']) { continue }
        $value = $pp['Data'].Value
        if ($null -eq $value -or "$value" -eq '') { continue }
        $bag[$pp['KeyName'].Value] = $value
    }
    return $bag
}


function Get-BagValue {
    param($Bag, [string]$Key)
    if ($Bag.ContainsKey($Key)) { return $Bag[$Key] }
    return $null
}


function ConvertTo-Bdf {
    <#
    .SYNOPSIS
      lspci-style bus:device.function from Windows' location data.
    .DESCRIPTION
      Prefers DEVPKEY_Device_LocationInfo ("PCI bus 1, device 0, function 0"),
      which is authoritative. Falls back to BusNumber plus the packed Address
      property (device in the high word, function in the low word) when the
      location string is absent or in an unexpected form.
    #>
    param($LocationInfo, $BusNumber, $Address)

    if ($LocationInfo -and $LocationInfo -match 'bus (\d+), device (\d+), function (\d+)') {
        return ('{0:x2}:{1:x2}.{2:d}' -f [int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
    }
    if ($null -ne $BusNumber -and $null -ne $Address) {
        $dev = ([int]$Address -shr 16) -band 0xFFFF
        $fun = [int]$Address -band 0xFFFF
        return ('{0:x2}:{1:x2}.{2:d}' -f [int]$BusNumber, $dev, $fun)
    }
    return '??:??.?'
}



function Get-ClassFromHardwareId {
    <#
    .SYNOPSIS
      Class code from the PnP hardware IDs, for devices that report no
      DEVPKEY_PciDevice_BaseClass.
    .DESCRIPTION
      The host bridge on a typical machine carries no BaseClass/SubClass
      property at all, yet its hardware IDs include
      "PCI\VEN_8086&DEV_9A14&CC_060000". Windows derives that CC_ token from
      the same config-space class register, so it is an equally authoritative
      source and costs nothing extra -- HardwareID is already on the
      Win32_PnPEntity instance. Without it, "no class reported" and "class 00"
      collapse into one another, which is the kind of quiet wrong answer this
      module exists to avoid.
    #>
    param($HardwareIds)
    foreach ($id in @($HardwareIds)) {
        if ("$id" -match 'CC_([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})?') {
            $progIf = $null
            if ($Matches[3]) { $progIf = [Convert]::ToInt32($Matches[3], 16) }
            return @{
                Base   = [Convert]::ToInt32($Matches[1], 16)
                Sub    = [Convert]::ToInt32($Matches[2], 16)
                ProgIf = $progIf
            }
        }
    }
    return $null
}


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
      Windows' PnP data carries no PCI segment, so every device is in domain 0:
      a filter naming any other domain matches nothing, which is also what
      lspci reports on a single-segment machine.
    #>
    param([string]$Bdf, $Filter)
    if ($null -eq $Filter) { return $true }
    if ($Bdf -notmatch '^([0-9a-f]{2}):([0-9a-f]{2})\.(\d)$') { return $false }
    $bus = [Convert]::ToInt32($Matches[1], 16)
    $dev = [Convert]::ToInt32($Matches[2], 16)
    $fun = [int]$Matches[3]
    if ($null -ne $Filter.Domain -and $Filter.Domain -ne 0) { return $false }
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


# The shape of a WinLspci.PciDevice, in output order. Kept as data so
# Get-PciAttributeName can answer without enumerating the machine (it used to
# run a full ~2s enumeration to ask one object what its fields were called),
# and pinned by a test that compares it against a live object.
$script:AttributeNames = @(
    'Slot', 'VendorId', 'DeviceId', 'SubsystemVendorId', 'SubsystemId', 'Revision',
    'VendorName', 'DeviceName', 'ClassCode', 'ClassName', 'ProgIf',
    'FriendlyName', 'Driver', 'DriverVersion', 'Status', 'Problem', 'NumaNode',
    'LinkStateReported', 'LinkSpeed', 'LinkSpeedRaw', 'LinkWidth',
    'MaxLinkSpeed', 'MaxLinkSpeedRaw', 'MaxLinkWidth', 'Downtrained',
    'MaxPayloadSize', 'MaxPayloadSizeSupported', 'MaxReadRequestSize',
    'AerCapable', 'ParentInstanceId', 'InstanceId', 'Present'
)


function Get-PciDevice {
    <#
    .SYNOPSIS
      Enumerate PCI devices with identity, class, link state and driver.

    .PARAMETER Device
      lspci-style selector: [<vendor>]:[<device>][:<class>]. Any field may be
      empty or omitted. Vendor and device are exact hex IDs; class is a hex
      prefix. Examples: 11f8: , :174a , ::0108 , ::01

    .PARAMETER Slot
      lspci-style slot filter [[<domain>]:]<bus>:]<device>[.<func>], any field
      optional: 01: , 01:00.0 , 1 (device 01 on any bus) , .0 (every function 0)

    .PARAMETER IncludeAbsent
      Include devices that are not currently present.

    .EXAMPLE
      Get-PciDevice -Device '11f8:'
    .EXAMPLE
      Get-PciDevice | Where-Object Downtrained
    #>
    [CmdletBinding()]
    param(
        [Alias('d')][string]$Device = '',
        [Alias('s')][string]$Slot = '',
        [switch]$IncludeAbsent
    )

    # Validate both selectors up front, so a typo is one clear error before
    # any enumeration rather than a .NET exception per device.
    $devFilter = ConvertTo-DeviceFilter $Device
    $slotFilter = ConvertTo-SlotFilter $Slot
    $filterVendor = $devFilter.Vendor
    $filterDevice = $devFilter.Device
    $filterClass = $devFilter.Class

    # One projected WQL query for the PCI entities, then the CIM property
    # method per device.
    #
    # The projection matters more than the WHERE: SELECT * on Win32_PnPEntity
    # costs ~1.3s on a laptop and naming only the columns this module reads
    # halves it, because the provider materialises far less per instance. The
    # per-device property fetch is ~30ms, so a full listing is ~1.5s rather
    # than the ~36s the Get-PnpDevice / Get-PnpDeviceProperty pairing took.
    #
    # The LIKE text is exactly "PCI\\VEN[_]%": two backslashes (one level of
    # string escaping -- LIKE does not consume a second), and [_] because a
    # bare underscore is WQL's single-character wildcard. Get this wrong and
    # the query returns ZERO rows silently, rendering a machine with no PCI
    # bus; a test pins the row count against a client-side -like.
    #
    # $filterVendor is only ever four validated hex digits (see
    # ConvertTo-DeviceFilter), so interpolating it into the query is safe.
    $where = 'PNPDeviceID LIKE "PCI\\VEN[_]%"'
    if ($filterVendor) {
        $where = 'PNPDeviceID LIKE "PCI\\VEN[_]{0}%"' -f $filterVendor
    }
    $query = 'SELECT DeviceID,PNPDeviceID,Name,Service,Status,ConfigManagerErrorCode,HardwareID ' +
             "FROM Win32_PnPEntity WHERE $where"
    $entities = @(Get-CimInstance -Query $query -ErrorAction SilentlyContinue)

    foreach ($pnp in $entities) {
        $instanceId = $pnp.PNPDeviceID
        if (-not $IncludeAbsent -and $pnp.Status -eq 'Unknown') { continue }
        if ($instanceId -notmatch 'VEN_([0-9A-Fa-f]{4})&DEV_([0-9A-Fa-f]{4})') { continue }
        $ven = $Matches[1].ToLower()
        $dev = $Matches[2].ToLower()

        if ($filterVendor -and $ven -ne $filterVendor) { continue }
        if ($filterDevice -and $dev -ne $filterDevice) { continue }

        # Windows packs the subsystem as SUBSYS_<device><vendor>: the high word
        # is the subsystem DEVICE id and the low word the subsystem VENDOR id.
        # Printed raw it reads backwards against lspci's vendor:device habit --
        # 174a1c5c on an SK hynix (1c5c) drive looks like Sandisk (174a).
        $subVen = $null; $subDev = $null
        if ($instanceId -match 'SUBSYS_([0-9A-Fa-f]{4})([0-9A-Fa-f]{4})') {
            $subDev = $Matches[1].ToLower()
            $subVen = $Matches[2].ToLower()
        }
        $rev = $null
        if ($instanceId -match 'REV_([0-9A-Fa-f]{2})') { $rev = $Matches[1].ToLower() }

        $bag = Get-DevicePropertyBag $pnp

        $baseClass = Get-BagValue $bag 'DEVPKEY_PciDevice_BaseClass'
        $subClass  = Get-BagValue $bag 'DEVPKEY_PciDevice_SubClass'
        $progIf    = Get-BagValue $bag 'DEVPKEY_PciDevice_ProgIf'

        # Host bridges commonly carry no BaseClass property; the hardware IDs
        # still say CC_0600. Fall back to them rather than asserting class 00.
        if ($null -eq $baseClass -or $null -eq $subClass) {
            $cc = Get-ClassFromHardwareId $pnp.HardwareID
            if ($cc) {
                $baseClass = $cc.Base
                $subClass = $cc.Sub
                if ($null -eq $progIf) { $progIf = $cc.ProgIf }
            }
        }

        # $null, not '', when absent: "class not reported" must stay distinct
        # from class 0000, exactly as link state does.
        $classHex = $null
        if ($null -ne $baseClass -and $null -ne $subClass) {
            $classHex = ('{0:x2}{1:x2}' -f [int]$baseClass, [int]$subClass)
        }
        if ($filterClass) {
            if ($null -eq $classHex -or -not $classHex.StartsWith($filterClass)) { continue }
        }

        $bdf = ConvertTo-Bdf `
            (Get-BagValue $bag 'DEVPKEY_Device_LocationInfo') `
            (Get-BagValue $bag 'DEVPKEY_Device_BusNumber') `
            (Get-BagValue $bag 'DEVPKEY_Device_Address')

        if (-not (Test-SlotMatch $bdf $slotFilter)) { continue }

        $curSpeed = Get-BagValue $bag 'DEVPKEY_PciDevice_CurrentLinkSpeed'
        $curWidth = Get-BagValue $bag 'DEVPKEY_PciDevice_CurrentLinkWidth'
        $maxSpeed = Get-BagValue $bag 'DEVPKEY_PciDevice_MaxLinkSpeed'
        $maxWidth = Get-BagValue $bag 'DEVPKEY_PciDevice_MaxLinkWidth'
        $mpsRaw   = Get-BagValue $bag 'DEVPKEY_PciDevice_CurrentPayloadSize'
        $mpsMax   = Get-BagValue $bag 'DEVPKEY_PciDevice_MaxPayloadSize'
        $mrrsRaw  = Get-BagValue $bag 'DEVPKEY_PciDevice_MaxReadRequestSize'

        $speedText = $null
        if ($null -ne $curSpeed -and $script:LinkSpeed.ContainsKey([int]$curSpeed)) {
            $speedText = $script:LinkSpeed[[int]$curSpeed]
        }
        $maxSpeedText = $null
        if ($null -ne $maxSpeed -and $script:LinkSpeed.ContainsKey([int]$maxSpeed)) {
            $maxSpeedText = $script:LinkSpeed[[int]$maxSpeed]
        }
        $mps = $null
        if ($null -ne $mpsRaw -and $script:PayloadSize.ContainsKey([int]$mpsRaw)) {
            $mps = $script:PayloadSize[[int]$mpsRaw]
        }
        $mpsMaxBytes = $null
        if ($null -ne $mpsMax -and $script:PayloadSize.ContainsKey([int]$mpsMax)) {
            $mpsMaxBytes = $script:PayloadSize[[int]$mpsMax]
        }
        $mrrs = $null
        if ($null -ne $mrrsRaw -and $script:PayloadSize.ContainsKey([int]$mrrsRaw)) {
            $mrrs = $script:PayloadSize[[int]$mrrsRaw]
        }

        $className = $null
        if ($null -ne $baseClass) {
            if ($null -ne $subClass) {
                $className = Get-PciClassName -BaseClass ([int]$baseClass) -SubClass ([int]$subClass)
            } else {
                $className = Get-PciClassName -BaseClass ([int]$baseClass)
            }
        }

        $downtrain = Get-LinkDowntrainReason $curSpeed $maxSpeed $curWidth $maxWidth

        [pscustomobject]@{
            PSTypeName       = 'WinLspci.PciDevice'
            Slot             = $bdf
            VendorId         = $ven
            DeviceId         = $dev
            SubsystemVendorId = $subVen
            SubsystemId      = $subDev
            Revision         = $rev
            VendorName       = Get-PciVendorName $ven
            DeviceName       = Get-PciDeviceName $ven $dev
            ClassCode        = $classHex
            ClassName        = $className
            ProgIf           = $progIf
            FriendlyName     = $pnp.Name
            Driver           = $pnp.Service
            DriverVersion    = Get-BagValue $bag 'DEVPKEY_Device_DriverVersion'
            Status           = $pnp.Status
            Problem          = $pnp.ConfigManagerErrorCode
            NumaNode         = Get-BagValue $bag 'DEVPKEY_Device_Numa_Node'
            # "not reported" must stay distinct from "reported as zero". Root
            # ports and chipset devices legitimately report no link state, and
            # rendering that as x0 would look like a dead link.
            LinkStateReported = ($null -ne $curSpeed)
            LinkSpeed        = $speedText
            LinkSpeedRaw     = $curSpeed
            LinkWidth        = $curWidth
            MaxLinkSpeed     = $maxSpeedText
            MaxLinkSpeedRaw  = $maxSpeed
            MaxLinkWidth     = $maxWidth
            Downtrained      = ($downtrain.Count -gt 0)
            MaxPayloadSize   = $mps
            MaxPayloadSizeSupported = $mpsMaxBytes
            MaxReadRequestSize = $mrrs
            AerCapable       = Get-BagValue $bag 'DEVPKEY_PciDevice_AERCapabilityPresent'
            ParentInstanceId = Get-BagValue $bag 'DEVPKEY_Device_Parent'
            InstanceId       = $instanceId
            Present          = ($pnp.Status -ne 'Unknown')
        }
    }
}


function Format-Lspci {
    <#
    .SYNOPSIS
      Render devices in lspci's style.
    .PARAMETER Verbosity
      0 = one line per device (lspci)
      1 = plus link state and driver (lspci -v)
      2 = plus MPS/MRRS, subsystem, NUMA, capabilities present (lspci -vv)
    .PARAMETER Numeric
      0 = names only, 1 = IDs only (-n), 2 = names and IDs (-nn)
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]$Device,
        [int]$Verbosity = 0,
        [int]$Numeric = 2
    )
    process {
        foreach ($d in @($Device)) {
            # Get-Field, not dot access: under StrictMode a trimmed object
            # (Select-Object Slot,DeviceName) must render with gaps, not crash.
            $vendorId = Get-Field $d 'VendorId'
            $deviceId = Get-Field $d 'DeviceId'
            $vendor = ConvertTo-SafeText (Get-Field $d 'VendorName')
            if (-not $vendor) { $vendor = "Vendor $vendorId" }
            $name = ConvertTo-SafeText (Get-Field $d 'DeviceName')
            if (-not $name) {
                $name = ConvertTo-SafeText (Get-Field $d 'FriendlyName')
                if (-not $name) { $name = "Device $deviceId" }
            }

            # A device that reports no class is said to have none -- never
            # shown as class 0000 or as the real class-00 name.
            $classCode = Get-Field $d 'ClassCode'
            $className = Get-Field $d 'ClassName'
            if (-not $classCode) { $classCode = '????' }
            if (-not $className) { $className = 'Unknown class' }

            if ($Numeric -eq 1) {
                $ident = "${vendorId}:${deviceId}"
                $classPart = $classCode
            } elseif ($Numeric -eq 2) {
                $ident = "$vendor $name [${vendorId}:${deviceId}]"
                $classPart = "$className [$classCode]"
            } else {
                $ident = "$vendor $name"
                $classPart = $className
            }

            $rev = ''
            $revision = Get-Field $d 'Revision'
            if ($revision) { $rev = " (rev $revision)" }
            Write-Output ("{0} {1}: {2}{3}" -f (Get-Field $d 'Slot'), $classPart, $ident, $rev)

            if ($Verbosity -ge 1) {
                if (Get-Field $d 'LinkStateReported') {
                    $width = Get-Field $d 'LinkWidth'
                    $maxWidth = Get-Field $d 'MaxLinkWidth'
                    $widthText = 'x?'
                    if ($null -ne $width) { $widthText = "x$width" }
                    $line = "        LnkSta: $(Get-Field $d 'LinkSpeed') $widthText"
                    if (Get-Field $d 'MaxLinkSpeed') {
                        $maxWidthText = 'x?'
                        if ($null -ne $maxWidth) { $maxWidthText = "x$maxWidth" }
                        $line += " (max $(Get-Field $d 'MaxLinkSpeed') $maxWidthText)"
                    }
                    # Downtrained links are the single most useful thing this
                    # tool can point at, so say it in words rather than making
                    # the reader compare two numbers.
                    $reasons = Get-LinkDowntrainReason (Get-Field $d 'LinkSpeedRaw') `
                        (Get-Field $d 'MaxLinkSpeedRaw') $width $maxWidth
                    foreach ($r in $reasons) { $line += "  <-- DOWNTRAINED ($r)" }
                    Write-Output $line
                } else {
                    Write-Output '        LnkSta: not reported by this device'
                }

                $drv = ConvertTo-SafeText (Get-Field $d 'Driver')
                if (-not $drv) { $drv = '<none>' }
                $status = "        Driver: $drv"
                $drvVer = Get-Field $d 'DriverVersion'
                if ($drvVer) { $status += " ($drvVer)" }
                $devStatus = Get-Field $d 'Status'
                if ($devStatus -and $devStatus -ne 'OK') {
                    $status += "  STATUS=$devStatus PROBLEM=$(Get-Field $d 'Problem')"
                }
                Write-Output $status
            }

            if ($Verbosity -ge 2) {
                $subVen = Get-Field $d 'SubsystemVendorId'
                $subDev = Get-Field $d 'SubsystemId'
                if ($subVen -and $subDev) {
                    $subName = Get-PciVendorName $subVen
                    if (-not $subName) { $subName = "Vendor $subVen" }
                    Write-Output "        Subsystem: $subName [${subVen}:${subDev}]"
                }
                $mps = Get-Field $d 'MaxPayloadSize'
                if ($null -ne $mps) {
                    Write-Output ("        DevCtl: MPS {0} bytes (max {1}), MaxReadReq {2} bytes" -f `
                        $mps, (Get-Field $d 'MaxPayloadSizeSupported'), (Get-Field $d 'MaxReadRequestSize'))
                }
                $numa = Get-Field $d 'NumaNode'
                if ($null -ne $numa) { Write-Output "        NUMA node: $numa" }
                if (Get-Field $d 'AerCapable') { Write-Output '        Capabilities: AER present' }
                Write-Output "        InstanceId: $(Get-Field $d 'InstanceId')"
            }

            if ($Verbosity -ge 3) {
                # lspci -vvv decodes every capability structure. We cannot --
                # that needs config space. So -vvv here means everything -vv
                # shows, then "every field Windows will give us", plus an
                # explicit statement of what is missing, rather than a quieter
                # version of -vv that leaves the reader assuming they saw
                # everything.
                Write-Output '        -- all available properties --'
                foreach ($prop in ($d.PSObject.Properties | Sort-Object Name)) {
                    if ($prop.Name -eq 'PSTypeName') { continue }
                    $v = $prop.Value
                    if ($null -eq $v -or "$v" -eq '') { $v = '<not reported>' }
                    Write-Output ("        {0,-24} {1}" -f $prop.Name, $v)
                }
                Write-Output ('        NOT AVAILABLE without a kernel driver: ' +
                              'config-space dump, capability walk, ASPM, ' +
                              'AER registers, LTR, DPC')
            }
        }
    }
}



function Format-PciTree {
    <#
    .SYNOPSIS
      Bus topology, in the shape of `lspci -t`.

    .DESCRIPTION
      Built from DEVPKEY_Device_Parent, which Windows populates with the
      upstream bridge's instance id. Devices whose parent is not itself a PCI
      device (root complexes, and anything whose parent left the tree) become
      roots, so nothing is silently dropped -- an incomplete tree that LOOKS
      complete is worse than an obviously ragged one.

    .PARAMETER Numeric
      0 names, 1 ids, 2 both -- as Format-Lspci.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Devices,
        [int]$Numeric = 0
    )

    # Everything below works on INDICES into $all, never on InstanceId as a
    # key for a node: a trimmed object has no InstanceId, and keying visited
    # on the empty string once marked the first such node visited and silently
    # dropped every other one. Indices need no identity and cannot collide.
    $all = @($Devices)
    $indexById = @{}
    for ($n = 0; $n -lt $all.Count; $n++) {
        $id = Get-Field $all[$n] 'InstanceId'
        if ($null -ne $id -and "$id" -ne '' -and -not $indexById.ContainsKey("$id")) { $indexById["$id"] = $n }
    }

    $children = @{}     # parent index -> list of child indices
    $roots = @()
    for ($n = 0; $n -lt $all.Count; $n++) {
        $parent = Get-Field $all[$n] 'ParentInstanceId'
        $parentIndex = -1
        if ($parent -and $indexById.ContainsKey("$parent")) { $parentIndex = $indexById["$parent"] }
        # A node whose parent is itself (or otherwise unreachable from a root)
        # is caught by the visited sweep at the end.
        if ($parentIndex -ge 0 -and $parentIndex -ne $n) {
            if (-not $children.ContainsKey($parentIndex)) { $children[$parentIndex] = @() }
            $children[$parentIndex] += $n
        } else {
            $roots += $n
        }
    }

    $visited = New-Object 'bool[]' $all.Count

    function Write-Node {
        param([int]$Index, [string]$Prefix, [bool]$IsLast, [bool]$IsRoot)

        if ($visited[$Index]) { return }
        $visited[$Index] = $true
        $Node = $all[$Index]

        $label = "$(Get-Field $Node 'Slot')"
        $ids = "$(Get-Field $Node 'VendorId'):$(Get-Field $Node 'DeviceId')"
        if ($Numeric -eq 1) {
            $label += " [$ids]"
        } else {
            $desc = Get-Field $Node 'DeviceName'
            if (-not $desc) { $desc = Get-Field $Node 'FriendlyName' }
            if (-not $desc) { $desc = Get-Field $Node 'ClassName' }
            if (-not $desc) { $desc = 'Unknown class' }
            $desc = ConvertTo-SafeText $desc
            if ($Numeric -eq 2) { $desc = "$desc [$ids]" }
            $label += "  $desc"
        }
        if (Get-Field $Node 'LinkStateReported') {
            $w = Get-Field $Node 'LinkWidth'
            $wText = 'x?'
            if ($null -ne $w) { $wText = "x$w" }
            $label += "  ($(Get-Field $Node 'LinkSpeed') $wText)"
        }

        if ($IsRoot) {
            Write-Output "-$label"
            $childPrefix = ' '
        } else {
            if ($IsLast) { $branch = '\-' } else { $branch = '+-' }
            Write-Output "$Prefix$branch$label"
            if ($IsLast) { $childPrefix = "$Prefix  " } else { $childPrefix = "$Prefix| " }
        }

        $kids = @()
        if ($children.ContainsKey($Index)) {
            $kids = @($children[$Index] | Sort-Object { "$(Get-Field $all[$_] 'Slot')" })
        }
        for ($i = 0; $i -lt $kids.Count; $i++) {
            Write-Node $kids[$i] $childPrefix ($i -eq $kids.Count - 1) $false
        }
    }

    $bySlot = { "$(Get-Field $all[$_] 'Slot')" }
    foreach ($r in ($roots | Sort-Object $bySlot)) {
        Write-Node $r '' $true $true
    }

    # Nothing may be silently dropped. Anything the walk from the roots did
    # not reach (a parent cycle, for instance) is rendered as a root of its
    # own, so an incomplete tree is obviously ragged rather than quietly short.
    $orphans = @(0..($all.Count - 1) | Where-Object { $all.Count -gt 0 -and -not $visited[$_] })
    foreach ($o in ($orphans | Sort-Object $bySlot)) {
        Write-Node $o '' $true $true
    }
}


function ConvertTo-PciAttributeRecord {
    <#
    .SYNOPSIS
      Flatten a device to one record per ATTRIBUTE.

    .DESCRIPTION
      Turns a device object into rows of
      (Slot, Attribute, Value, Present) so a query can be written against
      attributes rather than devices -- grouping, diffing two machines, or
      asking "which devices report MaxPayloadSize at all".

      `Present` is a first-class field because absent and zero must not
      collapse: a root port that reports no link width is not a device running
      at x0, and any tool that renders both as 0 will eventually send someone
      to debug a link that is fine.

    .EXAMPLE
      Get-PciDevice | ConvertTo-PciAttributeRecord |
        Where-Object { $_.Attribute -eq 'LinkWidth' -and $_.Present }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$Device,
        [string[]]$Attribute,
        [string]$Match,
        [switch]$PresentOnly
    )
    process {
        foreach ($d in @($Device)) {
            foreach ($prop in $d.PSObject.Properties) {
                if ($prop.Name -eq 'PSTypeName') { continue }

                # Wildcards, not exact names. Without grep on the far side, the
                # filtering has to happen here -- `-Attribute Link*` is the
                # thing you would otherwise pipe through `grep -i link`.
                if ($Attribute) {
                    $nameHit = $false
                    foreach ($pattern in $Attribute) {
                        if ($prop.Name -like $pattern) { $nameHit = $true; break }
                    }
                    if (-not $nameHit) { continue }
                }

                $value = $prop.Value
                $isPresent = ($null -ne $value -and "$value" -ne '')
                if ($PresentOnly -and -not $isPresent) { continue }
                if ($Match -and "$value" -notmatch $Match) { continue }
                [pscustomobject]@{
                    Slot      = Get-Field $d 'Slot'
                    VendorId  = Get-Field $d 'VendorId'
                    DeviceId  = Get-Field $d 'DeviceId'
                    Attribute = $prop.Name
                    Value     = $value
                    Present   = $isPresent
                }
            }
        }
    }
}



function Get-PciAttributeName {
    <#
    .SYNOPSIS
      Every attribute name a device object carries.
    .DESCRIPTION
      Exists because attribute-level queries are only usable if you can find
      out what the attributes are called. `lspci -ListAttributes` is the
      discovery step that `grep` would otherwise stand in for.
    #>
    [CmdletBinding()]
    param()
    # Answered from the static shape, not by enumerating the machine: this
    # used to cost a full ~2s enumeration (and the CLI had already done one).
    $script:AttributeNames | Sort-Object
}



function Format-PciDelimited {
    <#
    .SYNOPSIS
      One record per line, fields separated by `|` -- for cut, awk and -split.

    .DESCRIPTION
      Windows has no grep, awk or cut, but the muscle memory is real and
      PowerShell's own equivalents are wordy. A delimited stream is the
      familiar shape:

          lspci -Delimited | ForEach-Object { ($_ -split '\|')[0] }
          lspci -Attribute Link* -Delimited | Select-String LinkSpeed

      Two properties chosen deliberately:

      **An empty field means NOT REPORTED; a literal 0 means zero.** The
      absent/zero distinction that the object model protects survives into the
      text form for free, because an unset value serialises to nothing at all.
      Any consumer splitting on the delimiter sees the difference.

      **The delimiter is stripped from values, not escaped.** Quoting rules
      turn a one-liner into a parser, which defeats the point. No `|` occurs in
      live PCI data or in pci.ids today, but FriendlyName comes from driver INF
      files and is not under our control, so a stray delimiter is replaced with
      `/` rather than being allowed to silently shift every later column. Use
      -Csv when you need real quoting.

    .PARAMETER Delimiter
      Defaults to `|`. Use "`t" for tab-separated.

    .PARAMETER Header
      Emit a leading header row. Off by default, as Unix tools are.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$InputObject,
        [string]$Delimiter = '|',
        [switch]$Header,
        [string[]]$Field
    )
    begin {
        if ($Delimiter -eq '') { throw 'Format-PciDelimited: -Delimiter must not be empty' }

        # Function-local, not $script: -- begin/process share scope, and a
        # module-scope flag was reset by any NESTED Format-PciDelimited
        # (e.g. inside a ForEach-Object on the outer stream), re-emitting the
        # header for every remaining row.
        $headerWritten = $false

        # A device row and an attribute row have different natural columns.
        $deviceFields = @(
            'Slot', 'VendorId', 'DeviceId', 'ClassCode', 'ClassName',
            'VendorName', 'DeviceName', 'Revision',
            'LinkSpeed', 'LinkWidth', 'MaxLinkSpeed', 'MaxLinkWidth',
            'Driver', 'Status'
        )
        $attributeFields = @('Slot', 'VendorId', 'DeviceId', 'Attribute', 'Value', 'Present')
    }
    process {
        foreach ($item in @($InputObject)) {
            $names = $Field
            if (-not $names) {
                if ($item.PSObject.Properties['Attribute']) {
                    $names = $attributeFields
                } else {
                    $names = $deviceFields
                }
                # Only keep columns the object actually has, so a trimmed
                # object does not produce phantom empty columns.
                $names = @($names | Where-Object { $item.PSObject.Properties[$_] })
            }

            if ($Header -and -not $headerWritten) {
                Write-Output ($names -join $Delimiter)
                $headerWritten = $true
            }

            $values = foreach ($n in $names) {
                $prop = $item.PSObject.Properties[$n]
                $v = ''
                if ($prop -and $null -ne $prop.Value) { $v = "$($prop.Value)" }
                # Strip, do not escape -- see the note above. Line breaks and
                # other control characters get the same treatment: one record
                # must stay one physical line, whatever a driver INF put in
                # FriendlyName.
                $v = $v -replace '[\x00-\x1f\x7f]', ' '
                $v.Replace($Delimiter, '/')
            }
            Write-Output ($values -join $Delimiter)
        }
    }
}


function Update-PciIds {
    <#
    .SYNOPSIS
      Refresh the bundled PCI ID database from pci-ids.ucw.cz.
    .DESCRIPTION
      Optional and explicit. The database is bundled so the tool works with no
      network at all -- on a lab bench that is usually the situation.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Uri = 'https://pci-ids.ucw.cz/v2.2/pci.ids')

    if ($Uri -notmatch '^https://') { throw "Update-PciIds: -Uri must be https:// (got '$Uri')" }
    if (-not $PSCmdlet.ShouldProcess($script:PciIdsPath, "download $Uri")) { return }

    # PS 5.1 on older Windows negotiates TLS 1.0 by default, which the origin
    # refuses. Add 1.2 to whatever is already enabled rather than replacing it.
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # Download to the system temp dir, not the install dir: a failed transfer
    # leaves nothing behind next to the module, and the install dir may be
    # read-only (Program Files) -- in which case Move-Item fails with a clear
    # access error instead of a half-written database.
    $tmp = [IO.Path]::GetTempFileName()
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $tmp -UseBasicParsing -ErrorAction Stop

        # Prove it PARSES -- the old check only counted lines, so a long but
        # wrong-format response would have replaced a working database.
        $tables = Read-PciIdsFile -Path $tmp
        if ($tables.Vendors.Count -lt 1000 -or -not $tables.Vendors.ContainsKey('8086') -or
            -not $tables.Classes.ContainsKey('0108')) {
            throw ("downloaded pci.ids does not parse as a PCI ID database " +
                   "($($tables.Vendors.Count) vendors); refusing to replace the bundled copy")
        }

        # Keep the previous database until the new one is in place.
        $bak = "$script:PciIdsPath.bak"
        if (Test-Path $script:PciIdsPath) { Copy-Item $script:PciIdsPath $bak -Force }
        # Copy, not Move: a file MOVED out of %TEMP% keeps the temp directory's
        # ACL (admins + SYSTEM + this user only), so in a machine-wide install
        # every other account would silently lose vendor/device names. An
        # overwrite keeps the destination's own ACL; the finally block removes
        # the temp copy.
        Copy-Item $tmp $script:PciIdsPath -Force
        Import-PciIds -Force
        Write-Verbose "updated: $($tables.Vendors.Count) vendors, $($tables.Devices.Count) devices; previous copy at $bak"
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}


Export-ModuleMember -Function Get-PciDevice, Format-Lspci, Format-PciTree,
    ConvertTo-PciAttributeRecord, Get-PciAttributeName,
    Format-PciDelimited, Update-PciIds,
    Get-PciVendorName, Get-PciDeviceName, Get-PciClassName, Import-PciIds,
    Read-PciIdsFile
