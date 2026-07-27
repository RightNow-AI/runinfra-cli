# RunInfra CLI installer for Windows.
#
#   irm https://raw.githubusercontent.com/RightNow-AI/runinfra-cli/main/install.ps1 | iex
#
# Installs the standalone runinfra.exe, which needs no Node and no Python
# runtime on the machine. The binary is verified against the release's
# SHA256SUMS file before anything is put into place, and this script never
# edits your PATH: if the install directory is not on it, the exact command to
# add it is printed and the decision stays yours.
#
# OPTIONS. Every option is an environment variable and a parameter. A piped
# install has nowhere to put a parameter, so use the variables there:
#
#   $env:RUNINFRA_VERSION = "0.1.1"; irm <url> | iex
#
# and use the parameters when you have the file, or when you want both at once:
#
#   .\install.ps1 -Version 0.1.1 -InstallDir C:\tools\bin
#   & ([scriptblock]::Create((irm <url>))) -Version 0.1.1
#
#   RUNINFRA_VERSION       -Version      Pin a release, "0.1.1" or "v0.1.1".
#                                        Default: the newest release.
#   RUNINFRA_INSTALL_DIR   -InstallDir   Default: %LOCALAPPDATA%\RunInfra\bin
#   RUNINFRA_REPO          -Repo         owner/name holding the releases.
#   RUNINFRA_BASE_URL      -BaseUrl      Take the artifacts from this directory
#                                        URL instead of a release. https:// and
#                                        file:// only. Skips the version lookup.
#   RUNINFRA_TARGET        -Target       Force the build to fetch, for example
#                                        "windows-x64". Default: detected.
#
# THE RELEASE LAYOUT THIS EXPECTS. Each release is tagged "v<version>" and
# carries these files as flat assets, with no directory components in the name:
#
#   runinfra-linux-x64           runinfra-darwin-x64
#   runinfra-linux-x64-musl      runinfra-darwin-arm64
#   runinfra-linux-arm64         runinfra-windows-x64.exe
#   runinfra-linux-arm64-musl    SHA256SUMS
#
# SHA256SUMS is coreutils format: one "<64 lowercase hex>  <artifact>" line per
# artifact. Windows on Arm is served the x64 build and told so, because Windows
# runs it under emulation and there is no native Arm build to ship.
#
# This file is deliberately plain ASCII. Windows PowerShell 5.1 reads a .ps1
# with no byte order mark as the system ANSI code page, so a non-ASCII
# character here would arrive as mojibake on some machines.

param(
    [string] $Version = $env:RUNINFRA_VERSION,
    [string] $InstallDir = $env:RUNINFRA_INSTALL_DIR,
    [string] $Repo = $env:RUNINFRA_REPO,
    [string] $BaseUrl = $env:RUNINFRA_BASE_URL,
    [string] $Target = $env:RUNINFRA_TARGET
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Invoke-WebRequest is not used here, but the progress renderer is global and
# it is what makes large transfers crawl on Windows PowerShell.
$ProgressPreference = 'SilentlyContinue'

$RepoDefault = 'RightNow-AI/runinfra-cli'
$BinaryName = 'runinfra.exe'
$SupportedTargets = @('windows-x64')

# ------------------------------------------------------------------ output --

function Write-Plain {
    param([string] $Text = '')
    Write-Host $Text
}

# The only way this script reports failure. It throws rather than calling
# exit: `exit` inside an `irm | iex` install terminates the whole PowerShell
# process, which would close the window the user is standing in. A throw stops
# the install, prints in red, and still makes `powershell -File install.ps1`
# return a non zero exit code to a CI job.
function Fail {
    param(
        [Parameter(Mandatory = $true)][string] $Message,
        [string[]] $Hints = @()
    )
    $lines = @($Message)
    foreach ($hint in $Hints) { $lines += "  $hint" }
    throw ($lines -join [Environment]::NewLine)
}

# ----------------------------------------------------------------- helpers --

function Get-DetectedTarget {
    # A 32 bit PowerShell on 64 bit Windows reports x86 in PROCESSOR_ARCHITECTURE
    # and the real answer in PROCESSOR_ARCHITEW6432. Read the truthful one first.
    $raw = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $env:PROCESSOR_ARCHITECTURE }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Fail "could not read this machine's CPU architecture." @(
            'Force it: -Target windows-x64'
        )
    }

    switch ($raw.ToUpperInvariant()) {
        'AMD64' { return @{ Target = 'windows-x64'; Detected = "Windows $raw"; Note = $null } }
        'ARM64' {
            return @{
                Target   = 'windows-x64'
                Detected = "Windows $raw"
                Note     = 'This is an Arm machine. Windows runs the x64 build under emulation, and there is no native Arm build to install.'
            }
        }
        'X86' {
            Fail "this is 32 bit Windows, and the CLI is published as a 64 bit program only." @(
                'A 64 bit version of Windows is required.'
            )
        }
        default {
            Fail "unsupported CPU architecture: Windows reported '$raw'." @(
                'The published Windows build is x64.'
            )
        }
    }
}

function Get-LatestTag {
    param([Parameter(Mandatory = $true)][string] $Repository)

    # Asking github.com for /releases/latest answers with a redirect to the
    # tag. Reading that redirect costs no API rate limit, which matters on a
    # shared cloud address where the API budget is spent by everyone at once.
    $request = [System.Net.HttpWebRequest]::Create("https://github.com/$Repository/releases/latest")
    $request.AllowAutoRedirect = $false
    $request.Method = 'HEAD'
    $request.UserAgent = 'runinfra-installer'
    $request.Timeout = 30000

    $response = $null
    try {
        try {
            $response = $request.GetResponse()
        } catch [System.Net.WebException] {
            $response = $_.Exception.Response
        }
        if ($null -eq $response) { return $null }
        $location = $response.Headers['Location']
        if ([string]::IsNullOrWhiteSpace($location)) { return $null }
        return ($location.TrimEnd('/') -split '/')[-1]
    } finally {
        if ($null -ne $response) { $response.Close() }
    }
}

function Save-Url {
    param(
        [Parameter(Mandatory = $true)][string] $Url,
        [Parameter(Mandatory = $true)][string] $Destination
    )
    $client = New-Object System.Net.WebClient
    try {
        if ($Url -like 'http*') { $client.Headers.Add('User-Agent', 'runinfra-installer') }
        $client.DownloadFile($Url, $Destination)
    } finally {
        $client.Dispose()
    }
}

# WebClient reports an HTTP 404 as "the connection was closed unexpectedly",
# which sends the reader hunting for a network fault when the real answer is
# that the file is not there. Dig the status code out and say it plainly.
function Get-TransferFailureReason {
    param([Parameter(Mandatory = $true)] $ErrorRecord)
    $exception = $ErrorRecord.Exception
    for ($depth = 0; $depth -lt 5 -and $null -ne $exception; $depth++) {
        if ($exception -is [System.Net.WebException]) {
            $response = $exception.Response
            if ($null -ne $response -and $response -is [System.Net.HttpWebResponse]) {
                return "The server answered $([int]$response.StatusCode) $($response.StatusDescription)."
            }
            return $exception.Message
        }
        $exception = $exception.InnerException
    }
    return $ErrorRecord.Exception.Message
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-PathContains {
    param([string] $PathValue, [Parameter(Mandatory = $true)][string] $Directory)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }
    $wanted = $Directory.TrimEnd('\')
    foreach ($entry in $PathValue -split ';') {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if ($entry.Trim().TrimEnd('\') -ieq $wanted) { return $true }
    }
    return $false
}

# -------------------------------------------------------------- the install --

function Install-RunInfraCli {
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Fail "this installer needs Windows PowerShell 5.1 or newer, and this is $($PSVersionTable.PSVersion)." @(
            'Windows 10 and Windows 11 ship 5.1 as standard.'
        )
    }
    if (-not (Get-Command Get-FileHash -ErrorAction SilentlyContinue)) {
        Fail 'this PowerShell has no Get-FileHash, so the download cannot be verified.' @(
            'Refusing to install bytes that cannot be checked against the published hash.'
        )
    }

    # Some hosts still default to TLS 1.0, which github.com refuses.
    try {
        [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        Fail 'this machine cannot negotiate TLS 1.2, which the download requires.'
    }

    $repository = if ([string]::IsNullOrWhiteSpace($Repo)) { $RepoDefault } else { $Repo.Trim() }

    # --- what machine is this
    $note = $null
    if (-not [string]::IsNullOrWhiteSpace($Target)) {
        $target = $Target.Trim()
        if ($SupportedTargets -notcontains $target) {
            Fail "unknown target: $target" @("Windows builds that exist: $($SupportedTargets -join ', ')")
        }
        $detected = 'forced with -Target'
    } else {
        $detection = Get-DetectedTarget
        $target = $detection.Target
        $detected = $detection.Detected
        $note = $detection.Note
    }
    $artifact = "runinfra-$target.exe"

    # --- where to install
    $directory = $InstallDir
    if ([string]::IsNullOrWhiteSpace($directory)) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            Fail 'LOCALAPPDATA is not set, so there is no default install directory.' @(
                'Pass one: -InstallDir C:\tools\bin'
            )
        }
        $directory = Join-Path $env:LOCALAPPDATA 'RunInfra\bin'
    }

    # --- where the files come from
    $tag = $null
    if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
        $trimmed = $BaseUrl.Trim().TrimEnd('/')
        if ($trimmed -like 'http://*') {
            Fail "refusing an http:// source: $trimmed" @(
                'The checksum would arrive over the same unprotected connection as the',
                'binary, so anything able to change one can change the other. Use https.'
            )
        }
        if (-not ($trimmed -like 'https://*' -or $trimmed -like 'file://*')) {
            Fail "-BaseUrl must start with https:// or file://, got: $trimmed"
        }
        $sourceBase = $trimmed
        $sourceLabel = $trimmed
    } else {
        if (-not [string]::IsNullOrWhiteSpace($Version)) {
            # "0.1.1" becomes the v form, which is how releases are tagged.
            # Anything not starting with a digit is taken to be a tag already,
            # so an unusual scheme can still be pinned without a switch for it.
            $wanted = $Version.Trim()
            $tag = if ($wanted -match '^[0-9]') { "v$wanted" } else { $wanted }
        } else {
            Write-Plain "Looking up the newest release of $repository."
            try {
                $tag = Get-LatestTag -Repository $repository
            } catch {
                $tag = $null
            }
            if ([string]::IsNullOrWhiteSpace($tag)) {
                Fail "could not work out the newest release of $repository." @(
                    'Check the network, or pin one: -Version 0.1.1'
                )
            }
            # This tag came from the release itself, so it only has to look
            # like a version, with or without the v. Demanding one spelling
            # here would break a correct lookup over punctuation.
            if ($tag -notmatch '^v?[0-9]') {
                Fail "the newest release of $repository is tagged '$tag', which is not a version." @(
                    'Pin the one you want: -Version 0.1.1'
                )
            }
        }
        $sourceBase = "https://github.com/$repository/releases/download/$tag"
        $sourceLabel = "$repository $tag"
    }

    # --- say what is about to happen
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $directory = (Resolve-Path -LiteralPath $directory).ProviderPath
    $destination = Join-Path $directory $BinaryName
    $verb = if (Test-Path -LiteralPath $destination) { 'Upgrading' } else { 'Installing' }

    Write-Plain ''
    Write-Plain "$verb the runinfra CLI."
    Write-Plain ('  {0,-14}{1}' -f 'machine', $detected)
    Write-Plain ('  {0,-14}{1}' -f 'build', $artifact)
    Write-Plain ('  {0,-14}{1}' -f 'source', $sourceLabel)
    Write-Plain ('  {0,-14}{1}' -f 'install to', $destination)
    if ($note) { Write-Plain "  $note" }
    Write-Plain ''

    # The download is staged inside the install directory so the final step is
    # a rename on one volume. A staged copy in the temp folder could be on a
    # different drive, which turns the last step into a slow copy that can be
    # interrupted half written.
    $staged = Join-Path $directory (".runinfra.download.$PID.exe")
    $sums = Join-Path ([System.IO.Path]::GetTempPath()) "runinfra-SHA256SUMS.$PID"
    $backup = "$destination.old"

    try {
        Write-Plain "Downloading $artifact"
        try {
            Save-Url -Url "$sourceBase/$artifact" -Destination $staged
        } catch {
            Fail "could not download $artifact" @(
                "from $sourceBase/$artifact",
                (Get-TransferFailureReason -ErrorRecord $_),
                "If that file is not there, this release has no build for $target."
            )
        }

        Write-Plain 'Downloading SHA256SUMS'
        try {
            Save-Url -Url "$sourceBase/SHA256SUMS" -Destination $sums
        } catch {
            Fail "could not download SHA256SUMS from $sourceBase/SHA256SUMS" @(
                (Get-TransferFailureReason -ErrorRecord $_),
                'Without it the binary cannot be verified, so nothing has been installed.'
            )
        }

        # GNU writes "<hash>  <name>", and in binary mode "<hash> *<name>".
        # Match both, and match the exact name so that a line for a different
        # build can never be read as this one's.
        $expected = $null
        foreach ($line in (Get-Content -LiteralPath $sums)) {
            $fields = $line.Trim() -split '\s+', 2
            if ($fields.Count -lt 2) { continue }
            if ($fields[1].TrimStart('*') -eq $artifact) { $expected = $fields[0]; break }
        }
        if ([string]::IsNullOrWhiteSpace($expected)) {
            Fail "SHA256SUMS has no line for $artifact." @(
                "Nothing has been installed. This release is incomplete for $target."
            )
        }
        if ($expected -notmatch '^[0-9a-fA-F]{64}$') {
            Fail "the SHA256SUMS entry for $artifact is not a sha256 hash." @(
                'Nothing has been installed.'
            )
        }
        $expected = $expected.ToLowerInvariant()

        Write-Plain 'Verifying checksum'
        $actual = Get-Sha256 -Path $staged
        if ($actual -ne $expected) {
            Fail "checksum mismatch on $artifact. Nothing has been installed." @(
                "expected  $expected",
                "got       $actual",
                'The download is damaged or it is not the file the release published.',
                'Try again, and if it happens twice do not use the file.'
            )
        }

        # Run the staged copy before it takes the real name. If it cannot run
        # here it will not run once renamed, and an upgrade that swapped a
        # working binary for a broken one would be the worst outcome this
        # script could produce.
        # All of the output is collected before anything is inspected. Piping a
        # native command straight into Select-Object -First stops it early, and
        # an early stop leaves $LASTEXITCODE reading whatever ran before it.
        $probeOutput = $null
        try {
            $probeOutput = & $staged --version 2>&1
            $probeExit = $LASTEXITCODE
        } catch {
            $probeOutput = $_.Exception.Message
            $probeExit = 1
        }
        $reported = ($probeOutput | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($reported)) { $reported = 'runinfra' }
        if ($probeExit -ne 0) {
            Fail 'the downloaded program passed its checksum but will not run here.' @(
                "$reported",
                'Nothing has been replaced. Some endpoint protection blocks new',
                'executables in this location. Try another: -InstallDir C:\tools\bin'
            )
        }

        # Windows will not let a running program be overwritten, but it will
        # let one be renamed. Move the old one aside, put the new one in, and
        # only then try to delete the old one.
        $movedAside = $false
        if (Test-Path -LiteralPath $destination) {
            if (Test-Path -LiteralPath $backup) {
                Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
            }
            try {
                Move-Item -LiteralPath $destination -Destination $backup -Force
                $movedAside = $true
            } catch {
                Fail "could not move the installed runinfra.exe aside to replace it." @(
                    'Close any window that is running runinfra and try again.',
                    $_.Exception.Message
                )
            }
        }

        try {
            Move-Item -LiteralPath $staged -Destination $destination -Force
        } catch {
            # Put the previous install back rather than leave the machine with
            # no CLI at all.
            if ($movedAside) {
                Move-Item -LiteralPath $backup -Destination $destination -Force -ErrorAction SilentlyContinue
            }
            Fail "could not put the new runinfra.exe into $directory." @(
                'The previous install has been left in place.',
                $_.Exception.Message
            )
        }

        if ($movedAside -and (Test-Path -LiteralPath $backup)) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $backup) {
                Write-Plain "The previous version is still in use, so it was left at $backup."
                Write-Plain 'It can be deleted once nothing is running it.'
            }
        }
    } finally {
        # A half written program in the install directory is worse than none,
        # and it is a file the user did not ask for. It never survives us.
        if (Test-Path -LiteralPath $staged) {
            Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $sums) {
            Remove-Item -LiteralPath $sums -Force -ErrorAction SilentlyContinue
        }
    }

    # ------------------------------------------------------------- report --
    Write-Plain ''
    Write-Plain "Installed $reported to $destination"

    if (Test-PathContains -PathValue $env:PATH -Directory $directory) {
        Write-Plain 'Run: runinfra login'
        return
    }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (Test-PathContains -PathValue $userPath -Directory $directory) {
        Write-Plain ''
        Write-Plain "$directory is already on your PATH, but not in this window."
        Write-Plain 'Open a new terminal, then run: runinfra login'
        return
    }

    Write-Plain ''
    Write-Plain "$directory is not on your PATH, so the name runinfra will not"
    Write-Plain 'resolve yet. This command adds it for your account only, and it'
    Write-Plain 'appends rather than replaces:'
    Write-Plain ''
    Write-Plain '  [Environment]::SetEnvironmentVariable(''Path'','
    Write-Plain "    [Environment]::GetEnvironmentVariable('Path','User') + ';$directory', 'User')"
    Write-Plain ''
    Write-Plain 'Run it, then open a new terminal. This installer does not change'
    Write-Plain 'your PATH on its own. Until then, the full path works:'
    Write-Plain "  $destination login"
}

try {
    Install-RunInfraCli
    Write-Plain ''
} catch {
    Write-Plain ''
    $messageLines = $_.Exception.Message -split "`n"
    Write-Host ("runinfra install: " + $messageLines[0].TrimEnd("`r")) -ForegroundColor Red
    if ($messageLines.Count -gt 1) {
        foreach ($line in $messageLines[1..($messageLines.Count - 1)]) {
            Write-Host $line.TrimEnd("`r") -ForegroundColor Red
        }
    }
    Write-Plain ''
    # Rethrown so `powershell -File install.ps1` reports failure to whatever
    # ran it. Never `exit`: that would close an interactive window.
    throw 'runinfra install failed.'
}
