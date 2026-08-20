function Format-PciTree {
    <#
    .SYNOPSIS
      Bus topology, in the shape of `lspci -t`.

    .DESCRIPTION
      Built from DEVPKEY_Device_Parent, which Windows populates with the
      upstream bridge's instance id. Devices whose parent is not itself a PCI
      device (root complexes, and anything whose parent left the tree) become
      roots, so nothing is silently dropped -- an incomplete tree that LOOKS
      complete is worse than an obviously ragged one.

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

    function Write-Node {
        param([int]$Index, [string]$Prefix, [bool]$IsLast, [bool]$IsRoot)

        if ($visited[$Index]) { return }
        $visited[$Index] = $true
        $Node = $all[$Index]

        $label = "$(Get-Field $Node 'Slot')"
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
        if (Get-Field $Node 'LinkStateReported') {
            $w = Get-Field $Node 'LinkWidth'
            $wText = 'x?'
            if ($null -ne $w) { $wText = "x$w" }
            $label += "  ($(Get-Field $Node 'LinkSpeed') $wText)"
        }

        if ($IsRoot) {
            Write-Output "-$label"
            $childPrefix = ' '
        } else {
            if ($IsLast) { $branch = '\-' } else { $branch = '+-' }
            Write-Output "$Prefix$branch$label"
            if ($IsLast) { $childPrefix = "$Prefix  " } else { $childPrefix = "$Prefix| " }
        }

        $kids = @()
        if ($children.ContainsKey($Index)) {
            $kids = @($children[$Index] | Sort-Object { "$(Get-Field $all[$_] 'Slot')" })
        }
        for ($i = 0; $i -lt $kids.Count; $i++) {
            Write-Node $kids[$i] $childPrefix ($i -eq $kids.Count - 1) $false
        }
    }

    $bySlot = { "$(Get-Field $all[$_] 'Slot')" }
    foreach ($r in ($roots | Sort-Object $bySlot)) {
        Write-Node $r '' $true $true
    }

    # Nothing may be silently dropped. Anything the walk from the roots did
    # not reach (a parent cycle, for instance) is rendered as a root of its
    # own, so an incomplete tree is obviously ragged rather than quietly short.
    $orphans = @(0..($all.Count - 1) | Where-Object { $all.Count -gt 0 -and -not $visited[$_] })
    foreach ($o in ($orphans | Sort-Object $bySlot)) {
        Write-Node $o '' $true $true
    }
}
