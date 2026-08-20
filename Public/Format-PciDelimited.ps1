function Format-PciDelimited {
    <#
    .SYNOPSIS
      One record per line, fields separated by `|` -- for cut, awk and -split.

    .DESCRIPTION
      Windows has no grep, awk or cut, but the muscle memory is real and
      PowerShell's own equivalents are wordy. A delimited stream is the
      familiar shape:

          lspci -Delimited | ForEach-Object { ($_ -split '\|')[0] }
          lspci -Attribute Link* -Delimited | Select-String LinkSpeed

      Two properties chosen deliberately:

      **An empty field means NOT REPORTED; a literal 0 means zero.** The
      absent/zero distinction that the object model protects survives into the
      text form for free, because an unset value serialises to nothing at all.
      Any consumer splitting on the delimiter sees the difference.

      **The delimiter is stripped from values, not escaped.** Quoting rules
      turn a one-liner into a parser, which defeats the point. No `|` occurs in
      live PCI data or in pci.ids today, but FriendlyName comes from driver INF
      files and is not under our control, so a stray delimiter is replaced with
      `/` rather than being allowed to silently shift every later column. Use
      -Csv when you need real quoting.

    .PARAMETER Delimiter
      Defaults to `|`. Use "`t" for tab-separated.

    .PARAMETER Header
      Emit a leading header row. Off by default, as Unix tools are.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$InputObject,
        [string]$Delimiter = '|',
        [switch]$Header,
        [string[]]$Field
    )
    begin {
        if ($Delimiter -eq '') { throw 'Format-PciDelimited: -Delimiter must not be empty' }

        # Function-local, not $script: -- begin/process share scope, and a
        # module-scope flag was reset by any NESTED Format-PciDelimited
        # (e.g. inside a ForEach-Object on the outer stream), re-emitting the
        # header for every remaining row.
        $headerWritten = $false

        # A device row and an attribute row have different natural columns.
        $deviceFields = @(
            'Slot', 'VendorId', 'DeviceId', 'ClassCode', 'ClassName',
            'VendorName', 'DeviceName', 'Revision',
            'LinkSpeed', 'LinkWidth', 'MaxLinkSpeed', 'MaxLinkWidth',
            'Driver', 'Status'
        )
        $attributeFields = @('Slot', 'VendorId', 'DeviceId', 'Attribute', 'Value', 'Present')
    }
    process {
        foreach ($item in @($InputObject)) {
            $names = $Field
            if (-not $names) {
                if ($item.PSObject.Properties['Attribute']) {
                    $names = $attributeFields
                } else {
                    $names = $deviceFields
                }
                # Only keep columns the object actually has, so a trimmed
                # object does not produce phantom empty columns.
                $names = @($names | Where-Object { $item.PSObject.Properties[$_] })
            }

            if ($Header -and -not $headerWritten) {
                Write-Output ($names -join $Delimiter)
                $headerWritten = $true
            }

            $values = foreach ($n in $names) {
                $prop = $item.PSObject.Properties[$n]
                $v = ''
                if ($prop -and $null -ne $prop.Value) { $v = "$($prop.Value)" }
                # Strip, do not escape -- see the note above. Line breaks and
                # other control characters get the same treatment: one record
                # must stay one physical line, whatever a driver INF put in
                # FriendlyName.
                $v = $v -replace '[\x00-\x1f\x7f]', ' '
                $v.Replace($Delimiter, '/')
            }
            Write-Output ($values -join $Delimiter)
        }
    }
}
