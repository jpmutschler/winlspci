# Packaging and release

How winlspci gets to people who do not `git clone`. Nothing here runs in CI;
these are the manual steps for a release, kept next to the files they use.

## 1. Tag the release

```powershell
# ModuleVersion in winlspci.psd1 and the top entry of CHANGELOG.md agree.
git tag -a v0.5.0 -m "winlspci 0.5.0"
git push origin v0.5.0
```

GitHub builds the source archive at
`https://github.com/jpmutschler/winlspci/archive/refs/tags/v0.5.0.zip`. That
archive *is* the release: the module runs from a directory, no build step.

## 1b. Build the single-file module

The source tree dot-sources 12 files from `Public\` and `Private\`; that costs
~160 ms per invocation (measured: import 378 ms from 12 files, 217 ms from
one). Releases ship one concatenated `winlspci.psm1`:

```powershell
.\packaging\Build-Module.ps1 -OutputDirectory .\dist
Import-Module .\dist\winlspci\winlspci.psd1; Get-Command -Module winlspci   # 19 commands
powershell -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1               # suite still runs against the source tree
```

`dist\` is git-ignored. The release zip (§4b) and, later, the Gallery publish
are made from `dist\winlspci`, not from the source tree; scoop/winget install
the tag's source archive.

## 2. PowerShell Gallery — planned, not yet done

The manifest is Gallery-ready (`ProjectUri`, `LicenseUri`, tags, release
notes pointing at `CHANGELOG.md`), but nothing has been published: it needs a
Gallery API key, which is a one-time setup — sign in at
<https://www.powershellgallery.com>, *API Keys* → *Create*, scope "Push new
packages and package versions", glob pattern `winlspci`. Then, from the built
copy:

```powershell
Test-ModuleManifest .\dist\winlspci\winlspci.psd1
Publish-Module -Path .\dist\winlspci -NuGetApiKey $env:PSGALLERY_KEY -Repository PSGallery
Find-Module winlspci
```

Once published, `Install-Module winlspci -Scope CurrentUser` lands the module
in a `PSModulePath` directory with `bin\` **not** on PATH, which is what
`Install-LspciShim` is for (it already works for a module unzipped from a
release): it writes a two-line `lspci.cmd` into
`%LOCALAPPDATA%\Microsoft\WindowsApps` pointing at the module's
`bin\lspci.ps1`; `-Remove` deletes it.

## 3. scoop

`packaging/scoop/winlspci.json` is a manifest for a bucket. Before publishing
a version, fill in the archive hash:

```powershell
$v = '0.5.0'
$zip = "https://github.com/jpmutschler/winlspci/archive/refs/tags/v$v.zip"
Invoke-WebRequest $zip -OutFile "$env:TEMP\winlspci-$v.zip"
(Get-FileHash "$env:TEMP\winlspci-$v.zip" -Algorithm SHA256).Hash.ToLower()
```

and put it in `hash`; `scoop install winlspci` then puts `bin\lspci.cmd` on
PATH through scoop's shim directory (the `bin` entry in the manifest).

**Never publish the manifest with `hash` removed.** The placeholder fails
closed (scoop rejects a mismatch), but an *absent* `hash` tells scoop to skip
verification entirely -- clearing the field to get past an install problem
silently disables integrity checking on the download.

## 4. winget

`packaging/winget/` holds the three-file manifest for the current version
(version / installer / default-locale) with the tag archive's SHA-256 filled
in: `InstallerType: zip`, a `portable` nested installer for `bin\lspci.cmd`
aliased `lspci`. To publish, copy them to
`manifests/j/jpmutschler/winlspci/<version>/` in a fork of
`microsoft/winget-pkgs`, validate with `winget validate --manifest <dir>`
(or `wingetcreate submit`), and open the PR there. Per release: bump
`PackageVersion`, the `InstallerUrl` tag, the `RelativeFilePath` folder name,
and recompute `InstallerSha256`.

## 4b. GitHub release

`gh release create v<version> <winlspci-<version>-module.zip> --verify-tag
--notes-file <CHANGELOG section>` — the attached zip is `dist\winlspci`
compressed (`Compress-Archive -Path .\dist\winlspci`), i.e. the single-file
build; the source archive of the tag is what scoop/winget install.

## 5. Authenticode (optional, not yet done)

`bin\lspci.cmd` launches `powershell.exe -ExecutionPolicy Bypass`, which is
the right flag for an unsigned script. With a code-signing certificate:

```powershell
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select-Object -First 1
Get-ChildItem -Recurse -Include *.ps1, *.psm1, *.psd1 | Set-AuthenticodeSignature -Certificate $cert -TimestampServer http://timestamp.digicert.com
```

and the launcher can drop `Bypass` for `AllSigned` environments. Until then,
`Bypass` stays -- it is not a security boundary (per Microsoft), and
`-NoProfile` is the flag that matters. If signing lands: sign the BUILT copy
(`dist\winlspci`, not the tests), and only after the `ModuleVersion` bump --
editing the manifest afterwards invalidates its signature.

## 6. Checklist

- [ ] `CHANGELOG.md`: move `[Unreleased]` under the new version with today's date
- [ ] `winlspci.psd1`: `ModuleVersion`
- [ ] `tests\Invoke-Tests.ps1` green locally and in CI
- [ ] `packaging\Build-Module.ps1 -OutputDirectory .\dist` and import the result once
- [ ] tag, push the tag
- [ ] GitHub release with the module zip attached (§4b)
- [ ] (when Gallery publishing is set up, §2) `Publish-Module` from `dist\winlspci`
- [ ] scoop manifest hash (§3), winget manifests in `packaging/winget/` (§4)
- [ ] README: confirm the install section still describes the easiest path
