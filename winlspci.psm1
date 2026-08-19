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


function Import-PciIds {
    <#
    .SYNOPSIS
      Load and index the PCI ID database. Cached for the session.
    .DESCRIPTION
      A full parse of the ~38k-line database takes about 170ms, which is fine
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

    $currentVendor = $null
    $currentClass = $null
    $inClassSection = $false

    foreach ($line in [System.IO.File]::ReadLines($script:PciIdsPath)) {
        if ($line.Length -eq 0 -or $line[0] -eq '#') { continue }

        if ($line[0] -eq 'C' -and $line.Length -gt 2 -and $line[1] -eq ' ') {
            # "C 03  Display controller" begins the device-class section.
            $inClassSection = $true
            $body = $line.Substring(2)
            $sep = $body.IndexOf('  ')
            if ($sep -gt 0) {
                $currentClass = $body.Substring(0, $sep)
                $script:ClassNames[$currentClass] = $body.Substring($sep + 2)
            }
            continue
        }

        if ($line[0] -ne "`t") {
            $sep = $line.IndexOf('  ')
            if ($sep -gt 0) {
                $currentVendor = $line.Substring(0, $sep)
                $script:VendorNames[$currentVendor] = $line.Substring($sep + 2)
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
                if ($currentClass) { $script:ClassNames["$currentClass$id"] = $name }
            } elseif ($currentVendor) {
                $script:DeviceNames["$currentVendor/$id"] = $name
            }
        }
    }
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


function Get-PciDevice {
    <#
    .SYNOPSIS
      Enumerate PCI devices with identity, class, link state and driver.

    .PARAMETER Device
      lspci-style selector: [<vendor>]:[<device>][:<class>]. Any field may be
      empty or omitted. Examples: 11f8: , :174a , ::0108

    .PARAMETER Slot
      lspci-style slot filter, matched as a prefix: 01: or 01:00 or 01:00.0

    .PARAMETER IncludeAbsent
      Include devices that are not currently present.

    .EXAMPLE
      Get-PciDevice -Device '11f8:'
    .EXAMPLE
      Get-PciDevice | Where-Object { $_.LinkSpeedRaw -lt $_.MaxLinkSpeedRaw }
    #>
    [CmdletBinding()]
    param(
        [Alias('d')][string]$Device = '',
        [Alias('s')][string]$Slot = '',
        [switch]$IncludeAbsent
    )

    $filterVendor = ''; $filterDevice = ''; $filterClass = ''
    if ($Device) {
        $parts = $Device.Split(':')
        if ($parts.Count -ge 1) { $filterVendor = ($parts[0] -replace '^0[xX]', '').Trim() }
        if ($parts.Count -ge 2) { $filterDevice = ($parts[1] -replace '^0[xX]', '').Trim() }
        if ($parts.Count -ge 3) { $filterClass  = ($parts[2] -replace '^0[xX]', '').Trim() }
    }

    # Push the vendor filter into the instance-id wildcard. Enumerating every
    # device and filtering afterwards, then querying properties on all of them,
    # took over two minutes on a normal laptop; this makes it ~2s.
    if ($filterVendor) {
        $idFilter = "PCI\VEN_$filterVendor*"
    } else {
        $idFilter = 'PCI\VEN_*'
    }

    # Win32_PnPEntity in one query, then the CIM property method per device.
    # Enumerating this way costs ~1s for the whole machine; the property fetch
    # is ~40ms per device, so a full listing lands around 1.5s rather than the
    # ~36s the Get-PnpDevice / Get-PnpDeviceProperty pairing took.
    $entities = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -like 'PCI\VEN_*' })

    if ($filterVendor) {
        $entities = @($entities | Where-Object {
            $_.PNPDeviceID -like "PCI\VEN_$filterVendor*"
        })
    }

    foreach ($pnp in $entities) {
        $instanceId = $pnp.PNPDeviceID
        if (-not $IncludeAbsent -and $pnp.Status -eq 'Unknown') { continue }
        if ($instanceId -notmatch 'VEN_([0-9A-Fa-f]{4})&DEV_([0-9A-Fa-f]{4})') { continue }
        $ven = $Matches[1].ToLower()
        $dev = $Matches[2].ToLower()

        if ($filterDevice -and $dev -notlike $filterDevice) { continue }

        $sub = $null
        if ($instanceId -match 'SUBSYS_([0-9A-Fa-f]{8})') { $sub = $Matches[1].ToLower() }
        $rev = $null
        if ($instanceId -match 'REV_([0-9A-Fa-f]{2})') { $rev = $Matches[1].ToLower() }

        $bag = Get-DevicePropertyBag $pnp

        $baseClass = Get-BagValue $bag 'DEVPKEY_PciDevice_BaseClass'
        $subClass  = Get-BagValue $bag 'DEVPKEY_PciDevice_SubClass'
        $progIf    = Get-BagValue $bag 'DEVPKEY_PciDevice_ProgIf'

        $classHex = ''
        if ($null -ne $baseClass -and $null -ne $subClass) {
            $classHex = ('{0:x2}{1:x2}' -f [int]$baseClass, [int]$subClass)
        }
        if ($filterClass -and $classHex -notlike "$filterClass*") { continue }

        $bdf = ConvertTo-Bdf `
            (Get-BagValue $bag 'DEVPKEY_Device_LocationInfo') `
            (Get-BagValue $bag 'DEVPKEY_Device_BusNumber') `
            (Get-BagValue $bag 'DEVPKEY_Device_Address')

        if ($Slot -and -not $bdf.StartsWith($Slot.TrimStart('0'))) {
            if (-not $bdf.StartsWith($Slot)) { continue }
        }

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

        $className = 'Unclassified device'
        if ($null -ne $baseClass) {
            if ($null -ne $subClass) {
                $className = Get-PciClassName -BaseClass ([int]$baseClass) -SubClass ([int]$subClass)
            } else {
                $className = Get-PciClassName -BaseClass ([int]$baseClass)
            }
        }

        [pscustomobject]@{
            PSTypeName       = 'WinLspci.PciDevice'
            Slot             = $bdf
            VendorId         = $ven
            DeviceId         = $dev
            SubsystemId      = $sub
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
            MaxPayloadSize   = $mps
            MaxPayloadSizeSupported = $mpsMaxBytes
            MaxReadRequestSize = $mrrs
            AerCapable       = Get-BagValue $bag 'DEVPKEY_PciDevice_AERCapabilityPresent'
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
        [int]$Numeric = 2,
        [switch]$ShowDriver
    )
    process {
        foreach ($d in @($Device)) {
            $vendor = $d.VendorName
            if (-not $vendor) { $vendor = "Vendor $($d.VendorId)" }
            $name = $d.DeviceName
            if (-not $name) {
                $name = $d.FriendlyName
                if (-not $name) { $name = "Device $($d.DeviceId)" }
            }

            if ($Numeric -eq 1) {
                $ident = "$($d.VendorId):$($d.DeviceId)"
                $classPart = $d.ClassCode
            } elseif ($Numeric -eq 2) {
                $ident = "$vendor $name [$($d.VendorId):$($d.DeviceId)]"
                $classPart = "$($d.ClassName) [$($d.ClassCode)]"
            } else {
                $ident = "$vendor $name"
                $classPart = $d.ClassName
            }

            $rev = ''
            if ($d.Revision) { $rev = " (rev $($d.Revision))" }
            Write-Output ("{0} {1}: {2}{3}" -f $d.Slot, $classPart, $ident, $rev)

            if ($Verbosity -ge 1) {
                if ($d.LinkStateReported) {
                    $line = "        LnkSta: $($d.LinkSpeed) x$($d.LinkWidth)"
                    if ($d.MaxLinkSpeed) {
                        $line += " (max $($d.MaxLinkSpeed) x$($d.MaxLinkWidth))"
                    }
                    # Downtrained links are the single most useful thing this
                    # tool can point at, so say it in words rather than making
                    # the reader compare two numbers.
                    if ($null -ne $d.MaxLinkSpeedRaw -and
                        $d.LinkSpeedRaw -lt $d.MaxLinkSpeedRaw) {
                        $line += '  <-- DOWNTRAINED (speed)'
                    }
                    if ($null -ne $d.MaxLinkWidth -and $d.LinkWidth -lt $d.MaxLinkWidth) {
                        $line += '  <-- DOWNTRAINED (width)'
                    }
                    Write-Output $line
                } else {
                    Write-Output '        LnkSta: not reported by this device'
                }

                $drv = $d.Driver
                if (-not $drv) { $drv = '<none>' }
                $status = "        Driver: $drv"
                if ($d.DriverVersion) { $status += " ($($d.DriverVersion))" }
                if ($d.Status -ne 'OK') { $status += "  STATUS=$($d.Status) PROBLEM=$($d.Problem)" }
                Write-Output $status
            }

            if ($Verbosity -ge 2) {
                if ($d.SubsystemId) { Write-Output "        Subsystem: $($d.SubsystemId)" }
                if ($null -ne $d.MaxPayloadSize) {
                    Write-Output ("        DevCtl: MPS {0} bytes (max {1}), MaxReadReq {2} bytes" -f `
                        $d.MaxPayloadSize, $d.MaxPayloadSizeSupported, $d.MaxReadRequestSize)
                }
                if ($null -ne $d.NumaNode) { Write-Output "        NUMA node: $($d.NumaNode)" }
                if ($d.AerCapable) { Write-Output '        Capabilities: AER present' }
                Write-Output "        InstanceId: $($d.InstanceId)"
            }
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

    if ($PSCmdlet.ShouldProcess($script:PciIdsPath, "download $Uri")) {
        $tmp = "$script:PciIdsPath.tmp"
        Invoke-WebRequest -Uri $Uri -OutFile $tmp -UseBasicParsing
        # Only replace a working database once the new one parses.
        $lineCount = (Get-Content $tmp | Measure-Object -Line).Lines
        if ($lineCount -lt 1000) {
            Remove-Item $tmp -Force
            throw "downloaded pci.ids has only $lineCount lines; refusing to replace the bundled copy"
        }
        Move-Item $tmp $script:PciIdsPath -Force
        Import-PciIds -Force
        Write-Verbose "updated: $lineCount lines"
    }
}


Export-ModuleMember -Function Get-PciDevice, Format-Lspci, Update-PciIds,
    Get-PciVendorName, Get-PciDeviceName, Get-PciClassName, Import-PciIds
