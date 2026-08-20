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
