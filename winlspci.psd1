@{
    RootModule        = 'winlspci.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a7c3f2e1-5b94-4d8a-9e21-6f0c4b8d3a75'
    Author            = 'Joshua Mutschler'
    CompanyName       = 'Serial Cables'
    Copyright         = '(c) Joshua Mutschler. MIT.'
    Description       = 'lspci for Windows, without a kernel driver. Reads the PnP/PCI enumeration for identity, class, BDF, negotiated and maximum link state, MPS/MRRS and driver binding. Cannot read configuration space.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-PciDevice', 'Format-Lspci', 'Update-PciIds',
        'Get-PciVendorName', 'Get-PciDeviceName', 'Get-PciClassName',
        'Import-PciIds'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData = @{
        PSData = @{
            Tags         = @('PCI', 'PCIe', 'lspci', 'hardware', 'diagnostics', 'Windows')
            LicenseUri   = 'https://opensource.org/licenses/MIT'
            ReleaseNotes = 'Initial release. Identity, class decode, BDF, link state (current and max), MPS/MRRS, driver binding, JSON output, -Downtrained filter.'
        }
    }
}
