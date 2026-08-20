# Changelog

All notable changes to winlspci. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/) with the usual 0.x caveat that the
object shape may still change between minors (and says so here when it does).

## [Unreleased]

### Added
- **Device type** (`DeviceType`, `DeviceTypeRaw`, `IsBridge`) from
  `DEVPKEY_PciDevice_DeviceType`: root port, upstream/downstream switch port,
  endpoint, root-complex integrated endpoint, conventional PCI. `-v` prints
  `Type:`; `-t` tags bridges (`[root port]`, `[upstream port]`,
  `[downstream port]`); a device that reports no link now says why when the
  type explains it (integrated endpoint, conventional PCI).
- **Capability presence** on one `-vv` line — `Capabilities: AER, MSI, MSI-X
  (33 vectors), SR-IOV, ARI, ATS, AtomicOps` — from `InterruptSupport`,
  `InterruptMessageMaximum`, `SriovSupport` (reported only where the
  capability exists; value is a status, `SriovStatus`), `AriSupport`,
  `AtsSupport`, `AtomicsSupported`; plus `ExpressSpecVersion`,
  `AcsCapabilityRegister`, `BarTypesRaw`, `LinkSubStateRaw` as attributes.
  Presence only; contents still need config space, and `-vvv` says so.
- **`ACS: present | not needed | missing`** on its own `-vv` line
  (`AcsSupport`), with the three values verified against the ACS capability
  register on real hardware.
- A failed WMI query is reported as such (exit 70) instead of rendering as a
  machine with no PCI devices.
- `Subsystem:` is omitted for `0000:0000` instead of printing "Vendor 0000".
- A zero Device Serial Number is marked "(capability present, not populated)".
- `DOWNTRAINED (speed, width)` is one marker; the power-state note is its own
  line.
- **Physical slot** (`PhysicalSlot`, from `DEVPKEY_Device_UINumber`, printed
  as lspci's `Physical Slot:`), **location path** (`LocationPath`,
  `PCIROOT(0)#PCI(1C00)#PCI(0000)`), and **device serial number**
  (`SerialNumber`, the DSN capability, `00-11-22-33-44-55-66-77`).
- **Power state** (`PowerState`, the most recent D-state from
  `DEVPKEY_Device_PowerData`): printed in `-vv`, and appended to a
  `DOWNTRAINED` flag when the device is in D1–D3 — *"device in D3 -- likely
  idle power management, not a fault"* — which is the README's own GPU
  example, now explained by the tool.
- The property fetch asks for 17 more DEVPKEYs; measured at ~+300 ms on a
  24-device laptop (each key ~0.9 ms per device plus ~14 ms fixed per call).
- **Subsystem and prog-if names** from pci.ids: `SubsystemVendorName`,
  `SubsystemName` (`Subsystem: SK hynix Gold P31 [1c5c:174a]`), `ProgIfName`
  (`(prog-if 02 [NVM Express])` on the `-v` line); `Get-PciSubsystemName`,
  `Get-PciClassName -ProgIf`, `Read-PciIdsFile` now returns `Subsystems`.
  Parse is ~110 ms (was ~50) for ~18k subsystem entries.
- **`-m` / `-mm`** machine-readable output (`Format-PciMachine`), quoted and
  escaped as lspci does; **`-i <file>`** alternate `pci.ids`
  (`Import-PciIds -Path`). Both removed from the not-implemented list.
- **Baseline and diff**: `Export-PciBaseline`, `Compare-PciBaseline`,
  `Compare-PciDeviceSet`; CLI `-Baseline <file>`, `-Diff <file>`
  (`-IgnoreAttribute`, `PowerState` ignored unless `-IncludeVolatile`, exit 3
  on differences, `-Json`/`-Csv`/`-Delimited` forms, `-d`/`-s` applied to
  both sides, attributes compared as the union of both sides). Reseated
  cards match by slot+ids; absent vs zero survives as `<absent> -> 0`.
  Diff values are sanitised at record build (a baseline is untrusted input).
- `-m` omits `-r00`/`-p00` and prints `"" ""` for no subsystem, as pciutils
  does; `ClassName` is sanitised like every other name; `Import-PciIds -Path`
  keeps the override separate from the file `Update-PciIds` writes.
- **`-Watch <seconds>`** (`-Iterations <n>`): re-enumerate and print only
  timestamped changes; exit 3 if anything changed.
- `-Json` envelope carries `schemaVersion` (1), `winlspciVersion`,
  `generatedAt` (UTC) and `computerName`. Additive changes keep the schema
  version; a rename or change of meaning bumps it.
- Recorded fixtures: `tests\Export-PciFixture.ps1` captures a machine's PCI
  enumeration (entities + DEVPKEY bags) as JSON, and the suite replays
  fixtures through `Get-PciDevice` in place of the CIM calls, so Azure's
  packed bus numbers, a German `LocationInfo`, a phantom device and a switch
  hierarchy are tested on every box. Golden outputs live beside the fixtures;
  `tests\Invoke-Tests.ps1 -UpdateGolden` rewrites them deliberately.
- `CHANGELOG.md` (this file); the manifest's release notes point here.

### Changed
- `Present` now comes from `DEVPKEY_Device_IsPresent` (the `Status -eq
  'Unknown'` heuristic remains the fallback), so a device Windows reports as
  not present is excluded even when its Status is not `Unknown`. Phantoms are
  listed only with `-IncludeAbsent`.
- Module version is 0.5.0 while this series lands; `-Json` reports it.

### Fixed
- `LocationInfo` is parsed positionally (three integers), so a localised
  string ("PCI-Bus 0, Gerät 28, Funktion 0") gives the right slot without
  falling back to the packed address.

## [0.4.0] - 2026-08-20

### Added
- `Domain` property and domain-qualified slots (`556f:00:02.0`): Hyper-V and
  Azure report SR-IOV functions on a bus number with the PCI segment packed
  into its upper bits; those now render like Linux `lspci` and `-s` accepts
  the domain. Found by the first CI run.
- `Downtrained` property (null-guarded, one comparison site).
- `SubsystemVendorId`; `Subsystem:` printed as `vendor:device`.
- CLI argument parser of its own: case-sensitive combinable short flags
  (`-tv`, `-nnk`), `-D` and `-k` work, known-but-unimplemented lspci flags
  exit 2 with "not implemented", unknown options exit 64, raw command line
  recovered when launched via `powershell.exe -File`.
- `Read-PciIdsFile` exported; `Update-PciIds` validates the download parses,
  keeps `pci.ids.bak`, downloads to the temp dir, forces TLS 1.2, https only.
- GitHub Actions: the suite runs on `windows-latest` under Windows
  PowerShell 5.1.
- Module split into `Public\` and `Private\` files; `winlspci.psm1` is a loader.

### Changed
- **`SubsystemId` is now the 4-digit subsystem device id** (was the raw
  8-digit `SUBSYS_` word). `SubsystemVendorId` carries the other half.
- `-s` follows lspci's grammar field by field: `-s 1` is device 01 on any
  bus (was bus 01); `.0` and `:00.0` work; non-hex is one clear error.
- `-d` vendor and device are exact hex ids (`-d 80:` is vendor 0080, was a
  prefix); wildcards are rejected.
- `-vvv` is a superset of `-vv`.
- `-Downtrained` is a filter: exit 1 when nothing matches.
- `-Attribute … -Json` is always an array (`[]` when empty).
- Host bridge class comes from the `CC_` hardware id when the property is
  absent; a device with no class at all renders `Unknown class [????]`.
- Enumeration uses a projected WQL query (~20% faster); `-ListAttributes`
  answers from a static list (~80% faster); module import deferred past
  argument parsing.
- README recommends `%LOCALAPPDATA%\Programs\winlspci` rather than `C:\tools`.
- `pci.ids` refreshed to 2026-08-19.

### Fixed
- False `DOWNTRAINED (width)` when width was not reported (`$null -lt 4`).
- `-Header` re-emitted when another `Format-PciDelimited` ran in the pipeline.
- Formatters crashed under StrictMode on `Select-Object`-trimmed objects.
- `Format-PciTree` dropped nodes in a parent cycle.
- Control characters in names reach neither the console nor a `-Delimited` line.
- Six tests that assumed bus `01:` / an Intel device now sample the machine.

## [0.3.0] - 2026-08-19

### Added
- `-Delimited` output (`|`-separated records) with `-Delimiter` and `-Header`,
  as the shape `cut`/`awk` habits expect. An empty field means not reported;
  a literal `0` means zero. The delimiter is stripped from values, not escaped.

## [0.2.0] - 2026-08-19

### Added
- `-t` topology tree from `DEVPKEY_Device_Parent`, link state inline.
- `-vvv`: every property Windows exposes plus an explicit list of what is
  missing.
- `-Domain` (later `-D`).
- Attribute-level serialisation: `-Attribute` (wildcards), `-Match`,
  `-PresentOnly`, `-ListAttributes`, `-Csv`; `Present` is a field so absent
  and zero never collapse.

### Fixed
- `-s` matched only zero-padded slots (`-s 1:` found nothing while `-s 01:`
  matched).

## [0.1.0] - 2026-08-19

### Added
- First release: `Get-PciDevice`, `Format-Lspci`, bundled `pci.ids`, `-d`,
  `-s`, `-v`/`-vv`, `-n`/`-nn`, `-Json`, `-Downtrained`, `-x` refused with
  exit 2. Dependency-free test suite (no Pester).
