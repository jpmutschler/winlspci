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
      lspci-style [domain:]bus:device.function from Windows' location data.
    .DESCRIPTION
      Prefers DEVPKEY_Device_LocationInfo ("PCI bus 1, device 0, function 0"),
      which is authoritative. Falls back to BusNumber plus the packed Address
      property (device in the high word, function in the low word) when the
      location string is absent or in an unexpected form.

      Windows' bus number is 32 bits wide while a PCI bus is 8: Hyper-V and
      Azure put the PCI SEGMENT in the upper bits for SR-IOV virtual functions
      ("PCI bus 5598976" = 0x556F00 = segment 556f, bus 00). Rendering that as
      bus "556f00" produced a slot nothing could parse. The segment becomes
      the Domain, and -- as lspci does -- it is shown in the slot whenever it
      is not zero: 556f:00:02.0.

      Returns a hashtable: Domain (int) and Slot (string).
    #>
    param($LocationInfo, $BusNumber, $Address)

    $domain = 0; $bus = $null; $dev = $null; $fun = $null
    if ($LocationInfo -and $LocationInfo -match 'bus (\d+), device (\d+), function (\d+)') {
        $raw = [int64]$Matches[1]; $dev = [int]$Matches[2]; $fun = [int]$Matches[3]
        $bus = [int]($raw -band 0xFF)
        $domain = [int](($raw -shr 8) -band 0xFFFF)
    } elseif ($null -ne $BusNumber -and $null -ne $Address) {
        $raw = [int64]$BusNumber
        $bus = [int]($raw -band 0xFF)
        $domain = [int](($raw -shr 8) -band 0xFFFF)
        $dev = ([int64]$Address -shr 16) -band 0xFFFF
        $fun = [int64]$Address -band 0xFFFF
    } else {
        return @{ Domain = 0; Slot = '??:??.?' }
    }

    $slot = '{0:x2}:{1:x2}.{2:d}' -f $bus, $dev, $fun
    if ($domain -ne 0) { $slot = ('{0:x4}:' -f $domain) + $slot }
    return @{ Domain = $domain; Slot = $slot }
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
