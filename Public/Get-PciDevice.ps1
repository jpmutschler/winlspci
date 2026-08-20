# The shape of a WinLspci.PciDevice, in output order. Kept as data so
# Get-PciAttributeName can answer without enumerating the machine (it used to
# run a full ~2s enumeration to ask one object what its fields were called),
# and pinned by a test that compares it against a live object.
$script:AttributeNames = @(
    'Slot', 'Domain', 'VendorId', 'DeviceId', 'SubsystemVendorId', 'SubsystemId',
    'SubsystemVendorName', 'SubsystemName', 'Revision',
    'VendorName', 'DeviceName', 'ClassCode', 'ClassName', 'ProgIf', 'ProgIfName',
    'FriendlyName', 'Driver', 'DriverVersion', 'Status', 'Problem', 'NumaNode',
    'LinkStateReported', 'LinkSpeed', 'LinkSpeedRaw', 'LinkWidth',
    'MaxLinkSpeed', 'MaxLinkSpeedRaw', 'MaxLinkWidth', 'Downtrained',
    'DownstreamSlot', 'DownstreamLinkSpeed', 'DownstreamLinkWidth',
    'MaxPayloadSize', 'MaxPayloadSizeSupported', 'MaxReadRequestSize',
    'AerCapable',
    'DeviceType', 'DeviceTypeRaw', 'IsBridge', 'ExpressSpecVersion',
    'InterruptModes', 'InterruptSupportRaw', 'InterruptVectorsMax', 'MsiSupported', 'MsixSupported',
    'SriovCapable', 'SriovStatus', 'SriovSupportRaw', 'AcsSupport', 'AcsSupportRaw', 'AcsCapabilityRegister',
    'AriCapable', 'AtsCapable', 'AtomicsCapable', 'BarTypesRaw', 'LinkSubStateRaw',
    'PhysicalSlot', 'LocationPath', 'SerialNumber', 'SerialNumberRaw', 'PowerState',
    'ParentInstanceId', 'InstanceId', 'ComputerName', 'Present'
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

    .PARAMETER ComputerName
      Enumerate these machines instead of this one (one CIM session each,
      WinRM; -Credential if needed). A node that cannot be reached is
      reported with a warning and skipped; if none can, the call fails
      rather than returning an empty list that looks like "no devices".
      Every object carries ComputerName, so a fleet can be sorted, diffed
      and filtered in one pipeline.
    .PARAMETER CimSession
      Existing CIM sessions to enumerate through (DCOM or WSMan; you manage
      their lifetime).

    .EXAMPLE
      Get-PciDevice -Device '11f8:'
    .EXAMPLE
      Get-PciDevice | Where-Object Downtrained
    .EXAMPLE
      Get-PciDevice -ComputerName node1, node2, node3 | Where-Object Downtrained |
        Select-Object ComputerName, Slot, LinkSpeed, MaxLinkSpeed
    #>
    [CmdletBinding()]
    param(
        [Alias('d')][string]$Device = '',
        [Alias('s')][string]$Slot = '',
        [switch]$IncludeAbsent,
        # Fetch property bags one device at a time instead of in parallel.
        # Diagnostic: the output is identical; only the timing differs.
        [switch]$Serial,
        [string[]]$ComputerName,
        [PSCredential]$Credential,
        [CimSession[]]$CimSession
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
    # Where to look: this machine (or a fixture standing in for it), the
    # caller's sessions, and/or sessions opened here for -ComputerName.
    # The source list is validated before it is used: a blank name (a config
    # variable that came back empty) must not fall through to "this machine"
    # and read as if the node had answered; a name or session given twice
    # must not double every device (which would also switch off the
    # downstream-link pass, since no bridge would have exactly one child).
    $remoteRequested = $PSBoundParameters.ContainsKey('ComputerName') -or $PSBoundParameters.ContainsKey('CimSession')
    $sources = @()
    $ownedSessions = @()
    $seenSource = @{}
    foreach ($s in @($CimSession)) {
        if ($null -eq $s) { continue }
        $key = "session:$($s.InstanceId)"
        if ($seenSource.ContainsKey($key)) { continue }
        $seenSource[$key] = $true
        $sources += @{ Name = "$($s.ComputerName)"; Session = $s }
    }
    # Only walk the names if the parameter was actually given: an unbound
    # [string[]] is $null, and @($null) iterates once on PowerShell 7 (not on
    # 5.1), which turned every plain Get-PciDevice into "empty name" there.
    # An EXPLICIT $null or '' is still an error.
    $rawNames = @()
    if ($PSBoundParameters.ContainsKey('ComputerName')) { $rawNames = @($ComputerName) }
    $names = @()
    foreach ($c in $rawNames) {
        $n = "$c".Trim()
        if ($n -eq '') { throw "Get-PciDevice: -ComputerName contains an empty name; refusing to fall back to the local machine silently." }
        if ($seenSource.ContainsKey("name:$($n.ToLowerInvariant())")) { continue }
        $seenSource["name:$($n.ToLowerInvariant())"] = $true
        $names += $n
    }
    foreach ($c in $names) {
        try {
            $opts = @{ ComputerName = $c; ErrorAction = 'Stop' }
            if ($Credential) { $opts['Credential'] = $Credential }
            $s = New-CimSession @opts
            $ownedSessions += $s
            $sources += @{ Name = $c; Session = $s }
        } catch {
            # One unreachable node must not empty the whole result silently.
            Write-Warning "winlspci: cannot reach '$c': $($_.Exception.Message.Split([char]10)[0])"
        }
    }
    if ($remoteRequested -and $sources.Count -eq 0) {
        throw "PCI enumeration failed: none of the requested computers could be reached ($($names -join ', '))."
    }
    if ($sources.Count -eq 0) { $sources = @(@{ Name = $env:COMPUTERNAME; Session = $null }) }

    $script:LastBagError = $null
    $built = @()

    # -d / -s are DISPLAY filters applied at the very end, never a reduction
    # of what is enumerated: a bridge's downstream link comes from its child,
    # and `lspci -s <port> -v` must show it even though the child is not
    # selected. The cost (bags for every device on a filtered query; measured
    # +0.6s on `-d <vendor matching one device>`, a wash or a win elsewhere)
    # buys an answer that does not change with the selector.
    #
    # Before anyone tries a "fetch only the selected devices and their
    # children" optimisation: it can never apply to -s, because the slot
    # itself comes from DEVPKEY_Device_LocationInfo INSIDE the bag -- you
    # cannot know which devices match a slot without fetching them all. For
    # -d it is possible (DEVPKEY_Device_Children is valid), but two fetch
    # phases cost two pool setups and measured no faster at 24 devices.
    # Revisit only for 300-device servers.
    try {
    foreach ($source in $sources) {
    $entities = @(Get-PciEntity -CimSession $source.Session)
    $sourceName = $source.Name
    # Per source: a node whose property fetch fails for everything must be
    # reported as such, not hidden behind another node's successes.
    $script:LastBagError = $null
    $bagsFetched = 0
    $bagsPopulated = 0
    $sourceBuilt = @()

    # Pass 1: decide which entities are candidates (id shape, phantom
    # pre-filter) WITHOUT touching CIM, so pass 2 can fetch every candidate's
    # bag in one parallel call.
    $candidates = @()
    foreach ($pnp in $entities) {
        $instanceId = $pnp.PNPDeviceID
        if ($instanceId -notmatch 'VEN_([0-9A-Fa-f]{4})&DEV_([0-9A-Fa-f]{4})') { continue }
        # Cheap pre-filter: a Status of 'Unknown' is a phantom, and it costs a
        # CIM round trip (~35ms) to fetch a bag we would then discard. The
        # authoritative IsPresent check below still runs for everything else.
        if (-not $IncludeAbsent -and "$($pnp.Status)" -eq 'Unknown') { continue }
        $candidates += $pnp
    }

    # Pass 2: the bags. Fixture entities carry theirs; live local entities go
    # through the RunspacePool (~1.1s -> ~0.4s for 24 devices at 34 keys).
    # Remote instances stay serial: Invoke-CimMethod routes each through the
    # session it came from, and sessions are not shared across runspaces.
    $bagSet = @{}
    $live = @($candidates | Where-Object { $null -eq (Get-Field $_ 'Bag') })
    if ($live.Count -gt 0) {
        if ($Serial -or $null -ne $source.Session) { foreach ($i in $live) { $bagSet["$($i.PNPDeviceID)"] = Get-DevicePropertyBag $i } }
        else { $bagSet = Get-DevicePropertyBagSet $live }
    }

    # Pass 3: build the objects. Results are collected so a final pass can
    # give bridges their downstream link (see below) before anything is
    # emitted.
    foreach ($pnp in $candidates) {
        $instanceId = $pnp.PNPDeviceID
        $null = $instanceId -match 'VEN_([0-9A-Fa-f]{4})&DEV_([0-9A-Fa-f]{4})'
        $ven = $Matches[1].ToLower()
        $dev = $Matches[2].ToLower()

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

        $bag = Get-Field $pnp 'Bag'
        if ($null -eq $bag) {
            $bag = @{}
            if ($bagSet.ContainsKey("$instanceId")) { $bag = $bagSet["$instanceId"] }
        }
        $bagsFetched++
        if ($bag.Count -gt 0) { $bagsPopulated++ }
        # Every bag empty AND a CIM error seen: the property fetch is broken
        # (a rejected DEVPKEY, WMI refusing). Say so rather than listing
        # devices with no slot and no link state. Checked after the first few
        # so a single bad device does not trip it; evaluated per source.
        if ($bagsFetched -ge 3 -and $bagsPopulated -eq 0 -and $script:LastBagError) {
            $msg = "PCI enumeration failed on ${sourceName}: the property fetch (GetDeviceProperties) failed for every device ($($script:LastBagError)). Either WMI is refusing, or a DEVPKEY name the module asks for is not valid on this Windows build."
            if ($sources.Count -eq 1) { throw $msg }
            Write-Warning "winlspci: $msg -- dropping that node's rows"
            $sourceBuilt = @(); $bagsFetched = -1   # mark: abandon this source
            break
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

        $location = ConvertTo-Bdf `
            (Get-BagValue $bag 'DEVPKEY_Device_LocationInfo') `
            (Get-BagValue $bag 'DEVPKEY_Device_BusNumber') `
            (Get-BagValue $bag 'DEVPKEY_Device_Address')
        $bdf = $location.Slot

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

        $className = $null; $progIfName = $null
        if ($null -ne $baseClass) {
            if ($null -ne $subClass) {
                $className = Get-PciClassName -BaseClass ([int]$baseClass) -SubClass ([int]$subClass)
                # pci.ids names some prog-ifs ("NVM Express", "XHCI"); lspci
                # prints them as "(prog-if 02 [NVM Express])". Only when the
                # database has a distinct entry -- never the subclass name twice.
                if ($null -ne $progIf) {
                    $p = Get-PciClassName -BaseClass ([int]$baseClass) -SubClass ([int]$subClass) -ProgIf ([int]$progIf)
                    if ($p -ne $className) { $progIfName = $p }
                }
            } else {
                $className = Get-PciClassName -BaseClass ([int]$baseClass)
            }
        }
        $subVenName = $null; $subName = $null
        if ($subVen) { $subVenName = Get-PciVendorName $subVen }
        if ($subVen -and $subDev) { $subName = Get-PciSubsystemName $ven $dev $subVen $subDev }

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

        $sourceBuilt += [pscustomobject]@{
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
            SubsystemVendorName = $subVenName
            SubsystemName    = $subName
            Revision         = $rev
            VendorName       = Get-PciVendorName $ven
            DeviceName       = Get-PciDeviceName $ven $dev
            ClassCode        = $classHex
            ClassName        = $className
            ProgIf           = $progIf
            ProgIfName       = $progIfName
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
            # Filled in by the final pass: a bridge reports no link state of
            # its own on Windows, but its single child does. Never copied into
            # LinkSpeed/LinkWidth -- those stay "this device's own report".
            DownstreamSlot   = $null
            DownstreamLinkSpeed = $null
            DownstreamLinkWidth = $null
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
            # Which machine: this one (or the fixture standing in for it), or
            # the remote node. Present on every object so a fleet pipeline can
            # group by it.
            ComputerName     = $sourceName
            Present          = $isPresent
        }
    }
    # Fewer than three devices on this source and all of them failed: same
    # verdict as above.
    if ($bagsFetched -gt 0 -and $bagsPopulated -eq 0 -and $script:LastBagError) {
        $msg = "PCI enumeration failed on ${sourceName}: the property fetch (GetDeviceProperties) failed for every device ($($script:LastBagError)). Either WMI is refusing, or a DEVPKEY name the module asks for is not valid on this Windows build."
        if ($sources.Count -eq 1) { throw $msg }
        Write-Warning "winlspci: $msg -- dropping that node's rows"
        $sourceBuilt = @()
    }
    $built += $sourceBuilt
    }   # foreach source
    } finally {
        foreach ($s in $ownedSessions) { Remove-CimSession $s -ErrorAction SilentlyContinue }
    }

    # Final pass: a bridge with exactly one child that reports link state
    # gets that child's negotiated link as Downstream*, which is what lspci
    # shows as the port's own LnkSta. Marked as the child's, never merged.
    # Keyed by machine + instance id: two nodes can share an instance id.
    $byId = @{}
    foreach ($d in $built) { if ($d.InstanceId) { $byId["$($d.ComputerName)|$($d.InstanceId)"] = $d } }
    $kids = @{}
    foreach ($d in $built) {
        $p = "$($d.ComputerName)|$($d.ParentInstanceId)"
        if ($d.ParentInstanceId -and $byId.ContainsKey($p)) {
            if (-not $kids.ContainsKey($p)) { $kids[$p] = @() }
            $kids[$p] += $d
        }
    }
    foreach ($d in $built) {
        if (-not $d.IsBridge) { continue }
        $id = "$($d.ComputerName)|$($d.InstanceId)"
        if (-not $kids.ContainsKey($id)) { continue }
        $linked = @($kids[$id] | Where-Object { $_.LinkStateReported })
        if ($linked.Count -eq 1) {
            $d.DownstreamSlot = $linked[0].Slot
            $d.DownstreamLinkSpeed = $linked[0].LinkSpeed
            $d.DownstreamLinkWidth = $linked[0].LinkWidth
        }
    }

    # Now the selectors, on complete objects.
    foreach ($d in $built) {
        if ($filterVendor -and $d.VendorId -ne $filterVendor) { continue }
        if ($filterDevice -and $d.DeviceId -ne $filterDevice) { continue }
        if ($filterClass -and (-not $d.ClassCode -or -not $d.ClassCode.StartsWith($filterClass))) { continue }
        if (-not (Test-SlotMatch $d.Slot $slotFilter)) { continue }
        $d
    }
}
