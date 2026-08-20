<#
    winlspci -- lspci for Windows, without a kernel driver.

    Windows has no lspci, and there is no userland path to PCI configuration
    space, so a faithful port is impossible without a signed kernel-mode
    driver. This reads Windows' own PnP/PCI enumeration instead, which the PCI
    bus driver populates from config space at enumeration time.

    That trade is worth stating plainly, because it decides what this tool can
    be trusted for:

      CAN report   presence, vendor/device/subsystem IDs, class codes, BDF,
                   revision, driver + version, negotiated AND maximum link
                   speed/width, MPS, MRRS, AER presence, NUMA node, topology.

      CANNOT report anything requiring live config-space reads: `lspci -x` hex
                   dumps, capability structure walks, ASPM state, AER register
                   detail, or per-capability decoding.

    Requires Windows PowerShell 5.1 or later. Written to 5.1 syntax
    deliberately -- no ternary, no null-coalescing, no -AsHashtable -- because
    5.1 is what ships with Windows and a portable tool should not require an
    install before it can tell you what is in the machine.
#>

Set-StrictMode -Version 2.0

$script:PciIdsPath = Join-Path $PSScriptRoot 'data\pci.ids'
$script:VendorNames = $null
$script:DeviceNames = $null
$script:ClassNames = $null

# PCIe link speed is reported as an enum, not GT/s. Getting this mapping wrong
# would be an easy, invisible error, so it is spelled out rather than computed.
$script:LinkSpeed = @{
    1 = '2.5GT/s'; 2 = '5GT/s'; 3 = '8GT/s'
    4 = '16GT/s';  5 = '32GT/s'; 6 = '64GT/s'
}

# MPS/MRRS are encoded as 0..5 => 128..4096 bytes.
$script:PayloadSize = @{ 0 = 128; 1 = 256; 2 = 512; 3 = 1024; 4 = 2048; 5 = 4096 }

# One function (or one cohesive group) per file. Private\ holds helpers the
# module uses internally; Public\ holds what the manifest exports. Everything
# is dot-sourced into module scope here, so $script: state set in those files
# is module state.
foreach ($dir in 'Private', 'Public') {
    foreach ($file in (Get-ChildItem -Path (Join-Path $PSScriptRoot $dir) -Filter '*.ps1' | Sort-Object Name)) {
        . $file.FullName
    }
}

Export-ModuleMember -Function Get-PciDevice, Format-Lspci, Format-PciTree,
    ConvertTo-PciAttributeRecord, Get-PciAttributeName,
    Format-PciDelimited, Update-PciIds,
    Get-PciVendorName, Get-PciDeviceName, Get-PciClassName, Import-PciIds,
    Read-PciIdsFile
