function Format-PciMachine {
    <#
    .SYNOPSIS
      lspci's machine-readable forms: -m (one quoted line per device) and
      -mm (one "Key:\tValue" record per device, blank-line separated).

    .DESCRIPTION
      Unlike -Delimited, these forms ARE parsed by other tools, so values are
      quoted and an embedded quote is escaped the way lspci does it
      (backslash before the quote; pciutils prints \" ). Control characters
      are folded to spaces as everywhere else.

      -m:  Slot "Class" "Vendor" "Device" -rXX -pXX "SVendor" "SDevice"
      -mm: Slot:\t01:00.0
           Class:\tNon-Volatile memory controller
           Vendor:\tSK hynix
           ...
           (blank line)

      Names fall back to the ids when pci.ids has no entry, as lspci prints
      "Device 174a" -- here "Device 174a" / "Vendor 1c5c" to match the rest
      of this tool. -n / -nn are honoured the same way as Format-Lspci.

    .PARAMETER Mode
      1 = -m (single line), 2 = -mm (record). Default 2.
    .PARAMETER Numeric
      0 names only, 1 ids only, 2 names with ids.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]$Device,
        [ValidateSet(1, 2)][int]$Mode = 2,
        [int]$Numeric = 0
    )
    process {
        foreach ($d in @($Device)) {
            $vendorId = "$(Get-Field $d 'VendorId')"
            $deviceId = "$(Get-Field $d 'DeviceId')"
            $classCode = Get-Field $d 'ClassCode'
            if (-not $classCode) { $classCode = '????' }

            $vendor = ConvertTo-SafeText (Get-Field $d 'VendorName')
            $name   = ConvertTo-SafeText (Get-Field $d 'DeviceName')
            $class  = ConvertTo-SafeText (Get-Field $d 'ClassName')
            if (-not $vendor) { $vendor = "Vendor $vendorId" }
            if (-not $name)   { $name = ConvertTo-SafeText (Get-Field $d 'FriendlyName') }
            if (-not $name)   { $name = "Device $deviceId" }
            if (-not $class)  { $class = 'Unknown class' }

            $subVen = "$(Get-Field $d 'SubsystemVendorId')"
            $subDev = "$(Get-Field $d 'SubsystemId')"
            # 0000:0000 is "no subsystem": lspci prints "" "" there, not a
            # vendor called 0000 -- the same rule as Format-Lspci.
            if ($subVen -eq '0000' -and $subDev -eq '0000') { $subVen = ''; $subDev = '' }
            $subVendorName = ConvertTo-SafeText (Get-Field $d 'SubsystemVendorName')
            $subDeviceName = ConvertTo-SafeText (Get-Field $d 'SubsystemName')
            if ($subVen -and -not $subVendorName) { $subVendorName = "Vendor $subVen" }
            if ($subDev -and -not $subDeviceName) { $subDeviceName = "Device $subDev" }
            if (-not $subVen) { $subVendorName = '' }
            if (-not $subDev) { $subDeviceName = '' }

            switch ($Numeric) {
                1 {
                    $class = $classCode; $vendor = $vendorId; $name = $deviceId
                    $subVendorName = $subVen; $subDeviceName = $subDev
                }
                2 {
                    $class = "$class [$classCode]"; $vendor = "$vendor [$vendorId]"; $name = "$name [$deviceId]"
                    if ($subVen) { $subVendorName = "$subVendorName [$subVen]" }
                    if ($subDev) { $subDeviceName = "$subDeviceName [$subDev]" }
                }
            }

            # pciutils prints -rXX / -pXX only when non-zero; a parser written
            # against lspci expects that, so -m follows it (-vv keeps the
            # absent-vs-zero distinction where a human reads it).
            $rev = Get-Field $d 'Revision'
            if ($rev -and ([Convert]::ToInt32("$rev", 16) -eq 0)) { $rev = $null }
            $progIf = Get-Field $d 'ProgIf'
            if ($null -ne $progIf -and [int]$progIf -eq 0) { $progIf = $null }
            $slot = "$(Get-Field $d 'Slot')"
            $driver = ConvertTo-SafeText (Get-Field $d 'Driver')

            if ($Mode -eq 1) {
                $q = { param($s) '"' + ("$s" -replace '\\', '\\' -replace '"', '\"') + '"' }
                $line = "$slot $(& $q $class) $(& $q $vendor) $(& $q $name)"
                if ($rev) { $line += " -r$rev" }
                if ($null -ne $progIf) { $line += (' -p{0:x2}' -f [int]$progIf) }
                # lspci prints the subsystem pair always; empty quotes when none.
                $line += " $(& $q $subVendorName) $(& $q $subDeviceName)"
                Write-Output $line
            } else {
                Write-Output "Slot:`t$slot"
                Write-Output "Class:`t$class"
                Write-Output "Vendor:`t$vendor"
                Write-Output "Device:`t$name"
                if ($subVen -or $subDev) {
                    Write-Output "SVendor:`t$subVendorName"
                    Write-Output "SDevice:`t$subDeviceName"
                }
                $physSlot = Get-Field $d 'PhysicalSlot'
                if ($null -ne $physSlot) { Write-Output "PhySlot:`t$physSlot" }
                if ($rev) { Write-Output "Rev:`t$rev" }
                if ($null -ne $progIf) { Write-Output ("ProgIf:`t{0:x2}" -f [int]$progIf) }
                if ($driver) { Write-Output "Driver:`t$driver" }
                $numa = Get-Field $d 'NumaNode'
                if ($null -ne $numa) { Write-Output "NUMANode:`t$numa" }
                Write-Output ''
            }
        }
    }
}
