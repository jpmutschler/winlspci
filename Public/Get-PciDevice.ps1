# The shape of a WinLspci.PciDevice, in output order. Kept as data so
# Get-PciAttributeName can answer without enumerating the machine (it used to
# run a full ~2s enumeration to ask one object what its fields were called),
# and pinned by a test that compares it against a live object.
$script:AttributeNames = @(
    'Slot', 'Domain', 'VendorId', 'DeviceId', 'SubsystemVendorId', 'SubsystemId', 'Revision',
    'VendorName', 'DeviceName', 'ClassCode', 'ClassName', 'ProgIf',
    'FriendlyName', 'Driver', 'DriverVersion', 'Status', 'Problem', 'NumaNode',
    'LinkStateReported', 'LinkSpeed', 'LinkSpeedRaw', 'LinkWidth',
    'MaxLinkSpeed', 'MaxLinkSpeedRaw', 'MaxLinkWidth', 'Downtrained',
    'MaxPayloadSize', 'MaxPayloadSizeSupported', 'MaxReadRequestSize',
    'AerCapable',
    'DeviceType', 'DeviceTypeRaw', 'IsBridge', 'ExpressSpecVersion',
    'InterruptModes', 'InterruptSupportRaw', 'InterruptVectorsMax', 'MsiSupported', 'MsixSupported',
    'SriovCapable', 'SriovStatus', 'SriovSupportRaw', 'AcsSupport', 'AcsSupportRaw', 'AcsCapabilityRegister',
    'AriCapable', 'AtsCapable', 'AtomicsCapable', 'BarTypesRaw', 'LinkSubStateRaw',
    'PhysicalSlot', 'LocationPath', 'SerialNumber', 'SerialNumberRaw', 'PowerState',
    'ParentInstanceId', 'InstanceId', 'Present'
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

    # One projected WQL query for the PCI entities (Get-PciEntity), then the
    # CIM property method per device (~30ms each), so a full listing is ~1.7s
    # rather than the ~36s the Get-PnpDevice / Get-PnpDeviceProperty pairing
    # took. Under a test fixture both come from the recording instead.
    $entities = @(Get-PciEntity -VendorId $filterVendor)

    $script:LastBagError = $null
    $bagsFetched = 0
    $bagsPopulated = 0

    foreach ($pnp in $entities) {
        $instanceId = $pnp.PNPDeviceID
        if ($instanceId -notmatch 'VEN_([0-9A-Fa-f]{4})&DEV_([0-9A-Fa-f]{4})') { continue }
        # Cheap pre-filter: a Status of 'Unknown' is a phantom, and it costs a
        # CIM round trip (~35ms) to fetch a bag we would then discard. The
        # authoritative IsPresent check below still runs for everything else.
        if (-not $IncludeAbsent -and "$($pnp.Status)" -eq 'Unknown') { continue }
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
        $bagsFetched++
        if ($bag.Count -gt 0) { $bagsPopulated++ }
        # Every bag empty AND a CIM error seen: the property fetch is broken
        # (a rejected DEVPKEY, WMI refusing). Say so rather than listing
        # devices with no slot and no link state. Checked after the first few
        # so a single bad device does not trip it.
        if ($bagsFetched -ge 3 -and $bagsPopulated -eq 0 -and $script:LastBagError) {
            throw "PCI enumeration failed: the property fetch (GetDeviceProperties) failed for every device ($($script:LastBagError)). Either WMI is refusing, or a DEVPKEY name the module asks for is not valid on this Windows build."
        }

        # Presence: DEVPKEY_Device_IsPresent is explicit; the older
        # Status -eq 'Unknown' heuristic is the fallback. A phantom device
        # (unplugged card Windows still remembers) is excluded unless asked
        # for, and its last-known values are then historical, not live.
        $isPresent = Get-BagValue $bag 'DEVPKEY_Device_IsPresent'
        if ($null -eq $isPresent) { $isPresent = ($pnp.Status -ne 'Unknown') }
        $isPresent = [bool]$isPresent
        if (-not $IncludeAbsent -and -not $isPresent) { continue }

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

        $location = ConvertTo-Bdf `
            (Get-BagValue $bag 'DEVPKEY_Device_LocationInfo') `
            (Get-BagValue $bag 'DEVPKEY_Device_BusNumber') `
            (Get-BagValue $bag 'DEVPKEY_Device_Address')
        $bdf = $location.Slot

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

        # -- type, capability presence, location, power (all $null when absent)
        $typeRaw = Get-BagValue $bag 'DEVPKEY_PciDevice_DeviceType'
        $typeName = $null; $isBridge = $null
        if ($null -ne $typeRaw) {
            if ($script:DeviceTypeName.ContainsKey([int]$typeRaw)) { $typeName = $script:DeviceTypeName[[int]$typeRaw] }
            $isBridge = ($script:BridgeDeviceTypes -contains [int]$typeRaw)
        }
        $intRaw = Get-BagValue $bag 'DEVPKEY_PciDevice_InterruptSupport'
        $intList = ConvertFrom-InterruptSupport $intRaw
        $intModes = $null; $msi = $null; $msix = $null
        if ($null -ne $intList) {
            $msi = ($intList -contains 'MSI'); $msix = ($intList -contains 'MSI-X')
            # A string, not an array: every consumer (-Delimited, -Match, -vvv)
            # then sees "INTx,MSI,MSI-X"; 'none' keeps a reported 0 distinct
            # from absent.
            $intModes = 'none'
            if ($intList.Count -gt 0) { $intModes = ($intList -join ',') }
        }
        # The key is reported only for devices with the SR-IOV capability; its
        # value is a status (0 = ok). Capable = key present, never value != 0.
        $sriovRaw = Get-BagValue $bag 'DEVPKEY_PciDevice_SriovSupport'
        $sriov = $null; $sriovStatus = $null
        if ($null -ne $sriovRaw) {
            $sriov = $true
            if ($script:SriovStatusName.ContainsKey([int]$sriovRaw)) { $sriovStatus = $script:SriovStatusName[[int]$sriovRaw] }
            else { $sriovStatus = "status $sriovRaw" }
        }
        $acsRaw = Get-BagValue $bag 'DEVPKEY_PciDevice_AcsSupport'
        $acsText = $null
        if ($null -ne $acsRaw -and $script:AcsSupportName.ContainsKey([int]$acsRaw)) { $acsText = $script:AcsSupportName[[int]$acsRaw] }
        $toBool = { param($v) if ($null -eq $v) { $null } else { [bool]$v } }
        $powerState = ConvertFrom-PowerData (Get-BagValue $bag 'DEVPKEY_Device_PowerData')
        $locPaths = Get-BagValue $bag 'DEVPKEY_Device_LocationPaths'
        $locPath = $null
        if ($null -ne $locPaths) { $locPath = "$(@($locPaths)[0])" }
        $serialRaw = Get-BagValue $bag 'DEVPKEY_PciDevice_SerialNumber'

        [pscustomobject]@{
            PSTypeName       = 'WinLspci.PciDevice'
            Slot             = $bdf
            # PCI segment. 0 on ordinary machines; Hyper-V/Azure SR-IOV VFs
            # carry it in the upper bits of Windows' bus number, and then the
            # Slot shows it too (556f:00:02.0), as lspci does.
            Domain           = $location.Domain
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
            # What kind of device (root port, switch port, endpoint...). The
            # most useful single byte Windows exposes for topology work.
            DeviceType       = $typeName
            DeviceTypeRaw    = $typeRaw
            IsBridge         = $isBridge
            ExpressSpecVersion = Get-BagValue $bag 'DEVPKEY_PciDevice_ExpressSpecVersion'
            # Capability PRESENCE, not contents: that still needs config space.
            InterruptModes   = $intModes
            InterruptSupportRaw = $intRaw
            InterruptVectorsMax = Get-BagValue $bag 'DEVPKEY_PciDevice_InterruptMessageMaximum'
            MsiSupported     = $msi
            MsixSupported    = $msix
            SriovCapable     = $sriov
            SriovStatus      = $sriovStatus
            SriovSupportRaw  = $sriovRaw
            AcsSupport       = $acsText
            AcsSupportRaw    = $acsRaw
            AcsCapabilityRegister = Get-BagValue $bag 'DEVPKEY_PciDevice_AcsCapabilityRegister'
            AriCapable       = & $toBool (Get-BagValue $bag 'DEVPKEY_PciDevice_AriSupport')
            AtsCapable       = & $toBool (Get-BagValue $bag 'DEVPKEY_PciDevice_AtsSupport')
            AtomicsCapable   = & $toBool (Get-BagValue $bag 'DEVPKEY_PciDevice_AtomicsSupported')
            BarTypesRaw      = Get-BagValue $bag 'DEVPKEY_PciDevice_BarTypes'
            LinkSubStateRaw  = Get-BagValue $bag 'DEVPKEY_PciDevice_SupportedLinkSubState'
            # Where it is: chassis slot number (lspci "Physical Slot") and the
            # firmware location path.
            PhysicalSlot     = Get-BagValue $bag 'DEVPKEY_Device_UINumber'
            LocationPath     = $locPath
            SerialNumber     = Format-DeviceSerialNumber $serialRaw
            SerialNumberRaw  = $serialRaw
            # Most recent D-state. D3 next to DOWNTRAINED usually means idle
            # link power management, not a fault.
            PowerState       = $powerState
            ParentInstanceId = Get-BagValue $bag 'DEVPKEY_Device_Parent'
            InstanceId       = $instanceId
            Present          = $isPresent
        }
    }

    # Fewer than three devices and all of them failed: same verdict.
    if ($bagsFetched -gt 0 -and $bagsPopulated -eq 0 -and $script:LastBagError) {
        throw "PCI enumeration failed: the property fetch (GetDeviceProperties) failed for every device ($($script:LastBagError)). Either WMI is refusing, or a DEVPKEY name the module asks for is not valid on this Windows build."
    }
}
