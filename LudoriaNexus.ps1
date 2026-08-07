# ============================================================================
#  LUDORIA NEXUS - engine (scanner + metadata cache + local UI server)
#  Windows PowerShell 5.1+ compatible. Runs unelevated. Portable (app folder).
#
#  Layout:
#    LudoriaNexus.ps1      this engine
#    ui\index.html         the interface (served at http://127.0.0.1:<port>/)
#    data\settings.json    editable settings (scan folders, port, ...)
#    data\games.json       editable library cache
#    data\art\             cached cover / hero / logo images
#
#  Modular scanners: Get-SteamGames / Get-EpicGames / Get-LocalGames all return
#  the same game shape, so new sources (GOG, Xbox) can be added as one function.
# ============================================================================
param(
    [switch]$Rescan,
    [switch]$NoBrowser,
    [switch]$ScanOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$script:Version = '1.0.0'
if (-not $PSScriptRoot) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path } else { $script:Root = $PSScriptRoot }
$script:DataDir = Join-Path $script:Root 'data'
$script:ArtDir  = Join-Path $script:DataDir 'art'
$script:UiFile  = Join-Path $script:Root 'ui\index.html'
$script:LibFile = Join-Path $script:DataDir 'games.json'
$script:SetFile = Join-Path $script:DataDir 'settings.json'
$script:Utf8    = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList @($false)
$script:Quit    = $false
$script:SteamRoot = $null
$script:Listener = $null
$script:UiProc  = $null

# ----------------------------------------------------------------- utilities
function Write-Log([string]$msg, [string]$color = 'Gray') {
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -ForegroundColor $color
}

function Read-Text([string]$path) { return [System.IO.File]::ReadAllText($path) }

function Read-Json([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Read-Text $path | ConvertFrom-Json) }
    catch {
        Write-Log "Could not parse $path - backing it up and starting fresh. ($($_.Exception.Message))" 'Yellow'
        try { Copy-Item -LiteralPath $path -Destination "$path.backup" -Force } catch {}
        return $null
    }
}

function Write-Json([string]$path, $obj) {
    # PS 5.1 serializes List[T] as {value,Count} — always normalize collections first.
    if ($obj -is [hashtable] -or $obj -is [System.Collections.Specialized.OrderedDictionary] -or $obj -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($p in @($obj.PSObject.Properties)) {
            $v = $p.Value
            if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string]) -and -not ($v -is [hashtable]) -and -not ($v -is [System.Collections.IDictionary])) {
                $copy[$p.Name] = @($v)
            } else {
                $copy[$p.Name] = $v
            }
        }
        $obj = $copy
    }
    $json = ConvertTo-Json -InputObject $obj -Depth 12 -Compress:$false
    if ($null -eq $json) { $json = '{}' }
    if ($json -is [System.Array]) { $json = ($json -join "`n") }
    $json = [string]$json
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, $script:Utf8)
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function ConvertTo-Bool($v) {
    $default = $false
    if ($args.Count -ge 1) { $default = [bool]$args[0] }
    if ($null -eq $v) { return [bool]$default }
    if ($v -is [bool]) { return $v }
    if ($v -is [string]) {
        $s = $v.Trim().ToLowerInvariant()
        if ($s -eq '') { return [bool]$default }
        if ($s -in @('1','true','yes','y','on')) { return $true }
        if ($s -in @('0','false','no','n','off')) { return $false }
        return [bool]$default
    }
    try {
        if ($v -is [int] -or $v -is [long] -or $v -is [byte] -or $v -is [double] -or $v -is [decimal]) {
            return ($v -ne 0)
        }
        return [bool]$default
    } catch { return [bool]$default }
}

function ConvertTo-Long($v) {
    $default = [long]0
    if ($args.Count -ge 1) { try { $default = [long]$args[0] } catch { $default = 0 } }
    if ($null -eq $v) { return $default }
    if ($v -is [string] -and $v.Trim() -eq '') { return $default }
    try { return [long]$v } catch {
        try { return [long][double]$v } catch { return $default }
    }
}

function ConvertTo-Int32($v) {
    $default = 0
    if ($args.Count -ge 1) { try { $default = [int]$args[0] } catch { $default = 0 } }
    if ($null -eq $v) { return $default }
    if ($v -is [string] -and $v.Trim() -eq '') { return $default }
    try { return [int]$v } catch {
        try { return [int][double]$v } catch { return $default }
    }
}

function New-TcpListenerOn([int]$port) {
    # PS 5.1: never use New-Object Type(arg1, arg2) — comma becomes a single Object[] arg.
    return New-Object -TypeName System.Net.Sockets.TcpListener -ArgumentList @([System.Net.IPAddress]::Loopback, [int]$port)
}

function Get-Prop($obj, [string]$name, $default) {
    if ($null -eq $obj) { return $default }
    if ($obj -is [hashtable] -or $obj -is [System.Collections.Specialized.OrderedDictionary]) {
        if ($obj.Contains($name) -and $null -ne $obj[$name]) { return $obj[$name] }
        return $default
    }
    $p = $obj.PSObject.Properties[$name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $default
}

function Get-ShortHash([string]$s) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hex = ($md5.ComputeHash($script:Utf8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') }) -join ''
    return $hex.Substring(0, 10)
}

function Get-NowIso { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

# ----------------------------------------------------------------- settings
function Get-DefaultScanFolders {
    $folders = New-Object System.Collections.ArrayList
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            if ($d.DriveType -ne 'Fixed') { continue }
            foreach ($name in @('Games', 'Game')) {
                $p = Join-Path $d.RootDirectory.FullName $name
                if (Test-Path -LiteralPath $p) { [void]$folders.Add($p) }
            }
        }
    } catch {}
    $up = Join-Path $env:USERPROFILE 'Games'
    if (Test-Path -LiteralPath $up) { [void]$folders.Add($up) }
    return @($folders | Sort-Object -Unique)
}

function Get-Settings {
    $s = Read-Json $script:SetFile
    $set = [ordered]@{
        port        = (ConvertTo-Int32 (Get-Prop $s 'port' 8998) 8998)
        chromeless  = (ConvertTo-Bool (Get-Prop $s 'chromeless' $true) $true)
        downloadArt = (ConvertTo-Bool (Get-Prop $s 'downloadArt' $true) $true)
        scanFolders = @(Get-Prop $s 'scanFolders' @())
        _help       = 'scanFolders: folders scanned for non-Steam/Epic games. chromeless: open in Edge app window. downloadArt: fetch cover art from the internet.'
    }
    if (-not $s -or $null -eq (Get-Prop $s 'scanFolders' $null)) {
        $set.scanFolders = @(Get-DefaultScanFolders)
        Write-Json $script:SetFile $set
        Write-Log "Created data\settings.json (edit it to add your game folders)." 'DarkCyan'
    }
    $set.scanFolders = @($set.scanFolders | Where-Object { $_ })
    return $set
}

# ------------------------------------------------------------- game shaping
function New-Game {
    return [ordered]@{
        id          = ''
        title       = ''
        source      = 'manual'   # steam | epic | local | manual
        launch      = ''         # protocol URI or exe path
        installPath = ''
        sizeMB      = 0
        cover       = ''         # art/xxx.jpg | http(s) url | '' (UI draws one)
        hero        = ''
        logo        = ''
        artSource   = 'none'     # steam-local | steam-cdn | steam-match | custom | none
        artStamp    = 0
        hidden      = $false
        favorite    = $false
        locked      = $false     # user edited title/launch: rescans keep them
        artLocked   = $false     # user edited art: refetch/rescan keeps it
        artQuery    = ''
        addedAt     = ''
        lastPlayed  = ''
        timesPlayed = 0
    }
}

function ConvertTo-Game($src) {
    $g = New-Game
    foreach ($k in @($g.Keys)) {
        $v = Get-Prop $src $k $g[$k]
        $g[$k] = $v
    }
    # Coerce every field safely — hand-edited JSON / PS 5.1 List round-trips can be messy.
    $g['id']          = [string](Get-Prop $g 'id' '')
    $g['title']       = [string](Get-Prop $g 'title' '')
    $g['source']      = [string](Get-Prop $g 'source' 'manual')
    $g['launch']      = [string](Get-Prop $g 'launch' '')
    $g['installPath'] = [string](Get-Prop $g 'installPath' '')
    $g['cover']       = [string](Get-Prop $g 'cover' '')
    $g['hero']        = [string](Get-Prop $g 'hero' '')
    $g['logo']        = [string](Get-Prop $g 'logo' '')
    $g['artSource']   = [string](Get-Prop $g 'artSource' 'none')
    $g['artQuery']    = [string](Get-Prop $g 'artQuery' '')
    $g['addedAt']     = [string](Get-Prop $g 'addedAt' '')
    $g['lastPlayed']  = [string](Get-Prop $g 'lastPlayed' '')
    $g['hidden']      = ConvertTo-Bool $g['hidden'] $false
    $g['favorite']    = ConvertTo-Bool $g['favorite'] $false
    $g['locked']      = ConvertTo-Bool $g['locked'] $false
    $g['artLocked']   = ConvertTo-Bool $g['artLocked'] $false
    $g['sizeMB']      = ConvertTo-Long $g['sizeMB'] 0
    $g['timesPlayed'] = ConvertTo-Int32 $g['timesPlayed'] 0
    $g['artStamp']    = ConvertTo-Long $g['artStamp'] 0
    return $g
}

function ConvertTo-Library($src) {
    $lib = [ordered]@{
        app         = 'Ludoria Nexus'
        version     = 1
        updatedAt   = [string](Get-Prop $src 'updatedAt' '')
        fingerprint = [string](Get-Prop $src 'fingerprint' '')
        ignoredIds  = @()
        games       = New-Object System.Collections.ArrayList
    }
    # ignoredIds may be a real array, or a PS 5.1 List round-trip object with .value
    $rawIgn = Get-Prop $src 'ignoredIds' @()
    if ($rawIgn -and ($null -ne (Get-Prop $rawIgn 'value' $null))) { $rawIgn = Get-Prop $rawIgn 'value' @() }
    $lib.ignoredIds = @($rawIgn | ForEach-Object { [string]$_ } | Where-Object { $_ })

    $rawGames = Get-Prop $src 'games' @()
    # Repair PS 5.1 List[T] JSON shape: { "value": [ ... ], "Count": N }
    if ($rawGames -and ($null -ne (Get-Prop $rawGames 'value' $null)) -and -not ($rawGames -is [System.Collections.IList] -and $rawGames -isnot [string])) {
        $maybe = Get-Prop $rawGames 'value' $null
        if ($maybe) { $rawGames = $maybe }
    }
    $games = New-Object System.Collections.ArrayList
    foreach ($g in @($rawGames)) {
        if (-not $g) { continue }
        # Skip non-game objects (e.g. accidental Count property iteration)
        $idProbe = Get-Prop $g 'id' $null
        if (-not $idProbe -and -not (Get-Prop $g 'title' $null)) { continue }
        [void]$games.Add((ConvertTo-Game $g))
    }
    $lib.games = $games
    return $lib
}

# ------------------------------------------------------------ steam scanner
function Get-SteamRoot {
    if ($script:SteamRoot) { return $script:SteamRoot }
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($n in @('SteamPath', 'InstallPath')) {
                $v = Get-Prop $p $n $null
                if ($v) {
                    $v = ($v -replace '/', '\')
                    if (Test-Path -LiteralPath $v) { $script:SteamRoot = $v; return $v }
                }
            }
        } catch {}
    }
    return $null
}

function Get-SteamLibraryDirs {
    $dirs = New-Object System.Collections.ArrayList
    $root = Get-SteamRoot
    if (-not $root) { return @() }
    $main = Join-Path $root 'steamapps'
    if (Test-Path -LiteralPath $main) { [void]$dirs.Add($main) }
    $vdfPath = Join-Path $main 'libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdfPath) {
        $vdf = Read-Text $vdfPath
        foreach ($m in [regex]::Matches($vdf, '"(?:path|\d+)"\s+"([^"]+)"')) {
            $p = $m.Groups[1].Value -replace '\\\\', '\'
            if ($p -match '^[A-Za-z]:') {
                $lib = Join-Path $p 'steamapps'
                if (Test-Path -LiteralPath $lib) { [void]$dirs.Add($lib) }
            }
        }
    }
    return @($dirs | Sort-Object -Unique)
}

function Get-SteamGames {
    $found = New-Object System.Collections.ArrayList
    foreach ($libDir in Get-SteamLibraryDirs) {
        $acfs = @(Get-ChildItem -LiteralPath $libDir -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue)
        foreach ($f in $acfs) {
            try {
                $t = Read-Text $f.FullName
                if ($t -notmatch '"appid"\s+"(\d+)"') { continue }
                $appid = $Matches[1]
                if ($t -notmatch '"name"\s+"([^"]*)"') { continue }
                $name = $Matches[1]
                $installdir = ''
                if ($t -match '"installdir"\s+"([^"]*)"') { $installdir = $Matches[1] }
                $size = 0
                if ($t -match '"SizeOnDisk"\s+"(\d+)"') { $size = [long]$Matches[1] }
                if ($name -match 'Redistributab|Steamworks Common|Dedicated Server|SteamVR|Proton \d|Steam Linux Runtime|Runtime -') { continue }
                if (@('228980','1070560','1391110','1628350','1493710') -contains $appid) { continue }
                $g = New-Game
                $g['id'] = "steam_$appid"
                $g['title'] = $name
                $g['source'] = 'steam'
                $g['launch'] = "steam://rungameid/$appid"
                if ($installdir) { $g['installPath'] = Join-Path (Join-Path $libDir 'common') $installdir }
                $g['sizeMB'] = ConvertTo-Long ([math]::Round(([double]$size) / 1MB)) 0
                [void]$found.Add($g)
            } catch {}
        }
    }
    return @(@($found.ToArray()) | Where-Object { $_ -is [System.Collections.IDictionary] })
}

# ------------------------------------------------------------- epic scanner
function Get-EpicManifestDir {
    $pd = $env:ProgramData
    if (-not $pd) { $pd = 'C:\ProgramData' }
    return (Join-Path $pd 'Epic\EpicGamesLauncher\Data\Manifests')
}

function Get-EpicGames {
    $found = New-Object System.Collections.ArrayList
    $dir = Get-EpicManifestDir
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.item' -File -ErrorAction SilentlyContinue)) {
        try {
            $j = Read-Text $f.FullName | ConvertFrom-Json
            if ((Get-Prop $j 'bIsIncompleteInstall' $false) -eq $true) { continue }
            $an = [string](Get-Prop $j 'AppName' '')
            $title = [string](Get-Prop $j 'DisplayName' '')
            if (-not $title -or -not $an) { continue }
            if ($an -match '^UE_' -or $title -match '^Unreal Engine') { continue }
            $ns = [string](Get-Prop $j 'CatalogNamespace' '')
            $ci = [string](Get-Prop $j 'CatalogItemId' '')
            $loc = [string](Get-Prop $j 'InstallLocation' '')
            $exeRel = [string](Get-Prop $j 'LaunchExecutable' '')
            if ($ns -and $ci) { $launch = "com.epicgames.launcher://apps/${ns}:${ci}:${an}?action=launch&silent=true" }
            else { $launch = "com.epicgames.launcher://apps/${an}?action=launch&silent=true" }
            $size = ConvertTo-Long (Get-Prop $j 'InstallSize' 0) 0
            $g = New-Game
            $g['id'] = "epic_$(Get-ShortHash $an)"
            $g['title'] = $title
            $g['source'] = 'epic'
            $g['launch'] = $launch
            $g['installPath'] = $loc
            $g['sizeMB'] = ConvertTo-Long ([math]::Round(([double]$size) / 1MB)) 0
            [void]$found.Add($g)
        } catch {}
    }
    return @(@($found.ToArray()) | Where-Object { $_ -is [System.Collections.IDictionary] })
}

# ------------------------------------------------------------ local scanner
function Get-LocalGames($settings, [string[]]$knownRoots) {
    $found = New-Object System.Collections.ArrayList
    $excl = 'unins|setup|install|redist|vcredist|dxsetup|directx|crash|report|helper|handler|updater|update|patcher|cleanup|repair|activation|benchmark|dedicated|server|eac|easyanticheat|battleye|be_|launcher_|prereq|dotnet|oalinst|touchup'
    foreach ($folder in @($settings.scanFolders)) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        foreach ($sub in @(Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue)) {
            $subLower = $sub.FullName.ToLowerInvariant()
            $isKnown = $false
            foreach ($kr in $knownRoots) {
                if ($kr -and ($subLower -eq $kr -or $subLower.StartsWith($kr + '\') -or $kr.StartsWith($subLower + '\'))) { $isKnown = $true; break }
            }
            if ($isKnown) { continue }
            $exes = @(Get-ChildItem -LiteralPath $sub.FullName -Recurse -Depth 2 -Filter '*.exe' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch $excl } | Sort-Object Length -Descending)
            if ($exes.Count -eq 0) { continue }
            $exe = $exes[0]
            $g = New-Game
            $g['id'] = "local_$(Get-ShortHash $exe.FullName.ToLowerInvariant())"
            $g['title'] = $sub.Name
            $g['source'] = 'local'
            $g['launch'] = $exe.FullName
            $g['installPath'] = $sub.FullName
            $g['sizeMB'] = ConvertTo-Long ([math]::Round(([double]$exe.Length) / 1MB)) 0
            [void]$found.Add($g)
        }
    }
    return @(@($found.ToArray()) | Where-Object { $_ -is [System.Collections.IDictionary] })
}

# -------------------------------------------------------------- fingerprint
# Cheap change detection: full rescans only run when this value changes
# (i.e. games were installed/removed/updated) or when you force one.
function Get-Fingerprint($settings) {
    $tokens = New-Object System.Collections.ArrayList
    foreach ($libDir in Get-SteamLibraryDirs) {
        foreach ($f in @(Get-ChildItem -LiteralPath $libDir -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue)) {
            [void]$tokens.Add("s|$($f.FullName)|$($f.Length)")
        }
    }
    $epicDir = Get-EpicManifestDir
    if (Test-Path -LiteralPath $epicDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $epicDir -Filter '*.item' -File -ErrorAction SilentlyContinue)) {
            [void]$tokens.Add("e|$($f.Name)|$($f.LastWriteTimeUtc.Ticks)")
        }
    }
    foreach ($folder in @($settings.scanFolders)) {
        if (Test-Path -LiteralPath $folder) {
            foreach ($d in @(Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue)) { [void]$tokens.Add("l|$($d.FullName)") }
        }
    }
    $joined = (@($tokens | Sort-Object) -join '~')
    $md5 = [System.Security.Cryptography.MD5]::Create()
    return (($md5.ComputeHash($script:Utf8.GetBytes($joined)) | ForEach-Object { $_.ToString('x2') }) -join '')
}

# ------------------------------------------------------------------ artwork
function Save-Download([string]$url, [string]$dest) {
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 20 | Out-Null
        if ((Get-Item -LiteralPath $dest).Length -gt 200) { return $true }
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        return $false
    } catch {
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

function Copy-IfExists([string[]]$candidates, [string]$dest) {
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            try { Copy-Item -LiteralPath $c -Destination $dest -Force; return $true } catch {}
        }
    }
    return $false
}

function Get-NormalizedTitle([string]$t) {
    # aggressive normalization so slightly different names still match:
    # punctuation and trademark symbols become spaces, edition suffixes are
    # stripped. 'Nier Automata Game of the Year' -> 'nier automata'
    $s = $t.ToLowerInvariant()
    $s = [regex]::Replace($s, '[^a-z0-9]+', ' ')
    $s = [regex]::Replace($s, '\b(game of the year|goty|definitive|enhanced|complete|deluxe|ultimate|premium|gold|legendary|anniversary|remastered|remaster|redux|director s cut|directors cut|special|collector s|collectors|extended|digital|hd|vr|edition|the)\b', ' ')
    $s = [regex]::Replace($s, '\s+', ' ')
    return $s.Trim()
}

function Get-TitleScore([string]$a, [string]$b) {
    # similarity of two normalized titles: 1.0 identical, token overlap otherwise
    if (-not $a -or -not $b) { return 0.0 }
    if ($a -eq $b) { return 1.0 }
    $ca = $a -replace ' ', ''
    $cb = $b -replace ' ', ''
    if ($ca -eq $cb) { return 0.98 }
    if ($ca.Contains($cb) -or $cb.Contains($ca)) { return 0.85 }
    $ta = @($a -split ' ' | Where-Object { $_ } | Select-Object -Unique)
    $tb = @($b -split ' ' | Where-Object { $_ } | Select-Object -Unique)
    if ($ta.Count -eq 0 -or $tb.Count -eq 0) { return 0.0 }
    $common = 0
    foreach ($tok in $ta) { if ($tb -contains $tok) { $common++ } }
    $union = $ta.Count + $tb.Count - $common
    return [Math]::Round($common / [double]$union, 3)
}

function Get-SteamCatalog {
    # Full Steam app list catches delisted/hidden games that storesearch omits
    # (Fall Guys is the classic example). Cached for seven days in app data.
    if ($null -ne $script:SteamCatalog) { return @($script:SteamCatalog) }
    $cache = Join-Path $script:DataDir 'steam_catalog.json'
    $apps = @()
    if (Test-Path -LiteralPath $cache) {
        try {
            $age = (Get-Date) - (Get-Item -LiteralPath $cache).LastWriteTime
            if ($age.TotalDays -lt 7) { $apps = @((Read-Text $cache | ConvertFrom-Json)) }
        } catch { $apps = @() }
    }
    if ($apps.Count -eq 0) {
        try {
            $r = Invoke-RestMethod -Uri 'https://api.steampowered.com/ISteamApps/GetAppList/v2/' -TimeoutSec 45 -UseBasicParsing
            $apps = @(Get-Prop (Get-Prop $r 'applist' $null) 'apps' @())
            if ($apps.Count) {
                $json = $apps | ConvertTo-Json -Depth 3 -Compress
                $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
                [IO.File]::WriteAllText($cache, $json, $utf8)
            }
        } catch { $apps = @() }
    }
    $script:SteamCatalog = @($apps)
    return @($script:SteamCatalog)
}

function Find-SteamAppIdByName([string]$title) {
    $want = Get-NormalizedTitle $title
    if (-not $want) { return $null }

    # Known delisted/catalog edge cases; the full catalog below handles others.
    $known = @{
        'fall guys' = '1097150'
        'fall guys ultimate knockout' = '1097150'
        'wuthering waves' = '3513350'
    }
    if ($known.ContainsKey($want)) { return $known[$want] }

    $short = (($want -split ' ') | Select-Object -First 3) -join ' '
    $terms = New-Object System.Collections.ArrayList
    foreach ($t in @($title, $want, $short)) {
        if ($t -and -not $terms.Contains($t)) { [void]$terms.Add($t) }
    }
    $bestId = $null
    $bestScore = 0.0

    # Fast public store search first, using raw and cleaned variants.
    foreach ($t in $terms) {
        $items = @()
        try {
            $term = [Uri]::EscapeDataString([string]$t)
            $u = 'https://store.steampowered.com/api/storesearch/?term={0}&l=english&cc=US' -f $term
            $r = Invoke-RestMethod -Uri $u -TimeoutSec 20 -UseBasicParsing
            $items = @(Get-Prop $r 'items' @())
        } catch { $items = @() }
        foreach ($it in $items) {
            $have = Get-NormalizedTitle ([string](Get-Prop $it 'name' ''))
            $sc = Get-TitleScore $want $have
            if ($sc -gt $bestScore) {
                $bestScore = $sc
                $bestId = [string](Get-Prop $it 'id' $null)
            }
        }
        if ($bestScore -ge 0.97) { return $bestId }
    }

    # Search Steam's complete app catalog. This includes delisted games and
    # future listings that storesearch may not surface. Exact normalized names
    # return immediately; fuzzy candidates must share the first useful token.
    $first = @($want -split ' ' | Where-Object { $_.Length -gt 2 } | Select-Object -First 1)
    $first = if ($first.Count) { [string]$first[0] } else { [string]($want -split ' ')[0] }
    foreach ($app in @(Get-SteamCatalog)) {
        $name = [string](Get-Prop $app 'name' '')
        if (-not $name) { continue }
        $have = Get-NormalizedTitle $name
        if ($have -eq $want) { return [string](Get-Prop $app 'appid' $null) }
        if ($first -and -not (($have -split ' ') -contains $first)) { continue }
        $sc = Get-TitleScore $want $have
        if ($sc -gt $bestScore) {
            $bestScore = $sc
            $bestId = [string](Get-Prop $app 'appid' $null)
        }
    }
    if ($bestScore -ge 0.62) { return $bestId }
    return $null
}

# Fills cover/hero/logo for one game. Priority:
#   1. Steam's own local image cache (offline, instant)
#   2. Official Steam CDN art by appid
#   3. For Epic/local/manual: Steam catalog match by title (trusted fallback)
function Update-GameArt($game, $settings, [bool]$force) {
    if ($game['artLocked'] -and -not $force) { return $false }
    $id = $game['id']
    $stem = [regex]::Replace([string]$game['title'], '[<>:"/\|?*]', '')
    $stem = ([regex]::Replace($stem, '\s+', ' ')).Trim()
    $stem = [regex]::Replace($stem, '\.+$', '')
    if ($stem.Length -gt 100) { $stem = $stem.Substring(0, 100) }
    if (-not $stem) { $stem = $id }
    $coverFile = Join-Path $script:ArtDir "${stem}_cover.jpg"
    $heroFile  = Join-Path $script:ArtDir "${stem}_hero.jpg"
    $logoFile  = Join-Path $script:ArtDir "${stem}_logo.png"
    # Migrate old ID filenames without deleting or overwriting manual art.
    if (-not (Test-Path -LiteralPath $coverFile)) { [void](Copy-IfExists @((Join-Path $script:ArtDir "${id}_cover.jpg")) $coverFile) }
    if (-not (Test-Path -LiteralPath $heroFile))  { [void](Copy-IfExists @((Join-Path $script:ArtDir "${id}_hero.jpg"))  $heroFile) }
    if (-not (Test-Path -LiteralPath $logoFile))  { [void](Copy-IfExists @((Join-Path $script:ArtDir "${id}_logo.png"))  $logoFile) }
    $appid = $null
    $artSource = 'none'
    if ($game['source'] -eq 'steam') {
        $appid = $game['id'] -replace '^steam_', ''
        $artSource = 'steam-cdn'
        $steamRoot = Get-SteamRoot
        if ($steamRoot) {
            $cache = Join-Path $steamRoot 'appcache\librarycache'
            if (-not (Test-Path -LiteralPath $coverFile)) {
                if (Copy-IfExists @((Join-Path $cache "${appid}_library_600x900.jpg"), (Join-Path $cache "$appid\library_600x900.jpg")) $coverFile) { $artSource = 'steam-local' }
            }
            if (-not (Test-Path -LiteralPath $heroFile)) {
                [void](Copy-IfExists @((Join-Path $cache "${appid}_library_hero.jpg"), (Join-Path $cache "$appid\library_hero.jpg")) $heroFile)
            }
            if (-not (Test-Path -LiteralPath $logoFile)) {
                [void](Copy-IfExists @((Join-Path $cache "${appid}_logo.png"), (Join-Path $cache "$appid\logo.png")) $logoFile)
            }
        }
    } else {
        $q = $game['artQuery']; if (-not $q) { $q = $game['title'] }
        if ($settings.downloadArt) {
            $appid = Find-SteamAppIdByName $q
            if ($appid) { $artSource = 'steam-match' }
        }
    }
    if ($appid -and $settings.downloadArt) {
        $cdn = "https://cdn.cloudflare.steamstatic.com/steam/apps/$appid"
        if (-not (Test-Path -LiteralPath $coverFile)) { [void](Save-Download "$cdn/library_600x900.jpg" $coverFile) }
        if (-not (Test-Path -LiteralPath $heroFile))  { [void](Save-Download "$cdn/library_hero.jpg" $heroFile) }
        if (-not (Test-Path -LiteralPath $logoFile))  { [void](Save-Download "$cdn/logo.png" $logoFile) }
        if (-not (Test-Path -LiteralPath $heroFile))  { [void](Save-Download "$cdn/header.jpg" $heroFile) }
    }
    if ((-not (Test-Path -LiteralPath $coverFile)) -and (Test-Path -LiteralPath $heroFile)) {
        try { Copy-Item -LiteralPath $heroFile -Destination $coverFile -Force } catch {}
    }
    $changed = $false
    if (Test-Path -LiteralPath $coverFile) { $game['cover'] = "art/${stem}_cover.jpg"; $changed = $true } elseif ($force) { $game['cover'] = '' }
    if (Test-Path -LiteralPath $heroFile)  { $game['hero']  = "art/${stem}_hero.jpg";  $changed = $true } elseif ($force) { $game['hero'] = '' }
    if (Test-Path -LiteralPath $logoFile)  { $game['logo']  = "art/${stem}_logo.png";  $changed = $true } elseif ($force) { $game['logo'] = '' }
    if ($changed) {
        $game['artSource'] = $artSource
        try { $game['artStamp'] = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
        catch { $game['artStamp'] = [long]([DateTime]::UtcNow - [datetime]'1970-01-01Z').TotalSeconds }
    }
    return $changed
}

# ------------------------------------------------------------ orchestration
function Invoke-LibraryScan($settings, $oldLib) {
    Write-Log 'Scanning for installed games...' 'Cyan'
    $steam = Get-SteamGames
    Write-Log ("  Steam : {0} found" -f $steam.Count) 'Gray'
    $epic = Get-EpicGames
    Write-Log ("  Epic  : {0} found" -f $epic.Count) 'Gray'
    $knownRoots = @()
    foreach ($g in ($steam + $epic)) { if ($g['installPath']) { $knownRoots += $g['installPath'].ToLowerInvariant() } }
    $local = Get-LocalGames $settings $knownRoots
    Write-Log ("  Local : {0} found (folders: {1})" -f $local.Count, (@($settings.scanFolders) -join ', ')) 'Gray'

    $ignored = @()
    $oldGames = @{}
    $manual = New-Object System.Collections.ArrayList
    if ($oldLib) {
        $ignored = @(Get-Prop $oldLib 'ignoredIds' @())
        foreach ($og in @(Get-Prop $oldLib 'games' @())) {
            if ($null -eq $og) { continue }
            if (($og -is [int]) -or ($og -is [long]) -or ($og -is [string])) { continue }
            $g = ConvertTo-Game $og
            if ([string]::IsNullOrEmpty([string]$g['id'])) { continue }
            $oldGames[[string]$g['id']] = $g
            if ($g['source'] -eq 'manual') { [void]$manual.Add($g) }
        }
    }

    $games = New-Object System.Collections.ArrayList
    foreach ($g in @($steam + $epic + $local)) {
        if ($null -eq $g) { continue }
        if (-not ($g -is [System.Collections.IDictionary])) { continue }
        $gid = [string]$g['id']
        if ([string]::IsNullOrEmpty($gid)) { continue }
        if ($ignored -contains $gid) { continue }
        if ($oldGames.ContainsKey($gid)) {
            $old = $oldGames[$gid]
            foreach ($k in @('hidden','favorite','addedAt','lastPlayed','timesPlayed','artQuery','artLocked','locked','artStamp')) { $g[$k] = $old[$k] }
            foreach ($k in @('cover','hero','logo','artSource')) { if ($old[$k]) { $g[$k] = $old[$k] } }
            if ($old['locked']) { $g['title'] = $old['title']; $g['launch'] = $old['launch'] }
        }
        if (-not $g['addedAt']) { $g['addedAt'] = Get-NowIso }
        [void]$games.Add($g)
    }
    foreach ($m in $manual) { [void]$games.Add($m) }

    # metadata / artwork pass (cache-first; downloads only what is missing)
    $need = @($games | Where-Object { -not $_['cover'] -or -not (Test-Path -LiteralPath (Join-Path $script:DataDir ($_['cover'] -replace '/', '\'))) })
    if ($need.Count -gt 0) {
        Write-Log ("Fetching artwork for {0} title(s)... (first run takes a moment, results are cached)" -f $need.Count) 'Cyan'
        $i = 0
        foreach ($g in $need) {
            $i++
            [void](Update-GameArt $g $settings $false)
            $tag = 'ok'
            if (-not $g['cover']) { $tag = 'no art (UI will style it)' }
            Write-Log ("  [{0}/{1}] {2} - {3}" -f $i, $need.Count, $g['title'], $tag) 'DarkGray'
        }
    }

    $lib = ConvertTo-Library @{ updatedAt = (Get-NowIso); fingerprint = (Get-Fingerprint $settings); ignoredIds = $ignored; games = @($games) }
    Write-Log ("Library ready: {0} games." -f $lib.games.Count) 'Green'
    return $lib
}

# -------------------------------------------------------------- http server
function Find-FreePort([int]$preferred) {
    $ports = @()
    if ($preferred -gt 0) { $ports += [int]$preferred }
    $ports += 8998..9010
    foreach ($p in $ports) {
        try {
            $t = New-TcpListenerOn ([int]$p)
            $t.Start(); $t.Stop()
            return [int]$p
        } catch {}
    }
    throw 'No free port found between 8998 and 9010.'
}

function Send-Http($stream, [int]$code, [string]$ctype, $body, [string]$cache = 'no-store') {
    $reasons = @{ 200 = 'OK'; 204 = 'No Content'; 400 = 'Bad Request'; 404 = 'Not Found'; 500 = 'Server Error' }
    $reason = $reasons[$code]; if (-not $reason) { $reason = 'OK' }
    if ($null -eq $body) { $body = [byte[]]@() }
    elseif ($body -isnot [byte[]]) { $body = [byte[]]$body }
    $len = 0
    if ($body) { $len = $body.Length }
    $h = "HTTP/1.1 $code $reason`r`nContent-Type: $ctype`r`nContent-Length: $len`r`nCache-Control: $cache`r`nX-Content-Type-Options: nosniff`r`nConnection: close`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($h)
    $stream.Write($hb, 0, $hb.Length)
    if ($len -gt 0) { $stream.Write($body, 0, $len) }
    $stream.Flush()
}

function Send-Json($stream, $obj, [int]$code = 200) {
    # Flatten library.games List so PS 5.1 ConvertTo-Json emits a real JSON array
    if ($obj -is [hashtable] -or $obj -is [System.Collections.Specialized.OrderedDictionary]) {
        $flat = @{}
        foreach ($k in @($obj.Keys)) {
            $v = $obj[$k]
            if ($k -eq 'library' -and $v) {
                $lg = Get-Prop $v 'games' $null
                $flat[$k] = [ordered]@{
                    app         = Get-Prop $v 'app' 'Ludoria Nexus'
                    version     = Get-Prop $v 'version' 1
                    updatedAt   = Get-Prop $v 'updatedAt' ''
                    fingerprint = Get-Prop $v 'fingerprint' ''
                    ignoredIds  = @((Get-Prop $v 'ignoredIds' @()))
                    games       = @($lg)
                }
            } elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string]) -and -not ($v -is [hashtable]) -and -not ($v -is [System.Collections.IDictionary])) {
                $flat[$k] = @($v)
            } else {
                $flat[$k] = $v
            }
        }
        $obj = $flat
    }
    $json = ConvertTo-Json -InputObject $obj -Depth 12 -Compress
    if ($null -eq $json) { $json = '{}' }
    if ($json -is [System.Array]) { $json = ($json -join '') }
    $bytes = $script:Utf8.GetBytes([string]$json)
    Send-Http $stream $code 'application/json; charset=utf-8' $bytes
}

function Find-Game([string]$id) {
    foreach ($g in $script:Library.games) { if ($g['id'] -eq $id) { return $g } }
    return $null
}

function Get-IndexFile { return (Join-Path $script:DataDir 'index.tsv') }
function Get-OverridesFile { return (Join-Path $script:DataDir 'overrides.tsv') }

# The overlay writes favourite/hidden flags to a tiny tsv; fold them back into the library.
function Read-Overrides {
    $map = @{}
    $f = Get-OverridesFile
    if (-not (Test-Path -LiteralPath $f)) { return $map }
    try {
        foreach ($line in @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $parts = $line -split "`t"
            if ($parts.Count -lt 3) { continue }
            $key = [string]$parts[0]
            if ([string]::IsNullOrEmpty($key)) { continue }
            $map[$key] = @{ fav = ([string]$parts[1] -eq '1'); hidden = ([string]$parts[2] -eq '1') }
        }
    } catch {}
    return $map
}

function Merge-Overrides {
    $ov = Read-Overrides
    if ($ov.Count -eq 0) { return }
    foreach ($g in @($script:Library.games)) {
        if ($null -eq $g) { continue }
        if (-not ($g -is [System.Collections.IDictionary])) { continue }
        $id = [string](Get-Prop $g 'id' '')
        if ($ov.ContainsKey($id)) {
            $g['favorite'] = [bool]$ov[$id]['fav']
            $g['hidden']   = [bool]$ov[$id]['hidden']
        }
    }
}

# Flat, dead-simple index the native overlay reads (no JSON parsing in the UI).
function Write-Index {
    try {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("id`ttitle`tsource`tlaunch`tworkdir`tcover`tfav`thidden")
        $n = 0
        foreach ($g in @($script:Library.games)) {
            if ($null -eq $g) { continue }
            if (-not ($g -is [System.Collections.IDictionary])) { continue }
            $id = [string](Get-Prop $g 'id' '')
            if ([string]::IsNullOrEmpty($id)) { continue }
            $coverRel = [string](Get-Prop $g 'cover' '')
            $coverAbs = ''
            if (-not [string]::IsNullOrEmpty($coverRel) -and ($coverRel -notmatch '^https?:')) {
                $try = Join-Path $script:DataDir ($coverRel -replace '/', '\')
                if (Test-Path -LiteralPath $try) { $coverAbs = $try }
            }
            $fav    = if (ConvertTo-Bool (Get-Prop $g 'favorite' $false) $false) { '1' } else { '0' }
            $hidden = if (ConvertTo-Bool (Get-Prop $g 'hidden' $false) $false) { '1' } else { '0' }
            $cells = @(
                $id,
                [string](Get-Prop $g 'title' ''),
                [string](Get-Prop $g 'source' 'manual'),
                [string](Get-Prop $g 'launch' ''),
                [string](Get-Prop $g 'installPath' ''),
                $coverAbs,
                $fav,
                $hidden
            )
            $clean = @()
            foreach ($c in $cells) { $clean += ([string]$c -replace "[`t`r`n]", ' ') }
            [void]$sb.AppendLine(($clean -join "`t"))
            $n++
        }
        $enc = New-Object System.Text.UTF8Encoding -ArgumentList @($true)
        [System.IO.File]::WriteAllText((Get-IndexFile), $sb.ToString(), $enc)
        Write-Log ("Index written: {0} rows -> data\index.tsv" -f $n) 'DarkGray'
    } catch {
        Write-Log ("Index write failed: {0}" -f $_.Exception.Message) 'Yellow'
    }
}

function Save-Library {
    $script:Library.updatedAt = Get-NowIso
    Merge-Overrides
    Write-Json $script:LibFile $script:Library
    Write-Index
}

function Invoke-GameLaunch($game) {
    $target = [string]$game['launch']
    if (-not $target) { throw 'No launch target set.' }
    if ($target -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        Start-Process $target
    } elseif (Test-Path -LiteralPath $target) {
        $wd = Split-Path -Parent $target
        if ($wd) { Start-Process -FilePath $target -WorkingDirectory $wd }
        else { Start-Process -FilePath $target }
    } else {
        throw "Launch target not found: $target"
    }
    $game['lastPlayed'] = Get-NowIso
    $game['timesPlayed'] = (ConvertTo-Int32 $game['timesPlayed'] 0) + 1
    Save-Library
}

function Get-LibraryPayload {
    return @{ ok = $true; version = $script:Version; port = $script:Port; library = $script:Library }
}

function Handle-Request($stream, [string]$method, [string]$path, [string]$body) {
    if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
        Send-Http $stream 200 'text/html; charset=utf-8' ([System.IO.File]::ReadAllBytes($script:UiFile))
        return
    }
    if ($method -eq 'GET' -and $path.StartsWith('/art/')) {
        $name = $path.Substring(5)
        if ($name -notmatch '^[A-Za-z0-9._\-]+$') { Send-Json $stream @{ ok = $false; error = 'bad name' } 400; return }
        $file = Join-Path $script:ArtDir $name
        if (-not (Test-Path -LiteralPath $file)) { Send-Http $stream 404 'text/plain' ($script:Utf8.GetBytes('not found')); return }
        $ext = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
        $types = @{ '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.png' = 'image/png'; '.webp' = 'image/webp'; '.gif' = 'image/gif'; '.ico' = 'image/x-icon' }
        $ct = $types[$ext]; if (-not $ct) { $ct = 'application/octet-stream' }
        Send-Http $stream 200 $ct ([System.IO.File]::ReadAllBytes($file)) 'max-age=86400'
        return
    }
    if ($method -eq 'GET' -and ($path -eq '/api/library' -or $path -eq '/api/status')) {
        Send-Json $stream (Get-LibraryPayload)
        return
    }
    if ($method -eq 'POST') {
        $req = $null
        if ($body) { try { $req = $body | ConvertFrom-Json } catch {} }
        switch ($path) {
            '/api/launch' {
                $g = Find-Game ([string](Get-Prop $req 'id' ''))
                if (-not $g) { Send-Json $stream @{ ok = $false; error = 'game not found' } 404; return }
                try { Invoke-GameLaunch $g; Send-Json $stream @{ ok = $true; game = $g } }
                catch { Send-Json $stream @{ ok = $false; error = $_.Exception.Message } 500 }
                return
            }
            '/api/rescan' {
                Write-Log 'Rescan requested from UI.' 'Cyan'
                try {
                    $script:Library = Invoke-LibraryScan $script:Settings $script:Library
                    Save-Library
                    Send-Json $stream (Get-LibraryPayload)
                } catch { Send-Json $stream @{ ok = $false; error = $_.Exception.Message } 500 }
                return
            }
            '/api/game/update' {
                $g = Find-Game ([string](Get-Prop $req 'id' ''))
                if (-not $g) { Send-Json $stream @{ ok = $false; error = 'game not found' } 404; return }
                $set = Get-Prop $req 'set' $null
                if ($set) {
                    foreach ($k in @('title', 'launch')) {
                        $v = Get-Prop $set $k $null
                        if ($null -ne $v -and [string]$v -ne [string]$g[$k]) { $g[$k] = [string]$v; $g['locked'] = $true }
                    }
                    foreach ($k in @('cover', 'hero', 'logo')) {
                        $v = Get-Prop $set $k $null
                        if ($null -ne $v -and [string]$v -ne [string]$g[$k]) { $g[$k] = [string]$v; $g['artLocked'] = $true; $g['artSource'] = 'custom' }
                    }
                    foreach ($k in @('hidden', 'favorite')) {
                        $v = Get-Prop $set $k $null
                        if ($null -ne $v) { $g[$k] = [bool]$v }
                    }
                    $v = Get-Prop $set 'artQuery' $null
                    if ($null -ne $v) { $g['artQuery'] = [string]$v }
                }
                Save-Library
                Send-Json $stream @{ ok = $true; game = $g }
                return
            }
            '/api/game/add' {
                $title = [string](Get-Prop $req 'title' '')
                $launch = [string](Get-Prop $req 'launch' '')
                if (-not $title -or -not $launch) { Send-Json $stream @{ ok = $false; error = 'title and launch target are required' } 400; return }
                $g = New-Game
                $g['id'] = "manual_$(Get-ShortHash ($title + '|' + $launch))"
                if (Find-Game $g['id']) { Send-Json $stream @{ ok = $false; error = 'already in library' } 400; return }
                $g['title'] = $title
                $g['source'] = 'manual'
                $g['launch'] = $launch
                if ($launch -notmatch '://') { try { $g['installPath'] = Split-Path -Parent $launch } catch {} }
                $g['addedAt'] = Get-NowIso
                $cover = [string](Get-Prop $req 'cover' '')
                if ($cover) { $g['cover'] = $cover; $g['artLocked'] = $true; $g['artSource'] = 'custom' }
                elseif ($script:Settings.downloadArt) { try { [void](Update-GameArt $g $script:Settings $false) } catch {} }
                [void]$script:Library.games.Add($g)
                Save-Library
                Send-Json $stream @{ ok = $true; game = $g }
                return
            }
            '/api/game/remove' {
                $id = [string](Get-Prop $req 'id' '')
                $g = Find-Game $id
                if (-not $g) { Send-Json $stream @{ ok = $false; error = 'game not found' } 404; return }
                $mode = [string](Get-Prop $req 'mode' 'hide')
                if ($mode -eq 'hide') {
                    $g['hidden'] = $true
                } else {
                    [void]$script:Library.games.Remove($g)
                    if ($g['source'] -ne 'manual') { $script:Library.ignoredIds = @(@($script:Library.ignoredIds) + @($id) | Sort-Object -Unique) }
                }
                Save-Library
                Send-Json $stream @{ ok = $true }
                return
            }
            '/api/art/refetch' {
                $g = Find-Game ([string](Get-Prop $req 'id' ''))
                if (-not $g) { Send-Json $stream @{ ok = $false; error = 'game not found' } 404; return }
                $q = [string](Get-Prop $req 'query' '')
                if ($q) { $g['artQuery'] = $q }
                $g['artLocked'] = $false
                try { [void](Update-GameArt $g $script:Settings $true) } catch {}
                Save-Library
                Send-Json $stream @{ ok = $true; game = $g }
                return
            }
            '/api/quit' {
                Send-Json $stream @{ ok = $true; bye = $true }
                $script:Quit = $true
                return
            }
        }
    }
    Send-Http $stream 404 'text/plain; charset=utf-8' ($script:Utf8.GetBytes('not found'))
}

function Handle-Client($client) {
    $client.ReceiveTimeout = 8000
    $client.SendTimeout = 8000
    $stream = $client.GetStream()
    try {
        $stream.ReadTimeout = 8000
        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 16384
        $headerEnd = -1
        while ($headerEnd -lt 0) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { return }
            $ms.Write($buf, 0, $n)
            $bytes = $ms.ToArray()
            $scanFrom = [Math]::Max(0, $bytes.Length - $n - 3)
            for ($i = $scanFrom; $i -le $bytes.Length - 4; $i++) {
                if ($bytes[$i] -eq 13 -and $bytes[$i + 1] -eq 10 -and $bytes[$i + 2] -eq 13 -and $bytes[$i + 3] -eq 10) { $headerEnd = $i; break }
            }
            if ($ms.Length -gt 1MB) { return }
        }
        $bytes = $ms.ToArray()
        $headerText = [System.Text.Encoding]::ASCII.GetString($bytes, 0, $headerEnd)
        $lines = $headerText -split "`r`n"
        $parts = $lines[0] -split ' '
        if ($parts.Count -lt 2) { return }
        $method = $parts[0].ToUpperInvariant()
        $rawUrl = $parts[1]
        $path = $rawUrl
        $qi = $rawUrl.IndexOf('?')
        if ($qi -ge 0) { $path = $rawUrl.Substring(0, $qi) }
        $path = [System.Uri]::UnescapeDataString($path)
        $contentLength = 0
        foreach ($l in $lines) { if ($l -match '^Content-Length:\s*(\d+)') { $contentLength = [int]$Matches[1] } }
        $bodyMs = New-Object System.IO.MemoryStream
        $already = $bytes.Length - ($headerEnd + 4)
        if ($already -gt 0) { $bodyMs.Write($bytes, $headerEnd + 4, $already) }
        while ($bodyMs.Length -lt $contentLength) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $bodyMs.Write($buf, 0, $n)
        }
        $body = $script:Utf8.GetString($bodyMs.ToArray())
        try {
            Handle-Request $stream $method $path $body
        } catch {
            Write-Log "Request error ($method $path): $($_.Exception.Message)" 'Yellow'
            try { Send-Json $stream @{ ok = $false; error = $_.Exception.Message } 500 } catch {}
        }
    } finally {
        try { $stream.Close() } catch {}
    }
}

function Open-Browser([string]$url, $settings) {
    if ($NoBrowser) { return }
    if ($settings.chromeless) {
        $bases = @()
        if (${env:ProgramFiles(x86)}) { $bases += ${env:ProgramFiles(x86)} }
        if ($env:ProgramFiles) { $bases += $env:ProgramFiles }
        if ($env:LOCALAPPDATA) { $bases += $env:LOCALAPPDATA }
        foreach ($base in $bases) {
            $edge = Join-Path $base 'Microsoft\Edge\Application\msedge.exe'
            if (Test-Path -LiteralPath $edge) {
                # dedicated profile = separate process tree we can close cleanly
                $prof = Join-Path $script:DataDir 'edge-profile'
                if (-not (Test-Path -LiteralPath $prof)) { New-Item -ItemType Directory -Path $prof -Force | Out-Null }
                $edgeArgs = @(
                    "--user-data-dir=$prof",
                    "--app=$url",
                    '--start-fullscreen',
                    '--no-first-run',
                    '--no-default-browser-check',
                    '--disable-session-crashed-bubble',
                    '--hide-crash-restore-bubble'
                )
                try { $script:UiProc = Start-Process -FilePath $edge -ArgumentList $edgeArgs -PassThru } catch {}
                return
            }
        }
    }
    Start-Process $url
}

function Stop-UiWindow {
    if (-not $script:UiProc) { return }
    try { if (-not $script:UiProc.HasExited) { Stop-Process -Id $script:UiProc.Id -Force -ErrorAction Stop } } catch {}
    try {
        $profEsc = [regex]::Escape((Join-Path $script:DataDir 'edge-profile'))
        Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine -match $profEsc } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
    } catch {}
}

# --------------------------------------------------------------------- main
function Start-Nexus {
    try { $Host.UI.RawUI.WindowTitle = "Ludoria Nexus $($script:Version)" } catch {}
    Write-Host ''
    Write-Host '  ==============================================' -ForegroundColor DarkCyan
    Write-Host "   LUDORIA NEXUS  -  game hub engine  v$($script:Version)" -ForegroundColor Cyan
    Write-Host '  ==============================================' -ForegroundColor DarkCyan
    Write-Host ''
    if ((-not $ScanOnly) -and (-not (Test-Path -LiteralPath $script:UiFile))) { throw 'ui\index.html is missing next to LudoriaNexus.ps1' }
    if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir | Out-Null }
    if (-not (Test-Path -LiteralPath $script:ArtDir)) { New-Item -ItemType Directory -Path $script:ArtDir | Out-Null }
    $script:Settings = Get-Settings

    # if an engine is already running, just reopen the overlay on it (fast summon)
    $probePorts = if ($ScanOnly) { @() } else { 8998..9010 }
    foreach ($p in $probePorts) {
        try {
            $r = Invoke-RestMethod -Uri "http://127.0.0.1:$p/api/status" -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop
            if ($r -and $r.ok) {
                Write-Log "Engine already running on port $p - opening overlay." 'Green'
                if ($Rescan) { try { Invoke-RestMethod -Uri "http://127.0.0.1:$p/api/rescan" -Method Post -TimeoutSec 600 -UseBasicParsing | Out-Null } catch {} }
                Open-Browser "http://127.0.0.1:$p/" $script:Settings
                return
            }
        } catch {}
    }

    $lib = Read-Json $script:LibFile
    if ($lib) { $lib = ConvertTo-Library $lib }
    $needScan = $false
    if (-not $lib) {
        $needScan = $true
        Write-Log 'No cache yet - first run. Initial scan + artwork fetch takes a moment; later starts are instant.' 'Yellow'
    } elseif ($Rescan) {
        $needScan = $true
        Write-Log 'Forced rescan (-Rescan).' 'Cyan'
    } else {
        $fp = Get-Fingerprint $script:Settings
        if ($fp -ne $lib.fingerprint) {
            $needScan = $true
            Write-Log 'Game installs changed since last run - rescanning.' 'Cyan'
        } else {
            Write-Log ("Cache is fresh - instant start. {0} games loaded." -f $lib.games.Count) 'Green'
        }
    }
    if ($needScan) {
        $script:Library = Invoke-LibraryScan $script:Settings $lib
        Save-Library
    } else {
        $script:Library = $lib
    }

    if ($ScanOnly) {
        Save-Library
        Write-Log ("Scan-only mode: done. {0} games in library." -f (@($script:Library.games).Count)) 'Green'
        return
    }

    $script:Port = Find-FreePort (ConvertTo-Int32 $script:Settings.port 8998)
    $listener = New-TcpListenerOn ([int]$script:Port)
    $listener.Start()
    $script:Listener = $listener
    $url = "http://127.0.0.1:$($script:Port)/"
    try { $Host.UI.RawUI.WindowTitle = "Ludoria Nexus - $url" } catch {}
    Write-Log "Nexus online at $url" 'Green'
    Write-Log 'Overlay closes itself after a launch, on Esc / controller B, or after 30 s idle. Reopen anytime with the .bat.' 'DarkGray'
    Open-Browser $url $script:Settings
    while (-not $script:Quit) {
        if ($listener.Pending()) {
            $client = $listener.AcceptTcpClient()
            try { Handle-Client $client } catch {} finally { try { $client.Close() } catch {} }
        } else {
            Start-Sleep -Milliseconds 30
        }
    }
    Write-Log 'Nexus offline. Bye!' 'Cyan'
}

try {
    Start-Nexus
} catch {
    Write-Log "Fatal: $($_.Exception.Message)" 'Red'
    try {
        $err = $_
        if ($err.InvocationInfo -and $err.InvocationInfo.PositionMessage) {
            Write-Host $err.InvocationInfo.PositionMessage -ForegroundColor DarkRed
        }
        if ($err.ScriptStackTrace) {
            Write-Host $err.ScriptStackTrace -ForegroundColor DarkGray
        }
    } catch {}
    Write-Host ''
    Write-Host 'Press Enter to close...'
    try { [void](Read-Host) } catch { Start-Sleep -Seconds 8 }
} finally {
    if ($script:Listener) { try { $script:Listener.Stop() } catch {} }
    # only kill the UI window if we own the engine (not when reusing an existing one)
    if ($script:Listener) { Stop-UiWindow }
}
