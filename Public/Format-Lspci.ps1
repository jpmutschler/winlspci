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
        # Prefix every header line with "<ComputerName>: " -- for a stream
        # that mixes machines (Get-PciDevice -ComputerName a,b,c).
        [switch]$ShowComputer
    )
    process {
        foreach ($d in @($Device)) {
            $hostPrefix = ''
            if ($ShowComputer) {
                $cn = ConvertTo-SafeText (Get-Field $d 'ComputerName')
                if ($cn) { $hostPrefix = "${cn}: " }
            }
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
            $className = ConvertTo-SafeText (Get-Field $d 'ClassName')   # pci.ids text, -i makes it user-supplied
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
            # lspci -v appends "(prog-if 02 [NVM Express])" when the database
            # names the programming interface.
            $progIfPart = ''
            if ($Verbosity -ge 1) {
                $pi = Get-Field $d 'ProgIf'
                $piName = ConvertTo-SafeText (Get-Field $d 'ProgIfName')
                if ($null -ne $pi -and $piName) { $progIfPart = (' (prog-if {0:x2} [{1}])' -f [int]$pi, $piName) }
            }
            Write-Output ("{5}{0} {1}: {2}{3}{4}" -f (Get-Field $d 'Slot'), $classPart, $ident, $rev, $progIfPart, $hostPrefix)

            if ($Verbosity -ge 1) {
                # lspci prints the chassis slot right under the header line.
                $physSlot = Get-Field $d 'PhysicalSlot'
                if ($null -ne $physSlot) { Write-Output "        Physical Slot: $(ConvertTo-SafeText $physSlot)" }

                $powerState = Get-Field $d 'PowerState'
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
                    if ($reasons.Count -gt 0) { $line += "  <-- DOWNTRAINED ($($reasons -join ', '))" }
                    Write-Output $line
                    # A downtrained link on a device in D1-D3 is almost always
                    # idle link power management. Say so, on its own line under
                    # the flag, rather than leaving the reader to guess -- and
                    # only when the state is actually known and not D0.
                    # "may be", not "is": the D-state is a snapshot, and a stale
                    # D3 must not talk anyone out of looking at a real downtrain.
                    if ($reasons.Count -gt 0 -and $powerState -and $powerState -ne 'D0') {
                        Write-Output "                (device is in ${powerState}: may be idle link power management rather than a fault)"
                    }
                } else {
                    $why = 'not reported by this device'
                    $typeRaw = Get-Field $d 'DeviceTypeRaw'
                    if ($null -ne $typeRaw -and [int]$typeRaw -eq 4) { $why = 'root-complex integrated endpoint: no link' }
                    elseif ($null -ne $typeRaw -and [int]$typeRaw -in 5, 13) { $why = 'Windows treats this PCIe device as conventional PCI: no link reported' }
                    elseif ($null -ne $typeRaw -and [int]$typeRaw -in 0, 1, 6, 7) { $why = 'Windows reports this as a conventional PCI device: no PCIe link' }
                    # A bridge's link IS its child's link; say whose it is.
                    $dsSlot = Get-Field $d 'DownstreamSlot'
                    if ($dsSlot) {
                        $dsW = Get-Field $d 'DownstreamLinkWidth'; $dsWText = 'x?'; if ($null -ne $dsW) { $dsWText = "x$dsW" }
                        $why += " (downstream $dsSlot reports $(Get-Field $d 'DownstreamLinkSpeed') $dsWText)"
                    }
                    Write-Output "        LnkSta: $why"
                }

                $typeName = Get-Field $d 'DeviceType'
                if ($typeName) {
                    $typeLine = "        Type: $typeName"
                    $specVer = Get-Field $d 'ExpressSpecVersion'
                    if ($null -ne $specVer) { $typeLine += " (PCIe capability v$specVer)" }
                    Write-Output $typeLine
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
                # 0000:0000 is "no subsystem", not a subsystem called 0000.
                # lspci omits the line; so do we, rather than inventing
                # "Vendor 0000" for it.
                if ($subVen -and $subDev -and -not ($subVen -eq '0000' -and $subDev -eq '0000')) {
                    # "Subsystem: SK hynix Gold P31 [1c5c:174a]" when pci.ids
                    # names the pair; the vendor name alone when it does not.
                    $subVenName = ConvertTo-SafeText (Get-Field $d 'SubsystemVendorName')
                    if (-not $subVenName) { $subVenName = Get-PciVendorName $subVen }
                    if (-not $subVenName) { $subVenName = "Vendor $subVen" }
                    $subName = ConvertTo-SafeText (Get-Field $d 'SubsystemName')
                    $subText = $subVenName
                    if ($subName) { $subText = "$subVenName $subName" }
                    Write-Output "        Subsystem: $subText [${subVen}:${subDev}]"
                }
                $mps = Get-Field $d 'MaxPayloadSize'
                if ($null -ne $mps) {
                    Write-Output ("        DevCtl: MPS {0} bytes (max {1}), MaxReadReq {2} bytes" -f `
                        $mps, (Get-Field $d 'MaxPayloadSizeSupported'), (Get-Field $d 'MaxReadRequestSize'))
                }
                $numa = Get-Field $d 'NumaNode'
                if ($null -ne $numa) { Write-Output "        NUMA node: $numa" }

                # Capability PRESENCE, as one line -- what lspci's capability
                # list would show minus the contents, which need config space.
                # Omitted entirely when Windows reported none of the keys;
                # "none reported" when it reported them all as absent.
                $caps = @()
                $anyReported = $false
                foreach ($pair in @(
                        @('AerCapable', 'AER'), @('MsiSupported', 'MSI'), @('MsixSupported', 'MSI-X'),
                        @('SriovCapable', 'SR-IOV'), @('AriCapable', 'ARI'), @('AtsCapable', 'ATS'),
                        @('AtomicsCapable', 'AtomicOps'))) {
                    $v = Get-Field $d $pair[0]
                    if ($null -eq $v) { continue }
                    $anyReported = $true
                    if ($v) {
                        $label = $pair[1]
                        if ($pair[0] -eq 'MsixSupported' -or ($pair[0] -eq 'MsiSupported' -and -not (Get-Field $d 'MsixSupported'))) {
                            $vec = Get-Field $d 'InterruptVectorsMax'
                            if ($null -ne $vec) {
                                if ([int]$vec -eq 1) { $label += ' (1 vector)' } else { $label += " ($vec vectors)" }
                            }
                        }
                        if ($pair[0] -eq 'SriovCapable') {
                            $st = Get-Field $d 'SriovStatus'
                            if ($st -and $st -ne 'ok') { $label += " ($st)" }
                        }
                        $caps += $label
                    }
                }
                if ($anyReported) {
                    if ($caps.Count -gt 0) { Write-Output "        Capabilities: $($caps -join ', ')" }
                    else { Write-Output '        Capabilities: none reported' }
                }
                # ACS is a statement about the PORT, not a capability the
                # device "has", and "missing" must not sit in a list of things
                # that are present -- its own line. An endpoint with no ACS is
                # the normal case and says nothing about isolation (that is
                # decided by the ports above it), so "missing" is shown for
                # bridges only; "present" and "not needed" are always shown.
                $acs = Get-Field $d 'AcsSupport'
                $isBridge = Get-Field $d 'IsBridge'
                if ($acs -and ($acs -ne 'missing' -or $isBridge -or $null -eq $isBridge)) {
                    $acsLine = "        ACS: $acs"
                    if ($acs -eq 'missing') { $acsLine += ' (Windows expected ACS on this port and found none; matters for DMA isolation / IOMMU grouping)' }
                    Write-Output $acsLine
                }
                $serial = Get-Field $d 'SerialNumber'
                if ($serial) {
                    $serialLine = "        Device Serial Number $serial"
                    if ($serial -eq '00-00-00-00-00-00-00-00') { $serialLine += ' (capability present, not populated)' }
                    Write-Output $serialLine
                }
                if ($powerState) { Write-Output "        Power: $powerState (most recent state Windows recorded)" }
                # Firmware text, so sanitised like every other free string.
                $locPath = ConvertTo-SafeText (Get-Field $d 'LocationPath')
                if ($locPath) { Write-Output "        Location: $locPath" }
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
                    if ($v -is [array]) { $v = ($v -join ', ') }
                    if ($null -eq $v -or "$v" -eq '') { $v = '<not reported>' }
                    # The dump is the one place every raw string reaches the
                    # console; sanitise here too or -vvv bypasses the rule.
                    Write-Output ("        {0,-24} {1}" -f $prop.Name, (ConvertTo-SafeText $v))
                }
                Write-Output ('        NOT AVAILABLE without a kernel driver: ' +
                              'config-space dump, capability CONTENTS (presence only above), ' +
                              'ASPM state, AER registers, LTR, DPC')
            }
        }
    }
}
