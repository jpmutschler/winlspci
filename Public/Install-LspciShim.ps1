function Install-LspciShim {
    <#
    .SYNOPSIS
      Put an `lspci` command on PATH that runs this module's CLI.

    .DESCRIPTION
      Clone-and-run users add bin\ to PATH themselves. A module unzipped from
      a release (or, once published, installed from the PowerShell Gallery)
      sits wherever it was put, with no bin\ on PATH, so this writes a tiny
      lspci.cmd into a directory that is on PATH -- by
      default %LOCALAPPDATA%\Microsoft\WindowsApps, which Windows usually
      puts on the user's PATH (it warns if it is not) and which no other
      non-admin user can write to.

      The shim is the same two lines as bin\lspci.cmd, pointed at wherever
      this module is installed, so `lspci -nn` works from any shell.

    .PARAMETER Directory
      Where to write lspci.cmd. Must already be on PATH for the shim to be
      useful; the function says so if it is not.
    .PARAMETER Remove
      Delete the shim instead.

    .EXAMPLE
      Expand-Archive winlspci-0.5.0-module.zip $env:LOCALAPPDATA\Programs
      Import-Module $env:LOCALAPPDATA\Programs\winlspci\winlspci.psd1
      Install-LspciShim
      lspci -nn
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Directory = (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'),
        [switch]$Remove
    )

    $dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Directory)
    $shim = Join-Path $dir 'lspci.cmd'

    $marker = 'Shim written by Install-LspciShim'

    if ($Remove) {
        if (-not (Test-Path -LiteralPath $shim)) { Write-Verbose "no shim at $shim"; return }
        # Only remove what this function wrote: the repo's own bin\lspci.cmd
        # (or anyone else's lspci.cmd) does not carry the marker.
        if ((Get-Content -LiteralPath $shim -Raw) -notlike "*$marker*") {
            throw "Install-LspciShim: '$shim' was not written by Install-LspciShim; refusing to remove it"
        }
        if ($PSCmdlet.ShouldProcess($shim, 'remove lspci shim')) { Remove-Item -LiteralPath $shim -Force }
        return
    }

    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        throw "Install-LspciShim: directory '$dir' does not exist"
    }

    # The CLI lives next to this module, wherever it was installed.
    $cliPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\lspci.ps1'
    if (-not (Test-Path -LiteralPath $cliPath)) { throw "Install-LspciShim: cannot find the CLI at '$cliPath'" }

    # cmd.exe expands %NAME% inside a batch file even within quotes, so a
    # path containing '%' must have it doubled or the shim points somewhere
    # that does not exist. Nothing else in an NTFS path escapes the quotes.
    $cmdSafePath = $cliPath.Replace('%', '%%')
    $content = @(
        '@echo off'
        "REM winlspci -- lspci for Windows. $marker."
        ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" %*' -f $cmdSafePath)
    ) -join "`r`n"

    # Never overwrite something that is not ours.
    if ((Test-Path -LiteralPath $shim) -and ((Get-Content -LiteralPath $shim -Raw) -notlike "*$marker*")) {
        throw "Install-LspciShim: '$shim' exists and was not written by Install-LspciShim; remove it yourself or choose another -Directory"
    }

    if (-not $PSCmdlet.ShouldProcess($shim, "write lspci shim pointing at $cliPath")) { return }
    [IO.File]::WriteAllText($shim, $content + "`r`n", [System.Text.Encoding]::ASCII)
    $onPath = @(($env:PATH -split ';') | Where-Object { $_ -and ($_.TrimEnd('\') -ieq $dir.TrimEnd('\')) }).Count -gt 0
    if ($onPath) { Write-Verbose "wrote $shim; 'lspci' is on PATH" }
    else { Write-Warning "wrote $shim, but '$dir' is not on PATH in this session; add it, or pass -Directory <a directory on PATH>" }
    return $shim
}
