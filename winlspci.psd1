@{
    RootModule        = 'winlspci.psm1'
    ModuleVersion     = '0.3.0'
    GUID              = 'a7c3f2e1-5b94-4d8a-9e21-6f0c4b8d3a75'
    Author            = 'Joshua Mutschler'
    CompanyName       = 'Serial Cables'
    Copyright         = '(c) Joshua Mutschler. MIT.'
    Description       = 'lspci for Windows, without a kernel driver. Reads the PnP/PCI enumeration for identity, class, BDF, negotiated and maximum link state, MPS/MRRS and driver binding. Cannot read configuration space.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-PciDevice', 'Format-Lspci', 'Format-PciTree',
        'ConvertTo-PciAttributeRecord', 'Get-PciAttributeName',
        'Format-PciDelimited', 'Update-PciIds',
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
            ReleaseNotes = '0.3.0 -- adds -Delimited pipe-separated output (-Delimiter, -Header) as a familiar shape for grep/awk/cut habits, with absent-vs-zero surviving into the text form. 0.2.0 -- adds -t topology tree, -vvv, -Domain, and attribute-level serialisation (-Attribute with wildcards, -Match value filtering, -PresentOnly, -ListAttributes, -Csv) as a structured replacement for piping to grep. Fixes -s so unpadded and domain-qualified slots match.'
        }
    }
}
