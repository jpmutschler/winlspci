# winlspci

`lspci` for Windows, without a kernel driver.

```
PS> lspci -nn
00:1c.0 PCI bridge [0604]: Intel Corporation Tigerlake PCH-LP PCI Express Root Port #6 [8086:a0bd] (rev 20)
01:00.0 Non-Volatile memory controller [0108]: SK hynix Gold P31/BC711/PC711 NVMe SSD [1c5c:174a] (rev 00)

PS> lspci -d 1c5c: -vv
01:00.0 Non-Volatile memory controller: SK hynix Gold P31/BC711/PC711 NVMe Solid State Drive (rev 00)
        LnkSta: 8GT/s x4 (max 8GT/s x4)
        Driver: stornvme (10.0.26100.8972)
        Subsystem: 174a1c5c
        DevCtl: MPS 256 bytes (max 512), MaxReadReq 512 bytes
        Capabilities: AER present

PS> lspci -Downtrained          # the question you actually opened lspci to answer
```

---

## What it can and cannot do

This is the important section. **Windows exposes no userland path to PCI
configuration space.** A faithful `lspci` port is therefore impossible without a
signed kernel-mode driver, and shipping one of those means driver signing,
Secure Boot friction and a much larger attack surface on a lab machine.

So `winlspci` reads Windows' own PnP/PCI enumeration instead — populated by the
PCI bus driver from config space at enumeration time.

| ✅ Reports | ❌ Cannot report |
|---|---|
| Presence, vendor / device / subsystem IDs, revision | `lspci -x` config-space hex dumps |
| Class / subclass / prog-if, with names | Capability structure walks |
| `bus:device.function` | ASPM state, LTR, DPC |
| **Negotiated *and* maximum** link speed and width | AER register detail (presence only) |
| MPS, MRRS | Anything requiring a live register read |
| Driver binding and version, device status / problem code | |
| NUMA node, AER capability presence | |

If you ask for something in the right column, it says so and exits 2 rather
than quietly doing less than you asked:

```
PS> lspci -x
lspci: cannot dump configuration space (-x). Windows exposes no userland path
to PCI config space; that needs a signed kernel-mode driver. ...
```

---

## Install

No install required — clone and run.

```powershell
git clone <this repo> C:\tools\winlspci
$env:PATH += ';C:\tools\winlspci\bin'
lspci -nn
```

To make it permanent, append to the **User** PATH:

```powershell
$p = [Environment]::GetEnvironmentVariable('PATH','User')
[Environment]::SetEnvironmentVariable('PATH', "$p;C:\tools\winlspci\bin", 'User')
```

> Use the .NET API, **not** `setx`. `setx` silently truncates PATH at 1024
> characters, and a developer machine is routinely well past that — truncating
> it destroys most of your environment with no warning.

Or import the module directly:

```powershell
Import-Module C:\tools\winlspci\winlspci.psd1
Get-PciDevice -Device '10de:' | Format-Lspci -Verbosity 2
```

**Requires Windows PowerShell 5.1** — the one that ships with Windows. Written
to 5.1 syntax on purpose (no ternary, no `??`, no `-AsHashtable`): a tool that
tells you what is in the machine should not need an install before it runs.

---

## Usage

| Flag | Meaning |
|---|---|
| `-d <ven>:<dev>:<class>` | Filter. Any field may be empty: `-d 11f8:`, `-d :174a`, `-d ::0108` |
| `-s <bdf>` | Slot filter, matched as a prefix: `-s 01:`, `-s 01:00.0` |
| `-v` / `-vv` | Add link state and driver / add MPS, MRRS, subsystem, NUMA |
| `-n` / `-nn` | IDs only / names *and* IDs |
| `-Json` | Structured output |
| `-Downtrained` | Only devices running below their maximum speed or width |
| `-Version` | Module version and the bundled `pci.ids` date |

### PowerShell as a first-class interface

The reason to have this rather than a straight port: the objects are real.

```powershell
# Every device not running at full width
Get-PciDevice | Where-Object { $_.LinkWidth -lt $_.MaxLinkWidth }

# Group the machine by vendor
Get-PciDevice | Group-Object VendorName | Sort-Object Count -Descending

# Feed a report
Get-PciDevice -Device '11f8:' | ConvertTo-Json -Depth 5 > switch-inventory.json
```

---

## Two design decisions worth knowing

**"Not reported" is never rendered as zero.** Root ports and chipset devices
legitimately expose no link state. Rendering that as `x0` would look like a dead
link, so absent stays `$null` and prints as *"not reported by this device"*.
There is a test for it.

**A filter that matches nothing exits non-zero.** `lspci -d 11f8:` finding no
card must not look like success — that is the difference between "the card is
not there" and "the command worked".

---

## Performance

Full enumeration of a laptop (24 devices) takes ~2s; a filtered query ~1s.

Getting there took three attempts, and the middle one is worth recording:

| Approach | Time |
|---|---|
| `Get-PnpDevice` + per-property `Get-PnpDeviceProperty` | **>5 min** |
| Batched `Get-PnpDeviceProperty -KeyName <16 keys>` | ~36s |
| `Get-PnpDeviceProperty -KeyName '*'` | *appeared* 2× faster — **returned zero properties** |
| `Win32_PnPEntity` + `Invoke-CimMethod GetDeviceProperties` | **~2s** |

The wildcard was the interesting failure: it looked like the fastest option and
was in fact doing nothing, because `-KeyName` does not support wildcards. The
benchmark was measuring a no-op, and the output still looked plausible. Only
checking the *values* caught it.

The winning approach uses the CIM method the cmdlet wraps — ~39ms per device
versus ~1230ms — because the cmdlet appears to re-resolve the device on every
call while the CIM method takes an already-resolved instance.

---

## PCI ID database

Bundled (`data/pci.ids`, ~1.4MB) so the tool works with no network — on a lab
bench that is usually the situation. Refresh it explicitly:

```powershell
Update-PciIds          # from https://pci-ids.ucw.cz
```

The update refuses to replace a working database with a suspiciously short
download.

> **`11f8` reads "PMC-Sierra Inc."** Microsemi acquired PMC-Sierra, Microchip
> acquired Microsemi, and the vendor ID never changed. A Microchip Switchtec
> switch shows as PMC-Sierra. There is a test pinning this, so nobody at a
> bench at 11pm concludes they have the wrong part.

`pci.ids` is maintained by the PCI ID Project and is BSD/GPL dual-licensed.

---

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1
```

No Pester required, deliberately: stock Windows ships Pester 3.4.0, whose
`Should Be` syntax is incompatible with Pester 5's `Should -Be`, so a Pester
suite would pass on the author's machine and fail on a colleague's.

Hardware-dependent tests assert on *shape* rather than values, since the PCI
inventory differs on every machine, and skip with a stated reason where they
genuinely need a specific device.

---

## Licence

MIT. `data/pci.ids` is BSD/GPL dual-licensed, from the PCI ID Project.
