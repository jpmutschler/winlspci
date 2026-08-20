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
    'DEVPKEY_Device_IsPresent'
    # -- 0.5.0: type, capability presence, location, power. Measured at
    #    ~+300ms for 24 devices (fetch 660 -> 950ms); each key is ~1.4ms per
    #    device. Every one below was verified to populate on real hardware;
    #    keys that Windows rejects as invalid (Label, ExtendedConfigAvailable,
    #    SubsystemVendorID) abort the WHOLE call, so add nothing unverified.
    'DEVPKEY_PciDevice_DeviceType'
    'DEVPKEY_PciDevice_ExpressSpecVersion'
    'DEVPKEY_PciDevice_InterruptSupport'
    'DEVPKEY_PciDevice_InterruptMessageMaximum'
    'DEVPKEY_PciDevice_SriovSupport'
    'DEVPKEY_PciDevice_AcsSupport'
    'DEVPKEY_PciDevice_AcsCapabilityRegister'
    'DEVPKEY_PciDevice_AriSupport'
    'DEVPKEY_PciDevice_AtsSupport'
    'DEVPKEY_PciDevice_AtomicsSupported'
    'DEVPKEY_PciDevice_BarTypes'
    'DEVPKEY_PciDevice_SupportedLinkSubState'
    'DEVPKEY_PciDevice_SerialNumber'
    'DEVPKEY_Device_UINumber'
    'DEVPKEY_Device_LocationPaths'
    'DEVPKEY_Device_PowerData'
)

# DEVPKEY_PciDevice_DeviceType (devpkey.h DevProp_PciDevice_DeviceType_*).
# Spelled out, like the link-speed map: a mis-numbered enum is an invisible
# error. 6..13 are the bridge types; Format-PciTree labels those.
$script:DeviceTypeName = @{
    0  = 'PCI';                        1  = 'PCI-X'
    2  = 'PCIe Endpoint';              3  = 'PCIe Legacy Endpoint'
    4  = 'PCIe Root Complex Integrated Endpoint'
    5  = 'PCIe (treated as PCI)'
    6  = 'PCI bridge';                 7  = 'PCI-X bridge'
    8  = 'PCIe Root Port';             9  = 'PCIe Upstream Switch Port'
    10 = 'PCIe Downstream Switch Port'
    11 = 'PCIe-to-PCI-X bridge';       12 = 'PCI-X-to-PCIe bridge'
    13 = 'PCIe bridge (treated as PCI)'
    14 = 'PCIe Event Collector'
}
$script:BridgeDeviceTypes = @(6, 7, 8, 9, 10, 11, 12, 13)

# DEVPKEY_PciDevice_AcsSupport: 0 = present, 1 = not needed, 2 = missing.
# Verified against hardware, not assumed: on the author's laptop every
# device with raw 0 carries a populated ACS capability register (0x1f), every
# device with raw 2 has register 0 (no ACS capability), and raw 1 is the two
# root-complex integrated endpoints, which have no peer-to-peer path to
# isolate. An earlier map read 0 as "not supported", which would have told
# someone reasoning about DMA isolation the opposite of the truth; a fixture
# test pins all three values now. Rendered with the word, never a bare number.
$script:AcsSupportName = @{ 0 = 'present'; 1 = 'not needed'; 2 = 'missing' }

# DEVPKEY_PciDevice_SriovSupport is reported only for devices that carry the
# SR-IOV capability (here: the Xe iGPU), and its value is a STATUS: 0 = ok,
# non-zero = a reason virtual functions cannot be enabled. The capability is
# the key's presence; the status is its value.
$script:SriovStatusName = @{ 0 = 'ok' }

# DEVICE_POWER_STATE, as found in CM_POWER_DATA.PD_MostRecentPowerState.
$script:DevicePowerStateName = @{ 0 = $null; 1 = 'D0'; 2 = 'D1'; 3 = 'D2'; 4 = 'D3' }


function ConvertFrom-InterruptSupport {
    <#
    .SYNOPSIS
      DEVPKEY_PciDevice_InterruptSupport bitfield -> names.
    .DESCRIPTION
      1 = line-based (INTx), 2 = MSI, 4 = MSI-X. Returns a string[] in that
      order, or @() when the value is 0, or $null for $null.
    #>
    param($Value)
    if ($null -eq $Value) { return $null }
    $v = [int]$Value
    $modes = @()
    if ($v -band 1) { $modes += 'INTx' }
    if ($v -band 2) { $modes += 'MSI' }
    if ($v -band 4) { $modes += 'MSI-X' }
    return ,$modes
}


function ConvertFrom-PowerData {
    <#
    .SYNOPSIS
      The most recent D-state out of a DEVPKEY_Device_PowerData blob.
    .DESCRIPTION
      CM_POWER_DATA (cfgmgr32.h) arrives as a byte array:
        0..3   PD_Size (56 on current Windows)
        4..7   PD_MostRecentPowerState  (DEVICE_POWER_STATE: 1 = D0 .. 4 = D3)
        8..11  PD_Capabilities
        ...
      Only the state is decoded. Bounds-checked: a short or odd blob yields
      $null, never an exception -- this is the module's first binary parse and
      it runs once per device. "Most recent" is a snapshot; the README says so.
    #>
    param($Bytes)
    if ($null -eq $Bytes) { return $null }
    $b = @($Bytes)
    if ($b.Count -lt 8) { return $null }
    try {
        $state = [int]$b[4] -bor ([int]$b[5] -shl 8) -bor ([int]$b[6] -shl 16) -bor ([int]$b[7] -shl 24)
    } catch { return $null }
    if ($script:DevicePowerStateName.ContainsKey($state)) { return $script:DevicePowerStateName[$state] }
    return $null
}


function Format-DeviceSerialNumber {
    <#
    .SYNOPSIS
      A 64-bit Device Serial Number as lspci prints it: 00-11-22-33-44-55-66-77.
    #>
    param($Value)
    if ($null -eq $Value) { return $null }
    try { $u = [uint64]$Value } catch { return $null }
    $parts = foreach ($i in 7..0) { '{0:x2}' -f (($u -shr (8 * $i)) -band 0xff) }
    return ($parts -join '-')
}


# ---------------------------------------------------------------- fixtures
#
# A recorded fixture stands in for the machine: an array of entity objects
# (PNPDeviceID, Name, Service, Status, ConfigManagerErrorCode, HardwareID)
# each carrying a Bag of DEVPKEY values -- exactly what Get-PciDevice
# consumes after the two CIM calls. With one loaded, enumeration is
# deterministic, machine-independent and instant, which is how the
# interesting cases (Azure's packed bus numbers, a German LocationInfo, a
# phantom device, a switch hierarchy) get tested on every box, not just the
# one that happened to have them. Test-only: set through the module scope,
# never from the CLI.
$script:Fixture = $null
$script:LastBagError = $null

function Set-PciFixture {
    <#
    .SYNOPSIS
      Load a recorded fixture (JSON) as the device source, or -Clear it.
    #>
    param([string]$Path, [switch]$Clear)
    if ($Clear) { $script:Fixture = $null; return }
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Set-PciFixture: no such file '$Path'" }
    $raw = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8 | ConvertFrom-Json
    $entities = @()
    foreach ($e in @($raw)) {
        # Bag: PSCustomObject -> hashtable, so Get-BagValue's ContainsKey works.
        $bag = @{}
        if ($e.PSObject.Properties['Bag'] -and $null -ne $e.Bag) {
            foreach ($p in $e.Bag.PSObject.Properties) {
                if ($null -ne $p.Value -and "$($p.Value)" -ne '') { $bag[$p.Name] = $p.Value }
            }
        }
        $entities += [pscustomobject]@{
            PNPDeviceID            = $e.PNPDeviceID
            Name                   = Get-Field $e 'Name'
            Service                = Get-Field $e 'Service'
            Status                 = Get-Field $e 'Status'
            ConfigManagerErrorCode = Get-Field $e 'ConfigManagerErrorCode'
            HardwareID             = @(Get-Field $e 'HardwareID')
            Bag                    = $bag
        }
    }
    $script:Fixture = $entities
}


function Get-PciEntity {
    <#
    .SYNOPSIS
      The PCI entities to enumerate: from the machine, or from a fixture.
    .DESCRIPTION
      One projected WQL query for the PCI entities.

      The projection matters more than the WHERE: SELECT * on Win32_PnPEntity
      costs ~1.3s on a laptop and naming only the columns this module reads
      halves it, because the provider materialises far less per instance.

      The LIKE text is exactly "PCI\\VEN[_]%": two backslashes (one level of
      string escaping -- LIKE does not consume a second), and [_] because a
      bare underscore is WQL's single-character wildcard. Get this wrong and
      the query returns ZERO rows silently, rendering a machine with no PCI
      bus; a test pins the row count against a client-side -like.

      $VendorId is only ever four validated hex digits (ConvertTo-DeviceFilter),
      so interpolating it into the query is safe.
    #>
    param([string]$VendorId = '')

    if ($null -ne $script:Fixture) {
        $set = @($script:Fixture | Where-Object { $_.PNPDeviceID -like 'PCI\VEN_*' })
        if ($VendorId) { $set = @($set | Where-Object { $_.PNPDeviceID -like "PCI\VEN_${VendorId}*" }) }
        return $set
    }

    $where = 'PNPDeviceID LIKE "PCI\\VEN[_]%"'
    if ($VendorId) {
        $where = 'PNPDeviceID LIKE "PCI\\VEN[_]{0}%"' -f $VendorId
    }
    $query = 'SELECT DeviceID,PNPDeviceID,Name,Service,Status,ConfigManagerErrorCode,HardwareID ' +
             "FROM Win32_PnPEntity WHERE $where"
    # A failed query must not look like an empty machine. Under load the WMI
    # provider can refuse for a moment; with -ErrorAction SilentlyContinue
    # that rendered as "no PCI devices enumerated", exit 0. Throw instead;
    # the CLI reports it and exits 70.
    try {
        return @(Get-CimInstance -Query $query -ErrorAction Stop)
    } catch {
        throw "PCI enumeration failed: the WMI query for Win32_PnPEntity did not complete ($($_.Exception.Message)). This is a Windows/WMI error, not an empty machine -- retry, or check the Winmgmt service."
    }
}


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

    # Fixture entities carry their bag already.
    $fixtureBag = Get-Field $CimInstance 'Bag'
    if ($null -ne $fixtureBag) { return $fixtureBag }

    $bag = @{}
    try {
        $result = Invoke-CimMethod -InputObject $CimInstance `
            -MethodName GetDeviceProperties `
            -Arguments @{ devicePropertyKeys = $script:WantedKeys } `
            -ErrorAction Stop
    } catch {
        # One device failing is tolerable (an empty bag renders as "not
        # reported"); EVERY device failing is a broken fetch -- a rejected
        # DEVPKEY name, or WMI refusing -- and must not render as 24 devices
        # at ??:??.? with no link state. Remember the error; Get-PciDevice
        # throws if no bag at all came back populated.
        $script:LastBagError = $_.Exception.Message
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
    # Positional, not keyed on the English words: pci.sys localises the string
    # ("PCI-Bus 0, Geraet 2, Funktion 0" on a German system). Three integers in
    # order is the invariant; the words are not. [0-9] with length bounds, not
    # \d: .NET's \d matches every Unicode digit, which then fails the cast.
    # A device above 0x1f or a function above 7 is not a PCI address at all
    # (and -s could never match it), so such a string is treated as unusable.
    $parsed = $false
    if ($LocationInfo -and $LocationInfo -match '^[^0-9]*([0-9]{1,10})[^0-9]+([0-9]{1,5})[^0-9]+([0-9]{1,5})[^0-9]*$') {
        $raw = [int64]$Matches[1]; $dev = [int]$Matches[2]; $fun = [int]$Matches[3]
        if ($dev -le 0x1f -and $fun -le 7 -and $raw -le 0xFFFFFF) {
            $bus = [int]($raw -band 0xFF)
            $domain = [int](($raw -shr 8) -band 0xFFFF)
            $parsed = $true
        }
    }
    if ($parsed) {
        # from the location string
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
