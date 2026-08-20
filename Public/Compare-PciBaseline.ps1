# Attributes that change on their own between two otherwise identical
# enumerations. Ignored by Compare-* unless -IncludeVolatile.
$script:VolatileAttributes = @('PowerState')


function Export-PciBaseline {
    <#
    .SYNOPSIS
      Save the current enumeration as a baseline file for later comparison.

    .DESCRIPTION
      Writes the same envelope `lspci -Json` emits (schemaVersion, tool
      version, timestamp, computer name, devices) so a baseline is also just a
      JSON dump, and a JSON dump is also just a baseline. Compare-PciBaseline
      re-enumerates and diffs against it: "did the reboot / firmware / driver
      update change anything" in one command.

    .PARAMETER Path
      Where to write. Overwritten if it exists.
    .PARAMETER Device
      Devices to record; defaults to a fresh Get-PciDevice.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [object[]]$Device
    )
    $target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not $PSCmdlet.ShouldProcess($target, 'write baseline')) { return }
    if ($null -eq $Device) { $Device = @(Get-PciDevice) }
    $envelope = [pscustomobject]@{
        schemaVersion   = 1
        winlspciVersion = "$((Get-Module winlspci).Version)"
        generatedAt     = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        computerName    = $env:COMPUTERNAME
        source          = 'windows-pnp'
        count           = @($Device).Count
        devices         = @($Device)
    }
    $json = ConvertTo-Json -InputObject $envelope -Depth 6
    [IO.File]::WriteAllText($target, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Verbose "baseline: $(@($Device).Count) devices -> $target"
}


function Compare-PciBaseline {
    <#
    .SYNOPSIS
      Diff the current enumeration (or a given set) against a baseline file.

    .DESCRIPTION
      Three kinds of difference, as records:

        Change = Added      a device present now that the baseline lacked
        Change = Removed    a device in the baseline that is not present now
        Change = Changed    one attribute of one device: Attribute, Was, Now

      Devices are matched by InstanceId. Reseating a card can give it a new
      instance id, so a device whose InstanceId moved but whose
      Slot+VendorId+DeviceId still match is reported as Changed(InstanceId)
      rather than as a Removed/Added pair.

      Absent stays distinct from zero: an attribute that went from "not
      reported" to 0 is a Change, and the record says so ("<absent>" -> 0).

      Attributes that only ever say where/when the data came from
      (InstanceId is handled above) are compared; nothing is ignored by
      default, because the point is to see what moved. -IgnoreAttribute takes
      names (wildcards) to leave out -- e.g. PowerState, which flips with
      idle, or DriverVersion after an intended update.

    .PARAMETER Path
      A file written by Export-PciBaseline or `lspci -Json`.
    .PARAMETER Device
      The "now" set; defaults to a fresh Get-PciDevice.
    .PARAMETER IgnoreAttribute
      Attribute names (wildcards allowed) to skip when comparing, on top of
      the volatile set (PowerState) that is ignored unless -IncludeVolatile.
    .PARAMETER IncludeVolatile
      Also compare attributes that change on their own (PowerState flips
      with idle). Off by default so "did the update change anything" is not
      answered with D-state noise.
    .PARAMETER DeviceFilter / SlotFilter
      lspci-style -d / -s selectors applied to the BASELINE, so that a
      filtered "now" (lspci -d 1c5c: -Diff base.json) is compared against
      the same subset of the baseline rather than reporting every other
      device as gone.

    .EXAMPLE
      Export-PciBaseline before.json
      # ... reboot, update firmware ...
      Compare-PciBaseline before.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [object[]]$Device,
        [string[]]$IgnoreAttribute,
        [switch]$IncludeVolatile,
        [string]$DeviceFilter = '',
        [string]$SlotFilter = ''
    )
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Compare-PciBaseline: no such file '$Path'" }
    # A baseline is the one input a user is invited to accept from elsewhere
    # ("diff against the fleet reference"), so it is parsed defensively and
    # every value it contributes to output is sanitised below.
    try {
        $raw = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Compare-PciBaseline: '$Path' is not valid JSON ($($_.Exception.Message))"
    }
    $notBaseline = "Compare-PciBaseline: '$Path' does not look like a winlspci baseline (expected the -Json envelope with a 'devices' array)"
    if ($null -eq $raw) { throw $notBaseline }
    $baseList = @()
    if ($raw -is [array]) { $baseList = @($raw) }
    elseif ($raw.PSObject.Properties['devices'] -and $null -ne $raw.devices) { $baseList = @($raw.devices) }
    else { throw $notBaseline }
    if ($raw -isnot [array] -and $raw.PSObject.Properties['schemaVersion']) {
        $sv = 0
        if (-not [int]::TryParse("$($raw.schemaVersion)", [ref]$sv)) { throw "Compare-PciBaseline: schemaVersion '$($raw.schemaVersion)' in '$Path' is not a number" }
        if ($sv -gt 1) { Write-Warning "baseline schemaVersion $sv is newer than this tool understands (1); comparing anyway" }
    }

    # Apply the same selectors to the baseline that the caller applied to
    # "now" (Get-PciDevice -Device/-Slot), so the two sides are like for like.
    if ($DeviceFilter -or $SlotFilter) {
        $df = ConvertTo-DeviceFilter $DeviceFilter
        $sf = ConvertTo-SlotFilter $SlotFilter
        $baseList = @($baseList | Where-Object {
            $ven = "$(Get-Field $_ 'VendorId')"; $dev = "$(Get-Field $_ 'DeviceId')"; $cls = "$(Get-Field $_ 'ClassCode')"
            (-not $df.Vendor -or $ven -eq $df.Vendor) -and
            (-not $df.Device -or $dev -eq $df.Device) -and
            (-not $df.Class -or $cls.StartsWith($df.Class)) -and
            (Test-SlotMatch "$(Get-Field $_ 'Slot')" $sf)
        })
    }

    if ($null -eq $Device) { $Device = @(Get-PciDevice -Device $DeviceFilter -Slot $SlotFilter) }
    # Plain return: callers wrap in @(). A unary-comma return here plus the
    # caller's @() nests the array (learned the hard way, twice).
    return (Compare-PciDeviceSet -Before $baseList -After $Device -IgnoreAttribute $IgnoreAttribute -IncludeVolatile:$IncludeVolatile)
}


function Compare-PciDeviceSet {
    <#
    .SYNOPSIS
      Diff two device sets (Added / Removed / Changed records). The core of
      Compare-PciBaseline and of `lspci -Watch`.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Before,
        [object[]]$After,
        [string[]]$IgnoreAttribute,
        [switch]$IncludeVolatile
    )
    $baseList = @($Before)
    $nowList = @($After)

    # Volatile attributes change by themselves; without this a diff taken a
    # minute after its baseline reports D-state flips and nothing else.
    $ignore = @()
    if (-not $IncludeVolatile) { $ignore += $script:VolatileAttributes }
    if ($IgnoreAttribute) { $ignore += @($IgnoreAttribute) }
    function Test-Ignored([string]$name) {
        foreach ($p in $ignore) { if ($name -like $p) { return $true } }
        return $false
    }

    # Snapshot every object into a plain hashtable ONCE. The device object
    # carries ~60 attributes; reading each through Get-Field on both sides
    # was ~300ms for 24 devices and ~3.5s for 300 -- all call overhead, not
    # data. Hashtable reads make the same comparison a few milliseconds.
    function Get-Snapshot($obj) {
        $h = @{}
        if ($null -eq $obj) { return $h }
        foreach ($p in $obj.PSObject.Properties) { if ($p.Name -ne 'PSTypeName') { $h[$p.Name] = $p.Value } }
        return $h
    }
    function Get-Str($h, [string]$k) { if ($h.ContainsKey($k) -and $null -ne $h[$k]) { return "$($h[$k])" }; return '' }

    $baseSnaps = @(); foreach ($b in $baseList) { $baseSnaps += ,(Get-Snapshot $b) }
    $nowSnaps  = @(); foreach ($n in $nowList)  { $nowSnaps  += ,(Get-Snapshot $n) }

    # Index the baseline by InstanceId, then by the physical key for the
    # reseated-card case.
    $baseById = @{}; $baseByKey = @{}
    for ($i = 0; $i -lt $baseSnaps.Count; $i++) {
        $bs = $baseSnaps[$i]
        $id = Get-Str $bs 'InstanceId'
        if ($id) { $baseById[$id] = $i }
        $k = "$(Get-Str $bs 'Slot')|$(Get-Str $bs 'VendorId')|$(Get-Str $bs 'DeviceId')"
        if (-not $baseByKey.ContainsKey($k)) { $baseByKey[$k] = $i }
    }

    $records = @()
    $matchedBase = @{}
    $ignoreCache = @{}

    foreach ($ns in $nowSnaps) {
        $id = Get-Str $ns 'InstanceId'
        $slot = Get-Str $ns 'Slot'
        $bi = -1
        if ($id -and $baseById.ContainsKey($id)) {
            $bi = $baseById[$id]
        } else {
            $k = "$slot|$(Get-Str $ns 'VendorId')|$(Get-Str $ns 'DeviceId')"
            if ($baseByKey.ContainsKey($k) -and -not $matchedBase.ContainsKey($baseByKey[$k])) { $bi = $baseByKey[$k] }
        }
        if ($bi -lt 0) {
            $records += [pscustomobject]@{ Change = 'Added'; Slot = $slot; InstanceId = $id; Attribute = $null; Was = $null; Now = ConvertTo-SafeText "$(Get-Str $ns 'VendorId'):$(Get-Str $ns 'DeviceId') $(Get-Str $ns 'DeviceName')" }
            continue
        }
        $matchedBase[$bi] = $true
        $bs = $baseSnaps[$bi]

        # Compare the UNION of both sides' attributes: an older baseline has
        # fewer (they show as <absent> -> value), a newer one may have more
        # (value -> <absent>); neither direction is silently skipped.
        # Inlined on purpose: ~60 attributes x 2 sides x N devices through
        # helper functions was ~300ms of call overhead at N=24.
        $names = @{}
        foreach ($k in $ns.Keys) { $names[$k] = $true }
        foreach ($k in $bs.Keys) { $names[$k] = $true }
        $sorted = [string[]]@($names.Keys); [Array]::Sort($sorted)
        foreach ($name in $sorted) {
            if (-not $ignoreCache.ContainsKey($name)) { $ignoreCache[$name] = (Test-Ignored $name) }
            if ($ignoreCache[$name]) { continue }
            $nowS = '<absent>'; if ($ns.ContainsKey($name) -and $null -ne $ns[$name]) { $nowS = "$($ns[$name])"; if ($nowS -eq '') { $nowS = '<absent>' } }
            $wasS = '<absent>'; if ($bs.ContainsKey($name) -and $null -ne $bs[$name]) { $wasS = "$($bs[$name])"; if ($wasS -eq '') { $wasS = '<absent>' } }
            if ($nowS -ne $wasS) {
                # Sanitised at record-build time so -Csv and the text form
                # both get it; the baseline half is untrusted by design.
                $records += [pscustomobject]@{ Change = 'Changed'; Slot = $slot; InstanceId = $id; Attribute = $name; Was = (ConvertTo-SafeText $wasS); Now = (ConvertTo-SafeText $nowS) }
            }
        }
    }
    for ($i = 0; $i -lt $baseSnaps.Count; $i++) {
        if (-not $matchedBase.ContainsKey($i)) {
            $bs = $baseSnaps[$i]
            $records += [pscustomobject]@{ Change = 'Removed'; Slot = (ConvertTo-SafeText (Get-Str $bs 'Slot')); InstanceId = (ConvertTo-SafeText (Get-Str $bs 'InstanceId')); Attribute = $null; Was = (ConvertTo-SafeText "$(Get-Str $bs 'VendorId'):$(Get-Str $bs 'DeviceId') $(Get-Str $bs 'DeviceName')"); Now = $null }
        }
    }
    return $records
}
