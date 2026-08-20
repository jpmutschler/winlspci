function Format-PciTree {
    <#
    .SYNOPSIS
      Bus topology, in the shape of `lspci -t`.

    .DESCRIPTION
      Built from DEVPKEY_Device_Parent, which Windows populates with the
      upstream bridge's instance id. One root per [domain:bus] holding the
      devices whose parent is not itself a PCI device (the root complex), and
      under each bridge its children, with the bridge's secondary/subordinate
      bus range derived from its descendants -- lspci's -[0000:00]-+-00.0 /
      +-1c.0-[01] shape, except that every device keeps its full bus:dev.fn
      and stays on a line of its own (descriptions are shown, and a line per
      device is the invariant the tests pin):

          -[0000:00]-+-00:00.0  Host bridge
                     +-00:06.0-[01]  PCIe Controller  [root port]
                     |           \-01:00.0  NVMe SSD  (8GT/s x4)
                     \-00:1d.0-[f3]  Root Port #9  [root port]
                                 \-f3:00.0  GeForce RTX 3050 Ti  (8GT/s x4)

      Anything the walk from the roots does not reach (a parent cycle, a
      parent that left the tree) is rendered as a root of its own, so nothing
      is silently dropped -- an incomplete tree that LOOKS complete is worse
      than an obviously ragged one.

    .PARAMETER Numeric
      0 names, 1 ids, 2 both -- as Format-Lspci.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Devices,
        [int]$Numeric = 0
    )

    # Everything below works on INDICES into $all, never on InstanceId as a
    # key for a node: a trimmed object has no InstanceId, and keying visited
    # on the empty string once marked the first such node visited and silently
    # dropped every other one. Indices need no identity and cannot collide.
    $all = @($Devices)
    if ($all.Count -eq 0) { return }
    $indexById = @{}
    for ($n = 0; $n -lt $all.Count; $n++) {
        $id = Get-Field $all[$n] 'InstanceId'
        if ($null -ne $id -and "$id" -ne '' -and -not $indexById.ContainsKey("$id")) { $indexById["$id"] = $n }
    }

    $children = @{}     # parent index -> list of child indices
    $roots = @()
    for ($n = 0; $n -lt $all.Count; $n++) {
        $parent = Get-Field $all[$n] 'ParentInstanceId'
        $parentIndex = -1
        if ($parent -and $indexById.ContainsKey("$parent")) { $parentIndex = $indexById["$parent"] }
        # A node whose parent is itself (or otherwise unreachable from a root)
        # is caught by the visited sweep at the end.
        if ($parentIndex -ge 0 -and $parentIndex -ne $n) {
            if (-not $children.ContainsKey($parentIndex)) { $children[$parentIndex] = @() }
            $children[$parentIndex] += $n
        } else {
            $roots += $n
        }
    }

    $visited = New-Object 'bool[]' $all.Count
    $slotOf = { param($i) "$(Get-Field $all[$i] 'Slot')" }

    # [domain, bus] of a slot string "[dddd:]bb:dd.f"; $null when unparseable.
    function Get-SlotBus([string]$slot) {
        if ($slot -match '^(?:([0-9a-f]{4}):)?([0-9a-f]{2}):[0-9a-f]{2}\.\d$') {
            $dom = 0; if ($Matches[1]) { $dom = [Convert]::ToInt32($Matches[1], 16) }
            return @($dom, [Convert]::ToInt32($Matches[2], 16))
        }
        return $null
    }

    # Secondary..subordinate bus range of a bridge, from its descendants.
    # Windows does not hand us the configured range; the buses its children
    # actually sit on are exact for rendering and need no extra data.
    # Memoised: each node's range is computed once, bottom-up, so a fabric of
    # cascaded switches costs O(n) rather than re-walking every subtree per
    # bridge (which was quadratic on depth -- 2s at 80 levels).
    $rangeMemo = @{}
    $rangeInProgress = @{}
    function Get-BusRange([int]$index) {
        if ($rangeMemo.ContainsKey($index)) { return $rangeMemo[$index] }
        if ($rangeInProgress.ContainsKey($index)) { return $null }   # cycle guard
        $rangeInProgress[$index] = $true
        $min = $null; $max = $null
        if ($children.ContainsKey($index)) {
            foreach ($c in $children[$index]) {
                $b = Get-SlotBus (& $slotOf $c)
                if ($null -ne $b) {
                    if ($null -eq $min -or $b[1] -lt $min) { $min = $b[1] }
                    if ($null -eq $max -or $b[1] -gt $max) { $max = $b[1] }
                }
                $sub = Get-BusRange $c
                if ($null -ne $sub) {
                    if ($null -eq $min -or $sub[0] -lt $min) { $min = $sub[0] }
                    if ($null -eq $max -or $sub[1] -gt $max) { $max = $sub[1] }
                }
            }
        }
        $rangeInProgress.Remove($index)
        $result = $null
        if ($null -ne $min) { $result = @($min, $max) }
        $rangeMemo[$index] = $result
        return $result
    }

    # The slot token: "00:1c.0", or for a bridge with descendants
    # "00:1c.0-[01]" / "00:1d.0-[02-05]" -- lspci's secondary bus range.
    # Children hang under the end of this token.
    function Get-NodeToken([int]$index) {
        $Node = $all[$index]
        $token = "$(Get-Field $Node 'Slot')"
        if (Get-Field $Node 'IsBridge') {
            $range = Get-BusRange $index
            if ($null -ne $range) {
                if ($range[0] -eq $range[1]) { $token += ('-[{0:x2}]' -f $range[0]) }
                else { $token += ('-[{0:x2}-{1:x2}]' -f $range[0], $range[1]) }
            }
        }
        return $token
    }

    function Get-NodeLabel([int]$index) {
        $Node = $all[$index]
        $label = Get-NodeToken $index
        $ids = "$(Get-Field $Node 'VendorId'):$(Get-Field $Node 'DeviceId')"
        if ($Numeric -eq 1) {
            $label += " [$ids]"
        } else {
            $desc = Get-Field $Node 'DeviceName'
            if (-not $desc) { $desc = Get-Field $Node 'FriendlyName' }
            if (-not $desc) { $desc = Get-Field $Node 'ClassName' }
            if (-not $desc) { $desc = 'Unknown class' }
            $desc = ConvertTo-SafeText $desc
            if ($Numeric -eq 2) { $desc = "$desc [$ids]" }
            $label += "  $desc"
        }
        # Bridges get a short type tag: the topology reads very differently
        # once a root port, an upstream and a downstream switch port are told
        # apart. Endpoints are the default and stay unlabelled.
        if (Get-Field $Node 'IsBridge') {
            $t = "$(Get-Field $Node 'DeviceType')" -replace '^PCIe ', '' -replace ' Switch Port$', ' port' -replace ' Port$', ' port'
            if ($t) { $label += "  [$($t.ToLower())]" }
        }
        if (Get-Field $Node 'LinkStateReported') {
            $w = Get-Field $Node 'LinkWidth'
            $wText = 'x?'
            if ($null -ne $w) { $wText = "x$w" }
            $label += "  ($(Get-Field $Node 'LinkSpeed') $wText)"
        }
        return $label
    }

    # Render one node and its subtree. $Prefix is the text printed to the
    # left of this node's branch; $ContPrefix is what its children continue
    # from (the same, except that a root group's header text is replaced by
    # spaces so it appears once). Children hang under the slot(-[range]) token.
    function Write-Node {
        param([int]$Index, [string]$Prefix, [string]$ContPrefix, [bool]$IsLast)

        if ($visited[$Index]) { return }
        $visited[$Index] = $true

        $label = Get-NodeLabel $Index
        if ($IsLast) { $branch = '\-' } else { $branch = '+-' }
        Write-Output "$Prefix$branch$label"

        $kids = @()
        if ($children.ContainsKey($Index)) { $kids = Get-OrdinalSlotOrder @($children[$Index]) }
        if ($kids.Count -eq 0) { return }
        $token = Get-NodeToken $Index
        $continue = '  '
        if (-not $IsLast) { $continue = '| ' }
        $childPrefix = $ContPrefix + $continue + (' ' * [Math]::Max(0, $token.Length - 2))
        for ($i = 0; $i -lt $kids.Count; $i++) {
            Write-Node $kids[$i] $childPrefix $childPrefix ($i -eq $kids.Count - 1)
        }
    }

    # Ordinal, not culture, ordering: slots are ASCII hex, and goldens are
    # compared byte-for-byte on machines with other locales.
    function Get-OrdinalSlotOrder([int[]]$Indices) {
        if ($Indices.Count -le 1) { return ,@($Indices) }
        $keys = [string[]]@($Indices | ForEach-Object { & $slotOf $_ })
        $items = [int[]]@($Indices)
        [Array]::Sort($keys, $items, [StringComparer]::Ordinal)
        return ,@($items)
    }

    # Roots grouped by [domain:bus]; each group is one lspci-style root line.
    function Write-RootGroup([int[]]$Indices) {
        $sorted = Get-OrdinalSlotOrder $Indices
        $bus = Get-SlotBus (& $slotOf $sorted[0])
        $header = '-[????:??]-'
        if ($null -ne $bus) { $header = ('-[{0:x4}:{1:x2}]-' -f $bus[0], $bus[1]) }
        $indent = ' ' * $header.Length
        for ($i = 0; $i -lt $sorted.Count; $i++) {
            $prefix = $indent
            if ($i -eq 0) { $prefix = $header }
            Write-Node $sorted[$i] $prefix $indent ($i -eq $sorted.Count - 1)
        }
    }

    $groups = @{}
    foreach ($r in $roots) {
        $b = Get-SlotBus (& $slotOf $r)
        $key = '??'
        if ($null -ne $b) { $key = '{0:x4}:{1:x2}' -f $b[0], $b[1] }
        if (-not $groups.ContainsKey($key)) { $groups[$key] = @() }
        $groups[$key] += $r
    }
    $groupKeys = [string[]]@($groups.Keys); [Array]::Sort($groupKeys, [StringComparer]::Ordinal)
    foreach ($key in $groupKeys) { Write-RootGroup $groups[$key] }

    # Nothing may be silently dropped. Anything the walk from the roots did
    # not reach (a parent cycle, for instance) is rendered as a root group of
    # its own, so an incomplete tree is obviously ragged rather than quietly
    # short.
    $orphans = @(0..($all.Count - 1) | Where-Object { -not $visited[$_] })
    if ($orphans.Count -gt 0) {
        $ogroups = @{}
        foreach ($o in $orphans) {
            $b = Get-SlotBus (& $slotOf $o)
            $key = '??'
            if ($null -ne $b) { $key = '{0:x4}:{1:x2}' -f $b[0], $b[1] }
            if (-not $ogroups.ContainsKey($key)) { $ogroups[$key] = @() }
            $ogroups[$key] += $o
        }
        $okeys = [string[]]@($ogroups.Keys); [Array]::Sort($okeys, [StringComparer]::Ordinal)
        foreach ($key in $okeys) { Write-RootGroup $ogroups[$key] }
    }
}
