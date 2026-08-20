# winlspci

`lspci` for Windows, without a kernel driver.

Source and issues: <https://github.com/jpmutschler/winlspci> · [User's Manual (PDF)](docs/winlspci%20Users%20Manual%20v1.3.pdf) · MIT · Windows PowerShell 5.1 · [![tests](https://github.com/jpmutschler/winlspci/actions/workflows/tests.yml/badge.svg)](https://github.com/jpmutschler/winlspci/actions/workflows/tests.yml)

```
PS> lspci -nn
00:1c.0 PCI bridge [0604]: Intel Corporation Tigerlake PCH-LP PCI Express Root Port #6 [8086:a0bd] (rev 20)
01:00.0 Non-Volatile memory controller [0108]: SK hynix Gold P31/BC711/PC711 NVMe SSD [1c5c:174a] (rev 00)

PS> lspci -d 1c5c: -vv
01:00.0 Non-Volatile memory controller: SK hynix Gold P31/BC711/PC711 NVMe Solid State Drive (rev 00)
        LnkSta: 8GT/s x4 (max 8GT/s x4)
        Type: PCIe Endpoint (PCIe capability v2)
        Driver: stornvme (10.0.26100.8972)
        Subsystem: SK hynix [1c5c:174a]
        DevCtl: MPS 256 bytes (max 512), MaxReadReq 512 bytes
        Capabilities: AER, MSI, MSI-X (33 vectors)
        Device Serial Number 00-00-00-00-00-00-00-00 (capability present, not populated)
        Power: D0 (most recent state Windows recorded)
        Location: PCIROOT(0)#PCI(0600)#PCI(0000)
        InstanceId: PCI\VEN_1C5C&DEV_174A&SUBSYS_174A1C5C&REV_00\4&391CC7C&0&0030

PS> lspci -s f3:00.0 -v
f3:00.0 3D controller: NVIDIA Corporation GA107M [GeForce RTX 3050 Ti Mobile] (rev a1)
        LnkSta: 8GT/s x4 (max 16GT/s x16)  <-- DOWNTRAINED (speed, width)
                (device is in D3: may be idle link power management rather than a fault)
        Type: PCIe Endpoint (PCIe capability v2)
        Driver: nvlddmkm (32.0.16.1088)

PS> lspci -t
-[0000:00]-+-00:06.0-[01]  11th Gen Core Processor PCIe Controller  [root port]
           |           \-01:00.0  Gold P31/BC711/PC711 NVMe Solid State Drive  (8GT/s x4)
           \-00:1d.0-[f3]  Tiger Lake-LP PCI Express Root Port #9  [root port]
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
| Class / subclass / prog-if, with names | Capability structure **contents** (presence is reported) |
| `[domain:]bus:device.function` — the PCI segment too, where Windows reports one (Hyper-V / Azure) | ASPM state, LTR, DPC |
| **Negotiated *and* maximum** link speed and width | AER register detail (presence only) |
| MPS, MRRS | Anything requiring a live register read |
| Driver binding and version, device status / problem code | |
| **Device type**: root port / upstream / downstream switch port / endpoint / integrated endpoint | |
| **Capability presence**: AER, MSI, MSI-X (+ vector count), SR-IOV, ACS, ARI, ATS, AtomicOps; PCIe capability version | |
| **Physical slot** number, firmware location path, device serial number (DSN) | |
| **Power state** (most recent D-state) — shown next to a `DOWNTRAINED` flag when it explains it | |
| Subsystem and programming-interface **names** from pci.ids (`Subsystem: Dell PERC H740P [1028:1fd2]`, `(prog-if 02 [NVM Express])`) | |
| NUMA node | |
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
| 2 | the request is impossible here (`-x`) or a known lspci flag this tool does not implement (`-p`, `-b`, `-M`, …) |
| 3 | `-Diff` / `-Watch` found differences |
| 64 | usage error: unknown option, or a selector that is not hex |
| 70 | the WMI enumeration itself failed (Windows/WMI error — not an empty machine; retry, or check the Winmgmt service) |

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

From the PowerShell Gallery (once published — see `packaging/README.md`), the
module lands in a `PSModulePath` directory with no `bin\` on PATH;
`Install-LspciShim` writes a two-line `lspci.cmd` into
`%LOCALAPPDATA%\Microsoft\WindowsApps` (usually on the user's PATH — it warns
if not — and writable only by that user) pointing at the installed CLI:

```powershell
Install-Module winlspci -Scope CurrentUser
Install-LspciShim          # -Remove to undo
lspci -nn
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
| `-s [[<dom>]:]<bus>:]<dev>[.<fn>]` | `-s` | lspci's grammar, every field optional: `01:` (bus), `01:00.0`, `1` (**device** 01 on any bus), `.0` (every function 0), `:00.0`, `0000:01:00.0`. Padded or unpadded. A selector without a domain matches every domain; `556f:00:02.0` only that one |
| `-d [<ven>]:[<dev>][:<class>]` | `-d` | Vendor and device are exact hex IDs (`-d 80:` is vendor `0080`, not every `80xx`); class is a prefix (`::01` = all storage). `-d 11f8:`, `-d :174a`, `-d ::0108` |
| `-t` | `-t` | Real topology, from `DEVPKEY_Device_Parent`. Shows link state inline; bridges tagged `[root port]` / `[upstream port]` / `[downstream port]` |
| `-v` | `-v` | Physical slot, link state (current **and** max, with the power state when it explains a downtrain), device type, driver, status |
| `-vv` | `-vv` | Adds MPS, MRRS, subsystem (`vendor:device`), NUMA, capability presence (`Capabilities: AER, MSI-X (33 vectors), SR-IOV …`), `ACS: present|not needed|missing`, serial number, power state, location path |
| `-vvv` | `-vvv` | Everything `-vv` shows, then every property Windows exposes, **plus an explicit list of what is missing** |
| `-n` | `-n` | IDs only |
| `-nn` | `-nn` | Names and IDs |
| `-D` | `-D` | Domain on every line. `0000` on ordinary machines. Hyper-V / Azure SR-IOV functions carry the PCI segment in the upper bits of Windows' bus number (`PCI bus 5598976` = segment `556f`, bus `00`); those always show it, as lspci does: `556f:00:02.0` |
| `-k` | `-k` | Driver and version (the same lines `-v` shows) |
| `-m` / `-mm` | `-m` / `-mm` | lspci's machine-readable forms: one quoted line per device, or `Key:\tValue` records. Quoted and escaped the way lspci does it (unlike `-Delimited`, these *are* parsed by other tools) |
| `-i <file>` | `-i <file>` | Use an alternate `pci.ids` |
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

`-b` (bus-centric view — Windows exposes no bus-relative view distinct from the CPU one) · `-p` (custom ID file; `-i` loads an alternate `pci.ids`) · `-P` (path display) · `-q`/`-Q` (online ID lookup) · `-A`/`-O`/`-F`/`-G`/`-H1`/`-H2` (access methods — meaningless here) · `-M` (bus mapping)

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
| `-Json` / `-Csv` | Structured output; `-Csv` quotes properly. The JSON envelope carries `schemaVersion` (currently 1), `winlspciVersion`, `generatedAt` and `computerName` (so two machines can be diffed — note it names your host if you paste the output publicly); additive changes keep the schema version, a rename or change of meaning bumps it |
| `-Downtrained` | Only devices below their maximum speed or width (the `Downtrained` property). A filter: exits 1 when nothing is |
| `-Baseline <file>` / `-Diff <file>` | Save the enumeration; later, report what appeared, disappeared or changed (exit 3 if anything did). `PowerState` is ignored unless `-IncludeVolatile`; `-IgnoreAttribute DriverVersion,Link*` to leave out what you expect to move |
| `-Watch <seconds>` | Re-enumerate on an interval and print only the changes, timestamped — hot-plug, retimer bring-up, link flaps. `-Iterations <n>` to stop after n passes |
| `-ComputerName <a,b,c>` | Enumerate other machines over WinRM (`-Credential <user>` prompts). Lines are prefixed `host:`, `-t` prints one tree per host, every object carries `ComputerName` |

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

## Baseline, diff, watch

The attribute-record shape was always meant for "did anything change?"; now the
tool finishes the job.

```
PS> lspci -Baseline before.json          # 24 devices written
   ... reboot / flash firmware / swap a card ...
PS> lspci -Diff before.json
~ 01:00.0  LinkWidth: 4 -> 1
- 02:00.0  gone: 8086:15f3 Ethernet Controller I225-V
+ 03:00.0  appeared: 10de:2684 AD102 [GeForce RTX 4090]
PS> $LASTEXITCODE                        # 3: differences found (0 = identical)
```

- Devices are matched by `InstanceId`; a reseated card whose instance id
  changed but whose slot and ids did not is reported as `Changed(InstanceId)`,
  not as a removed/added pair.
- Absent stays distinct from zero in the diff: an attribute that went from
  not reported to `0` is reported as `<absent> -> 0`.
- Only `PowerState` is ignored by default — it flips with idle and would
  answer "did the update change anything" with D-state noise every time;
  `-IncludeVolatile` compares it too. Everything else is compared, because
  the point is to see what moved. `-IgnoreAttribute` takes names with
  wildcards (`DriverVersion` after an intended update; `Link*` if you only
  care about presence).
- A `-d` / `-s` selector applies to both sides — `lspci -d 1c5c: -Diff
  before.json` diffs just the NVMe against the baseline's NVMe — and a
  selector matching nothing is still exit 1.
- A newer baseline's extra attributes are reported too (`value -> <absent>`);
  the comparison walks the union of both sides.
- `-Diff` takes `-Json` / `-Csv` / `-Delimited` for scripts. A baseline file is
  the same envelope `lspci -Json` writes, so either serves as the other.
- `lspci -Watch 2` re-enumerates every 2 s and prints only changes,
  timestamped, until Ctrl-C (`-Iterations n` to stop after n passes; exit 3 if
  anything changed). Each pass is a full enumeration, so ~2 s is the floor.

From the module: `Export-PciBaseline`, `Compare-PciBaseline` (file vs now),
`Compare-PciDeviceSet` (any two sets).

---

## Remote machines

Everything the module reads comes through `Get-CimInstance` /
`Invoke-CimMethod`, and both take a CIM session — so a fleet is one
parameter away:

```
PS> lspci -ComputerName node1,node2,node3 -Downtrained
node2: 81:00.0 Non-Volatile memory controller: Samsung ... (rev 00)
        LnkSta: 8GT/s x2 (max 16GT/s x4)  <-- DOWNTRAINED (speed, width)

PS> Get-PciDevice -ComputerName node1,node2,node3 | Where-Object Downtrained |
        Select-Object ComputerName, Slot, LinkSpeed, MaxLinkSpeed, LinkWidth, MaxLinkWidth
```

- One WinRM session per name (`-Credential <user>` prompts rather than taking a
  password on the command line — it needs a console; from a script, call
  `Get-PciDevice -Credential $cred` with a `PSCredential` you already hold).
  A node that cannot be reached is reported with a warning and skipped; if
  *none* can, the command fails (exit 70) rather than printing an empty list
  that looks like "no devices". A blank name is refused rather than quietly
  meaning "this machine"; duplicate names are enumerated once; a node whose
  property fetch fails for every device is warned about and dropped.
- Every object carries `ComputerName` — locally it is this machine's name —
  so one pipeline can sort, group and diff across hosts. With more than one
  host the CLI prefixes each device line with `host:`, prints one `-t` tree
  per host, and leads `-Delimited` with a `ComputerName` column.
- `Get-PciDevice -CimSession $s` takes sessions you manage yourself — DCOM
  works too (`New-CimSessionOption -Protocol Dcom`), which is also how the
  test suite exercises the remote path on a machine without WinRM.
- pci.ids names are resolved on the machine running the tool; the remote
  property fetch is serial (sessions are not shared across runspaces).

---

## Device type, capabilities, slot, power

All four come from DEVPKEYs the PCI bus driver fills from config space at
enumeration, so they cost nothing extra in trust — and ~300 ms extra per full
listing, which the Performance section accounts for.

- **`DeviceType`** — what Windows says the device *is*: `PCIe Root Port`,
  `PCIe Upstream Switch Port`, `PCIe Downstream Switch Port`, `PCIe Endpoint`,
  `PCIe Root Complex Integrated Endpoint`, conventional `PCI`, … `IsBridge` is
  derived. `-t` tags the bridges, and a device that reports no link state now
  says *why* when the type explains it (integrated endpoint, conventional PCI)
  rather than the generic "not reported".
- **Capability presence** — one `-vv` line: `Capabilities: AER, MSI, MSI-X (33
  vectors), SR-IOV, ARI, ATS, AtomicOps`. *Presence*, not contents: which
  capabilities the device carries is in the PnP data; what their registers
  say is not, and `-vvv` continues to say so. Each flag is also a boolean
  attribute (`-Attribute *Capable, Msi*`), `$null` when Windows reported
  nothing. SR-IOV is reported only for devices that carry the capability, and
  its value is a status (`SriovStatus`: `ok`, or a reason VFs cannot be
  enabled).
- **`ACS:`** on its own line — `present`, `not needed` (root-complex
  integrated endpoints, which have no peer-to-peer path to isolate) or, on a
  bridge, `missing` — because it is a statement about the *port*, and
  "missing" does not belong in a list of things a device has. An endpoint
  without ACS is the normal case and says nothing about isolation (the ports
  above it decide that), so it is not printed for endpoints; the attribute
  `AcsSupport` still carries it. The three values were verified against the
  ACS capability register on real hardware, not read off an enum: every
  `present` port carries a populated register, every `missing` one has none.
  If you are reasoning about IOMMU groups or DMA isolation, this is the line.
- **`PhysicalSlot`** — the chassis slot number (`DEVPKEY_Device_UINumber`),
  printed as lspci's `Physical Slot:`; **`LocationPath`** —
  `PCIROOT(0)#PCI(1C00)#PCI(0000)`; **`SerialNumber`** — the Device Serial
  Number capability as `00-11-22-33-44-55-66-77`.
- **`PowerState`** — the most recent D-state Windows recorded for the device
  (`DEVPKEY_Device_PowerData`). Shown in `-vv`, and appended to a `DOWNTRAINED`
  flag when the device is in D1–D3: *"(device is in D3: may be idle link power
  management rather than a fault)"*. It is a snapshot, not a live read — the device
  may have woken since — which is why it is offered as the likely explanation
  and not as a verdict.

---

## PCI domains (segments)

On an ordinary machine every device is in domain `0000`, the slot is
`bus:device.function`, and `-D` is the only way to see the domain — exactly
as in lspci. The exception is virtualised hardware. **Hyper-V and Azure
report SR-IOV functions on a "bus" that is really segment and bus packed
together**: Windows says `PCI bus 5598976`, which is `0x556F00` — a PCI bus
is 8 bits wide, so the upper bits are the segment. An earlier version printed
that as bus `556f00`, a slot nothing could parse; the first CI run on a GitHub
Windows runner (an Azure VM with one Mellanox ConnectX-4 virtual function)
found it.

Now the bus number is split into the **`Domain`** property (upper 16 bits)
and the bus (low 8), and — as lspci does — a non-zero domain is always shown
in the slot:

```
PS> lspci -nn                       # on an Azure VM
3851:00:00.0 Non-Volatile memory controller [0108]: Microsoft Corporation Standard NVM Express Controller [1414:b111] (rev 01)
7870:00:00.0 Ethernet controller [0200]: Microsoft Corporation Microsoft Azure Network Adapter Virtual Bus [1414:00ba] (rev 00)
c05b:00:00.0 Non-Volatile memory controller [0108]: Microsoft Corporation ASAP NVM Express Controller [1414:00a9] (rev 00)
```

- `Slot` is `[dddd:]bb:dd.f`; `Domain` is an integer (`0` normally) and is
  one of the queryable attributes (`lspci -Attribute Domain`).
- `-s` without a domain matches every domain (`-s 00:00.0` finds all three
  above); `-s 7870:00:00.0` finds one; a domain nobody is in matches nothing
  and exits 1.
- `-D` prefixes `0000:` only where the slot has no domain already — it never
  produces `0000:7870:…`.
- Sorting is by the full slot string, so devices group by domain.
- Which domains exist is Windows' decision; the numbers are the same ones
  Linux `lspci` shows on the same VM.

---

## Topology

`-t` builds a real tree from `DEVPKEY_Device_Parent` in lspci's shape: one
root per `[domain:bus]`, bridges with the secondary/subordinate bus range
their descendants occupy, children under the bridge token, link state inline
— which is where a downtrained device becomes obvious:

```
-[0000:00]-+-00:00.0  Tiger Lake-UP3/H35 4 cores Host Bridge/DRAM Registers
           +-00:06.0-[01]  11th Gen Core Processor PCIe Controller  [root port]
           |           \-01:00.0  Gold P31/BC711/PC711 NVMe Solid State Drive  (8GT/s x4)
           +-00:1c.0-[f2]  500 Series Chipset Family PCI Express Root Port #6  [root port]
           |           \-f2:00.0  Wi-Fi 6 AX200  (5GT/s x1)
           \-00:1d.0-[f3]  500 Series Chipset Family PCI Express Root Port #9  [root port]
                       \-f3:00.0  GA107M [GeForce RTX 3050 Ti Mobile]  (8GT/s x4)
```

A switch renders as its hierarchy — `01:00.0-[02-04]  … [upstream port]`,
then `02:01.0-[03] … [downstream port]` and the endpoints under each — which
is what the type tags and bus ranges are for.

Unlike lspci, every device keeps its full `bus:device.function` and stays on a
line of its own (lspci collapses single-child bridges onto one line); the
descriptions are shown, and "every enumerated device appears exactly once" is
pinned by a test. A device whose parent is not itself a PCI device becomes a
root rather than being dropped, and a node the walk cannot reach (a parent
cycle) is rendered as a root of its own. An incomplete tree that *looks*
complete is worse than an obviously ragged one.

Windows reports link state on the downstream device, not on the bridge. A
bridge with exactly one child that reports a link shows that child's link as
`DownstreamSlot` / `DownstreamLinkSpeed` / `DownstreamLinkWidth`, and `-v`
says *"LnkSta: not reported by this device (downstream 01:00.0 reports 8GT/s
x4)"* — whose link it is stays explicit. Because of this, `-s` and `-d` are
*display* filters: the whole machine is enumerated and the selector applied
last, so `lspci -s 00:1c.0 -v` shows the same downstream link as the full
listing (a filtered query costs about the same as a full one).

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
client-side `-like`. Parsing `pci.ids` is ~110ms (it was ~50ms before
subsystem names were indexed; +60ms for real subsystem names was judged worth
it) and not worth optimising further.

**The per-device fetch is parallel.** Each `GetDeviceProperties` call is
~14ms of fixed round-trip latency plus ~0.9ms per key, and the module asks
for 34 keys; serial, that is ~1.1s for 24 devices and ~12s for 300. The fixed
part is pure latency, so a RunspacePool of 8 (PowerShell 5.1 has no
`ForEach-Object -Parallel`) overlaps it: measured 1.05s → 0.47s at 24
devices, identical output. A two-call "core keys now, detail keys on `-vv`"
split was measured and rejected — the fixed cost is paid twice, so it made
`-vv` slower than fetching everything once. `Get-PciDevice -Serial` or
`WINLSPCI_SERIAL=1` restores the serial path if a box ever misbehaves.

**`WINLSPCI_FIXTURE=<file>`** replays a recorded fixture instead of the
machine. It exists so the test suite's CLI child processes do not each pay a
live enumeration; it is not a user feature, and it cannot pass for one: the
CLI prints a banner on stderr, and `source` in `-Json` and baseline files
becomes `fixture:<name>`.

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

## Layout

```
winlspci.psd1            manifest (exports, version, release notes)
winlspci.psm1            loader: module state, then dot-sources Private\ and Public\
Public\                  exported functions, one file per function or cohesive group
  Get-PciDevice.ps1        enumeration and the device object shape
  Format-Lspci.ps1         lspci-style text
  Format-PciTree.ps1       -t
  Format-PciMachine.ps1    -m / -mm
  Attributes.ps1           ConvertTo-PciAttributeRecord, Get-PciAttributeName
  Format-PciDelimited.ps1  -Delimited
  Compare-PciBaseline.ps1  Export-PciBaseline, Compare-PciBaseline, Compare-PciDeviceSet
  PciIds.ps1               pci.ids parse (vendors, devices, subsystems, classes, prog-ifs), lookups, Update-PciIds
  Install-LspciShim.ps1    puts `lspci` on PATH for Install-Module users
packaging\               release notes: Gallery, scoop manifest, winget, signing
Private\                 internal helpers
  DeviceProperties.ps1     DEVPKEY fetch, BDF, class-from-hardware-id
  Selectors.ps1            -s and -d parsing
  Helpers.ps1              downtrain test, StrictMode-safe field access, text sanitising
bin\lspci.cmd / .ps1     the command-line front end and its argument parser
data\pci.ids             bundled PCI ID database
tests\Invoke-Tests.ps1   the suite (no Pester)
```

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1
```

The same suite runs on every push under Windows PowerShell 5.1 on a GitHub
`windows-latest` runner (`.github/workflows/tests.yml`) — a different machine
with a different PCI inventory, which is the point.

**Recorded fixtures.** `tests\fixtures\*.json` are captured PCI enumerations
(entities plus their DEVPKEY bags) that the suite replays through
`Get-PciDevice` in place of the CIM calls, so the cases that matter — Azure's
packed bus numbers, a German `LocationInfo`, a phantom device, the author's
laptop — are tested on every machine, deterministically. Each has a
`.golden.txt` with its name-free rendering; a change that alters output shows
up as a golden diff, and `tests\Invoke-Tests.ps1 -UpdateGolden` rewrites them
on purpose. Record your own box with
`tests\Export-PciFixture.ps1 -Path tests\fixtures\<name>.json`.

No Pester required, deliberately: stock Windows ships Pester 3.4.0, whose
`Should Be` syntax is incompatible with Pester 5's `Should -Be`, so a Pester
suite would pass on the author's machine and fail on a colleague's.

Hardware-dependent tests assert on *shape* rather than values, since the PCI
inventory differs on every machine, and skip with a stated reason where they
genuinely need a specific device.

---

## Licence

MIT. `data/pci.ids` is BSD/GPL dual-licensed, from the PCI ID Project.
