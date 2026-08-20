function ConvertTo-PciAttributeRecord {
    <#
    .SYNOPSIS
      Flatten a device to one record per ATTRIBUTE.

    .DESCRIPTION
      Turns a device object into rows of
      (Slot, Attribute, Value, Present) so a query can be written against
      attributes rather than devices -- grouping, diffing two machines, or
      asking "which devices report MaxPayloadSize at all".

      `Present` is a first-class field because absent and zero must not
      collapse: a root port that reports no link width is not a device running
      at x0, and any tool that renders both as 0 will eventually send someone
      to debug a link that is fine.

    .EXAMPLE
      Get-PciDevice | ConvertTo-PciAttributeRecord |
        Where-Object { $_.Attribute -eq 'LinkWidth' -and $_.Present }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$Device,
        [string[]]$Attribute,
        [string]$Match,
        [switch]$PresentOnly
    )
    process {
        foreach ($d in @($Device)) {
            foreach ($prop in $d.PSObject.Properties) {
                if ($prop.Name -eq 'PSTypeName') { continue }

                # Wildcards, not exact names. Without grep on the far side, the
                # filtering has to happen here -- `-Attribute Link*` is the
                # thing you would otherwise pipe through `grep -i link`.
                if ($Attribute) {
                    $nameHit = $false
                    foreach ($pattern in $Attribute) {
                        if ($prop.Name -like $pattern) { $nameHit = $true; break }
                    }
                    if (-not $nameHit) { continue }
                }

                $value = $prop.Value
                $isPresent = ($null -ne $value -and "$value" -ne '')
                if ($PresentOnly -and -not $isPresent) { continue }
                if ($Match -and "$value" -notmatch $Match) { continue }
                [pscustomobject]@{
                    Slot      = Get-Field $d 'Slot'
                    VendorId  = Get-Field $d 'VendorId'
                    DeviceId  = Get-Field $d 'DeviceId'
                    Attribute = $prop.Name
                    Value     = $value
                    Present   = $isPresent
                }
            }
        }
    }
}



function Get-PciAttributeName {
    <#
    .SYNOPSIS
      Every attribute name a device object carries.
    .DESCRIPTION
      Exists because attribute-level queries are only usable if you can find
      out what the attributes are called. `lspci -ListAttributes` is the
      discovery step that `grep` would otherwise stand in for.
    #>
    [CmdletBinding()]
    param()
    # Answered from the static shape, not by enumerating the machine: this
    # used to cost a full ~2s enumeration (and the CLI had already done one).
    $script:AttributeNames | Sort-Object
}
