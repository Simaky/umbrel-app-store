<#
.SYNOPSIS
  Updates the Pterodactyl apps in this store to the latest Panel and Wings releases.

.DESCRIPTION
  For each app it finds the newest matching GitHub release of pterodactyl/panel and
  pterodactyl/wings, checks that the ghcr.io image is published for amd64 and arm64,
  pins the image by digest in docker-compose.yml, and bumps version and releaseNotes in
  umbrel-app.yml. Runs on PowerShell 5.1 and 7.

.PARAMETER Pin
  Re-resolve digests even when the tag is unchanged (also pins unpinned base images).
#>
param(
    [switch]$Pin
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = Split-Path -Parent $PSScriptRoot

# Each app tracks one panel major. The stable app stays on 1.x because 2.0 needs a
# manual upgrade; the beta app follows 2.x, pre-releases included.
$Apps = @(
    @{ Dir = 'simaky-pterodactyl';         PanelMajor = '1'; WingsMajor = '1';   Prerelease = $false },
    @{ Dir = 'simaky-pterodactyl-v2-beta'; PanelMajor = '2'; WingsMajor = $null; Prerelease = $true }
)

# Third-party images that are pinned by digest but only change when edited by hand.
$BaseImages = @('mariadb', 'redis')

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Get-Releases([string]$Repo) {
    $headers = @{ 'User-Agent' = 'umbrel-app-store-updater'; 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
    $uri = "https://api.github.com/repos/pterodactyl/$Repo/releases?per_page=100"
    # The API lists releases newest first. Assign before piping so PowerShell 5.1
    # enumerates the JSON array instead of passing it as one object.
    $releases = Invoke-RestMethod -Uri $uri -Headers $headers
    return @($releases | Where-Object { -not $_.draft })
}

function Select-Release($Releases, [string]$Major, [bool]$Prerelease) {
    $pattern = if ($Major) { "^v$([regex]::Escape($Major))\." } else { '^v\d' }
    return $Releases | Where-Object { $_.tag_name -match $pattern -and ($Prerelease -or -not $_.prerelease) } |
        Select-Object -First 1
}

function Get-RegistryInfo([string]$Image) {
    # Image is "ghcr.io/owner/name:tag" or a Docker Hub "name:tag".
    if ($Image -notmatch '^(?:(?<registry>[a-z0-9.-]+\.[a-z]+)/)?(?<repo>[^:@]+):(?<tag>[^@]+)$') {
        throw "Cannot parse image reference '$Image'"
    }
    $repo = $Matches.repo
    $tag = $Matches.tag
    if ($Matches.registry -eq 'ghcr.io') {
        $tokenUri = "https://ghcr.io/token?scope=repository:${repo}:pull"
        $registry = 'https://ghcr.io'
    } else {
        if ($repo -notmatch '/') { $repo = "library/$repo" }
        $tokenUri = "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull"
        $registry = 'https://registry-1.docker.io'
    }
    $token = (Invoke-RestMethod -Uri $tokenUri).token
    $accept = @(
        'application/vnd.oci.image.index.v1+json',
        'application/vnd.docker.distribution.manifest.list.v2+json',
        'application/vnd.oci.image.manifest.v1+json',
        'application/vnd.docker.distribution.manifest.v2+json'
    ) -join ', '
    $response = Invoke-WebRequest -UseBasicParsing -Uri "$registry/v2/$repo/manifests/$tag" `
        -Headers @{ Authorization = "Bearer $token"; Accept = $accept }

    $digest = @($response.Headers['Docker-Content-Digest'])[0]
    $content = $response.Content
    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    if (-not $digest) {
        $sha = [Security.Cryptography.SHA256]::Create()
        $bytes = [Text.Encoding]::UTF8.GetBytes($content)
        $digest = 'sha256:' + (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    $manifest = $content | ConvertFrom-Json
    $platforms = @()
    if ($manifest.manifests) {
        $platforms = @($manifest.manifests | Where-Object { $_.platform -and $_.platform.os -ne 'unknown' } |
            ForEach-Object { "$($_.platform.os)/$($_.platform.architecture)" })
    }
    return @{ Digest = $digest; Platforms = $platforms }
}

function Get-PinnedImage([string]$Image) {
    $info = Get-RegistryInfo $Image
    foreach ($platform in 'linux/amd64', 'linux/arm64') {
        if ($info.Platforms -notcontains $platform) {
            throw "$Image is not published for $platform (found: $($info.Platforms -join ', '))"
        }
    }
    return "$Image@$($info.Digest)"
}

function Set-ImageReference([string]$Compose, [string]$Name, [string]$Reference) {
    $pattern = "(?m)(^\s*image:\s*)$([regex]::Escape($Name)):[^\s@]+(@sha256:[0-9a-f]{64})?\s*$"
    return [regex]::Replace($Compose, $pattern, { param($m) $m.Groups[1].Value + $Reference })
}

function Get-ImageTag([string]$Compose, [string]$Name) {
    $m = [regex]::Match($Compose, "(?m)^\s*image:\s*$([regex]::Escape($Name)):(?<tag>[^\s@]+)")
    if (-not $m.Success) { throw "No $Name image found" }
    return $m.Groups['tag'].Value
}

function Format-ReleaseBody([string]$Body) {
    $text = ($Body -replace "`r", '').Trim()
    if ($text.Length -gt 1500) { $text = $text.Substring(0, 1500).TrimEnd() + "`n..." }
    return $text
}

$panelReleases = Get-Releases 'panel'
$wingsReleases = Get-Releases 'wings'
$summary = @()

foreach ($app in $Apps) {
    $composePath = Join-Path $Root "$($app.Dir)/docker-compose.yml"
    $manifestPath = Join-Path $Root "$($app.Dir)/umbrel-app.yml"
    $compose = [IO.File]::ReadAllText($composePath)
    $manifest = [IO.File]::ReadAllText($manifestPath)

    $panel = Select-Release $panelReleases $app.PanelMajor $app.Prerelease
    $wings = Select-Release $wingsReleases $app.WingsMajor $app.Prerelease
    if (-not $panel -or -not $wings) { throw "No matching releases for $($app.Dir)" }

    $currentPanel = Get-ImageTag $compose 'ghcr.io/pterodactyl/panel'
    $currentWings = Get-ImageTag $compose 'ghcr.io/pterodactyl/wings'
    $panelChanged = $currentPanel -ne $panel.tag_name
    $wingsChanged = $currentWings -ne $wings.tag_name

    if (-not ($panelChanged -or $wingsChanged -or $Pin)) {
        Write-Host "$($app.Dir): up to date (panel $currentPanel, wings $currentWings)"
        continue
    }

    try {
        $panelRef = Get-PinnedImage "ghcr.io/pterodactyl/panel:$($panel.tag_name)"
        $wingsRef = Get-PinnedImage "ghcr.io/pterodactyl/wings:$($wings.tag_name)"
    } catch {
        # The release can be published before its image finishes building; retry next run.
        Write-Warning "$($app.Dir): skipping, $($_.Exception.Message)"
        continue
    }
    $compose = Set-ImageReference $compose 'ghcr.io/pterodactyl/panel' $panelRef
    $compose = Set-ImageReference $compose 'ghcr.io/pterodactyl/wings' $wingsRef

    if ($Pin) {
        foreach ($name in $BaseImages) {
            $tag = Get-ImageTag $compose $name
            $compose = Set-ImageReference $compose $name (Get-PinnedImage "${name}:$tag")
        }
    }

    if ($panelChanged -or $wingsChanged) {
        $version = [regex]::Match($manifest, '(?m)^version:\s*"(?<v>[^"]+)"').Groups['v'].Value
        if ($panelChanged) {
            $version = $panel.tag_name.TrimStart('v')
        } else {
            # Same panel, new Wings: Umbrel only offers an update when the version changes.
            $m = [regex]::Match($version, '^(?<base>.+)-patch\.(?<n>\d+)$')
            $version = if ($m.Success) { "$($m.Groups['base'].Value)-patch.$([int]$m.Groups['n'].Value + 1)" } else { "$version-patch.1" }
        }

        $notes = @("Pterodactyl Panel $($panel.tag_name) with Wings $($wings.tag_name).", '')
        if ($panelChanged) {
            $notes += "Panel $($panel.tag_name):", (Format-ReleaseBody $panel.body), '', $panel.html_url, ''
        }
        if ($wingsChanged) {
            $notes += "Wings $($wings.tag_name):", (Format-ReleaseBody $wings.body), '', $wings.html_url, ''
        }
        $block = (($notes -join "`n").Trim() -split "`n" | ForEach-Object { if ($_) { "  $_" } else { '' } }) -join "`n"

        $manifest = [regex]::Replace($manifest, '(?m)^version:\s*"[^"]*"', "version: `"$version`"")
        $manifest = [regex]::Replace($manifest, '(?ms)^releaseNotes:.*?(?=^\S)', { param($m) "releaseNotes: |-`n$block`n" })

        $summary += "$($app.Dir) $version (panel $($panel.tag_name), wings $($wings.tag_name))"
    }

    [IO.File]::WriteAllText($composePath, $compose, $Utf8NoBom)
    [IO.File]::WriteAllText($manifestPath, $manifest, $Utf8NoBom)
    Write-Host "$($app.Dir): panel $currentPanel -> $($panel.tag_name), wings $currentWings -> $($wings.tag_name)"
}

if ($env:GITHUB_OUTPUT) {
    $message = if ($summary.Count) { 'Update ' + ($summary -join '; ') } else { '' }
    [IO.File]::AppendAllText($env:GITHUB_OUTPUT, "message=$message`n", $Utf8NoBom)
}
