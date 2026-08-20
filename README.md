# winlspci

`lspci` for Windows, without a kernel driver.

Source and issues: <https://github.com/jpmutschler/winlspci> · [User's Manual (PDF)](docs/winlspci%20Users%20Manual%20v1.1.pdf) · MIT · Windows PowerShell 5.1

```
PS> lspci -nn
00:1c.0 PCI bridge [0604]: Intel Corporation Tigerlake PCH-LP PCI Express Root Port #6 [8086:a0bd] (rev 20)
01:00.0 Non-Volatile memory controller [0108]: SK hynix Gold P31/BC711/PC711 NVMe SSD [1c5c:174a] (rev 00)

PS> lspci -d 1c5c: -vv
01:00.0 Non-Volatile memory controller: SK hynix Gold P31/BC711/PC711 NVMe Solid State Drive (rev 00)
        LnkSta: 8GT/s x4 (max 8GT/s x4)
        Driver: stornvme (10.0.26100.8972)
        Subsystem: SK hynix [1c5c:174a]
        DevCtl: MPS 256 bytes (max 512), MaxReadReq 512 bytes
        Capabilities: AER present

PS> lspci -t
-00:1d.0  Tiger Lake-LP PCI Express Root Port #9
 \-f3:00.0  GA107M [GeForce RTX 3050 Ti Mobile]  (8GT/s x4)

PS> lspci -Attribute LinkSpeed -Match '16GT|32GT|64GT'   # no grep needed
PS> lspci -Downtrained                                   # anything below its max
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
| **Bus topology** (parent/child, via `DEVPKEY_Device_Parent`) | |
| Every field above, queryable **per attribute** | |

If you ask for something in the right column, it says so and exits 2 rather
than quietly doing less than you asked:

```
PS> lspci -x
lspci: cannot dump configuration space (-x). Windows exposes no userland path
to PCI config space; that needs a signed kernel-mode driver. ...
```

### Exit codes

| Code | Meaning |
|---|---|
| 0 | ok |
| 1 | a filter (`-s`, `-d`, `-Downtrained`, `-Attribute`/`-Match`) matched nothing |
| 2 | the request is impossible here (`-x`) or a known lspci flag this tool does not implement (`-m`, `-p`, `-b`, …) |
| 64 | usage error: unknown option, or a selector that is not hex |

---

## Install

No install required — clone and run.

```powershell
git clone https://github.com/jpmutschler/winlspci.git $env:LOCALAPPDATA\Programs\winlspci
$env:PATH += ";$env:LOCALAPPDATA\Programs\winlspci\bin"
lspci -nn
```

To make it permanent, append to the **User** PATH:

```powershell
$p = [Environment]::GetEnvironmentVariable('PATH','User')
[Environment]::SetEnvironmentVariable('PATH', "$p;$env:LOCALAPPDATA\Programs\winlspci\bin", 'User')
```

> Use the .NET API, **not** `setx`. `setx` silently truncates PATH at 1024
> characters, and a developer machine is routinely well past that — truncating
> it destroys most of your environment with no warning.

> Why `%LOCALAPPDATA%\Programs` rather than `C:\tools`: a folder created
> directly under `C:\` inherits *Modify* for every authenticated user, so any
> standard account could rewrite `lspci.ps1` for the next administrator who
> runs it. A hardware-debug tool is exactly the thing that gets run from an
> elevated shell. Per-user (`%LOCALAPPDATA%`) or `C:\Program Files` are both
> fine.

Or import the module directly:

```powershell
Import-Module $env:LOCALAPPDATA\Programs\winlspci\winlspci.psd1
Get-PciDevice -Device '10de:' | Format-Lspci -Verbosity 2
```

**Requires Windows PowerShell 5.1** — the one that ships with Windows. Written
to 5.1 syntax on purpose (no ternary, no `??`, no `-AsHashtable`): a tool that
tells you what is in the machine should not need an install before it runs.

---

## Flags — what maps, what doesn't

Measured against Linux `lspci`, not aspirational.

### Implemented

| lspci | winlspci | Notes |
|---|---|---|
| `-s [[<dom>]:]<bus>:]<dev>[.<fn>]` | `-s` | lspci's grammar, every field optional: `01:` (bus), `01:00.0`, `1` (**device** 01 on any bus), `.0` (every function 0), `:00.0`, `0000:01:00.0`. Padded or unpadded |
| `-d [<ven>]:[<dev>][:<class>]` | `-d` | Vendor and device are exact hex IDs (`-d 80:` is vendor `0080`, not every `80xx`); class is a prefix (`::01` = all storage). `-d 11f8:`, `-d :174a`, `-d ::0108` |
| `-t` | `-t` | Real topology, from `DEVPKEY_Device_Parent`. Shows link state inline |
| `-v` | `-v` | Link state (current **and** max), driver, status |
| `-vv` | `-vv` | Adds MPS, MRRS, subsystem (`vendor:device`), NUMA, AER presence |
| `-vvv` | `-vvv` | Everything `-vv` shows, then every property Windows exposes, **plus an explicit list of what is missing** |
| `-n` | `-n` | IDs only |
| `-nn` | `-nn` | Names and IDs |
| `-D` | `-D` | Domain prefix. Always `0000` — Windows' PnP data carries no segment number |
| `-k` | `-k` | Driver and version (the same lines `-v` shows) |
| `-tv`, `-nnk`, `-vvnn` … | same | Short flags combine, as in lspci; they are **case-sensitive** (`-D` ≠ `-d`) |

Long options (`-Json`, `-Downtrained`, `-Attribute` …) are case-insensitive and
may be abbreviated to a unique prefix.

> **Values and the PowerShell parser.** Run through the `lspci` launcher
> (`bin\lspci.cmd`, on PATH) every form works as typed, because the script
> recovers the raw command line. If you call `bin\lspci.ps1` directly from a
> PowerShell *prompt*, PowerShell's own parser gets there first: it splits
> `-s01:` at the colon and reads a bare `.0` or `00.0` as the number `0`. At
> the prompt, put a space before the value and quote anything that starts with
> a dot or a colon: `.\lspci.ps1 -s '.0'`, `-s ':00.0'`, `-s 01:00.0`.

### Deliberately refused

| lspci | Why |
|---|---|
| `-x`, `-xxx`, `-xxxx` | Config-space dumps. **Impossible without a signed kernel-mode driver.** Exits 2 with an explanation rather than pretending |

### Not implemented (possible, just not built)

`-b` (bus-centric view) · `-m`/`-mm` (machine-readable — `-Json`/`-Csv`/`-Attribute` supersede it) · `-p` (custom ID file) · `-P` (path display) · `-i` (custom pci.ids path) · `-q`/`-Q` (online ID lookup) · `-A`/`-O`/`-F`/`-G`/`-H1`/`-H2` (access methods — meaningless here) · `-M` (bus mapping)

Each of these is recognised and exits 2 with *"not implemented"* and a
pointer to the nearest equivalent. (An earlier version let PowerShell's
parameter binder guess: `-p` quietly ran `-PresentOnly`, `-m` demanded a
value for `-Match`. A tool that runs a different command from the one you
typed is worse than one that says no.) Anything else unknown exits 64.

### Beyond lspci

| Flag | Why it exists |
|---|---|
| `-Attribute <names>` | Query at the attribute level. Wildcards: `-Attribute Link*` |
| `-Match <regex>` | Filter by **value** |
| `-PresentOnly` | Drop attributes the device does not report |
| `-ListAttributes` | Discover what is queryable |
| `-Delimited` | `\|`-separated records, for `-split` / `cut` / `awk` habits |
| `-Delimiter` / `-Header` | Change the separator (e.g. tab); name the columns |
| `-Json` / `-Csv` | Structured output; `-Csv` quotes properly |
| `-Downtrained` | Only devices below their maximum speed or width (the `Downtrained` property). A filter: exits 1 when nothing is |

---

## Attribute-level queries — the grep replacement

Windows has no `grep`, so `lspci -vv | grep LnkSta` has no equivalent. Rather
than bolt on text search, the data is serialised to one record per attribute:

```
PS> lspci -Attribute Link* -s 01:00.0 -PresentOnly

Slot    VendorId DeviceId Attribute         Value Present
----    -------- -------- ---------         ----- -------
01:00.0 1c5c     174a     LinkStateReported  True    True
01:00.0 1c5c     174a     LinkSpeed         8GT/s    True
01:00.0 1c5c     174a     LinkWidth             4    True
```

Filter by value, which is what you would have piped to grep:

```powershell
lspci -Attribute LinkSpeed -Match '16GT|32GT|64GT'   # every Gen4+ link
lspci -Attribute Driver -Match 'stornvme'            # everything on one driver
lspci -Attribute '*' -Match '11f8' -Csv              # every field mentioning the vendor
lspci -ListAttributes                                # what can I ask for?
```

Three properties that make this better than text search:

- **`Present` is a field.** Absent and zero never collapse. A root port that
  reports no link width is not a device running at x0, and a text pipeline
  cannot tell those apart.
- **Values keep their types.** `LinkWidth` is an integer, so `-lt 4` works;
  grep would have you comparing strings.
- **An attribute query matching nothing exits 1**, so a script can tell "no
  match" from "it worked".

Composable, since these are real objects:

```powershell
# every device not running at full width, as a table
Get-PciDevice | Where-Object { $_.LinkStateReported -and $_.LinkWidth -lt $_.MaxLinkWidth } |
    Select-Object Slot, DeviceName, LinkWidth, MaxLinkWidth

# diff two machines
Get-PciDevice | ConvertTo-PciAttributeRecord | Export-Csv machine-a.csv
```

## Coming from Linux

You cannot have `grep`, `awk` and `cut` here, but you can have the shape of
them. `-Delimited` emits one record per line with `|` between fields:

```
PS> lspci -Delimited -s 01:
01:00.0|1c5c|174a|0108|Non-Volatile memory controller|SK hynix|Gold P31 NVMe SSD|00|8GT/s|4|8GT/s|4|stornvme|OK
```

| Linux | Here |
|---|---|
| `lspci \| grep NVMe` | `lspci \| Select-String NVMe` |
| `lspci -vv \| grep LnkSta` | `lspci -Attribute LinkSpeed,LinkWidth` |
| `lspci \| cut -d' ' -f1` | `lspci -Delimited \| %{ ($_ -split '\|')[0] }` |
| `lspci \| awk -F'\|' '{print $1, $9}'` | `lspci -Delimited \| %{ $f=$_ -split '\|'; "$($f[0]) $($f[8])" }` |
| `lspci \| wc -l` | `(lspci).Count` |
| `lspci -d 11f8: \|\| echo "absent"` | same — a filter matching nothing exits 1 |

`-Header` names the columns; `-Delimiter "\`t"` gives you TSV.

### Two properties worth relying on

**An empty field means *not reported*; a literal `0` means zero.** The
distinction the object model protects survives into the text form for free,
because an unset value serialises to nothing at all:

Real output from the machine this was written on:

```
00:1e.0|8086|a0a8|0780|Communication controller|Intel Corporation|Tiger Lake-LP Serial IO UART Controller #0|20|||||iaLPSS2_UART2_TGL|OK
                                                                                                               ^^^^ four empty fields: no link state
f3:00.0|10de|25a0|0302|3D controller|NVIDIA Corporation|GA107M [GeForce RTX 3050 Ti Mobile]|a1|8GT/s|4|16GT/s|16|nvlddmkm|OK
```

A device with no link state and a device genuinely training at x0 are different
findings, and `grep`-shaped output normally destroys that difference.

> The second line is also a real example of why `-Downtrained` exists: that GPU
> reports **8GT/s x4 against a maximum of 16GT/s x16**. On a laptop that is
> almost certainly link power management at idle rather than a fault — which is
> the point. The tool tells you *what the link is doing*; deciding whether that
> is a problem is still yours.
Here it survives a `-split`.

**The delimiter is stripped from values, not escaped.** Quoting rules turn a
one-liner into a parser, which defeats the point — so a `|` appearing inside a
value becomes `/` and the column count stays fixed. No `|` occurs in live PCI
data or in `pci.ids` today, but `FriendlyName` comes from driver INF files and
is not under our control. **If you need real quoting, use `-Csv`.**

> Structured beats textual where it can: `lspci -Attribute LinkSpeed -Match '16GT|32GT|64GT'`
> keeps types, so `LinkWidth -lt 4` is a numeric comparison rather than a
> string one. `-Delimited` is for when you already know the pipeline you want
> to write.

---

## Three design decisions worth knowing

All three come from the same instinct: **a wrong answer that looks right is
worse than an obvious failure.**

**"Not reported" is never rendered as zero.** Root ports and chipset devices
legitimately expose no link state. Rendering that as `x0` would look like a dead
link, so absent stays `$null` and prints as *"not reported by this device"*.
The same rule covers class codes: the host bridge reports no class property,
so it is read from the `CC_0600` hardware ID instead, and a device with no class
at all prints *Unknown class `[????]`* rather than class `0000`. `DOWNTRAINED`
is only ever said when both the current and the maximum are reported
(`$null -lt 4` is true in PowerShell, and once flagged a width that was never
there). `Present` is a real field in attribute output for the same reason.
There are tests for each.

**A filter that matches nothing exits non-zero.** `lspci -d 11f8:` finding no
card must not look like success — that is the difference between "the card is
not there" and "the command worked". Same for `-Downtrained` and for an
attribute query with no rows.

**Selectors are parsed, not string-matched.** `-s` follows lspci's grammar
field by field, so `1:` and `01:` agree, `-s 1` means device 01 on any bus
(as it does in lspci — an earlier version read it as bus 01), and `.0` or
`:00.0` work. `-d` compares vendor and device as hex numbers, so `-d 8:`
no longer quietly returns every Intel device. Anything that is not hex is one
clear error, not a .NET exception per device.

---

## Topology

`-t` builds a real tree from `DEVPKEY_Device_Parent`, so an endpoint appears
under the root port that carries it, with its link state inline — which is
where a downtrained device becomes obvious:

```
-00:06.0  11th Gen Core Processor PCIe Controller
 \-01:00.0  Gold P31/BC711/PC711 NVMe Solid State Drive  (8GT/s x4)
-00:1d.0  Tiger Lake-LP PCI Express Root Port #9
 \-f3:00.0  GA107M [GeForce RTX 3050 Ti Mobile]  (8GT/s x4)
```

A device whose parent is not itself a PCI device becomes a root rather than
being dropped. An incomplete tree that *looks* complete is worse than an
obviously ragged one, and a test asserts every enumerated device appears
exactly once.

---

## Performance

Full enumeration of a laptop (24 devices) takes ~1.7s in-process, ~2.5s as a
fresh `lspci` command (of which ~0.4s is PowerShell starting and importing the
module). `-ListAttributes` is ~0.6s: it answers from the module's static list
rather than enumerating the machine.

Getting there took several attempts, and two are worth recording:

| Approach | Time |
|---|---|
| `Get-PnpDevice` + per-property `Get-PnpDeviceProperty` | **>5 min** |
| Batched `Get-PnpDeviceProperty -KeyName <16 keys>` | ~36s |
| `Get-PnpDeviceProperty -KeyName '*'` | *appeared* 2× faster — **returned zero properties** |
| `Win32_PnPEntity` (`SELECT *`) + `Invoke-CimMethod GetDeviceProperties` | ~2s |
| `SELECT <7 columns> … WHERE PNPDeviceID LIKE "PCI\\VEN[_]%"` + same method | **~1.7s** |

The wildcard was the interesting failure: it looked like the fastest option and
was in fact doing nothing, because `-KeyName` does not support wildcards. The
benchmark was measuring a no-op, and the output still looked plausible. Only
checking the *values* caught it.

The per-device property fetch uses the CIM method the cmdlet wraps — ~30ms per
device versus ~1230ms — because the cmdlet appears to re-resolve the device on
every call while the CIM method takes an already-resolved instance.

The other surprise was where the remaining time went: the `Win32_PnPEntity`
enumeration itself, not the per-device calls. A `WHERE` clause alone barely
moves it; *projecting* the seven columns the module reads halves it, because
the provider materialises far less per instance. The `LIKE` text has exactly
two backslashes and `[_]` for the underscore (WQL's single-character wildcard)
— get the escaping wrong and the query returns **zero rows silently**, which
renders as a machine with no PCI bus. A test pins its row count against a
client-side `-like`. Parsing `pci.ids` is ~50ms and not worth optimising.

---

## PCI ID database

Bundled (`data/pci.ids`, ~1.4MB) so the tool works with no network — on a lab
bench that is usually the situation. Refresh it explicitly:

```powershell
Update-PciIds          # from https://pci-ids.ucw.cz
```

The update downloads to the temp directory, proves the file parses as a PCI ID
database (vendors, a known vendor, a known class) before touching anything,
keeps the previous copy as `pci.ids.bak`, and forces TLS 1.2 on for older
Windows PowerShell hosts. The bundled copy is dated in `lspci -Version`.

> **`11f8` is Microchip, whatever name the database shows.** Microsemi acquired
> PMC-Sierra, Microchip acquired Microsemi, and the vendor ID never changed.
> Databases before mid-2026 still read "PMC-Sierra Inc.", so a Microchip
> Switchtec switch showed as PMC-Sierra; the bundled copy now says "Microchip
> Technology". A test accepts any of the three names, so nobody at a bench at
> 11pm concludes they have the wrong part.

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
