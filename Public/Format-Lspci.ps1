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
