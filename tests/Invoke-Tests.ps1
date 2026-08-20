<#
.SYNOPSIS
  winlspci test suite. No Pester required.

.DESCRIPTION
  Deliberately dependency-free. The Pester that ships on a stock Windows box is
  3.4.0, whose syntax ("Should Be") is incompatible with Pester 5's
  ("Should -Be"), so a Pester suite would work on the author's machine and fail
  on a colleague's. A portable diagnostic tool should not need an install
  before its own tests will run.

  Tests that need real hardware assert on SHAPE rather than on values, since
  the PCI inventory differs on every machine. Where a test genuinely needs a
  specific device it is skipped with a reason rather than failed, and sample
  slots are taken from whatever the machine actually has rather than assumed.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1
#>
[CmdletBinding()]
param(
    [switch]$Quiet,
    # Rewrite the fixtures' golden outputs from the current code. Deliberate
    # only: review the diff before committing.
    [switch]$UpdateGolden
)

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
$script:Skip = 0
$script:Failures = @()

function It {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Pass++
        if (-not $Quiet) { Write-Host "  PASS  $Name" -ForegroundColor Green }
    } catch {
        if ($_.Exception.Message -like 'SKIP:*') {
            $script:Skip++
            Write-Host "  SKIP  $Name -- $($_.Exception.Message -replace '^SKIP:\s*','')" -ForegroundColor Yellow
        } else {
            $script:Fail++
            $script:Failures += "$Name : $($_.Exception.Message)"
            Write-Host "  FAIL  $Name" -ForegroundColor Red
            Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Assert-True {
    param($Condition, [string]$Message = 'expected true')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = '')
    if ($Expected -ne $Actual) {
        throw "expected '$Expected', got '$Actual'. $Message"
    }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Like, [string]$Message = 'expected an exception')
    $threw = $false
    try { & $Body | Out-Null } catch {
        $threw = $true
        if ($Like -and $_.Exception.Message -notlike $Like) {
            throw "exception did not match '$Like': $($_.Exception.Message)"
        }
    }
    if (-not $threw) { throw $Message }
}

function Skip-Test { param([string]$Why) throw "SKIP: $Why" }

$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'winlspci.psd1') -Force

$cli = Join-Path $root 'bin\lspci.ps1'

function Invoke-Cli {
    <#
      Run the CLI in a child powershell.exe and return its combined output and
      exit code. Windows PowerShell 5.1 wraps ANY stderr from a native
      executable in a NativeCommandError, whatever redirection you use -- and
      this suite runs with $ErrorActionPreference = 'Stop', so a child's
      (correct, expected) refusal message on stderr would terminate the test.
      Relax the preference just for the call; stderr lines are stringified into
      the output so a test can look for the message.

      By default the child runs against the recorded laptop fixture
      (WINLSPCI_FIXTURE), so a CLI test costs ~0.7s instead of a ~3s live
      enumeration and sees the same inventory on every machine; tests that
      must hit real hardware pass -Live. The fixture banner the CLI prints on
      stderr is kept separately as .Banner and filtered out of .Output.
    #>
    param([string[]]$CliArgs = @(), [switch]$Live)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $prevFixture = $env:WINLSPCI_FIXTURE
    try {
        if ($Live) { Remove-Item Env:WINLSPCI_FIXTURE -ErrorAction SilentlyContinue }
        else { $env:WINLSPCI_FIXTURE = $script:cliFixturePath }
        $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli @CliArgs 2>&1 |
            ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
        if ($null -ne $prevFixture) { $env:WINLSPCI_FIXTURE = $prevFixture } else { Remove-Item Env:WINLSPCI_FIXTURE -ErrorAction SilentlyContinue }
    }
    # The fixture banner (stderr) and the "# source:" provenance line (stdout,
    # human listing only) are kept apart from the data lines under test.
    $banner = @($raw | Where-Object { $_ -like 'lspci: WARNING: enumerating from fixture*' })
    $provenance = @($raw | Where-Object { $_ -like '# source: fixture:*' })
    $out = @($raw | Where-Object { $_ -notlike 'lspci: WARNING: enumerating from fixture*' -and $_ -notlike '# source: fixture:*' })
    return [pscustomobject]@{ Output = $out; Text = ($out -join "`n"); Code = $code; Banner = $banner; Provenance = $provenance }
}
$script:cliFixturePath = Join-Path $PSScriptRoot 'fixtures\tigerlake-laptop.json'

# A fully-populated fake, so formatter tests do not depend on the machine.
function New-FakeDevice {
    param([hashtable]$Override = @{})
    $d = [ordered]@{
        Slot = '01:00.0'; Domain = 0; VendorId = 'dead'; DeviceId = 'beef'
        SubsystemVendorId = 'dead'; SubsystemId = 'cafe'; SubsystemVendorName = $null; SubsystemName = $null; Revision = '00'
        VendorName = 'Test'; DeviceName = 'Widget'
        ClassCode = '0108'; ClassName = 'NVMe'; ProgIf = 2; ProgIfName = $null; FriendlyName = 'Widget'
        Driver = 'x'; DriverVersion = '1'; Status = 'OK'; Problem = 0; NumaNode = $null
        LinkStateReported = $true
        LinkSpeed = '8GT/s'; LinkSpeedRaw = 3; LinkWidth = 4
        MaxLinkSpeed = '8GT/s'; MaxLinkSpeedRaw = 3; MaxLinkWidth = 4
        Downtrained = $false
        MaxPayloadSize = 256; MaxPayloadSizeSupported = 512; MaxReadRequestSize = 512
        AerCapable = $false
        DeviceType = 'PCIe Endpoint'; DeviceTypeRaw = 2; IsBridge = $false; ExpressSpecVersion = 2
        InterruptModes = 'INTx,MSI,MSI-X'; InterruptSupportRaw = 7; InterruptVectorsMax = 33
        MsiSupported = $true; MsixSupported = $true; SriovCapable = $false; SriovStatus = $null; SriovSupportRaw = $null
        AcsSupport = 'missing'; AcsSupportRaw = 2; AcsCapabilityRegister = 0
        AriCapable = $false; AtsCapable = $false; AtomicsCapable = $false; BarTypesRaw = 256; LinkSubStateRaw = 0
        PhysicalSlot = $null; LocationPath = 'PCIROOT(0)#PCI(0600)#PCI(0000)'; SerialNumber = $null; SerialNumberRaw = $null
        PowerState = 'D0'
        ParentInstanceId = $null; InstanceId = 'X'; Present = $true
    }
    foreach ($k in $Override.Keys) { $d[$k] = $Override[$k] }
    return [pscustomobject]$d
}

Write-Host "`nwinlspci tests" -ForegroundColor Cyan
Write-Host "PowerShell $($PSVersionTable.PSVersion)`n"

# ------------------------------------------------------------ ID database

Write-Host 'PCI ID database'

It 'parses the bundled pci.ids' {
    Import-PciIds -Force
    Assert-True ((Get-PciVendorName '8086') -ne $null) 'Intel 8086 should resolve'
}

It 'resolves a known vendor' {
    Assert-Equal 'Intel Corporation' (Get-PciVendorName '8086')
}

It 'resolves a known device' {
    $n = Get-PciDeviceName '1c5c' '174a'
    Assert-True ($n -like '*NVMe*') "expected an NVMe name, got '$n'"
}

It 'resolves the Microchip/Microsemi switch vendor' {
    # 11f8 read "PMC-Sierra" upstream until mid-2026 and "Microchip Technology"
    # since: Microsemi bought PMC-Sierra, Microchip bought Microsemi, and the ID
    # never changed. Accept any of the three names, so nobody at a bench
    # concludes the card is the wrong part whichever database vintage is loaded.
    $n = Get-PciVendorName '11f8'
    Assert-True ($n -like '*PMC-Sierra*' -or $n -like '*Microsemi*' -or $n -like '*Microchip*') `
        "11f8 resolved to '$n'"
}

It 'is case-insensitive on vendor ids' {
    Assert-Equal (Get-PciVendorName '8086') (Get-PciVendorName '8086'.ToUpper())
}

It 'returns null for an unknown vendor rather than inventing a name' {
    Assert-Equal $null (Get-PciVendorName 'zzzz')
}

It 'decodes device classes' {
    Assert-Equal 'Non-Volatile memory controller' (Get-PciClassName -BaseClass 1 -SubClass 8)
}

It 'falls back to the base class when the subclass is unknown' {
    $n = Get-PciClassName -BaseClass 1 -SubClass 254
    Assert-True ($n -like '*storage*' -or $n -like '*Mass storage*') "got '$n'"
}

It 'indexes subsystems and prog-ifs, and resolves them' {
    $m = Get-Module winlspci
    $counts = & $m { "$($script:SubsystemNames.Count)|$($script:ClassNames.Count)" }
    $subCount = [int]($counts -split '\|')[0]
    Assert-True ($subCount -gt 10000) "expected thousands of subsystems, got $subCount"
    # A real key from the table, whatever the database vintage.
    $key = & $m { @($script:SubsystemNames.Keys)[0] }
    $parts = $key -split '/'   # vendor/device/svendorsdevice
    $n = Get-PciSubsystemName -VendorId $parts[0] -DeviceId $parts[1] -SubsystemVendorId $parts[2].Substring(0, 4) -SubsystemId $parts[2].Substring(4)
    Assert-True ([bool]$n) "subsystem $key did not resolve"
    Assert-Equal $null (Get-PciSubsystemName 'dead' 'beef' 'dead' 'beef') 'unknown subsystem is null'
    Assert-Equal 'NVM Express' (Get-PciClassName -BaseClass 1 -SubClass 8 -ProgIf 2)
    Assert-Equal 'XHCI' (Get-PciClassName -BaseClass 0xc -SubClass 3 -ProgIf 0x30)
    Assert-Equal 'Non-Volatile memory controller' (Get-PciClassName -BaseClass 1 -SubClass 8 -ProgIf 0x7f) 'unknown prog-if falls back to the subclass'
}

It 'Import-PciIds -Path loads an alternate database, and rejects a missing one' {
    Assert-Throws { Import-PciIds -Path 'C:\definitely\not\here.ids' } -Like '*no such file*'
    $tmp = [IO.Path]::GetTempFileName()
    try {
        # A tiny curated database: vendor dead, device beef, class 01/08.
        @('dead  Test Vendor', "`tbeef  Test Widget", 'C 01  Mass storage controller', "`t08  Non-Volatile memory controller") | Set-Content $tmp -Encoding Ascii
        Import-PciIds -Path $tmp
        Assert-Equal 'Test Vendor' (Get-PciVendorName 'dead')
        Assert-Equal $null (Get-PciVendorName '8086') 'the override replaces the bundled database for the session'
        # The override must NOT become Update-PciIds' target: -WhatIf names
        # the bundled file, never the curated one.
        $m = Get-Module winlspci
        $target = & $m { $script:PciIdsPath }
        Assert-True ($target -like '*data\pci.ids') "Update target drifted to '$target'"
        Assert-True ((& $m { $script:PciIdsOverride }) -eq $tmp) 'override recorded separately'
    } finally {
        & (Get-Module winlspci) { $script:PciIdsOverride = $null }
        Import-PciIds -Force
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    Assert-Equal 'Intel Corporation' (Get-PciVendorName '8086') 'bundled database restored'
}

It 'diff records are sanitised: a hostile baseline cannot rewrite the diff line' {
    $esc = [char]27
    $before = New-FakeDevice @{ DeviceName = "OLD${esc}[2K${esc}[1GSPOOFED`rX" }
    $after = New-FakeDevice @{ DeviceName = 'NEW' }
    $r = @(Compare-PciDeviceSet -Before @($before) -After @($after))
    $rec = $r | Where-Object Attribute -eq 'DeviceName'
    Assert-True ($rec.Was -notmatch '[\x00-\x1f\x7f]') "control characters in Was: $($rec.Was)"
    $gone = @(Compare-PciDeviceSet -Before @($before) -After @())
    Assert-True ($gone[0].Was -notmatch '[\x00-\x1f\x7f]') 'Removed record must be sanitised too'
}

It 'Compare-PciBaseline rejects non-baseline files in its own voice' {
    $tmp = [IO.Path]::GetTempFileName()
    try {
        Set-Content $tmp 'null'
        Assert-Throws { Compare-PciBaseline -Path $tmp -Device @() } -Like '*does not look like a winlspci baseline*'
        Set-Content $tmp '{"schemaVersion":"abc","devices":[]}'
        Assert-Throws { Compare-PciBaseline -Path $tmp -Device @() } -Like '*schemaVersion*not a number*'
        Set-Content $tmp '{not json'
        Assert-Throws { Compare-PciBaseline -Path $tmp -Device @() } -Like '*not valid JSON*'
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

It 'Read-PciIdsFile returns empty tables for a file that is not a pci.ids' {
    # Update-PciIds relies on this to refuse a long-but-wrong download.
    $tmp = [IO.Path]::GetTempFileName()
    try {
        1..2000 | ForEach-Object { "this is not a pci.ids line $_" } | Set-Content $tmp
        $t = Read-PciIdsFile -Path $tmp
        Assert-Equal 0 $t.Vendors.Count 'garbage must not yield vendors'
        Assert-Equal 0 $t.Classes.Count
    } finally { Remove-Item $tmp -Force }
}

It 'Update-PciIds -WhatIf does not touch the database' {
    $ids = Join-Path $root 'data\pci.ids'
    $before = (Get-Item $ids).LastWriteTimeUtc
    Update-PciIds -WhatIf
    Assert-Equal $before (Get-Item $ids).LastWriteTimeUtc 'pci.ids was modified by -WhatIf'
}

# ------------------------------------------------------------ fixtures

Write-Host "`nRecorded fixtures"

$module = Get-Module winlspci
$fixtureDir = Join-Path $PSScriptRoot 'fixtures'

function Use-Fixture {
    # Run a body with a recorded fixture standing in for the machine, and
    # always clear it afterwards so the live tests below see the real box.
    param([string]$Name, [scriptblock]$Body)
    & $module { param($p) Set-PciFixture -Path $p } (Join-Path $fixtureDir "$Name.json")
    try { & $Body } finally { & $module { Set-PciFixture -Clear } }
}

function Get-FixtureGolden {
    # A name-free rendering of a device set: pci.ids names are excluded so a
    # database refresh does not churn every golden.
    param([object[]]$Devs)
    $lines = @('# lspci -n -v')
    $lines += @($Devs | Sort-Object Slot | Format-Lspci -Numeric 1 -Verbosity 1)
    $lines += '# lspci -t -n'
    $lines += @(Format-PciTree -Devices $Devs -Numeric 1)
    $lines += '# attributes (names excluded)'
    $lines += @($Devs | Sort-Object Slot | ConvertTo-PciAttributeRecord |
        Where-Object { $_.Attribute -notlike '*Name' } |      # pci.ids names, and ComputerName (machine-specific)
        ForEach-Object { "$($_.Slot) $($_.Attribute)=$($_.Value) present=$($_.Present)" })
    return $lines
}

function Assert-Golden {
    param([string]$Name, [string[]]$Actual)
    $path = Join-Path $fixtureDir "$Name.golden.txt"
    if ($UpdateGolden) {
        [IO.File]::WriteAllLines($path, $Actual, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "        (golden rewritten: $Name)" -ForegroundColor DarkYellow
        return
    }
    if (-not (Test-Path $path)) { throw "no golden at $path -- run with -UpdateGolden once and review it" }
    $expected = [IO.File]::ReadAllLines($path)
    $n = [Math]::Max($expected.Count, $Actual.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $e = if ($i -lt $expected.Count) { $expected[$i] } else { '<end>' }
        $a = if ($i -lt $Actual.Count) { $Actual[$i] } else { '<end>' }
        if ($e -ne $a) { throw "golden '$Name' differs at line $($i + 1):`n          expected: $e`n          actual:   $a" }
    }
}

$fixtureNames = @(Get-ChildItem $fixtureDir -Filter '*.json' | ForEach-Object { $_.BaseName })

It 'every fixture loads, enumerates, and matches its golden output' {
    Assert-True ($fixtureNames.Count -ge 4) "expected the committed fixtures, found $($fixtureNames.Count)"
    foreach ($name in $fixtureNames) {
        Use-Fixture $name {
            $devs = @(Get-PciDevice -IncludeAbsent)
            Assert-True ($devs.Count -gt 0) "fixture $name enumerated nothing"
            Assert-Golden $name (Get-FixtureGolden $devs)
        }
    }
}

It 'azure-sriov: packed bus numbers become domain-qualified slots' {
    Use-Fixture 'azure-sriov' {
        $devs = @(Get-PciDevice | Sort-Object Slot)
        Assert-Equal '3851:00:00.0 556f:00:02.0 7870:00:00.0' (($devs | ForEach-Object Slot) -join ' ')
        Assert-Equal 0x556f ($devs | Where-Object Slot -like '556f:*').Domain
        Assert-Equal 2 @(Get-PciDevice -Slot '00:00.0').Count 'no domain given: every domain'
        Assert-Equal 1 @(Get-PciDevice -Slot '7870:00:00.0').Count
        Assert-Equal 0 @(Get-PciDevice -Slot '0000:00:00.0').Count
    }
}

It 'de-DE-location: a localised LocationInfo still yields the right slot' {
    # The fixture deliberately carries NO BusNumber/Address, so the string is
    # the only source: an English-keyed regex would render both as ??:??.?.
    Use-Fixture 'de-DE-location' {
        Assert-Equal '00:1c.0 01:00.0' ((@(Get-PciDevice | Sort-Object Slot) | ForEach-Object Slot) -join ' ')
    }
    # Built from a code point, not a literal: this file stays ASCII so PS 5.1
    # (which reads BOM-less UTF-8 as ANSI) and PS 7 see the same string.
    $german = 'PCI-Bus 1, Ger' + [char]0xE4 + 't 0, Funktion 0'
    $loc = & $module { param($s) ConvertTo-Bdf $s $null $null } $german
    Assert-Equal '01:00.0' $loc.Slot
}

It 'phantom: absent devices are excluded by default and marked when included' {
    Use-Fixture 'phantom' {
        Assert-Equal 1 @(Get-PciDevice).Count 'phantoms must not be listed by default'
        $all = @(Get-PciDevice -IncludeAbsent | Sort-Object Slot)
        Assert-Equal 3 $all.Count
        Assert-Equal $true  ($all | Where-Object Slot -eq '00:1c.0').Present
        Assert-Equal $false ($all | Where-Object Slot -eq '01:00.0').Present 'IsPresent=false must win'
        Assert-Equal $false ($all | Where-Object Slot -eq '02:00.0').Present 'no IsPresent: Status Unknown is the fallback'
        Assert-Equal 3 @(Format-PciTree -Devices $all -Numeric 1).Count 'phantoms still render in the tree'
    }
}

It 'tigerlake-laptop: the recorded machine replays with link state intact' {
    Use-Fixture 'tigerlake-laptop' {
        $devs = @(Get-PciDevice)
        Assert-Equal 24 $devs.Count
        $nvme = $devs | Where-Object Slot -eq '01:00.0'
        Assert-Equal '8GT/s' $nvme.LinkSpeed
        Assert-Equal 4 $nvme.LinkWidth
        Assert-Equal '0600' ($devs | Where-Object Slot -eq '00:00.0').ClassCode 'host bridge class via hardware id'
    }
}

It 'tigerlake-laptop: prog-if and subsystem vendor names resolve from the recording' {
    Use-Fixture 'tigerlake-laptop' {
        $devs = @(Get-PciDevice)
        $nvme = $devs | Where-Object Slot -eq '01:00.0'
        Assert-Equal 'NVM Express' $nvme.ProgIfName
        Assert-Equal 'SK hynix' $nvme.SubsystemVendorName
        $out = @($nvme | Format-Lspci -Verbosity 1) -join "`n"
        Assert-True ($out -like '*(prog-if 02 [[]NVM Express])*') "prog-if on the -v line: $out"
        $hb = $devs | Where-Object Slot -eq '00:00.0'
        Assert-Equal $null $hb.ProgIfName 'no distinct prog-if entry: null, not the subclass name repeated'
    }
}

It 'tigerlake-laptop: device types, capabilities, slot, power decode from the recording' {
    Use-Fixture 'tigerlake-laptop' {
        $devs = @(Get-PciDevice)
        $nvme = $devs | Where-Object Slot -eq '01:00.0'
        Assert-Equal 'PCIe Endpoint' $nvme.DeviceType
        Assert-Equal $false $nvme.IsBridge
        Assert-Equal 'INTx,MSI,MSI-X' $nvme.InterruptModes
        Assert-Equal $true $nvme.MsixSupported
        Assert-Equal 33 $nvme.InterruptVectorsMax
        Assert-Equal 2 $nvme.ExpressSpecVersion
        Assert-Equal 'D0' $nvme.PowerState
        $rp = $devs | Where-Object Slot -eq '00:1c.0'
        Assert-Equal 'PCIe Root Port' $rp.DeviceType
        Assert-Equal $true $rp.IsBridge
        $wifi = $devs | Where-Object { $_.VendorId -eq '8086' -and $_.DeviceId -eq '2723' }
        Assert-Equal 5 $wifi.PhysicalSlot 'UINumber is the chassis slot'
        $usb = $devs | Where-Object { $_.DeviceId -eq '9a13' }
        Assert-Equal 'D3' $usb.PowerState 'the xHCI was in D3 when recorded'
        $hb = $devs | Where-Object Slot -eq '00:00.0'
        Assert-Equal $null $hb.DeviceType 'host bridge reports no DeviceType: stays null'
        Assert-Equal $null $hb.MsiSupported
        Assert-Equal 24 @($devs | Where-Object { $null -ne $_.LocationPath }).Count 'every device has a location path'
        # ACS: 0 present (root ports with a populated register), 2 missing
        # (endpoints without the capability), 1 not needed (RC integrated).
        Assert-Equal 'present'    ($devs | Where-Object Slot -eq '00:06.0').AcsSupport
        Assert-Equal 'missing'    $nvme.AcsSupport
        Assert-Equal 'not needed' ($devs | Where-Object Slot -eq '00:02.0').AcsSupport
        Assert-Equal 31 ($devs | Where-Object Slot -eq '00:06.0').AcsCapabilityRegister 'present ports carry a register'
        Assert-Equal 0  $nvme.AcsCapabilityRegister 'missing means no register'
        # SR-IOV: only the iGPU carries the key, with status 0 = ok -> capable.
        Assert-Equal $true ($devs | Where-Object Slot -eq '00:02.0').SriovCapable
        Assert-Equal 'ok'  ($devs | Where-Object Slot -eq '00:02.0').SriovStatus
        Assert-Equal $null $nvme.SriovCapable 'no key: unknown, not false'
    }
}

It 'decodes CM_POWER_DATA, InterruptSupport and a device serial number' {
    $m = Get-Module winlspci
    # 56-byte blob, state at bytes 4..7 (little-endian)
    $d3 = [byte[]](@(56,0,0,0, 4,0,0,0) + (1..48 | ForEach-Object { 0 }))
    $d0 = [byte[]](@(56,0,0,0, 1,0,0,0) + (1..48 | ForEach-Object { 0 }))
    Assert-Equal 'D3' (& $m { param($b) ConvertFrom-PowerData $b } $d3)
    Assert-Equal 'D0' (& $m { param($b) ConvertFrom-PowerData $b } $d0)
    Assert-Equal $null (& $m { ConvertFrom-PowerData @(56,0,0) }) 'short blob is null, not an exception'
    Assert-Equal $null (& $m { ConvertFrom-PowerData $null })
    Assert-Equal $null (& $m { ConvertFrom-PowerData @(56,0,0,0, 9,0,0,0) }) 'unknown state is null'
    # JSON round trip hands back Int32 arrays, not byte[]; must still decode
    Assert-Equal 'D3' (& $m { ConvertFrom-PowerData @([int]56,[int]0,[int]0,[int]0,[int]4,[int]0,[int]0,[int]0) })

    Assert-Equal 'INTx,MSI,MSI-X' ((& $m { ConvertFrom-InterruptSupport 7 }) -join ',')
    Assert-Equal 'MSI' ((& $m { ConvertFrom-InterruptSupport 2 }) -join ',')
    $none = & $m { ConvertFrom-InterruptSupport 0 }     # a reported 0: empty list, not $null
    Assert-True ($null -ne $none) 'reported 0 must not be null'
    Assert-Equal 0 @($none).Count
    Assert-Equal $null (& $m { ConvertFrom-InterruptSupport $null })

    Assert-Equal '01-02-03-04-05-06-07-08' (& $m { Format-DeviceSerialNumber ([uint64]0x0102030405060708) })
    Assert-Equal $null (& $m { Format-DeviceSerialNumber $null })
}

It 'the DeviceType map covers every bridge type and nothing renders a bare number' {
    $m = Get-Module winlspci
    $names = & $m { $script:DeviceTypeName }
    $bridges = & $m { $script:BridgeDeviceTypes }
    foreach ($b in $bridges) { Assert-True ($names.ContainsKey($b)) "bridge type $b has no name" }
    Assert-Equal 'PCIe Root Port' $names[8]
    Assert-Equal 'PCIe Upstream Switch Port' $names[9]
    Assert-Equal 'PCIe Downstream Switch Port' $names[10]
    Assert-True ($bridges -contains 8 -and $bridges -contains 9 -and $bridges -contains 10)
    Assert-True ($bridges -notcontains 2 -and $bridges -notcontains 4) 'endpoints are not bridges'
}

It 'a fixture never leaks into the live enumeration' {
    Use-Fixture 'phantom' { $null = Get-PciDevice }
    Assert-True (@(Get-PciDevice).Count -ne 1 -or (Get-PciDevice).Slot -ne '00:1c.0') 'fixture still active after Use-Fixture'
    Assert-Equal 'windows-pnp' (Get-PciDataSource)
    Use-Fixture 'phantom' { Assert-Equal 'fixture:phantom.json' (Get-PciDataSource) }
}

It 'switch-hierarchy: lspci-shaped tree with bus ranges, type tags, and the downstream link on bridges' {
    Use-Fixture 'switch-hierarchy' {
        $devs = @(Get-PciDevice)
        Assert-Equal 7 $devs.Count
        $lines = @(Format-PciTree -Devices $devs -Numeric 1)
        Assert-Equal 7 $lines.Count 'one line per device'
        Assert-True ($lines[0] -like '-[[]0000:00]-\-00:1c.0-[[]01-04]*[[]root port]*') "root group + range: $($lines[0])"
        Assert-True (($lines -join "`n") -like '*01:00.0-[[]02-04]*[[]upstream port]*') 'upstream port range 02-04'
        Assert-True (($lines -join "`n") -like '*02:01.0-[[]03]*[[]downstream port]*') 'downstream port range 03'
        Assert-True (($lines | Where-Object { $_ -like '*02:03.0*' })[0] -notlike '*02:03.0-[[]*') 'a bridge with no children has no range'
        # Downstream link: DS1 has one linked child (03:00.0 16GT/s x4).
        $ds1 = $devs | Where-Object Slot -eq '02:01.0'
        Assert-Equal '03:00.0' $ds1.DownstreamSlot
        Assert-Equal '16GT/s' $ds1.DownstreamLinkSpeed
        Assert-Equal 4 $ds1.DownstreamLinkWidth
        Assert-Equal $null ($devs | Where-Object Slot -eq '02:03.0').DownstreamSlot 'no child: no downstream'
        $up = $devs | Where-Object Slot -eq '01:00.0'
        Assert-Equal $null $up.DownstreamSlot 'three children, none with a link: no single downstream'
        Assert-Equal '16GT/s' $up.LinkSpeed 'a bridge''s OWN link is never overwritten'
        $out = @($ds1 | Format-Lspci -Verbosity 1) -join "`n"
        Assert-True ($out -like '*LnkSta: not reported by this device (downstream 03:00.0 reports 16GT/s x4)*') $out
        # -s / -d are display filters: selecting the bridge alone must still
        # show its child's link, and a vendor filter must not hide it either.
        $only = @(Get-PciDevice -Slot '02:01.0')
        Assert-Equal 1 $only.Count
        Assert-Equal '03:00.0' $only[0].DownstreamSlot 'downstream link must survive a slot selector'
        $byVendor = @(Get-PciDevice -Device '11f8:')
        Assert-Equal '03:00.0' ($byVendor | Where-Object Slot -eq '02:01.0').DownstreamSlot 'downstream link must survive a vendor selector (the child is Samsung)'
    }
}

It 'the WINLSPCI_FIXTURE env var is not sticky in a module session' {
    $prev = $env:WINLSPCI_FIXTURE
    try {
        $env:WINLSPCI_FIXTURE = Join-Path $fixtureDir 'phantom.json'
        Assert-Equal 1 @(Get-PciDevice).Count 'env fixture active'
        Assert-Equal 'fixture:phantom.json' (Get-PciDataSource)
        Remove-Item Env:WINLSPCI_FIXTURE
        Assert-True (@(Get-PciDevice).Count -ne 1) 'clearing the env var must return to live data'
        Assert-Equal 'windows-pnp' (Get-PciDataSource)
        $env:WINLSPCI_FIXTURE = Join-Path $fixtureDir 'azure-sriov.json'
        Assert-Equal 3 @(Get-PciDevice).Count 'changing the env var reloads'
    } finally {
        if ($null -ne $prev) { $env:WINLSPCI_FIXTURE = $prev } else { Remove-Item Env:WINLSPCI_FIXTURE -ErrorAction SilentlyContinue }
        & (Get-Module winlspci) { Set-PciFixture -Clear }
    }
}

It 'Compare-PciBaseline warns when the baseline and the enumeration have different sources' {
    $tmp = [IO.Path]::GetTempFileName()
    try {
        Use-Fixture 'phantom' { Export-PciBaseline -Path $tmp -Device @(Get-PciDevice) }
        $warnings = @()
        $null = Compare-PciBaseline -Path $tmp -Device @(New-FakeDevice) -WarningVariable warnings -WarningAction SilentlyContinue
        Assert-True (@($warnings | Where-Object { "$_" -like '*baseline source is*fixture:phantom.json*' }).Count -eq 1) "expected a source-mismatch warning, got: $($warnings -join ' | ')"
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

It 'every device carries ComputerName; a remote session enumerates the same machine identically' {
    $live = @(Get-PciDevice)     # this section runs before $devices is populated
    foreach ($d in $live) { Assert-Equal $env:COMPUTERNAME $d.ComputerName "$($d.Slot)" }
    # DCOM needs no WinRM, so a localhost session is the remote path on any box.
    $s = $null
    try { $s = New-CimSession -ComputerName localhost -SessionOption (New-CimSessionOption -Protocol Dcom) -ErrorAction Stop }
    catch { Skip-Test "no DCOM session to localhost: $($_.Exception.Message.Split([char]10)[0])" }
    try {
        $rem = @(Get-PciDevice -CimSession $s)
        Assert-Equal $live.Count $rem.Count 'session enumerates the same devices'
        Assert-Equal 'localhost' $rem[0].ComputerName 'ComputerName is the session target'
        Assert-Equal 0 @(Compare-PciDeviceSet -Before $live -After $rem -IgnoreAttribute ComputerName).Count 'same data through a session'
        $out = @($rem[0] | Format-Lspci -Verbosity 0 -ShowComputer)[0]
        Assert-True ($out.StartsWith('localhost: ')) "-ShowComputer prefix: $out"
        $out = @($rem[0] | Format-Lspci -Verbosity 0)[0]
        Assert-True (-not $out.StartsWith('localhost')) 'no prefix without -ShowComputer'
    } finally { Remove-CimSession $s -ErrorAction SilentlyContinue }
}

It 'an unreachable -ComputerName fails loudly rather than returning an empty list' {
    $bogusHost = 'no-such-host-winlspci-test'   # a variable, so the analyzer does not read it as a hardcoded target
    Assert-Throws { Get-PciDevice -ComputerName $bogusHost -WarningAction SilentlyContinue } -Like 'PCI enumeration failed: none of the requested computers*'
}

It 'a blank -ComputerName is refused, never a silent fall-back to the local machine' {
    $blank = ''
    Assert-Throws { Get-PciDevice -ComputerName $blank } -Like '*empty name*'
    Assert-Throws { Get-PciDevice -ComputerName @('  ') } -Like '*empty name*'
    $r = Invoke-Cli @('-ComputerName', '') -Live
    Assert-True ($r.Code -ne 0) "CLI must not list the local machine for a blank name (exit $($r.Code))"
}

It 'a session passed twice is enumerated once, so the downstream-link pass still works' {
    $s = $null
    try { $s = New-CimSession -ComputerName localhost -SessionOption (New-CimSessionOption -Protocol Dcom) -ErrorAction Stop }
    catch { Skip-Test "no DCOM session to localhost: $($_.Exception.Message.Split([char]10)[0])" }
    try {
        $once = @(Get-PciDevice -CimSession $s)
        $twice = @(Get-PciDevice -CimSession $s, $s)
        Assert-Equal $once.Count $twice.Count 'duplicate session must be de-duplicated'
        $bridgesWithDownstream = @($twice | Where-Object { $_.DownstreamSlot }).Count
        Assert-Equal @($once | Where-Object { $_.DownstreamSlot }).Count $bridgesWithDownstream 'downstream links survive'
    } finally { Remove-CimSession $s -ErrorAction SilentlyContinue }
}

It 'Install-LspciShim writes a shim that points at this module''s CLI, and removes it' {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("winlspci-shim-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        $null = Install-LspciShim -Directory $dir -WhatIf
        Assert-True (-not (Test-Path (Join-Path $dir 'lspci.cmd'))) '-WhatIf must not write'
        $shim = Install-LspciShim -Directory $dir -WarningAction SilentlyContinue   # dir is not on PATH: warns
        Assert-True (Test-Path $shim) 'shim written'
        $content = Get-Content $shim -Raw
        Assert-True ($content -like "*-File `"$((Resolve-Path (Join-Path $root 'bin\lspci.ps1')).Path)`"*") "shim must point at this checkout's CLI: $content"
        Assert-True ($content -like '*-NoProfile*') 'shim keeps -NoProfile'
        Assert-True ($content -notmatch '(?<!%)%(?!%|\*)') 'any % in the path must be doubled for cmd.exe (only %* may stand alone)'
        Install-LspciShim -Directory $dir -Remove
        Assert-True (-not (Test-Path $shim)) '-Remove deletes the shim'
        Assert-Throws { Install-LspciShim -Directory (Join-Path $dir 'missing') } -Like '*does not exist*'
        # A foreign lspci.cmd is neither overwritten nor removed.
        Set-Content (Join-Path $dir 'lspci.cmd') '@echo off' -Encoding Ascii
        Assert-Throws { Install-LspciShim -Directory $dir } -Like '*was not written by Install-LspciShim*'
        Assert-Throws { Install-LspciShim -Directory $dir -Remove } -Like '*was not written by Install-LspciShim*'
        Assert-True (Test-Path (Join-Path $dir 'lspci.cmd')) 'foreign file left alone'
    } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

It 'packaging\Build-Module.ps1 produces a single-file module with the same commands' {
    $dist = Join-Path ([IO.Path]::GetTempPath()) ("winlspci-dist-" + [Guid]::NewGuid().ToString('N'))
    try {
        & (Join-Path $root 'packaging\Build-Module.ps1') -OutputDirectory $dist | Out-Null
        $built = Join-Path $dist 'winlspci'
        Assert-True (Test-Path (Join-Path $built 'winlspci.psm1')) 'psm1 written'
        Assert-True (-not (Test-Path (Join-Path $built 'Public'))) 'no Public\ in the build'
        # Import it in a CHILD process so it cannot collide with the source module loaded here.
        $cmd = "Import-Module '$built\winlspci.psd1'; (Get-Command -Module winlspci | Measure-Object).Count; (Get-PciDevice | Measure-Object).Count"
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = @(& powershell.exe -NoProfile -NonInteractive -Command $cmd 2>&1 | ForEach-Object { "$_" }) } finally { $ErrorActionPreference = $prev }
        $expected = (Get-Command -Module winlspci | Measure-Object).Count
        Assert-Equal "$expected" $out[0] "built module exports $($out[0]) commands, source exports $expected ($($out -join ' | '))"
        Assert-True ([int]$out[1] -gt 0) "built module enumerates ($($out -join ' | '))"
    } finally { Remove-Item $dist -Recurse -Force -ErrorAction SilentlyContinue }
}

It 'parallel and serial property fetches produce identical devices' {
    $par = @(Get-PciDevice)
    $ser = @(Get-PciDevice -Serial)
    Assert-Equal $par.Count $ser.Count
    Assert-Equal 0 @(Compare-PciDeviceSet -Before $ser -After $par -IncludeVolatile -IgnoreAttribute PowerState).Count 'parallel must not change a single value'
    $prev = $env:WINLSPCI_SERIAL
    try {
        $env:WINLSPCI_SERIAL = '1'
        Assert-Equal $par.Count @(Get-PciDevice).Count 'WINLSPCI_SERIAL path enumerates'
    } finally { if ($null -ne $prev) { $env:WINLSPCI_SERIAL = $prev } else { Remove-Item Env:WINLSPCI_SERIAL -ErrorAction SilentlyContinue } }
}

# ------------------------------------------------------------ enumeration

Write-Host "`nEnumeration"

$devices = @(Get-PciDevice)

function Split-Slot {
    # "[dddd:]bb:dd.f" -> its fields. Hyper-V / Azure VFs carry a non-zero
    # domain, so no test may assume the slot is exactly "bb:dd.f".
    param([string]$Slot)
    if ($Slot -notmatch '^(?:([0-9a-f]{4}):)?([0-9a-f]{2}):([0-9a-f]{2})\.(\d)$') { return $null }
    $dom = 0
    if ($Matches[1]) { $dom = [Convert]::ToInt32($Matches[1], 16) }
    return [pscustomobject]@{
        Domain = $dom; DomainHex = ('{0:x4}' -f $dom)
        Bus = $Matches[2]; Device = $Matches[3]; Function = $Matches[4]
        Bdf = "$($Matches[2]):$($Matches[3]).$($Matches[4])"
    }
}

# Samples taken from the machine, not assumed: there is no guarantee of a bus 01.
$sample = $null
$sampleSlot = $null     # as rendered, possibly domain-qualified
$sampleParts = $null
$sampleBdf = $null      # bb:dd.f without the domain
$sampleBus = $null
if ($devices.Count -gt 0) {
    $sample = $devices[0]
    $sampleSlot = $sample.Slot
    $sampleParts = Split-Slot $sampleSlot
    if ($sampleParts) { $sampleBdf = $sampleParts.Bdf; $sampleBus = $sampleParts.Bus }
}

It 'enumerates at least one PCI device' {
    Assert-True ($devices.Count -gt 0) 'no PCI devices found at all'
}

It 'an invalid DEVPKEY makes enumeration FAIL LOUDLY rather than list devices with empty bags' {
    # Add a bogus key in-memory: GetDeviceProperties then throws for every
    # device. The old behaviour was 24 devices at ??:??.? with no link state,
    # exit 0. Now it is one "PCI enumeration failed" error.
    $m = Get-Module winlspci
    $saved = & $m { $script:WantedKeys }
    try {
        & $m { $script:WantedKeys = $script:WantedKeys + @('DEVPKEY_Bogus_DoesNotExist') }
        Assert-Throws { Get-PciDevice } -Like 'PCI enumeration failed on *every device*' 'empty bags must not render as devices'
    } finally {
        & $m { param($k) $script:WantedKeys = $k } $saved
    }
    Assert-True (@(Get-PciDevice).Count -gt 0) 'restored key list enumerates again'
}

It 'live: the property fetch is populated -- an invalid DEVPKEY would silently empty every bag' {
    # One rejected key name makes GetDeviceProperties throw for EVERY device,
    # and Get-DevicePropertyBag swallows that into an empty bag: no class, no
    # link, slot ??:??.?. Fixtures cannot catch it (their bags are pre-made);
    # only a live call can. This is the tripwire for adding unverified keys.
    $withClass = @($devices | Where-Object { $null -ne $_.ClassCode }).Count
    $withSlot  = @($devices | Where-Object { $_.Slot -ne '??:??.?' }).Count
    Assert-True ($withClass -gt 0) 'no device has a class code: the DEVPKEY fetch is failing for every device'
    Assert-Equal $devices.Count $withSlot 'every live device must have a slot; ??:??.? means the bag was empty'
}

It 'decodes a Hyper-V bus number with the segment in its upper bits' {
    # Azure SR-IOV VFs report "PCI bus 5598976" (0x556F00): segment 556f,
    # bus 00. Rendered naively that was bus "556f00", which nothing can parse.
    $loc = & (Get-Module winlspci) { ConvertTo-Bdf 'PCI bus 5598976, device 2, function 0' $null $null }
    Assert-Equal '556f:00:02.0' $loc.Slot
    Assert-Equal 0x556f $loc.Domain
    $plain = & (Get-Module winlspci) { ConvertTo-Bdf 'PCI bus 1, device 0, function 0' $null $null }
    Assert-Equal '01:00.0' $plain.Slot 'domain 0 is not shown'
    Assert-Equal 0 $plain.Domain
    # Out-of-range device/function is not a PCI address; fall back, never render 01:63.9.
    $bad = & (Get-Module winlspci) { ConvertTo-Bdf 'PCI bus 1, device 99, function 9' 1 0 }
    Assert-Equal '01:00.0' $bad.Slot 'fell back to BusNumber/Address'
    $unicode = & (Get-Module winlspci) { ConvertTo-Bdf ('PCI bus ' + [char]0x0661 + ', device 0, function 0') $null $null }
    Assert-Equal '??:??.?' $unicode.Slot 'non-ASCII digits must not be cast'
}

It 'an unspecified domain in -s matches every domain; a given one only itself' {
    $m = Get-Module winlspci
    Assert-True (& $m { Test-SlotMatch '556f:00:02.0' (ConvertTo-SlotFilter '00:02.0') })
    Assert-True (& $m { Test-SlotMatch '556f:00:02.0' (ConvertTo-SlotFilter '556f:00:02.0') })
    Assert-True (-not (& $m { Test-SlotMatch '556f:00:02.0' (ConvertTo-SlotFilter '0000:00:02.0') }))
    Assert-True (& $m { Test-SlotMatch '01:00.0' (ConvertTo-SlotFilter '0000:01:00.0') })
}

It 'the WQL query finds every PCI entity a client-side filter finds' {
    # The server-side LIKE is the one place a wrong escape fails SILENTLY to
    # zero rows -- a machine with no PCI bus, rendered with a straight face.
    $expected = @(Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.PNPDeviceID -like 'PCI\VEN_*' }).Count
    $actual = @(Get-PciDevice -IncludeAbsent).Count
    Assert-Equal $expected $actual 'WQL filter and client-side -like disagree'
}

It 'every device has a 4-hex-digit vendor and device id' {
    foreach ($d in $devices) {
        Assert-True ($d.VendorId -match '^[0-9a-f]{4}$') "bad VendorId '$($d.VendorId)'"
        Assert-True ($d.DeviceId -match '^[0-9a-f]{4}$') "bad DeviceId '$($d.DeviceId)'"
    }
}

It 'every device has a parseable [domain:]bus:device.function' {
    foreach ($d in $devices) {
        $p = Split-Slot $d.Slot
        Assert-True ($null -ne $p) "device $($d.VendorId):$($d.DeviceId) has slot '$($d.Slot)'"
        Assert-Equal $p.Domain $d.Domain "$($d.Slot): Domain property disagrees with the slot"
    }
}

It 'a class code is either four hex digits or absent -- never empty string' {
    foreach ($d in $devices) {
        if ($null -ne $d.ClassCode) {
            Assert-True ($d.ClassCode -match '^[0-9a-f]{4}$') "$($d.Slot) ClassCode '$($d.ClassCode)'"
            Assert-True ($null -ne $d.ClassName) "$($d.Slot) has a class code but no name"
        } else {
            Assert-True ($null -eq $d.ClassName) "$($d.Slot) has no class code but ClassName '$($d.ClassName)'"
        }
    }
}

It 'the host bridge has a class, via the hardware ID when the property is absent' {
    # 00:00.0 commonly carries no DEVPKEY_PciDevice_BaseClass, but its hardware
    # IDs say CC_0600. It must not render as "Unclassified device", and
    # `-d ::0600` must find it.
    $hb = @($devices | Where-Object { $_.Slot -eq '00:00.0' })
    if ($hb.Count -eq 0) { Skip-Test 'no device at 00:00.0 on this machine' }
    Assert-Equal '0600' $hb[0].ClassCode "host bridge class was '$($hb[0].ClassCode)'"
    Assert-True (@(Get-PciDevice -Device '::0600').Count -ge 1) '-d ::0600 should find the host bridge'
}

It 'subsystem vendor and device ids are split, each four hex digits' {
    $withSub = @($devices | Where-Object { $_.SubsystemId })
    if ($withSub.Count -eq 0) { Skip-Test 'no device reports a subsystem here' }
    foreach ($d in $withSub) {
        Assert-True ($d.SubsystemVendorId -match '^[0-9a-f]{4}$') "$($d.Slot) SubsystemVendorId '$($d.SubsystemVendorId)'"
        Assert-True ($d.SubsystemId -match '^[0-9a-f]{4}$') "$($d.Slot) SubsystemId '$($d.SubsystemId)'"
    }
}

It 'never reports a link width without reporting link state' {
    # The distinction this tool exists to preserve: "not reported" and
    # "reported as zero" must not collapse. A device with no link state must
    # carry nulls, not zeros, or a reader sees a dead link that is not there.
    foreach ($d in $devices) {
        if (-not $d.LinkStateReported) {
            Assert-True ($null -eq $d.LinkSpeed) `
                "$($d.Slot) has no link state but LinkSpeed='$($d.LinkSpeed)'"
        }
    }
}

It 'reports link state for at least one endpoint' {
    $linked = @($devices | Where-Object { $_.LinkStateReported })
    if ($linked.Count -eq 0) { Skip-Test 'no device on this machine reports link state' }
    Assert-True ($linked[0].LinkWidth -gt 0) 'a reported link should have non-zero width'
}

It 'negotiated link speed never exceeds the maximum' {
    foreach ($d in $devices) {
        if ($d.LinkStateReported -and $null -ne $d.MaxLinkSpeedRaw) {
            Assert-True ($d.LinkSpeedRaw -le $d.MaxLinkSpeedRaw) `
                "$($d.Slot) negotiated $($d.LinkSpeedRaw) above max $($d.MaxLinkSpeedRaw)"
        }
    }
}

It 'Downtrained is true exactly when speed or width is below a reported maximum' {
    foreach ($d in $devices) {
        $expect = $false
        if ($null -ne $d.LinkSpeedRaw -and $null -ne $d.MaxLinkSpeedRaw -and $d.LinkSpeedRaw -lt $d.MaxLinkSpeedRaw) { $expect = $true }
        if ($null -ne $d.LinkWidth -and $null -ne $d.MaxLinkWidth -and $d.LinkWidth -lt $d.MaxLinkWidth) { $expect = $true }
        Assert-Equal $expect $d.Downtrained "$($d.Slot)"
    }
}

# ------------------------------------------------------------ filtering

Write-Host "`nFiltering (-d)"

It 'filters by vendor' {
    $ven = $devices[0].VendorId
    $filtered = @(Get-PciDevice -Device "${ven}:")
    Assert-True ($filtered.Count -gt 0) "vendor filter '$ven' matched nothing"
    foreach ($d in $filtered) { Assert-Equal $ven $d.VendorId }
}

It 'filters by vendor and device' {
    $d0 = $devices[0]
    $filtered = @(Get-PciDevice -Device "$($d0.VendorId):$($d0.DeviceId)")
    Assert-True ($filtered.Count -gt 0) 'vendor:device filter matched nothing'
    foreach ($d in $filtered) { Assert-Equal $d0.DeviceId $d.DeviceId }
}

It 'a vendor that is not present matches nothing' {
    Assert-Equal 0 @(Get-PciDevice -Device 'ffff:').Count
}

It 'tolerates a 0x-prefixed vendor id' {
    $ven = $devices[0].VendorId
    Assert-True (@(Get-PciDevice -Device "0x${ven}:").Count -gt 0) '0x prefix not stripped'
}

It 'vendor is an exact id, not a prefix: -d 80: is vendor 0080, not every 80xx' {
    # `-d 8:` used to return every Intel device. lspci compares numbers.
    $v = $devices[0].VendorId
    $prefix = $v.Substring(0, 2)
    $expected = @($devices | Where-Object { $_.VendorId -eq ('00' + $prefix) }).Count
    Assert-Equal $expected @(Get-PciDevice -Device "${prefix}:").Count
}

It 'an unpadded vendor id is padded, as lspci does' {
    $v = $devices[0].VendorId.TrimStart('0')
    if (-not $v -or $v -eq $devices[0].VendorId) { Skip-Test 'first vendor id has no leading zero to strip' }
    Assert-Equal @(Get-PciDevice -Device "$($devices[0].VendorId):").Count @(Get-PciDevice -Device "${v}:").Count
}

It 'a class filter is a prefix: ::01 is every mass-storage class' {
    $expected = @($devices | Where-Object { $_.ClassCode -and $_.ClassCode.StartsWith('01') }).Count
    Assert-Equal $expected @(Get-PciDevice -Device '::01').Count
}

It 'rejects a non-hex or wildcard device filter with one clear error' {
    Assert-Throws { Get-PciDevice -Device '*:' } -Like '*invalid device filter*'
    Assert-Throws { Get-PciDevice -Device 'zz:' } -Like '*invalid device filter*'
    Assert-Throws { Get-PciDevice -Device ':[abc' } -Like '*invalid device filter*'
}

# ------------------------------------------------------------ slot filter

Write-Host "`nSlot filter (-s)"

It 'accepts an unpadded bus number, as lspci does' {
    # This returned NOTHING before normalisation: `-s 1:` missed while
    # `-s 01:` matched. A filter that silently finds nothing when the device is
    # right there is the worst kind of wrong answer.
    $unpaddedBus = ([Convert]::ToInt32($sampleBus, 16)).ToString('x')
    $padded = @(Get-PciDevice -Slot "${sampleBus}:").Count
    $unpadded = @(Get-PciDevice -Slot "${unpaddedBus}:").Count
    Assert-True ($padded -gt 0) "sample bus $sampleBus matched nothing"
    Assert-Equal $padded $unpadded 'padded and unpadded must agree'
}

It 'accepts a full unpadded bus:device.function' {
    $unpadded = '{0:x}:{1:x}.{2}' -f [Convert]::ToInt32($sampleParts.Bus, 16), [Convert]::ToInt32($sampleParts.Device, 16), $sampleParts.Function
    $a = @(Get-PciDevice -Slot $sampleBdf).Count
    $b = @(Get-PciDevice -Slot $unpadded).Count
    Assert-True ($a -gt 0) "sample slot $sampleBdf matched nothing"
    Assert-Equal $a $b
}

It 'accepts a domain-qualified slot' {
    $any = @(Get-PciDevice -Slot $sampleBdf).Count                                    # every domain
    $one = @(Get-PciDevice -Slot "$($sampleParts.DomainHex):$sampleBdf").Count       # the sample's
    Assert-True ($one -ge 1) "domain-qualified $($sampleParts.DomainHex):$sampleBdf matched nothing"
    Assert-True ($one -le $any) 'qualifying by domain cannot match more'
    $allSameDomain = @($devices | Where-Object { $_.Domain -ne $sampleParts.Domain }).Count -eq 0
    if ($allSameDomain) { Assert-Equal $any $one 'single-domain machine: qualified and unqualified agree' }
}

It 'a domain nobody is in matches nothing' {
    $unused = '{0:x4}' -f ((($devices | ForEach-Object { $_.Domain } | Measure-Object -Maximum).Maximum + 1) -band 0xffff)
    Assert-Equal 0 @(Get-PciDevice -Slot "${unused}:$sampleBdf").Count
}

It 'a bus with nothing on it matches nothing' {
    $used = @($devices | ForEach-Object { $_.Slot.Substring(0, 2) })
    $empty = @('ee', 'ed', 'ec', 'eb', 'ea', 'e9') | Where-Object { $used -notcontains $_ } | Select-Object -First 1
    if (-not $empty) { Skip-Test 'could not find an unused bus number' }
    Assert-Equal 0 @(Get-PciDevice -Slot "${empty}:").Count
}

It 'a bare number is a DEVICE on any bus, as in lspci -- not a bus' {
    # lspci: [[[[<domain>]:]<bus>]:][<device>][.[<func>]]. `-s 1` is device 01.
    $devNum = $sampleParts.Device
    $expected = @($devices | Where-Object { (Split-Slot $_.Slot).Device -eq $devNum }).Count
    Assert-Equal $expected @(Get-PciDevice -Slot $devNum).Count "-s $devNum"
    Assert-Equal $expected @(Get-PciDevice -Slot ([Convert]::ToInt32($devNum, 16)).ToString('x')).Count 'unpadded device'
}

It '.0 selects function 0 of everything' {
    $expected = @($devices | Where-Object { $_.Slot.EndsWith('.0') }).Count
    Assert-True ($expected -gt 0) 'no function-0 device?'
    Assert-Equal $expected @(Get-PciDevice -Slot '.0').Count
}

It ':<device>.<func> selects that device and function on any bus' {
    $tail = "$($sampleParts.Device).$($sampleParts.Function)"   # dd.f
    $expected = @($devices | Where-Object { $_.Slot.EndsWith(":$tail") }).Count
    Assert-Equal $expected @(Get-PciDevice -Slot ":$tail").Count
}

It 'rejects a non-hex slot with one clear error, not an exception per device' {
    Assert-Throws { Get-PciDevice -Slot 'foo' } -Like '*invalid slot filter*'
    Assert-Throws { Get-PciDevice -Slot 'zz:qq.9' } -Like '*invalid slot filter*'
    Assert-Throws { Get-PciDevice -Slot '01:00.8' } -Like '*invalid slot filter*'
    Assert-Throws { Get-PciDevice -Slot '01:20' } -Like '*invalid slot filter*'
}

# ------------------------------------------------------------ formatting

Write-Host "`nFormatting"

It 'renders one line per device at verbosity 0' {
    $out = @($devices[0] | Format-Lspci -Verbosity 0 -Numeric 0)
    Assert-Equal 1 $out.Count
}

It 'includes hex ids in -nn mode and not in name mode' {
    $withIds = @($devices[0] | Format-Lspci -Verbosity 0 -Numeric 2) -join "`n"
    $namesOnly = @($devices[0] | Format-Lspci -Verbosity 0 -Numeric 0) -join "`n"
    # .Contains, not -like: '[' is a wildcard metacharacter in PowerShell, so
    # "*[8086:*" is an invalid pattern rather than a literal match.
    $needle = "[$($devices[0].VendorId):$($devices[0].DeviceId)]"
    Assert-True ($withIds.Contains($needle)) "nn mode should carry '$needle'"
    Assert-True (-not $namesOnly.Contains($needle)) 'name mode should not carry ids'
}

It 'flags a downtrained link in words, not just numbers' {
    $fake = New-FakeDevice @{ LinkSpeedRaw = 3; LinkWidth = 2; MaxLinkSpeed = '16GT/s'; MaxLinkSpeedRaw = 4; MaxLinkWidth = 4 }
    $out = @($fake | Format-Lspci -Verbosity 1) -join "`n"
    Assert-True ($out -like '*DOWNTRAINED (speed, width)*') "both downtrains, one marker: $out"
    $speedOnly = New-FakeDevice @{ LinkSpeedRaw = 3; MaxLinkSpeed = '16GT/s'; MaxLinkSpeedRaw = 4 }
    $out = @($speedOnly | Format-Lspci -Verbosity 1) -join "`n"
    Assert-True ($out -like '*DOWNTRAINED (speed)*' -and $out -notlike '*width*') "speed only: $out"
}

It 'explains a downtrained link by its power state, only when the state is known and not D0' {
    $down = @{ LinkSpeedRaw = 3; LinkWidth = 2; MaxLinkSpeed = '16GT/s'; MaxLinkSpeedRaw = 4; MaxLinkWidth = 4 }
    $d3 = New-FakeDevice ($down + @{ PowerState = 'D3' })
    $lines = @($d3 | Format-Lspci -Verbosity 1)
    $i = [array]::IndexOf(@($lines | ForEach-Object { $_ -like '*DOWNTRAINED*' }), $true)
    Assert-True ($i -ge 0) "no DOWNTRAINED line: $($lines -join "`n")"
    Assert-True ($lines[$i + 1] -like '*device is in D3*may be idle link power management*') "D3 note should follow on its own line: $($lines -join "`n")"
    $d0 = New-FakeDevice ($down + @{ PowerState = 'D0' })
    $out = @($d0 | Format-Lspci -Verbosity 1) -join "`n"
    Assert-True ($out -like '*DOWNTRAINED*' -and $out -notlike '*device is in D0*') "D0 must not be offered as an explanation: $out"
    $unknown = New-FakeDevice ($down + @{ PowerState = $null })
    $out = @($unknown | Format-Lspci -Verbosity 1) -join "`n"
    Assert-True ($out -notlike '*device is in*') "unknown power state must say nothing: $out"
}

It 'omits the Subsystem line for 0000:0000 rather than inventing "Vendor 0000"' {
    $fake = New-FakeDevice @{ SubsystemVendorId = '0000'; SubsystemId = '0000' }
    $out = @($fake | Format-Lspci -Verbosity 2) -join "`n"
    Assert-True ($out -notlike '*Subsystem:*') "0000:0000 must not print a subsystem: $out"
}

It 'marks an all-zero device serial number as not populated' {
    $fake = New-FakeDevice @{ SerialNumber = '00-00-00-00-00-00-00-00'; SerialNumberRaw = 0 }
    $out = @($fake | Format-Lspci -Verbosity 2) -join "`n"
    Assert-True ($out -like '*Device Serial Number 00-00-00-00-00-00-00-00 (capability present, not populated)*') $out
    $real = New-FakeDevice @{ SerialNumber = '01-02-03-04-05-06-07-08'; SerialNumberRaw = 72623859790382856 }
    $out = @($real | Format-Lspci -Verbosity 2) -join "`n"
    Assert-True ($out -like '*01-02-03-04-05-06-07-08*' -and $out -notlike '*not populated*') $out
}

It 'renders capability presence as one line, type and physical slot, and nothing when unreported' {
    $fake = New-FakeDevice @{ AerCapable = $true; PhysicalSlot = 4; SriovCapable = $true }
    $out = @($fake | Format-Lspci -Verbosity 2) -join "`n"
    Assert-True ($out -like '*Physical Slot: 4*') $out
    Assert-True ($out -like '*Type: PCIe Endpoint (PCIe capability v2)*') $out
    Assert-True ($out -like '*Capabilities: AER, MSI, MSI-X (33 vectors), SR-IOV*') "caps line: $out"
    $capsLine = @($out -split "`n" | Where-Object { $_ -like '*Capabilities:*' })[0]
    Assert-True ($capsLine -notlike '*ACS*') "ACS does not belong in the capability list: $capsLine"
    # The fake is an ENDPOINT: "missing" is the normal case there and says
    # nothing about isolation, so it is not printed; a bridge gets the line.
    Assert-True ($out -notlike '*ACS:*') "endpoint with ACS missing must print no ACS line: $out"
    $bridge = New-FakeDevice @{ IsBridge = $true; DeviceType = 'PCIe Root Port'; DeviceTypeRaw = 8; AcsSupport = 'missing'; AcsSupportRaw = 2 }
    $out = @($bridge | Format-Lspci -Verbosity 2) -join "`n"
    Assert-True ($out -like '*ACS: missing (Windows expected ACS*') "bridge ACS line: $out"
    $present = New-FakeDevice @{ AcsSupport = 'present'; AcsSupportRaw = 0; AcsCapabilityRegister = 31 }
    $out = @($present | Format-Lspci -Verbosity 2) -join "`n"
    Assert-True ($out -like '*ACS: present*') "endpoint with ACS present is worth saying: $out"
    Assert-True ($out -like '*Power: D0*') $out
    $none = New-FakeDevice @{ AerCapable = $false; MsiSupported = $false; MsixSupported = $false; SriovCapable = $false
        AriCapable = $false; AtsCapable = $false; AtomicsCapable = $false; AcsSupport = $null }
    $out = @($none | Format-Lspci -Verbosity 2) -join "`n"
    Assert-True ($out -like '*Capabilities: none reported*') "all-false must say none reported: $out"
    Assert-True ($out -notlike '*ACS:*') 'null AcsSupport prints no ACS line'
    $absent = New-FakeDevice @{ AerCapable = $null; MsiSupported = $null; MsixSupported = $null; SriovCapable = $null
        AriCapable = $null; AtsCapable = $null; AtomicsCapable = $null; AcsSupport = $null; DeviceType = $null
        PhysicalSlot = $null; PowerState = $null; LocationPath = $null }
    $out = @($absent | Format-Lspci -Verbosity 2) -join "`n"
    Assert-True ($out -notlike '*Capabilities:*' -and $out -notlike '*Type:*' -and $out -notlike '*Power:*') "absent must print nothing: $out"
}

It 'the tree tags bridges by type and leaves endpoints untagged' {
    $rp = New-FakeDevice @{ Slot = '00:1c.0'; InstanceId = 'RP'; DeviceType = 'PCIe Root Port'; DeviceTypeRaw = 8; IsBridge = $true; LinkStateReported = $false }
    $us = New-FakeDevice @{ Slot = '01:00.0'; InstanceId = 'US'; ParentInstanceId = 'RP'; DeviceType = 'PCIe Upstream Switch Port'; DeviceTypeRaw = 9; IsBridge = $true }
    $ds = New-FakeDevice @{ Slot = '02:00.0'; InstanceId = 'DS'; ParentInstanceId = 'US'; DeviceType = 'PCIe Downstream Switch Port'; DeviceTypeRaw = 10; IsBridge = $true }
    $ep = New-FakeDevice @{ Slot = '03:00.0'; InstanceId = 'EP'; ParentInstanceId = 'DS' }
    $lines = @(Format-PciTree -Devices @($rp, $us, $ds, $ep))
    Assert-Equal 4 $lines.Count
    Assert-True ($lines[0] -like '*[[]root port]*') $lines[0]
    Assert-True ($lines[1] -like '*[[]upstream port]*') $lines[1]
    Assert-True ($lines[2] -like '*[[]downstream port]*') $lines[2]
    Assert-True ($lines[3] -notlike '*[[]*port]*') "endpoint must not be tagged: $($lines[3])"
}

It 'does NOT flag a downtrained width when the width is simply not reported' {
    # $null -lt 4 is TRUE in PowerShell. An unguarded comparison once reported
    # a device with no link width as DOWNTRAINED (width) -- an invented fault.
    $fake = New-FakeDevice @{ LinkWidth = $null; MaxLinkWidth = 4 }
    $out = @($fake | Format-Lspci -Verbosity 1) -join "`n"
    Assert-True ($out -notlike '*DOWNTRAINED*') "absent width flagged as downtrained: $out"
    Assert-True ($out -like '*x?*') "absent width should render as x?, got: $out"
    Assert-True ($out -notlike '*x0*') "absent width must not render as x0: $out"
}

It 'says so plainly when link state is absent' {
    $fake = New-FakeDevice @{
        Slot = '00:00.0'; ClassCode = '0600'; ClassName = 'Host bridge'
        LinkStateReported = $false; LinkSpeed = $null; LinkSpeedRaw = $null; LinkWidth = $null
        MaxLinkSpeed = $null; MaxLinkSpeedRaw = $null; MaxLinkWidth = $null
    }
    $out = @($fake | Format-Lspci -Verbosity 1) -join "`n"
    Assert-True ($out -like '*not reported*') "expected an explicit 'not reported': $out"
    Assert-True ($out -notlike '*x0*') "must not render an absent width as x0: $out"
}

It 'an absent class renders as unknown, never as class 0000 or "Unclassified device"' {
    $fake = New-FakeDevice @{ ClassCode = $null; ClassName = $null }
    $n  = @($fake | Format-Lspci -Verbosity 0 -Numeric 1) -join "`n"
    $nn = @($fake | Format-Lspci -Verbosity 0 -Numeric 2) -join "`n"
    Assert-True ($n -like '*????*') "-n should show ????: $n"
    Assert-True ($nn -like '*Unknown class*') "-nn should say Unknown class: $nn"
    Assert-True ($nn -notlike '*Unclassified*' -and $nn -notlike '*0000*' -and $nn -notlike '*[[]]*') "leaked a fake class: $nn"
}

It 'prints the subsystem as vendor:device, the way lspci does' {
    # Windows packs SUBSYS_<device><vendor>; printed raw it reads backwards.
    $fake = New-FakeDevice @{ SubsystemVendorId = '1c5c'; SubsystemId = '174a' }
    $out = @($fake | Format-Lspci -Verbosity 2) -join "`n"
    Assert-True ($out.Contains('[1c5c:174a]')) "subsystem should be [vendor:device]: $out"
    Assert-True (-not $out.Contains('174a1c5c')) 'raw Windows order leaked'
}

It '-vvv is a superset of -vv' {
    $fake = New-FakeDevice
    $vv  = @($fake | Format-Lspci -Verbosity 2)
    $vvv = @($fake | Format-Lspci -Verbosity 3)
    foreach ($line in $vv) {
        Assert-True ($vvv -contains $line) "-vvv lost a -vv line: '$line'"
    }
    Assert-True (($vvv -join "`n") -like '*DevCtl: MPS 256 bytes*') '-vvv should keep the decoded DevCtl line'
}

It 'folds terminal escape sequences in names before they reach the console' {
    # Names come from driver INF files and pci.ids; an ESC-bearing name could
    # clear and rewrite the line it is printed on.
    $esc = [char]27
    $fake = New-FakeDevice @{ DeviceName = "Evil${esc}[2K${esc}[1Gspoofed`rX" }
    $out = @($fake | Format-Lspci -Verbosity 0) -join "`n"
    Assert-True ($out -notmatch '[\x00-\x1f\x7f]') "control characters leaked: $out"
    Assert-True ($out -like '*spoofed*') 'the printable text must survive'
}

It 'sanitises every verbosity, including the -vvv dump, Location and Physical Slot' {
    $esc = [char]27
    $fake = New-FakeDevice @{
        FriendlyName = "FRIENDLY${esc}[31mNAME"; DeviceName = $null
        LocationPath = "PCIROOT(0)#PCI(1D00)${esc}[2K${esc}[1GEVIL`rX"; PhysicalSlot = "3${esc}[31m"
    }
    foreach ($v in 1, 2, 3) {
        $out = @($fake | Format-Lspci -Verbosity $v) -join "`n"
        Assert-True ($out -notmatch '[\x00-\x08\x0b-\x1f\x7f]') "control characters leaked at -v$v"
    }
}

It 'formats a trimmed object (Select-Object) with gaps rather than crashing under StrictMode' {
    $trimmed = $devices[0] | Select-Object Slot, VendorId, DeviceId
    $out = @($trimmed | Format-Lspci -Verbosity 2)
    Assert-True ($out.Count -ge 1) 'no output for a trimmed object'
    Assert-True ($out[0] -like "$($devices[0].Slot)*") "first line should start with the slot: $($out[0])"
}

# ------------------------------------------------------------ tree

Write-Host "`nTree (-t)"

It 'renders a tree with every device present exactly once' {
    $lines = @(Format-PciTree -Devices $devices -Numeric 1)
    Assert-Equal $devices.Count $lines.Count `
        'a device must appear exactly once -- no drops, no duplicates'
    Assert-True ($lines[0] -like '-[[]????:??]-*' -or $lines[0] -match '^-\[[0-9a-f]{4}:[0-9a-f]{2}\]-') "first line is a [domain:bus] root group: $($lines[0])"
}

It 'nests an endpoint under its root port' {
    $child = $devices | Where-Object { $_.ParentInstanceId -and
        ($devices.InstanceId -contains $_.ParentInstanceId) } | Select-Object -First 1
    if (-not $child) { Skip-Test 'no parent/child pair on this machine' }
    $lines = @(Format-PciTree -Devices $devices -Numeric 1)
    $line = $lines | Where-Object { $_ -like "*$($child.Slot)*" } | Select-Object -First 1
    # A root group starts at column 0 with "-[dddd:bb]-"; a child is indented
    # and branched. Test the property (indented, not at column 0) rather than
    # an exact glyph set, so the assertion survives a cosmetic change.
    Assert-True ($line.StartsWith(' ')) "child line is not indented: '$line'"
    Assert-True ($line.Contains('-' + $child.Slot)) "child slot missing: '$line'"
    # And its parent carries the child's bus as its range.
    $parent = $devices | Where-Object InstanceId -eq $child.ParentInstanceId
    $childBus = (Split-Slot $child.Slot).Bus
    $pline = $lines | Where-Object { $_ -like "*$($parent.Slot)-[[]*" } | Select-Object -First 1
    if ($parent.IsBridge) { Assert-True ($pline -like "*$($parent.Slot)-[[]*$childBus*]*") "bridge range should cover bus $childBus : $pline" }
}

It 'a device whose parent is absent still appears, as a root' {
    # Nothing may be silently dropped: an incomplete tree that looks complete
    # is worse than an obviously ragged one.
    $orphan = [pscustomobject]@{
        Slot='09:00.0'; VendorId='dead'; DeviceId='beef'; DeviceName='Orphan'
        FriendlyName='Orphan'; ClassName='Test'; LinkStateReported=$false
        LinkSpeed=$null; LinkWidth=$null; InstanceId='X'; ParentInstanceId='NOT-PRESENT'
    }
    $lines = @(Format-PciTree -Devices @($orphan) -Numeric 1)
    Assert-Equal 1 $lines.Count
    Assert-True ($lines[0] -like '*09:00.0*') 'orphan must still be listed'
}

It 'a device in a parent cycle still appears exactly once' {
    # Self-parented (or mutually-parented) nodes are never reachable from a
    # root; they used to vanish from the tree without a word.
    $a = New-FakeDevice @{ Slot = '05:00.0'; InstanceId = 'A'; ParentInstanceId = 'B' }
    $b = New-FakeDevice @{ Slot = '06:00.0'; InstanceId = 'B'; ParentInstanceId = 'A' }
    $self = New-FakeDevice @{ Slot = '07:00.0'; InstanceId = 'S'; ParentInstanceId = 'S' }
    $lines = @(Format-PciTree -Devices @($a, $b, $self) -Numeric 1)
    Assert-Equal 3 $lines.Count "expected 3 lines, got: $($lines -join ' | ')"
}

It 'renders every trimmed object in the tree -- even with no InstanceId at all' {
    # Without InstanceId every node looks alike; an earlier version keyed its
    # visited-set on that (empty) id and rendered 24 devices as ONE line.
    $trimmed = @($devices | Select-Object Slot, DeviceName)
    $lines = @(Format-PciTree -Devices $trimmed)
    Assert-Equal $devices.Count $lines.Count 'every trimmed device must still appear'
    $dupes = @(Format-PciTree -Devices @($devices[0], $devices[0], $sample) -Numeric 1)
    Assert-Equal 3 $dupes.Count 'duplicate objects are still three inputs'
}

It 'flattens a trimmed object to attribute records without crashing' {
    $records = @($devices[0] | Select-Object DeviceName | ConvertTo-PciAttributeRecord)
    Assert-Equal 1 $records.Count
    Assert-Equal 'DeviceName' $records[0].Attribute
}

# ------------------------------------------------------ attribute queries

Write-Host "`nAttribute serialisation"

It 'flattens a device to one record per attribute' {
    $records = @($sample | ConvertTo-PciAttributeRecord)
    Assert-True ($records.Count -gt 10) "expected many attributes, got $($records.Count)"
    foreach ($r in $records) { Assert-Equal $sample.Slot $r.Slot }
}

It 'filters attributes by wildcard' {
    $records = @($sample | ConvertTo-PciAttributeRecord -Attribute 'Link*')
    Assert-True ($records.Count -gt 0) 'Link* matched nothing'
    foreach ($r in $records) { Assert-True ($r.Attribute -like 'Link*') $r.Attribute }
}

It 'filters by value, standing in for grep' {
    $ven = $sample.VendorId
    $records = @($devices | ConvertTo-PciAttributeRecord -Attribute 'VendorId' -Match "^$ven$")
    Assert-True ($records.Count -gt 0) "no $ven devices matched"
    foreach ($r in $records) { Assert-Equal $ven $r.Value }
}

It 'marks absent attributes as not present rather than dropping them' {
    $records = @($devices | ConvertTo-PciAttributeRecord -Attribute 'MaxPayloadSize')
    $absent = @($records | Where-Object { -not $_.Present })
    if ($absent.Count -eq 0) { Skip-Test 'every device reports MaxPayloadSize here' }
    foreach ($r in $absent) {
        Assert-True ($null -eq $r.Value -or "$($r.Value)" -eq '') `
            "marked absent but carries '$($r.Value)'"
    }
}

It 'PresentOnly drops the absent ones' {
    $all = @($devices | ConvertTo-PciAttributeRecord -Attribute 'MaxPayloadSize')
    $present = @($devices | ConvertTo-PciAttributeRecord -Attribute 'MaxPayloadSize' -PresentOnly)
    Assert-True ($present.Count -le $all.Count) 'PresentOnly must not add rows'
    foreach ($r in $present) { Assert-True $r.Present }
}

It 'lists the attribute names so a query can be written' {
    $names = @(Get-PciAttributeName)
    Assert-True ($names -contains 'LinkSpeed') 'LinkSpeed should be discoverable'
    Assert-True ($names -contains 'Slot')
}

It 'the static attribute list matches the live object shape exactly' {
    # Get-PciAttributeName answers from a static list so it need not enumerate
    # the machine. The only way that goes wrong is the list drifting from the
    # object, so pin them together.
    $live = @($sample.PSObject.Properties | Where-Object { $_.Name -ne 'PSTypeName' } |
        ForEach-Object { $_.Name } | Sort-Object)
    $static = @(Get-PciAttributeName)
    Assert-Equal ($live -join ',') ($static -join ',') 'attribute list drifted from the object'
}

# ------------------------------------------------------ machine-readable

Write-Host "`nMachine-readable (-m / -mm)"

It '-m is one quoted line per device with lspci quoting; -r00/-p00 and 0000 subsystem omitted as pciutils does' {
    $fake = New-FakeDevice @{ DeviceName = 'Widget "Pro"'; Revision = '1a'; SubsystemVendorId = '1c5c'; SubsystemId = '174a'; SubsystemVendorName = 'SK hynix'; SubsystemName = $null }
    $line = @($fake | Format-PciMachine -Mode 1)[0]
    Assert-Equal '01:00.0 "NVMe" "Test" "Widget \"Pro\"" -r1a -p02 "SK hynix" "Device 174a"' $line
    $ids = @($fake | Format-PciMachine -Mode 1 -Numeric 1)[0]
    Assert-True ($ids.StartsWith('01:00.0 "0108" "dead" "beef"')) $ids
    $zero = New-FakeDevice @{ Revision = '00'; ProgIf = 0; SubsystemVendorId = '0000'; SubsystemId = '0000' }
    $line = @($zero | Format-PciMachine -Mode 1)[0]
    Assert-True ($line -notlike '*-r00*' -and $line -notlike '*-p00*') "zero rev/prog-if must be omitted: $line"
    Assert-True ($line.EndsWith('"" ""')) "no subsystem prints empty quotes: $line"
    $rec = @($zero | Format-PciMachine -Mode 2) -join "`n"
    Assert-True ($rec -notlike '*SVendor*' -and $rec -notlike '*Vendor 0000*') "-mm must not invent a 0000 subsystem: $rec"
}

It 'the pci.ids parser resets nested state at vendor and class boundaries' {
    # Malformed input (reachable through -i): a two-tab line directly under a
    # new vendor, and one directly under a new class, must not attach to the
    # PREVIOUS vendor's device / class's subclass.
    $tmp = [IO.Path]::GetTempFileName()
    try {
        @('1000  Vendor One', "`t0001  Device A", "`t`t1028 1fd2  Card X", '1001  Vendor Two', "`t`t9999 8888  Orphan subsystem",
          'C 01  Mass storage', "`t08  NVM", "`t`t02  NVM Express", 'C 02  Network', "`t`t05  Orphan prog-if") | Set-Content $tmp -Encoding Ascii
        $t = Read-PciIdsFile -Path $tmp
        Assert-Equal 'Card X' $t.Subsystems['1000/0001/10281fd2']
        Assert-True (-not $t.Subsystems.ContainsKey('1001/0001/99998888')) 'orphan subsystem attached to a stale device'
        Assert-Equal 'NVM Express' $t.Classes['010802']
        Assert-True (-not $t.Classes.ContainsKey('020805')) 'orphan prog-if attached to a stale subclass'
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

It '-mm is a record per device, blank-line separated' {
    $rec = @((New-FakeDevice), (New-FakeDevice @{ Slot = '02:00.0' }) | Format-PciMachine -Mode 2)
    Assert-True ($rec[0] -eq "Slot:`t01:00.0") $rec[0]
    Assert-True (($rec | Where-Object { $_ -eq '' }).Count -eq 2) 'two records, two terminating blank lines'
    Assert-True (($rec | Where-Object { $_ -like 'Slot:*' }).Count -eq 2)
}

# ------------------------------------------------------ baseline / diff

Write-Host "`nBaseline and diff"

It 'Compare-PciDeviceSet reports added, removed and changed, keeping absent distinct from zero' {
    $a = New-FakeDevice @{ Slot = '01:00.0'; InstanceId = 'A'; LinkWidth = 4; NumaNode = $null }
    $b = New-FakeDevice @{ Slot = '02:00.0'; InstanceId = 'B' }
    $a2 = New-FakeDevice @{ Slot = '01:00.0'; InstanceId = 'A'; LinkWidth = 1; NumaNode = 0 }
    $c = New-FakeDevice @{ Slot = '03:00.0'; InstanceId = 'C' }
    $r = @(Compare-PciDeviceSet -Before @($a, $b) -After @($a2, $c))
    Assert-Equal 1 @($r | Where-Object Change -eq 'Added').Count
    Assert-Equal '03:00.0' ($r | Where-Object Change -eq 'Added').Slot
    Assert-Equal 1 @($r | Where-Object Change -eq 'Removed').Count
    $width = $r | Where-Object { $_.Change -eq 'Changed' -and $_.Attribute -eq 'LinkWidth' }
    Assert-Equal '4' $width.Was; Assert-Equal '1' $width.Now
    $numa = $r | Where-Object { $_.Change -eq 'Changed' -and $_.Attribute -eq 'NumaNode' }
    Assert-Equal '<absent>' $numa.Was 'absent must be named, not shown as empty'
    Assert-Equal '0' $numa.Now
    $r2 = @(Compare-PciDeviceSet -Before @($a, $b) -After @($a2, $c) -IgnoreAttribute 'Link*', 'NumaNode')
    Assert-Equal 0 @($r2 | Where-Object Change -eq 'Changed').Count 'ignored attributes must not be reported'
    # Volatile: PowerState is ignored by default, compared with -IncludeVolatile.
    $p0 = New-FakeDevice @{ InstanceId = 'P'; PowerState = 'D0' }
    $p3 = New-FakeDevice @{ InstanceId = 'P'; PowerState = 'D3' }
    Assert-Equal 0 @(Compare-PciDeviceSet -Before @($p0) -After @($p3)).Count 'PowerState flip must be ignored by default'
    Assert-Equal 1 @(Compare-PciDeviceSet -Before @($p0) -After @($p3) -IncludeVolatile).Count
    # Union of attributes: one the baseline has and "now" lacks is reported.
    $rich = New-FakeDevice @{ InstanceId = 'U' }
    $rich | Add-Member -NotePropertyName FutureAttribute -NotePropertyValue 'x'
    $plain = New-FakeDevice @{ InstanceId = 'U' }
    $ru = @(Compare-PciDeviceSet -Before @($rich) -After @($plain))
    Assert-Equal 'FutureAttribute' $ru[0].Attribute 'an attribute only the baseline carries must be reported'
    Assert-Equal '<absent>' $ru[0].Now
}

It 'Compare-PciBaseline applies -d / -s selectors to the baseline side too' {
    Use-Fixture 'tigerlake-laptop' {
        $tmp = [IO.Path]::GetTempFileName()
        try {
            $devs = @(Get-PciDevice)
            Export-PciBaseline -Path $tmp -Device $devs
            $nvme = @(Get-PciDevice -Device '1c5c:')
            $r = @(Compare-PciBaseline -Path $tmp -Device $nvme -DeviceFilter '1c5c:')
            Assert-Equal 0 $r.Count "filtered both sides should be identical, got $($r.Count) records"
            $r = @(Compare-PciBaseline -Path $tmp -Device $nvme)   # unfiltered baseline vs filtered now
            Assert-Equal 23 @($r | Where-Object Change -eq 'Removed').Count 'unfiltered baseline reports the rest as removed'
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

It 'a reseated card (new InstanceId, same slot and ids) is a Changed(InstanceId), not Removed+Added' {
    $before = New-FakeDevice @{ Slot = '01:00.0'; InstanceId = 'OLD' }
    $after = New-FakeDevice @{ Slot = '01:00.0'; InstanceId = 'NEW' }
    $r = @(Compare-PciDeviceSet -Before @($before) -After @($after))
    Assert-Equal 0 @($r | Where-Object { $_.Change -in 'Added', 'Removed' }).Count
    Assert-Equal 'InstanceId' ($r | Where-Object Change -eq 'Changed').Attribute
}

It 'Export-PciBaseline then Compare-PciBaseline round-trips a fixture with no differences' {
    Use-Fixture 'tigerlake-laptop' {
        $tmp = [IO.Path]::GetTempFileName()
        try {
            $devs = @(Get-PciDevice)
            Export-PciBaseline -Path $tmp -Device $devs
            $env = Get-Content $tmp -Raw | ConvertFrom-Json
            Assert-Equal 1 $env.schemaVersion
            Assert-Equal 24 $env.count
            Assert-Equal 0 @(Compare-PciBaseline -Path $tmp -Device $devs).Count 'identical sets differ'
            $mutated = @($devs | ForEach-Object { if ($_.Slot -eq '01:00.0') { $c = $_.PSObject.Copy(); $c.LinkWidth = 1; $c } else { $_ } } | Select-Object -Skip 1)
            $r = @(Compare-PciBaseline -Path $tmp -Device $mutated)
            Assert-Equal 1 @($r | Where-Object Change -eq 'Removed').Count
            Assert-Equal 'LinkWidth' ($r | Where-Object Change -eq 'Changed').Attribute
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
    Assert-Throws { Compare-PciBaseline -Path 'C:\nope\base.json' } -Like '*no such file*'
}

# ------------------------------------------------------ delimited output

Write-Host "`nDelimited output"

It 'emits one line per device with pipe-separated fields' {
    $lines = @($sample | Format-PciDelimited)
    Assert-Equal 1 $lines.Count
    Assert-True ($lines[0].Contains('|')) "no delimiter in '$($lines[0])'"
}

It 'an absent value is an EMPTY field, not a zero' {
    # The whole point of carrying the distinction into the text form: a device
    # with no link state must not look like a device running at x0.
    $noLink = @($devices | Where-Object { -not $_.LinkStateReported })
    if ($noLink.Count -eq 0) { Skip-Test 'every device here reports link state' }

    $line = @($noLink[0] | Format-PciDelimited)[0]
    $fields = $line -split '\|'
    # LinkSpeed and LinkWidth are fields 9 and 10 (1-indexed) of the device row.
    Assert-Equal '' $fields[8] "LinkSpeed should be empty, got '$($fields[8])'"
    Assert-Equal '' $fields[9] "LinkWidth should be empty, got '$($fields[9])'"
}

It 'a real zero survives as a literal 0' {
    $fake = New-FakeDevice @{ LinkWidth = 0 }
    $fields = (@($fake | Format-PciDelimited)[0]) -split '\|'
    Assert-Equal '0' $fields[9] 'a genuine zero must not become an empty field'
}

It 'strips a delimiter found inside a value rather than shifting columns' {
    # FriendlyName comes from driver INF files and is not under our control.
    # An unescaped delimiter would silently move every later column.
    $fake = New-FakeDevice @{ VendorName = 'Evil|Corp' }
    $line = @($fake | Format-PciDelimited)[0]
    $fields = $line -split '\|'
    Assert-Equal 14 $fields.Count 'column count must be stable'
    Assert-Equal 'Evil/Corp' $fields[5]
}

It 'folds a line break inside a value so one record stays one line' {
    $fake = New-FakeDevice @{ DeviceName = "Two`r`nLines`tTabbed" }
    $lines = @($fake | Format-PciDelimited)
    Assert-Equal 1 $lines.Count 'a record must be one physical line'
    Assert-True ($lines[0] -notmatch '[\r\n\t]') 'control characters must not survive'
}

It 'header row names the columns in order' {
    $lines = @($sample | Format-PciDelimited -Header)
    $header = ($lines[0] -split '\|')
    Assert-Equal 'Slot' $header[0]
    Assert-Equal 'LinkSpeed' $header[8]
    Assert-Equal $header.Count (($lines[1] -split '\|').Count) `
        'header and data must have the same column count'
}

It 'emits the header once even when another Format-PciDelimited runs inside the pipeline' {
    # The header flag used to live in module scope, so a nested call reset it
    # and the outer stream re-emitted the header for every remaining row.
    $out = @($devices | Format-PciDelimited -Header | ForEach-Object {
        $null = @(New-FakeDevice | Format-PciDelimited -Header); $_ })
    $headers = @($out | Where-Object { $_ -like 'Slot|*' }).Count
    Assert-Equal 1 $headers "expected one header row, got $headers"
}

It 'supports a different delimiter' {
    $line = @($sample | Format-PciDelimited -Delimiter "`t")[0]
    Assert-True ($line.Contains("`t")) 'tab delimiter not applied'
}

It 'rejects an empty delimiter' {
    Assert-Throws { $sample | Format-PciDelimited -Delimiter '' } -Like '*Delimiter*'
}

It 'attribute rows use their own column set' {
    $line = @($sample | ConvertTo-PciAttributeRecord -Attribute 'LinkSpeed' | Format-PciDelimited)[0]
    $f = $line -split '\|'
    Assert-Equal 6 $f.Count 'attribute rows are 6 columns'
    Assert-Equal 'LinkSpeed' $f[3]
}

# ------------------------------------------------------------ CLI contract

Write-Host "`nCLI"

# The CLI tests run against the recorded laptop fixture (see Invoke-Cli), so
# their expectations come from the fixture, not from this machine.
$script:fx = @(); $script:fxDev = $null; $script:fxSlot = $null; $script:fxParts = $null; $script:fxBdf = $null; $script:fxBus = $null
Use-Fixture 'tigerlake-laptop' {
    $script:fx = @(Get-PciDevice | Sort-Object Slot)
    $script:fxDev = $script:fx | Where-Object Slot -eq '01:00.0'     # the NVMe: has a link, a driver, a subsystem
    if (-not $script:fxDev) { $script:fxDev = $script:fx[0] }
    $script:fxSlot = $script:fxDev.Slot
    $script:fxParts = Split-Slot $script:fxSlot
    $script:fxBdf = $script:fxParts.Bdf
    $script:fxBus = $script:fxParts.Bus
}

It 'CLI tests replay the laptop fixture: banner on stderr, provenance in the data' {
    $r = Invoke-Cli @('-Json')
    Assert-Equal 1 $r.Banner.Count "expected one fixture banner, got $($r.Banner.Count)"
    Assert-True ($r.Banner[0] -like '*NOT this machine''s hardware*') $r.Banner[0]
    $obj = $r.Text | ConvertFrom-Json
    Assert-Equal 'fixture:tigerlake-laptop.json' $obj.source 'JSON must say where the data came from'
    Assert-Equal 24 $obj.count
    # The human listing says so on STDOUT too (the stderr banner can be silenced).
    $r = Invoke-Cli @('-s', $fxSlot)
    Assert-Equal 1 $r.Provenance.Count "expected one stdout provenance line, got: $($r.Provenance -join ' | ')"
    Assert-True ($r.Provenance[0] -like '# source: fixture:tigerlake-laptop.json*NOT this machine*') $r.Provenance[0]
    $r = Invoke-Cli @('-s', $fxSlot, '-Json')
    Assert-Equal 0 $r.Provenance.Count 'machine formats carry source in the data, not a comment line'
    # -Live runs the real machine: no banner, windows-pnp.
    $r = Invoke-Cli @('-Json') -Live
    Assert-Equal 0 $r.Banner.Count 'no banner without the env var'
    Assert-Equal 'windows-pnp' (($r.Text | ConvertFrom-Json).source)
}

It 'an unfiltered LIVE listing exits zero' {
    $r = Invoke-Cli -Live
    Assert-Equal 0 $r.Code
    Assert-True ($r.Output.Count -ge $devices.Count) 'fewer lines than devices'
}

It 'a vendor filter matching nothing exits non-zero' {
    $r = Invoke-Cli @('-d', 'ffff:')
    Assert-Equal 1 $r.Code 'a filter that matches nothing must not look like success'
}

It 'refuses -x rather than silently ignoring it' {
    # Config-space dumps are impossible without a kernel driver. A tool that
    # quietly does less than asked is worse than one that says it cannot.
    $r = Invoke-Cli @('-x')
    Assert-Equal 2 $r.Code 'expected exit 2 for an impossible request'
    Assert-True ($r.Text -like '*configuration space*') 'should explain why'
}

It 'says "not implemented" for -p instead of binding it to -PresentOnly' {
    # PowerShell's binder prefix-matched -p to -PresentOnly and dumped every
    # attribute. lspci's -p is a custom ID file; the user gets told, not served
    # a different command.
    $r = Invoke-Cli @('-p')
    Assert-Equal 2 $r.Code "exit was $($r.Code): $($r.Text)"
    Assert-True ($r.Text -like '*not implemented*') $r.Text
    Assert-True ($r.Text -notlike '*Attribute*Value*Present*') 'must not print the attribute table'
}

It 'says "not implemented" for -b / -p / -M / -A rather than a binder error' {
    foreach ($flag in @('-b', '-p', '-M', '-A', '-H1')) {
        $r = Invoke-Cli @($flag)
        Assert-Equal 2 $r.Code "$flag exit was $($r.Code): $($r.Text)"
        Assert-True ($r.Text -like '*not implemented*') "$flag : $($r.Text)"
    }
}

It 'CLI: -m, -mm and -i are implemented; -mm with -Json is refused' {
    $r = Invoke-Cli @('-m', '-s', $fxSlot)
    Assert-Equal 0 $r.Code $r.Text
    Assert-True ($r.Output[0] -match '^\S+ ".*" ".*" ".*"') "-m shape: $($r.Output[0])"
    $r = Invoke-Cli @('-mm', '-s', $fxSlot)
    Assert-Equal 0 $r.Code $r.Text
    Assert-True ($r.Output[0] -like "Slot:*$fxSlot") "-mm shape: $($r.Output[0])"
    $r = Invoke-Cli @('-mm', '-Json')
    Assert-Equal 64 $r.Code 'conflicting formats'
    $r = Invoke-Cli @('-i', (Join-Path $root 'data\pci.ids'), '-s', $fxSlot)
    Assert-Equal 0 $r.Code $r.Text
    $r = Invoke-Cli @('-i', 'C:\nope.ids')
    Assert-Equal 64 $r.Code 'missing ids file is a usage error'
}

It 'CLI: -Baseline then -Diff is exit 0 when nothing changed and 3 when it did' {
    $tmp = [IO.Path]::GetTempFileName()
    try {
        $r = Invoke-Cli @('-Baseline', $tmp)
        Assert-Equal 0 $r.Code $r.Text
        # PowerState is volatile and ignored by default, so a same-machine
        # round trip is clean.
        $r = Invoke-Cli @('-Diff', $tmp)
        Assert-Equal 0 $r.Code "identical diff: $($r.Text)"
        Assert-True ($r.Text -like '*no differences*') $r.Text
        # A selector applies to both sides: the sample device against itself.
        $r = Invoke-Cli @('-Diff', $tmp, '-s', $fxSlot)
        Assert-Equal 0 $r.Code "filtered diff of one device against itself: $($r.Text)"
        # A selector matching nothing is still "no matching PCI device", exit 1.
        $r = Invoke-Cli @('-Diff', $tmp, '-d', 'ffff:')
        Assert-Equal 1 $r.Code "empty filter must be exit 1, not everything-gone: $($r.Text)"
        # A baseline that LACKS a device now present -> Added, exit 3.
        $base = Get-Content $tmp -Raw | ConvertFrom-Json
        $base.devices = @($base.devices | Select-Object -Skip 1)
        $base | ConvertTo-Json -Depth 6 | Set-Content $tmp -Encoding UTF8
        $r = Invoke-Cli @('-Diff', $tmp)
        Assert-Equal 3 $r.Code "diff with an added device must exit 3: $($r.Text)"
        Assert-True (@($r.Output | Where-Object { $_ -like '+ *appeared:*' }).Count -eq 1) $r.Text
        $r = Invoke-Cli @('-Diff', $tmp, '-Json')
        Assert-Equal 3 $r.Code
        Assert-Equal 1 @($r.Text | ConvertFrom-Json).Count
        $r = Invoke-Cli @('-Diff', 'C:\nope\base.json')
        Assert-Equal 64 $r.Code
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

It 'CLI: -ComputerName with an unreachable host exits 70, not an empty listing' {
    $r = Invoke-Cli @('-ComputerName', 'no-such-host-winlspci-test') -Live
    Assert-Equal 70 $r.Code "exit $($r.Code): $($r.Text)"
    Assert-True ($r.Text -like '*none of the requested computers could be reached*') $r.Text
}

It 'CLI: blank or trailing-comma -ComputerName values are usage errors, never the local listing' {
    foreach ($v in @('', '   ', ',', 'a,')) {
        $r = Invoke-Cli @('-ComputerName', $v) -Live
        Assert-Equal 64 $r.Code "'$v' gave exit $($r.Code): $($r.Text)"
        # An empty argument is "requires a value"; blanks inside are "empty name". Both are usage errors.
        Assert-True ($r.Text -like '*empty name*' -or $r.Text -like '*requires a value*') "'$v': $($r.Text)"
        Assert-True ($r.Output.Count -lt 3) "'$v' must not print a listing"
    }
}

# No automated test drives the CLI's -Credential prompt: Get-Credential can
# raise a GUI dialog, and on a machine with saved credentials it can return
# one without any interaction (observed under -NonInteractive). The CLI guard
# (no credential obtained -> exit 64, never connect without it) is covered by
# reading; scripts are told to use the module's -Credential with a PSCredential.

It 'CLI: -Watch validates its interval and stops after -Iterations' {
    $r = Invoke-Cli @('-Watch', 'x')
    Assert-Equal 64 $r.Code $r.Text
    $r = Invoke-Cli @('-Watch', '0')
    Assert-Equal 64 $r.Code '-Watch 0 is not an interval'
    $r = Invoke-Cli @('-Watch', '1', '-Iterations', '1')
    Assert-True ($r.Code -in 0, 3) "watch exit $($r.Code): $($r.Text)"
    Assert-True ($r.Output[0] -like '*watching*devices every 1s*') $r.Output[0]
}

It 'rejects an unknown option with a usage error, not a warning and an unfiltered listing' {
    $r = Invoke-Cli @('-bogus')
    Assert-Equal 64 $r.Code "exit was $($r.Code)"
    Assert-True ($r.Output.Count -lt 5) 'must not run the listing'
}

It '-tv combines tree and verbose, as in lspci' {
    $r = Invoke-Cli @('-tv')
    Assert-Equal 0 $r.Code $r.Text
    Assert-True ($r.Text -notlike '*ignoring*') 'must not warn'
    Assert-True ($r.Output[0].StartsWith('-')) "first line should be a tree root: $($r.Output[0])"
}

It '-nnk prints ids and the driver line' {
    $r = Invoke-Cli @('-nnk', '-s', $fxSlot)
    Assert-Equal 0 $r.Code $r.Text
    $needle = "[$($fxDev.VendorId):$($fxDev.DeviceId)]"
    Assert-True ($r.Text.Contains($needle)) "ids missing: $($r.Text)"
    Assert-True ($r.Text -like '*Driver:*') "driver line missing: $($r.Text)"
}

It '-k alone is not silently ignored: it shows the driver' {
    $r = Invoke-Cli @('-k', '-s', $fxSlot)
    Assert-True ($r.Text -like '*Driver:*') "-k should show the driver: $($r.Text)"
}

It '-D prefixes the domain, distinct from -d' {
    $r = Invoke-Cli @('-D', '-s', $fxSlot)
    Assert-Equal 0 $r.Code $r.Text
    $expected = "$($fxParts.DomainHex):$fxBdf"   # a non-zero domain is already in the slot
    Assert-True ($r.Output[0].StartsWith($expected)) "expected '$expected' prefix: $($r.Output[0])"
    Assert-True (-not $r.Output[0].StartsWith('0000:0000:')) 'domain must not be prefixed twice'
}

It 'long options are case-insensitive and may be abbreviated' {
    $r = Invoke-Cli @('-json', '-s', $fxSlot)
    Assert-Equal 0 $r.Code $r.Text
    $obj = $r.Text | ConvertFrom-Json
    Assert-Equal 1 $obj.count
    $r2 = Invoke-Cli @('-Down', '-s', 'ee:')   # -Downtrained abbreviated, nothing matches
    Assert-Equal 1 $r2.Code
}

It 'lowercase long options starting with s or d are not mistaken for -s / -d' {
    # `-device` once parsed as `-d evice`. A multi-character token that names a
    # long option is a long option; a single character is a short flag.
    $r = Invoke-Cli @('-device', "$($fxDev.VendorId):", '-n')
    Assert-Equal 0 $r.Code $r.Text
    Assert-True ($r.Output.Count -ge 1) 'no output for -device'
    $r = Invoke-Cli @('-slot', $fxSlot, '-delimited')
    Assert-Equal 0 $r.Code $r.Text
    Assert-True ($r.Output[0].StartsWith("$fxSlot|")) "expected a delimited row: $($r.Output[0])"
    $r = Invoke-Cli @('-de')   # ambiguous: Delimited / Delimiter / Device
    Assert-Equal 64 $r.Code
    Assert-True ($r.Text -like '*ambiguous*') $r.Text
}

It 'conflicting output formats are refused rather than one silently winning' {
    $r = Invoke-Cli @('-Json', '-Csv')
    Assert-Equal 64 $r.Code $r.Text
}

It 'an attached -s value survives PowerShell eating the colon (-s01: and -s01:00.0)' {
    # powershell.exe -File tokenises -Name:value itself, dropping the colon: a
    # naive $args sees `-s01:` as `-s01`, which under lspci's grammar is DEVICE
    # 01 rather than bus 01 -- a silently different answer. The CLI recovers
    # the raw command line instead.
    $busOnly = @(Get-PciDevice -Slot "${sampleBus}:").Count
    $r = Invoke-Cli @("-s${sampleBus}:", '-n')
    Assert-Equal 0 $r.Code $r.Text
    Assert-Equal $busOnly $r.Output.Count "-s${sampleBus}: should select bus $fxBus"
    $r2 = Invoke-Cli @("-s$fxSlot", '-n')
    Assert-Equal 1 $r2.Output.Count "-s$fxSlot"
    $r3 = Invoke-Cli @('-Match:zzzznope', '-Attribute', 'Slot')
    Assert-Equal 1 $r3.Code '-Match:value form'
}

It 'a bad -s value is one clean usage error' {
    $r = Invoke-Cli @('-s', 'foo')
    Assert-Equal 64 $r.Code "exit was $($r.Code)"
    Assert-True ($r.Text -like '*invalid slot filter*') $r.Text
    Assert-True ($r.Text -notlike '*Exception*') "raw exception leaked: $($r.Text)"
}

It '-s <n> on the CLI selects a device number on any bus' {
    $devNum = $fxParts.Device
    $expected = @($fx | Where-Object { (Split-Slot $_.Slot).Device -eq $devNum }).Count
    $r = Invoke-Cli @('-s', $devNum, '-n')
    Assert-Equal $expected $r.Output.Count "-s $devNum"
}

It 'emits valid JSON with its limits stated and a schema version' {
    $r = Invoke-Cli @('-Json')
    $obj = $r.Text | ConvertFrom-Json
    Assert-True ($obj.count -gt 0) 'JSON should report devices'
    Assert-True ($obj.note -like '*configuration-space*') 'JSON should state its limits'
    Assert-Equal 1 $obj.schemaVersion 'schemaVersion is the compatibility promise'
    Assert-Equal "$((Get-Module winlspci).Version)" $obj.winlspciVersion
    Assert-True ($obj.generatedAt -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$') "generatedAt '$($obj.generatedAt)'"
    Assert-Equal $env:COMPUTERNAME $obj.computerName
}

It 'every listed device is present (phantoms need -IncludeAbsent)' {
    foreach ($d in $devices) { Assert-True $d.Present "$($d.Slot) listed but Present=$($d.Present)" }
}

It 'an attribute query with ONE record is still a JSON array' {
    $r = Invoke-Cli @('-Attribute', 'VendorId', '-s', $fxSlot, '-Json')
    Assert-Equal 0 $r.Code
    Assert-True ($r.Text.TrimStart().StartsWith('[')) "expected an array: $($r.Text)"
    Assert-Equal 1 @($r.Text | ConvertFrom-Json).Count
}

It 'an attribute query with NO records is an empty JSON array and exits 1' {
    $r = Invoke-Cli @('-Attribute', 'VendorId', '-Match', 'zzzznope', '-Json')
    Assert-Equal 1 $r.Code
    Assert-Equal '[]' $r.Text.Trim() "expected [], got: $($r.Text)"
}

It 'an attribute query matching nothing exits non-zero' {
    $r = Invoke-Cli @('-Attribute', 'VendorId', '-Match', 'zzzznope')
    Assert-Equal 1 $r.Code
}

It '-Downtrained is a filter: exit 1 when nothing is downtrained, 0 otherwise' {
    $expected = 0
    if (@($fx | Where-Object { $_.Downtrained }).Count -eq 0) { $expected = 1 }
    $r = Invoke-Cli @('-Downtrained')
    Assert-Equal $expected $r.Code $r.Text
}

It '-ListAttributes is fast: it does not enumerate the machine' {
    # Relative, not absolute: a loaded box makes both slow, but a -Version run
    # (process start + module import, no enumeration) and a -ListAttributes run
    # should cost about the same, and both far less than a listing.
    $floor = (Measure-Command { Invoke-Cli @('-Version') -Live | Out-Null }).TotalMilliseconds
    $ms = (Measure-Command { Invoke-Cli @('-ListAttributes') -Live | Out-Null }).TotalMilliseconds
    $full = (Measure-Command { Invoke-Cli @('-n') -Live | Out-Null }).TotalMilliseconds
    Assert-True ($ms -lt ($floor + ($full - $floor) / 2)) "-ListAttributes ${ms}ms vs -Version ${floor}ms and a listing ${full}ms"
}

It 'the CLI emits delimited output and composes with Select-String' {
    $r = Invoke-Cli @('-Delimited')
    $hit = @($r.Output | Select-String -SimpleMatch '|')
    Assert-True ($hit.Count -gt 0) 'delimited output should pipe into Select-String'
}

# ------------------------------------------------------------ summary

Write-Host ''
Write-Host ('-' * 60)
$colour = 'Green'
if ($script:Fail -gt 0) { $colour = 'Red' }
Write-Host "$($script:Pass) passed, $($script:Fail) failed, $($script:Skip) skipped" -ForegroundColor $colour
if ($UpdateGolden) {
    Write-Host 'GOLDENS REWRITTEN from the current code -- this run proved nothing about them; review the diff.' -ForegroundColor DarkYellow
}
if ($script:Fail -gt 0) {
    Write-Host ''
    foreach ($f in $script:Failures) { Write-Host "  $f" -ForegroundColor Red }
    exit 1
}
exit 0
