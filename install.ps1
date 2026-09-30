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
# WHAT THIS SCRIPT DOES NOT CHECK. Releases also publish SHA256SUMS.sig, an
# Ed25519 signature over SHA256SUMS. This installer does NOT verify it, and
# says so on screen rather than staying quiet about it. Windows PowerShell 5.1
# has no Ed25519 primitive, and .NET only gained one in 8, so there is nothing
# here to verify it with. The honest options were to add a dependency, to fake
# the check, or to tell you plainly which check ran and which did not. This
# file does the third: the sha256 comparison is real and still refuses a bad
# download, and the signature is left to you with the exact command printed.
# See https://github.com/RightNow-AI/runinfra-cli#verifying-a-release.
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
#   RUNINFRA_INSTALL_BASE_URL -BaseUrl   Take the artifacts from this directory
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
#                                SHA256SUMS.sig
#                                THIRD-PARTY-NOTICES.txt
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
    [string] $BaseUrl = $env:RUNINFRA_INSTALL_BASE_URL,
    [string] $Target = $env:RUNINFRA_TARGET
)

# The call operator creates a child scope even when this file is fed to iex.
# Preferences, StrictMode and installer helpers disappear on return or throw.
& {
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Invoke-WebRequest is not used here, but the progress renderer is global and
# it is what makes large transfers crawl on Windows PowerShell.
$ProgressPreference = 'SilentlyContinue'

$RepoDefault = 'RightNow-AI/runinfra-cli'
$BinaryName = 'runinfra.exe'
$NoticesName = 'THIRD-PARTY-NOTICES.txt'
$SupportedTargets = @('windows-x64')

# Printed, never used to verify anything here, because nothing in Windows
# PowerShell 5.1 can verify an Ed25519 signature. It is sha256 over the raw 32
# byte public key, and it lets a reader confirm that the key they fetched to
# run the check by hand is the same one cli/README.md and cli/install.sh pin.
$ReleaseKeyFingerprint = '5b2c8f637c0cd00a61ec6f126e5a9493c022ef1ea5be70fdd3ef4adf55801532'

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

function Get-HttpsUri {
    param([Parameter(Mandatory = $true)][string] $Url)
    $address = $null
    if ($Url -match '[\x00-\x20\x7f]' -or $Url -match '^https:[/\\]*[^/\\?#]*@' -or
        -not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref] $address) -or
        $address.Scheme -ne 'https' -or [string]::IsNullOrEmpty($address.Host) -or
        -not [string]::IsNullOrEmpty($address.UserInfo)) {
        Fail 'Downloads require an HTTPS URL without user information.'
    }
    return $address
}

function New-HttpsRequest {
    param([Parameter(Mandatory = $true)][Uri] $Address)
    $null = Get-HttpsUri -Url $Address.AbsoluteUri
    if ($null -ne [Net.ServicePointManager]::ServerCertificateValidationCallback) {
        Fail 'Downloads require the default TLS certificate validation.'
    }
    $request = [System.Net.WebRequest]::Create($Address)
    $request.AllowAutoRedirect = $false
    $request.UserAgent = 'runinfra-installer'
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    return $request
}

function Get-LocalMirrorUri {
    param([Parameter(Mandatory = $true)][string] $Url)
    $address = $null
    if ($Url -notmatch '^file:///' -or $Url -match '[\x00-\x1e\x7f\\]' -or
        -not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref] $address) -or
        -not $address.IsFile -or $address.IsUnc -or -not [string]::IsNullOrEmpty($address.Host) -or
        -not [string]::IsNullOrEmpty($address.UserInfo) -or -not [string]::IsNullOrEmpty($address.Query) -or
        -not [string]::IsNullOrEmpty($address.Fragment) -or $address.LocalPath -match '[\x00-\x1f\x7f]' -or
        $address.LocalPath -match '^[/\\]{2}') {
        Fail 'Downloads require HTTPS or an explicit local file mirror.'
    }
    return $address
}

function Get-LatestTag {
    param([Parameter(Mandatory = $true)][string] $Repository)

    # Asking github.com for /releases/latest answers with a redirect to the
    # tag. Reading that redirect costs no API rate limit, which matters on a
    # shared cloud address where the API budget is spent by everyone at once.
    $request = New-HttpsRequest -Address (Get-HttpsUri -Url "https://github.com/$Repository/releases/latest")
    $request.Method = 'HEAD'

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
        $redirect = Get-HttpsUri -Url ([Uri]::new($request.RequestUri, $location)).AbsoluteUri
        return ($redirect.AbsolutePath.TrimEnd('/') -split '/')[-1]
    } finally {
        if ($null -ne $response) { $response.Close() }
    }
}

function Save-Url {
    param(
        [Parameter(Mandatory = $true)][string] $Url,
        [Parameter(Mandatory = $true)][string] $Destination
    )
    $local = $Url.StartsWith('file:///', [StringComparison]::Ordinal)
    if ($local) {
        # A redirect never enters this branch. Only a caller-selected mirror
        # authorizes local bytes, which go through the same checksum checks.
        $selected = Get-Variable -Name BaseUrl -ValueOnly -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($selected) -or -not $Url.StartsWith($selected.TrimEnd('/') + '/', [StringComparison]::Ordinal)) {
            Fail 'Downloads require HTTPS or an explicit local file mirror.'
        }
        $address = Get-LocalMirrorUri -Url $Url
    } else { $address = Get-HttpsUri -Url $Url }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $complete = $false
    $created = $false
    $response = $null
    $inputStream = $null
    $outputStream = $null
    $request = $null
    try {
        if ($local) {
            $inputStream = [IO.File]::OpenRead($address.LocalPath)
            $expectedLength = $inputStream.Length
        } else {
        for ($redirects = 0; $redirects -le 5; $redirects++) {
            if ($watch.ElapsedMilliseconds -ge 600000) { Fail 'The download timed out.' }
            $request = New-HttpsRequest -Address $address
            $request.Timeout = [int][Math]::Min(30000, 600000 - $watch.ElapsedMilliseconds)
            $response = $request.GetResponse()
            $status = [int]$response.StatusCode
            if (@(301, 302, 303, 307, 308) -contains $status) {
                $location = $response.Headers['Location']
                if ($redirects -eq 5 -or [string]::IsNullOrWhiteSpace($location)) {
                    Fail 'The download returned too many redirects or an invalid redirect.'
                }
                $address = Get-HttpsUri -Url ([Uri]::new($address, $location)).AbsoluteUri
                $response.Close()
                $response = $null
                continue
            }
            if ($status -ne 200) { Fail 'The download did not return a complete file.' }
            break
        }
        $expectedLength = $response.ContentLength
        $inputStream = $response.GetResponseStream()
        }
        $maximumBytes = 536870912
        if ($expectedLength -gt $maximumBytes) { Fail 'The download exceeds the 512 MiB limit.' }
        $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $created = $true
        $buffer = New-Object byte[] 65536
        $received = [long]0
        while ($true) {
            $remaining = 600000 - $watch.ElapsedMilliseconds
            if ($remaining -le 0) { Fail 'The download timed out.' }
            if ($inputStream.CanTimeout) { $inputStream.ReadTimeout = [int][Math]::Min(30000, $remaining) }
            $count = $inputStream.Read($buffer, 0, $buffer.Length)
            if ($count -eq 0) { break }
            $received += $count
            if ($received -gt $maximumBytes) { Fail 'The download exceeds the 512 MiB limit.' }
            $outputStream.Write($buffer, 0, $count)
        }
        if ($expectedLength -ge 0 -and $received -ne $expectedLength) { Fail 'The download ended before the complete file arrived.' }
        $outputStream.Flush($true)
        $complete = $true
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        if ($null -ne $response) { $response.Close() }
        if ($null -ne $request) { $request.Abort() }
        $watch.Stop()
        if ($created -and -not $complete -and (Test-Path -LiteralPath $Destination)) {
            Remove-Item -LiteralPath $Destination -Force
        }
    }
}

# Keep missing release assets distinguishable from a failed connection.
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
    $stream = $null
    $hasher = $null
    try {
        # Hash directly without module discovery. Prefer the Windows FIPS provider.
        $hasherType = 'System.Security.Cryptography.SHA256CryptoServiceProvider' -as [type]
        $hasher = if ($null -ne $hasherType) {
            $hasherType::new()
        } else {
            [System.Security.Cryptography.SHA256]::Create()
        }
        $stream = [System.IO.File]::OpenRead($Path)
        return [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $hasher) { $hasher.Dispose() }
    }
}

function Get-ManifestChecksum {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Name,
        [switch] $Optional
    )
    $expected = $null
    $entryCount = 0
    $malformed = $false
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $fields = $line.Trim() -split '\s+'
        $listed = $false
        foreach ($field in $fields) {
            if ($field -ceq $Name -or $field -ceq "*$Name") { $listed = $true; break }
        }
        if (-not $listed) { continue }
        $entryCount++
        if ($fields.Count -ne 2 -or ($fields[1] -cne $Name -and $fields[1] -cne "*$Name")) {
            $malformed = $true
        } else {
            $expected = $fields[0]
        }
    }
    if ($entryCount -eq 0) {
        if ($Optional) { return $null }
        Fail "SHA256SUMS has no line for $Name." @('Nothing has been installed. This release is incomplete.')
    }
    if ($entryCount -ne 1 -or $malformed -or $expected -notmatch '^[0-9a-fA-F]{64}$') {
        Fail "SHA256SUMS must contain exactly one valid sha256 hash for $Name." @('Nothing has been installed.')
    }
    return $expected.ToLowerInvariant()
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
        if ($trimmed.StartsWith('file:///', [StringComparison]::Ordinal)) {
            $localMirror = Get-LocalMirrorUri -Url $trimmed
            if (-not [IO.Directory]::Exists($localMirror.LocalPath)) { Fail 'The local file mirror directory does not exist.' }
        } else { $null = Get-HttpsUri -Url $trimmed }
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
    $stagedNotices = Join-Path $directory (".$NoticesName.download.$PID")
    $noticesDestination = Join-Path $directory $NoticesName
    $noticesBackup = Join-Path $directory (".$NoticesName.previous.$PID")
    $noticesReplaced = $false
    $binaryInstalled = $false
    $keepNoticesBackup = $false
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
        $expected = Get-ManifestChecksum -Path $sums -Name $artifact

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

        # Releases before bundled third-party notices did not list this file.
        # Once listed, it is required and checked before the binary is run.
        $noticesExpected = Get-ManifestChecksum -Path $sums -Name $NoticesName -Optional
        if ($null -ne $noticesExpected) {
            Write-Plain "Downloading $NoticesName"
            try {
                Save-Url -Url "$sourceBase/$NoticesName" -Destination $stagedNotices
            } catch {
                Fail "could not download $NoticesName listed in SHA256SUMS." @(
                    (Get-TransferFailureReason -ErrorRecord $_),
                    'Nothing has been installed. This release is incomplete.'
                )
            }
            $noticesActual = Get-Sha256 -Path $stagedNotices
            if ($noticesActual -ne $noticesExpected) {
                Fail "checksum mismatch on $NoticesName. Nothing has been installed." @(
                    "expected  $noticesExpected",
                    "got       $noticesActual",
                    'Try again, and if it happens twice do not use the file.'
                )
            }
        }

        # Said out loud, next to the check that did run, so nobody reads
        # "Verifying checksum" as meaning everything was verified. The Linux
        # and macOS installer checks the release signature here. This one
        # cannot: there is no Ed25519 in Windows PowerShell 5.1, .NET only
        # gained one in 8, and adding a dependency to an installer whose whole
        # promise is that it needs nothing installed would be the wrong trade.
        # Skipping it quietly was the other option, and it is the one that
        # leaves a reader believing something untrue.
        Write-Plain 'Checksum verified. The release signature was NOT checked: this'
        Write-Plain 'installer has no Ed25519 available. To check it yourself, with openssl:'
        Write-Plain ''
        # curl.exe, not curl. In Windows PowerShell 5.1, which this installer
        # targets, `curl` is an alias for Invoke-WebRequest, and these flags are
        # a parse error against it rather than a download. Printing a command
        # the reader cannot paste is worse than printing none. The .exe suffix
        # costs nothing on PowerShell 7, where the alias no longer exists.
        Write-Plain "  curl.exe -fsSLO $sourceBase/SHA256SUMS"
        Write-Plain "  curl.exe -fsSLO $sourceBase/SHA256SUMS.sig"
        Write-Plain '  openssl pkeyutl -verify -pubin -inkey runinfra-release.pub -rawin -in SHA256SUMS -sigfile SHA256SUMS.sig'
        Write-Plain ''
        Write-Plain "The public key to save as runinfra-release.pub, its fingerprint"
        Write-Plain "$ReleaseKeyFingerprint,"
        Write-Plain 'and what a good signature does and does not prove, are all in'
        Write-Plain 'https://github.com/RightNow-AI/runinfra-cli#verifying-a-release.'
        Write-Plain ''

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

        # Put verified attribution beside the binary before promoting it. A
        # failed binary replacement restores the previous notices in finally.
        if ($null -ne $noticesExpected) {
            if (Test-Path -LiteralPath $noticesDestination) {
                if (-not (Test-Path -LiteralPath $noticesDestination -PathType Leaf)) {
                    Fail "$noticesDestination is not a file." @('Nothing has been replaced. Move it aside and try again.')
                }
                Copy-Item -LiteralPath $noticesDestination -Destination $noticesBackup -Force
            }
            $noticesReplaced = $true
            try {
                Move-Item -LiteralPath $stagedNotices -Destination $noticesDestination -Force
            } catch {
                Fail "could not put $NoticesName into $directory." @('Nothing has been replaced.', $_.Exception.Message)
            }
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
            $binaryInstalled = $true
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
        if ($noticesReplaced -and -not $binaryInstalled) {
            try {
                if (Test-Path -LiteralPath $noticesBackup) {
                    Move-Item -LiteralPath $noticesBackup -Destination $noticesDestination -Force
                } elseif (Test-Path -LiteralPath $noticesDestination) {
                    Remove-Item -LiteralPath $noticesDestination -Force
                }
            } catch {
                $keepNoticesBackup = $true
                Write-Plain "Could not restore the previous notices at $noticesDestination."
                if (Test-Path -LiteralPath $noticesBackup) {
                    Write-Plain "The previous notices remain at $noticesBackup."
                }
            }
        }
        # A half written program in the install directory is worse than none,
        # and it is a file the user did not ask for. It never survives us.
        if (Test-Path -LiteralPath $staged) {
            Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $sums) {
            Remove-Item -LiteralPath $sums -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $stagedNotices) {
            Remove-Item -LiteralPath $stagedNotices -Force -ErrorAction SilentlyContinue
        }
        if (-not $keepNoticesBackup -and (Test-Path -LiteralPath $noticesBackup)) {
            Remove-Item -LiteralPath $noticesBackup -Force -ErrorAction SilentlyContinue
        }
    }

    # ------------------------------------------------------------- report --
    Write-Plain ''
    Write-Plain "Installed $reported to $destination"

    if (Test-PathContains -PathValue $env:PATH -Directory $directory) {
        Write-Plain 'Paste the setup prompt into your coding agent: https://runinfra.ai/docs/tools-sdks/agent-setup'
        return
    }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (Test-PathContains -PathValue $userPath -Directory $directory) {
        Write-Plain ''
        Write-Plain "$directory is already on your PATH, but not in this window."
        Write-Plain 'Open a new terminal. Paste the setup prompt into your coding agent: https://runinfra.ai/docs/tools-sdks/agent-setup'
        return
    }

    Write-Plain ''
    Write-Plain "$directory is not on your PATH, so the name runinfra will not"
    Write-Plain 'resolve yet. This command adds it for your account only, and it'
    Write-Plain 'appends rather than replaces:'
    Write-Plain ''
    Write-Plain '  [Environment]::SetEnvironmentVariable(''Path'','
    $quotedDirectory = $directory.Replace("'", "''")
    Write-Plain "    [Environment]::GetEnvironmentVariable('Path','User') + ';$quotedDirectory', 'User')"
    Write-Plain ''
    Write-Plain 'Run it, then open a new terminal. This installer does not change'
    Write-Plain 'your PATH on its own. Until then, the full path works:'
    $quotedDestination = $destination.Replace("'", "''")
    Write-Plain "  & '$quotedDestination'"
    Write-Plain 'Paste the setup prompt into your coding agent: https://runinfra.ai/docs/tools-sdks/agent-setup'
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
}
