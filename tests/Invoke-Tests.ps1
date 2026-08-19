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
  specific device it is skipped with a reason rather than failed.

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

function Skip-Test { param([string]$Why) throw "SKIP: $Why" }

$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'winlspci.psd1') -Force

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
    # 11f8 still reads "PMC-Sierra" in the upstream database: Microsemi bought
    # PMC-Sierra, Microchip bought Microsemi, and the ID never changed. Worth
    # a test so nobody at a bench concludes the card is the wrong part.
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

# ------------------------------------------------------------ enumeration

Write-Host "`nEnumeration"

$devices = @(Get-PciDevice)

It 'enumerates at least one PCI device' {
    Assert-True ($devices.Count -gt 0) 'no PCI devices found at all'
}

It 'every device has a 4-hex-digit vendor and device id' {
    foreach ($d in $devices) {
        Assert-True ($d.VendorId -match '^[0-9a-f]{4}$') "bad VendorId '$($d.VendorId)'"
        Assert-True ($d.DeviceId -match '^[0-9a-f]{4}$') "bad DeviceId '$($d.DeviceId)'"
    }
}

It 'every device has a parseable bus:device.function' {
    foreach ($d in $devices) {
        Assert-True ($d.Slot -match '^[0-9a-f]{2}:[0-9a-f]{2}\.\d$') `
            "device $($d.VendorId):$($d.DeviceId) has slot '$($d.Slot)'"
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

# ------------------------------------------------------------ filtering

Write-Host "`nFiltering"

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
    $fake = [pscustomobject]@{
        Slot = '01:00.0'; VendorId = 'dead'; DeviceId = 'beef'; SubsystemId = $null
        Revision = '00'; VendorName = 'Test'; DeviceName = 'Widget'
        ClassCode = '0108'; ClassName = 'NVMe'; ProgIf = 2; FriendlyName = 'Widget'
        Driver = 'x'; DriverVersion = '1'; Status = 'OK'; Problem = 0; NumaNode = $null
        LinkStateReported = $true
        LinkSpeed = '8GT/s'; LinkSpeedRaw = 3; LinkWidth = 2
        MaxLinkSpeed = '16GT/s'; MaxLinkSpeedRaw = 4; MaxLinkWidth = 4
        MaxPayloadSize = $null; MaxPayloadSizeSupported = $null; MaxReadRequestSize = $null
        AerCapable = $false; InstanceId = 'X'; Present = $true
    }
    $out = @($fake | Format-Lspci -Verbosity 1) -join "`n"
    Assert-True ($out -like '*DOWNTRAINED (speed)*') "speed downtrain not flagged: $out"
    Assert-True ($out -like '*DOWNTRAINED (width)*') "width downtrain not flagged: $out"
}

It 'says so plainly when link state is absent' {
    $fake = [pscustomobject]@{
        Slot = '00:00.0'; VendorId = 'dead'; DeviceId = 'beef'; SubsystemId = $null
        Revision = $null; VendorName = 'T'; DeviceName = 'W'; ClassCode = '0600'
        ClassName = 'Host bridge'; ProgIf = 0; FriendlyName = 'W'; Driver = $null
        DriverVersion = $null; Status = 'OK'; Problem = 0; NumaNode = $null
        LinkStateReported = $false
        LinkSpeed = $null; LinkSpeedRaw = $null; LinkWidth = $null
        MaxLinkSpeed = $null; MaxLinkSpeedRaw = $null; MaxLinkWidth = $null
        MaxPayloadSize = $null; MaxPayloadSizeSupported = $null; MaxReadRequestSize = $null
        AerCapable = $false; InstanceId = 'X'; Present = $true
    }
    $out = @($fake | Format-Lspci -Verbosity 1) -join "`n"
    Assert-True ($out -like '*not reported*') "expected an explicit 'not reported': $out"
    Assert-True ($out -notlike '*x0*') "must not render an absent width as x0: $out"
}

# ------------------------------------------------------------ CLI contract

Write-Host "`nCLI"

$cli = Join-Path $root 'bin\lspci.ps1'

It 'a vendor filter matching nothing exits non-zero' {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli -d 'ffff:' | Out-Null
    Assert-Equal 1 $LASTEXITCODE 'a filter that matches nothing must not look like success'
}

It 'an unfiltered listing exits zero' {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli | Out-Null
    Assert-Equal 0 $LASTEXITCODE
}

It 'refuses -x rather than silently ignoring it' {
    # Config-space dumps are impossible without a kernel driver. A tool that
    # quietly does less than asked is worse than one that says it cannot.
    # No '--' separator: PowerShell has no such convention and treats it as an
    # empty parameter name. -x falls through to ValueFromRemainingArguments.
    # Windows PowerShell 5.1 wraps ANY stderr from a native executable in a
    # NativeCommandError, whatever redirection you use -- and this suite runs
    # with $ErrorActionPreference = 'Stop', so the child's (correct, expected)
    # refusal message would terminate the test. Relax the preference just for
    # this call; the exit code is what is under test, not the stream.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli -x 2>&1 | Out-Null
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    Assert-Equal 2 $code 'expected exit 2 for an impossible request'
}

It 'emits valid JSON' {
    $json = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli -Json | Out-String
    $obj = $json | ConvertFrom-Json
    Assert-True ($obj.count -gt 0) 'JSON should report devices'
    Assert-True ($obj.note -like '*configuration-space*') 'JSON should state its limits'
}


# ------------------------------------------------------------ slot filter

Write-Host "`nSlot filter (-s)"

It 'accepts an unpadded bus number, as lspci does' {
    # This returned NOTHING before normalisation: `-s 1:` missed while
    # `-s 01:` matched. A filter that silently finds nothing when the device is
    # right there is the worst kind of wrong answer.
    $padded = @(Get-PciDevice -Slot '01:').Count
    $unpadded = @(Get-PciDevice -Slot '1:').Count
    Assert-Equal $padded $unpadded 'padded and unpadded must agree'
}

It 'accepts a full unpadded bus:device.function' {
    $a = @(Get-PciDevice -Slot '01:00.0').Count
    $b = @(Get-PciDevice -Slot '1:0.0').Count
    Assert-Equal $a $b
}

It 'accepts a domain-qualified slot' {
    $a = @(Get-PciDevice -Slot '01:00.0').Count
    $b = @(Get-PciDevice -Slot '0000:01:00.0').Count
    Assert-Equal $a $b
}

It 'a bus with nothing on it matches nothing' {
    Assert-Equal 0 @(Get-PciDevice -Slot 'ee:').Count
}

# ------------------------------------------------------------ tree

Write-Host "`nTree (-t)"

It 'renders a tree with every device present exactly once' {
    $all = @(Get-PciDevice)
    $lines = @(Format-PciTree -Devices $all -Numeric 1)
    Assert-Equal $all.Count $lines.Count `
        'a device must appear exactly once -- no drops, no duplicates'
}

It 'nests an endpoint under its root port' {
    $all = @(Get-PciDevice)
    $child = $all | Where-Object { $_.ParentInstanceId -and
        ($all.InstanceId -contains $_.ParentInstanceId) } | Select-Object -First 1
    if (-not $child) { Skip-Test 'no parent/child pair on this machine' }
    $lines = @(Format-PciTree -Devices $all -Numeric 1)
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

# ------------------------------------------------------ attribute queries

Write-Host "`nAttribute serialisation"

It 'flattens a device to one record per attribute' {
    $d = @(Get-PciDevice)[0]
    $records = @($d | ConvertTo-PciAttributeRecord)
    Assert-True ($records.Count -gt 10) "expected many attributes, got $($records.Count)"
    foreach ($r in $records) { Assert-Equal $d.Slot $r.Slot }
}

It 'filters attributes by wildcard' {
    $d = @(Get-PciDevice)[0]
    $records = @($d | ConvertTo-PciAttributeRecord -Attribute 'Link*')
    Assert-True ($records.Count -gt 0) 'Link* matched nothing'
    foreach ($r in $records) { Assert-True ($r.Attribute -like 'Link*') $r.Attribute }
}

It 'filters by value, standing in for grep' {
    $records = @(Get-PciDevice | ConvertTo-PciAttributeRecord -Attribute 'VendorId' -Match '^8086$')
    Assert-True ($records.Count -gt 0) 'no Intel devices matched'
    foreach ($r in $records) { Assert-Equal '8086' $r.Value }
}

It 'marks absent attributes as not present rather than dropping them' {
    $records = @(Get-PciDevice | ConvertTo-PciAttributeRecord -Attribute 'MaxPayloadSize')
    $absent = @($records | Where-Object { -not $_.Present })
    if ($absent.Count -eq 0) { Skip-Test 'every device reports MaxPayloadSize here' }
    foreach ($r in $absent) {
        Assert-True ($null -eq $r.Value -or "$($r.Value)" -eq '') `
            "marked absent but carries '$($r.Value)'"
    }
}

It 'PresentOnly drops the absent ones' {
    $all = @(Get-PciDevice | ConvertTo-PciAttributeRecord -Attribute 'MaxPayloadSize')
    $present = @(Get-PciDevice | ConvertTo-PciAttributeRecord -Attribute 'MaxPayloadSize' -PresentOnly)
    Assert-True ($present.Count -le $all.Count) 'PresentOnly must not add rows'
    foreach ($r in $present) { Assert-True $r.Present }
}

It 'lists the attribute names so a query can be written' {
    $names = @(Get-PciAttributeName)
    Assert-True ($names -contains 'LinkSpeed') 'LinkSpeed should be discoverable'
    Assert-True ($names -contains 'Slot')
}

It 'an attribute query matching nothing exits non-zero' {
    $cliPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\lspci.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cliPath `
        -Attribute 'VendorId' -Match 'zzzznope' | Out-Null
    Assert-Equal 1 $LASTEXITCODE
}


# ------------------------------------------------------ delimited output

Write-Host "`nDelimited output"

It 'emits one line per device with pipe-separated fields' {
    $lines = @(Get-PciDevice -Slot '01:' | Format-PciDelimited)
    Assert-True ($lines.Count -ge 1) 'no delimited output'
    Assert-True ($lines[0].Contains('|')) "no delimiter in '$($lines[0])'"
}

It 'an absent value is an EMPTY field, not a zero' {
    # The whole point of carrying the distinction into the text form: a device
    # with no link state must not look like a device running at x0.
    $noLink = @(Get-PciDevice | Where-Object { -not $_.LinkStateReported })[0]
    if (-not $noLink) { Skip-Test 'every device here reports link state' }

    $line = @($noLink | Format-PciDelimited)[0]
    $fields = $line -split '\|'
    # LinkSpeed and LinkWidth are fields 9 and 10 (1-indexed) of the device row.
    Assert-Equal '' $fields[8] "LinkSpeed should be empty, got '$($fields[8])'"
    Assert-Equal '' $fields[9] "LinkWidth should be empty, got '$($fields[9])'"
}

It 'a real zero survives as a literal 0' {
    $fake = [pscustomobject]@{
        Slot='01:00.0'; VendorId='dead'; DeviceId='beef'; ClassCode='0108'
        ClassName='NVMe'; VendorName='T'; DeviceName='W'; Revision='00'
        LinkSpeed='8GT/s'; LinkWidth=0; MaxLinkSpeed='8GT/s'; MaxLinkWidth=4
        Driver='x'; Status='OK'
    }
    $fields = (@($fake | Format-PciDelimited)[0]) -split '\|'
    Assert-Equal '0' $fields[9] 'a genuine zero must not become an empty field'
}

It 'strips a delimiter found inside a value rather than shifting columns' {
    # FriendlyName comes from driver INF files and is not under our control.
    # An unescaped delimiter would silently move every later column.
    $fake = [pscustomobject]@{
        Slot='01:00.0'; VendorId='dead'; DeviceId='beef'; ClassCode='0108'
        ClassName='NVMe'; VendorName='Evil|Corp'; DeviceName='W'; Revision='00'
        LinkSpeed='8GT/s'; LinkWidth=4; MaxLinkSpeed='8GT/s'; MaxLinkWidth=4
        Driver='x'; Status='OK'
    }
    $line = @($fake | Format-PciDelimited)[0]
    $fields = $line -split '\|'
    Assert-Equal 14 $fields.Count 'column count must be stable'
    Assert-Equal 'Evil/Corp' $fields[5]
}

It 'header row names the columns in order' {
    $lines = @(Get-PciDevice -Slot '01:' | Format-PciDelimited -Header)
    $header = ($lines[0] -split '\|')
    Assert-Equal 'Slot' $header[0]
    Assert-Equal 'LinkSpeed' $header[8]
    Assert-Equal $header.Count (($lines[1] -split '\|').Count) `
        'header and data must have the same column count'
}

It 'supports a different delimiter' {
    $line = @(Get-PciDevice -Slot '01:' | Format-PciDelimited -Delimiter "`t")[0]
    Assert-True ($line.Contains("`t")) 'tab delimiter not applied'
}

It 'attribute rows use their own column set' {
    $line = @(Get-PciDevice -Slot '01:00.0' |
        ConvertTo-PciAttributeRecord -Attribute 'LinkSpeed' |
        Format-PciDelimited)[0]
    $f = $line -split '\|'
    Assert-Equal 6 $f.Count 'attribute rows are 6 columns'
    Assert-Equal 'LinkSpeed' $f[3]
}

It 'the CLI emits delimited output and composes with Select-String' {
    $cliPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\lspci.ps1'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cliPath -Delimited
    $hit = @($out | Select-String -SimpleMatch '|')
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
