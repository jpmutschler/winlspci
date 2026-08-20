@{
    RootModule        = 'winlspci.psm1'
    ModuleVersion     = '0.5.0'
    GUID              = 'a7c3f2e1-5b94-4d8a-9e21-6f0c4b8d3a75'
    Author            = 'Joshua Mutschler'
    CompanyName       = 'Serial Cables'
    Copyright         = '(c) Joshua Mutschler. MIT.'
    Description       = 'lspci for Windows, without a kernel driver. Reads the PnP/PCI enumeration for identity, class, BDF, negotiated and maximum link state, MPS/MRRS and driver binding. Cannot read configuration space.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-PciDevice', 'Format-Lspci', 'Format-PciTree',
        'ConvertTo-PciAttributeRecord', 'Get-PciAttributeName',
        'Format-PciDelimited', 'Format-PciMachine', 'Update-PciIds',
        'Get-PciVendorName', 'Get-PciDeviceName', 'Get-PciSubsystemName', 'Get-PciClassName',
        'Import-PciIds', 'Read-PciIdsFile', 'Export-PciBaseline', 'Compare-PciBaseline', 'Compare-PciDeviceSet',
        'Get-PciDataSource', 'Install-LspciShim'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData = @{
        PSData = @{
            Tags         = @('PCI', 'PCIe', 'lspci', 'hardware', 'diagnostics', 'Windows')
            LicenseUri   = 'https://opensource.org/licenses/MIT'
            ProjectUri   = 'https://github.com/jpmutschler/winlspci'
            ReleaseNotes = 'See CHANGELOG.md (https://github.com/jpmutschler/winlspci/blob/main/CHANGELOG.md). Summary of 0.4.0 -- adds a Domain property: Hyper-V/Azure SR-IOV functions carry the PCI segment in the upper bits of Windows'' bus number and were rendered as bus "556f00"; they are now 556f:00:02.0 and -s accepts the domain. correctness: -s follows lspci grammar (bare number is a device, .0 / :00.0 work, bad input is one clear error); -d vendor/device are exact hex ids (-d 80: no longer means every 80xx), wildcards rejected; class code falls back to the CC_ hardware id so host bridges are no longer "Unclassified"; absent class renders as unknown, never 0000; no false DOWNTRAINED (width) when width is unreported; Subsystem printed vendor:device with SubsystemVendorId split out (SubsystemId is now the 4-digit device part); -vvv is a superset of -vv; formatters tolerate trimmed objects; tree never drops a parent cycle; -Header emitted once even when nested. CLI: own lspci-style parser -- short flags combine (-tv, -nnk), -D works, -k shows the driver, known-but-unimplemented lspci flags exit 2 with "not implemented", unknown options exit 64, single-record -Json is an array. New Downtrained property; -Downtrained exits 1 when nothing matches. Performance: projected WQL query (~20% faster), -ListAttributes no longer enumerates. Update-PciIds validates the parse, keeps a .bak, uses the temp dir and TLS 1.2. 0.3.0 -- adds -Delimited pipe-separated output (-Delimiter, -Header) as a familiar shape for grep/awk/cut habits, with absent-vs-zero surviving into the text form. 0.2.0 -- adds -t topology tree, -vvv, -Domain, and attribute-level serialisation (-Attribute with wildcards, -Match value filtering, -PresentOnly, -ListAttributes, -Csv) as a structured replacement for piping to grep. Fixes -s so unpadded and domain-qualified slots match.'
        }
    }
}
