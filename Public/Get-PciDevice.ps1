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
            ParentInstanceId = Get-BagValue $bag 'DEVPKEY_Device_Parent'
            InstanceId       = $instanceId
            Present          = ($pnp.Status -ne 'Unknown')
        }
    }
}
