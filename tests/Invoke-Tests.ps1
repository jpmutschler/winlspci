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
param([switch]$Quiet)

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
    #>
    param([string[]]$CliArgs = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli @CliArgs 2>&1 |
            ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ Output = $out; Text = ($out -join "`n"); Code = $code }
}

# A fully-populated fake, so formatter tests do not depend on the machine.
function New-FakeDevice {
    param([hashtable]$Override = @{})
    $d = [ordered]@{
        Slot = '01:00.0'; Domain = 0; VendorId = 'dead'; DeviceId = 'beef'
        SubsystemVendorId = 'dead'; SubsystemId = 'cafe'; Revision = '00'
        VendorName = 'Test'; DeviceName = 'Widget'
        ClassCode = '0108'; ClassName = 'NVMe'; ProgIf = 2; FriendlyName = 'Widget'
        Driver = 'x'; DriverVersion = '1'; Status = 'OK'; Problem = 0; NumaNode = $null
        LinkStateReported = $true
        LinkSpeed = '8GT/s'; LinkSpeedRaw = 3; LinkWidth = 4
        MaxLinkSpeed = '8GT/s'; MaxLinkSpeedRaw = 3; MaxLinkWidth = 4
        Downtrained = $false
        MaxPayloadSize = 256; MaxPayloadSizeSupported = 512; MaxReadRequestSize = 512
        AerCapable = $false; ParentInstanceId = $null; InstanceId = 'X'; Present = $true
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

It 'decodes a Hyper-V bus number with the segment in its upper bits' {
    # Azure SR-IOV VFs report "PCI bus 5598976" (0x556F00): segment 556f,
    # bus 00. Rendered naively that was bus "556f00", which nothing can parse.
    $loc = & (Get-Module winlspci) { ConvertTo-Bdf 'PCI bus 5598976, device 2, function 0' $null $null }
    Assert-Equal '556f:00:02.0' $loc.Slot
    Assert-Equal 0x556f $loc.Domain
    $plain = & (Get-Module winlspci) { ConvertTo-Bdf 'PCI bus 1, device 0, function 0' $null $null }
    Assert-Equal '01:00.0' $plain.Slot 'domain 0 is not shown'
    Assert-Equal 0 $plain.Domain
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
    Assert-True ($out -like '*DOWNTRAINED (speed)*') "speed downtrain not flagged: $out"
    Assert-True ($out -like '*DOWNTRAINED (width)*') "width downtrain not flagged: $out"
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
}

It 'nests an endpoint under its root port' {
    $child = $devices | Where-Object { $_.ParentInstanceId -and
        ($devices.InstanceId -contains $_.ParentInstanceId) } | Select-Object -First 1
    if (-not $child) { Skip-Test 'no parent/child pair on this machine' }
    $lines = @(Format-PciTree -Devices $devices -Numeric 1)
    $line = $lines | Where-Object { $_ -like "*$($child.Slot)*" } | Select-Object -First 1
    # A root is rendered as "-<slot>"; a child is indented and branched. Test
    # the property (indented, not at column 0) rather than an exact glyph set,
    # so the assertion survives a cosmetic change to the branch characters.
    Assert-True (-not $line.StartsWith('-')) "child line is not indented: '$line'"
    Assert-True ($line.Contains('-' + $child.Slot)) "child slot missing: '$line'"
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

It 'an unfiltered listing exits zero' {
    $r = Invoke-Cli
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

It 'says "not implemented" for -m / -b / -i rather than a binder error' {
    foreach ($flag in @('-m', '-mm', '-b', '-i', '-M', '-A')) {
        $r = Invoke-Cli @($flag)
        Assert-Equal 2 $r.Code "$flag exit was $($r.Code): $($r.Text)"
        Assert-True ($r.Text -like '*not implemented*') "$flag : $($r.Text)"
    }
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
    $r = Invoke-Cli @('-nnk', '-s', $sampleSlot)
    Assert-Equal 0 $r.Code $r.Text
    $needle = "[$($sample.VendorId):$($sample.DeviceId)]"
    Assert-True ($r.Text.Contains($needle)) "ids missing: $($r.Text)"
    Assert-True ($r.Text -like '*Driver:*') "driver line missing: $($r.Text)"
}

It '-k alone is not silently ignored: it shows the driver' {
    $r = Invoke-Cli @('-k', '-s', $sampleSlot)
    Assert-True ($r.Text -like '*Driver:*') "-k should show the driver: $($r.Text)"
}

It '-D prefixes the domain, distinct from -d' {
    $r = Invoke-Cli @('-D', '-s', $sampleSlot)
    Assert-Equal 0 $r.Code $r.Text
    $expected = "$($sampleParts.DomainHex):$sampleBdf"   # a non-zero domain is already in the slot
    Assert-True ($r.Output[0].StartsWith($expected)) "expected '$expected' prefix: $($r.Output[0])"
    Assert-True (-not $r.Output[0].StartsWith('0000:0000:')) 'domain must not be prefixed twice'
}

It 'long options are case-insensitive and may be abbreviated' {
    $r = Invoke-Cli @('-json', '-s', $sampleSlot)
    Assert-Equal 0 $r.Code $r.Text
    $obj = $r.Text | ConvertFrom-Json
    Assert-Equal 1 $obj.count
    $r2 = Invoke-Cli @('-Down', '-s', 'ee:')   # -Downtrained abbreviated, nothing matches
    Assert-Equal 1 $r2.Code
}

It 'lowercase long options starting with s or d are not mistaken for -s / -d' {
    # `-device` once parsed as `-d evice`. A multi-character token that names a
    # long option is a long option; a single character is a short flag.
    $r = Invoke-Cli @('-device', "$($sample.VendorId):", '-n')
    Assert-Equal 0 $r.Code $r.Text
    Assert-True ($r.Output.Count -ge 1) 'no output for -device'
    $r = Invoke-Cli @('-slot', $sampleSlot, '-delimited')
    Assert-Equal 0 $r.Code $r.Text
    Assert-True ($r.Output[0].StartsWith("$sampleSlot|")) "expected a delimited row: $($r.Output[0])"
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
    Assert-Equal $busOnly $r.Output.Count "-s${sampleBus}: should select bus $sampleBus"
    $r2 = Invoke-Cli @("-s$sampleSlot", '-n')
    Assert-Equal 1 $r2.Output.Count "-s$sampleSlot"
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
    $devNum = $sampleParts.Device
    $expected = @($devices | Where-Object { (Split-Slot $_.Slot).Device -eq $devNum }).Count
    $r = Invoke-Cli @('-s', $devNum, '-n')
    Assert-Equal $expected $r.Output.Count "-s $devNum"
}

It 'emits valid JSON with its limits stated' {
    $r = Invoke-Cli @('-Json')
    $obj = $r.Text | ConvertFrom-Json
    Assert-True ($obj.count -gt 0) 'JSON should report devices'
    Assert-True ($obj.note -like '*configuration-space*') 'JSON should state its limits'
}

It 'an attribute query with ONE record is still a JSON array' {
    $r = Invoke-Cli @('-Attribute', 'VendorId', '-s', $sampleSlot, '-Json')
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
    if (@($devices | Where-Object { $_.Downtrained }).Count -eq 0) { $expected = 1 }
    $r = Invoke-Cli @('-Downtrained')
    Assert-Equal $expected $r.Code $r.Text
}

It '-ListAttributes is fast: it does not enumerate the machine' {
    # Relative, not absolute: a loaded box makes both slow, but a -Version run
    # (process start + module import, no enumeration) and a -ListAttributes run
    # should cost about the same, and both far less than a listing.
    $floor = (Measure-Command { Invoke-Cli @('-Version') | Out-Null }).TotalMilliseconds
    $ms = (Measure-Command { Invoke-Cli @('-ListAttributes') | Out-Null }).TotalMilliseconds
    $full = (Measure-Command { Invoke-Cli @('-n') | Out-Null }).TotalMilliseconds
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
if ($script:Fail -gt 0) {
    Write-Host ''
    foreach ($f in $script:Failures) { Write-Host "  $f" -ForegroundColor Red }
    exit 1
}
exit 0
