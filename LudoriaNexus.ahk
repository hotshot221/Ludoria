#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================================
;  LUDORIA NEXUS 1.2  -  native game launcher overlay   (a Hotshot tool)
;  Summon: F7 or controller Guide. Carousel of fan-stacked cards over a
;  blurred game banner. Library: data\games.csv (edit it - add/remove games,
;  point covers at your own images). data\index.tsv is the scanner's cache.
; ============================================================================
;@Ahk2Exe-Set CompanyName, Hotshot
;@Ahk2Exe-Set ProductName, Hotshot Ludoria
;@Ahk2Exe-Set Description, Ludoria`, a Hotshot tool
;@Ahk2Exe-Set Copyright, (c) 2026 Hotshot
;@Ahk2Exe-Set Version, 1.21.0.0

Persistent
SetTimer(NightWatch, 300000)          ; re-pin hooks every 5 min (never goes deaf)
OnMessage(0x218, OnPowerBroadcast)       ; re-arm instantly after sleep/resume
CoordMode 'Mouse', 'Screen'
SetWinDelay -1
A_IconTip := 'Ludoria'

; ------------------------------------------------------------------ state
NX := Map(
    'dir'    , A_ScriptDir,
    'data'   , A_ScriptDir '\data',
    'index'  , A_ScriptDir '\data\index.tsv',
    'csv'    , A_ScriptDir '\data\games.csv',
    'ovfile' , A_ScriptDir '\data\overrides.tsv',
    'ps1'    , A_ScriptDir '\LudoriaNexus.ps1',
    'games'  , [],
    'view'   , [],
    'imgs'   , Map(),
    'bg'     , Map(),      ; per-game blurred background bitmap + accent
    'fonts'  , Map(),
    'rects'  , [],
    'shown'  , false,
    'pos'    , 0.0,
    'target' , 0,
    'dirty'  , true,
    'act'    , 0,
    'scanpid', 0,
    'msg'    , '',
    'guide'  , false,
    'btns'   , 0,
    'navdir' , 0,
    'navrep' , 0,
    'xifn'   , 0,
    'blur'   , 0,
    'draw'   , 0,
    'hblur'  , 0,
    'hdraw'  , 0,
    'hdc'    , 0,
    'hbm'    , 0,
    'gfx'    , 0,
    'tok'    , 0,
    'fam'    , 0,
    'fmtc'   , 0,
    'fmtl'   , 0,
    'sw'     , 0,
    'sh'     , 0,
    'cw'     , 210,
    'ch'     , 315,
    'idle'   , 20000,
    'focus'  , -1,
    'input'  , 'kb',
    'anim'   , '',
    'anim0'  , 0,
    'scat'   , Map(),
    'lncmd'  , '',
    'lnwd'   , '',
    'ptab'   , false,
    'psel'   , 1,
    'pconf'  , 0,
    'deck'   , 'lib',
    'oview'  , [],
    'opos'   , 0.0,
    'otarget', 0,
    'dsw'    , 0,
    'fly'    , 0,
    'famd'   , 0,
    'pt0'    , 0,
    'gtitle' , '',
    'gt0'    , 0,
    'gdelay' , 0,
    'gdir'   , 1,
    'artfl'  , 0,
    'sheet'  , false,
    'ssel'   , 1,
    'st0'    , 0,
    'repair' , false,
    'rsel'   , 1,
    'rt0'    , 0,
    'vol'    , 0.60,
    'tint'   , 0,
    'ripple' , 0,
    'sfxok'  , Map(),
    'hwo'    , 0,
    'hwofmt' , 0,
    'hwodata', 0,
    'hwohdr' , 0
)

; ------------------------------------------------------------------ tray
A_TrayMenu.Delete()
A_TrayMenu.Add('Open Ludoria', (*) => ShowOverlay())
A_TrayMenu.Add('Repair artwork', (*) => OpenRepair())
A_TrayMenu.Add('Open art folder', (*) => OpenArtDir())
A_TrayMenu.Add('Rescan library', (*) => StartScan(true))
A_TrayMenu.Add('Diagnostics', (*) => ShowDiag())
A_TrayMenu.Add('About Ludoria', (*) => ShowAbout())
A_TrayMenu.Add()
A_TrayMenu.Add('Reload', (*) => Reload())
A_TrayMenu.Add('Pause Script', PauseTool)
A_TrayMenu.Add('Exit', (*) => ExitApp())
global VolMenu := Menu()
VolMenu.Add('Normal', (*) => SetVol(0.60))
VolMenu.Add('Soft', (*) => SetVol(0.30))
VolMenu.Add('Off', (*) => SetVol(0.0))
A_TrayMenu.Insert('Diagnostics', 'Sound volume', VolMenu)
SetVol(0.60)
WarmSfx()   ; open + prime every clip so no play ever loses its head
A_TrayMenu.Default := 'Open Ludoria'
A_TrayMenu.ClickCount := 1

PauseTool(ItemName, ItemPos, MyMenu) {
    Suspend -1
    Pause -1
    MyMenu.ToggleCheck(ItemName)
}

; ------------------------------------------------------------------ boot
InitGdip()
LoadAll()
if (NX['games'].Length = 0 && !FileExist(NX['index']) && !FileExist(NX['csv']))
    StartScan(false)
else if (NX['games'].Length && !FileExist(NX['csv']))
    SaveCsv()                     ; seed an editable library on first run
SetTimer(PadPoll, 120)

F7:: {
    global NX
    NX['input'] := 'kb'   ; summoned from the keyboard -> keycap hints below
    ToggleOverlay()
}

; ============================================================== csv + data
CsvEscape(v) {
    if (InStr(v, ',') || InStr(v, '"') || InStr(v, '`n'))
        return '"' StrReplace(v, '"', '""') '"'
    return v
}
CsvSplit(line) {
    ; one CSV row -> array of fields (handles "quoted, fields")
    out := []
    cur := ''
    inq := false
    i := 1
    n := StrLen(line)
    while (i <= n) {
        c := SubStr(line, i, 1)
        if inq {
            if (c = '"') {
                if (SubStr(line, i + 1, 1) = '"') {
                    cur .= '"'
                    i++
                } else {
                    inq := false
                }
            } else {
                cur .= c
            }
        } else if (c = '"') {
            inq := true
        } else if (c = ',') {
            out.Push(cur)
            cur := ''
        } else {
            cur .= c
        }
        i++
    }
    out.Push(cur)
    return out
}
ResolveArtPath(p) {
    ; cover may be absolute, relative to data\, or a bare name in data\art\.
    ; absolute paths from an old folder location are healed by falling back to
    ; the local art folder, so the whole folder can be moved anywhere.
    global NX
    if (p = '')
        return ''
    if FileExist(p)
        return p
    t := NX['data'] '\' p
    if FileExist(t)
        return t
    t := NX['data'] '\art\' p
    if FileExist(t)
        return t
    base := ''
    SplitPath(p, &base)
    if (base != '' && base != p) {
        t := NX['data'] '\art\' base
        if FileExist(t)
            return t
        t := NX['data'] '\' base
        if FileExist(t)
            return t
    }
    return ''
}
PortableCover(p) {
    ; store covers relative to data\ so games.csv survives folder moves
    global NX
    if (p = '')
        return ''
    pre := NX['data'] '\'
    if (SubStr(p, 1, StrLen(pre)) = pre)
        return SubStr(p, StrLen(pre) + 1)
    return p
}
MakeGame(id, title, source, launch, workdir, cover, fav, hidden) {
    return Map('id', id, 'title', title = '' ? id : title, 'source', source = '' ? 'manual' : source
        , 'launch', launch, 'workdir', workdir, 'cover', ResolveArtPath(cover)
        , 'fav', fav = '1', 'hidden', hidden = '1')
}
LoadCsv() {
    ; user-editable library. Rows here WIN over the scanner cache by id.
    global NX
    rows := []
    if !FileExist(NX['csv'])
        return rows
    txt := ''
    try txt := FileRead(NX['csv'], 'UTF-8')
    catch
        return rows
    if (SubStr(txt, 1, 1) = Chr(0xFEFF))
        txt := SubStr(txt, 2)
    loop parse, txt, '`n', '`r' {
        line := Trim(A_LoopField)
        if (line = '' || SubStr(line, 1, 1) = '#')
            continue
        f := CsvSplit(line)
        if (f.Length < 4)
            continue
        id := Trim(f[1])
        if (id = '' || StrLower(id) = 'id')
            continue
        fav := f.Length >= 7 ? Trim(f[7]) : '0'
        hid := f.Length >= 8 ? Trim(f[8]) : '0'
        wdir := f.Length >= 5 ? Trim(f[5]) : ''
        cov := f.Length >= 6 ? Trim(f[6]) : ''
        rows.Push(MakeGame(id, Trim(f[2]), Trim(f[3]), Trim(f[4]), wdir, cov, fav, hid))
    }
    return rows
}
LoadScannerCache() {
    global NX
    games := []
    if !FileExist(NX['index'])
        return games
    txt := ''
    try txt := FileRead(NX['index'], 'UTF-8')
    catch
        return games
    if (SubStr(txt, 1, 1) = Chr(0xFEFF))
        txt := SubStr(txt, 2)
    loop parse, txt, '`n', '`r' {
        line := A_LoopField
        if (Trim(line) = '')
            continue
        f := StrSplit(line, '`t')
        if (f.Length < 8)
            continue
        id := Trim(f[1])
        if (id = '' || id = 'id' || Trim(f[4]) = '')
            continue
        games.Push(MakeGame(id, f[2], f[3], f[4], f[5], f[6], f[7], f[8]))
    }
    return games
}
LoadOverrides() {
    global NX
    ov := Map()
    if !FileExist(NX['ovfile'])
        return ov
    txt := ''
    try txt := FileRead(NX['ovfile'], 'UTF-8')
    catch
        return ov
    loop parse, txt, '`n', '`r' {
        if (Trim(A_LoopField) = '')
            continue
        f := StrSplit(A_LoopField, '`t')
        if (f.Length < 3)
            continue
        ov[f[1]] := [f[2] = '1', f[3] = '1']
    }
    return ov
}
SaveOverrides() {
    global NX
    out := ''
    for g in NX['games']
        out .= g['id'] '`t' (g['fav'] ? '1' : '0') '`t' (g['hidden'] ? '1' : '0') '`n'
    try {
        if !DirExist(NX['data'])
            DirCreate(NX['data'])
        if FileExist(NX['ovfile'])
            FileDelete(NX['ovfile'])
        FileAppend(out, NX['ovfile'], 'UTF-8')
    }
}
LoadAll() {
    global NX
    NX['msg'] := ''
    NX['artfl'] := 0
    base := LoadScannerCache()
    byid := Map()
    for g in base
        byid[g['id']] := g
    for g in LoadCsv()            ; csv rows replace/add and win
        byid[g['id']] := g
    games := []
    for , g in byid
        games.Push(g)
    NX['games'] := games
    if (games.Length = 0)
        NX['msg'] := FileExist(NX['csv']) ? 'games.csv has no games' : 'No library yet  -  press R to scan'
    RebuildView()
}
RebuildView() {
    global NX
    favs := []
    lib := []
    for g in NX['games'] {
        if g['hidden']
            continue
        if g['fav']
            favs.Push(g)
        else
            lib.Push(g)
    }
    SortArr(favs)
    SortArr(lib)
    if !favs.Length
        NX['deck'] := 'lib'
    else if !lib.Length
        NX['deck'] := 'fav'
    if (NX['deck'] = 'fav') {
        NX['view'] := favs
        NX['oview'] := lib
    } else {
        NX['view'] := lib
        NX['oview'] := favs
    }
    frac := NX['pos'] - NX['target']
    ofrac := NX['opos'] - NX['otarget']
    NX['target'] := NormIdx(NX['target'], NX['view'].Length)
    NX['pos'] := NX['target'] + frac
    NX['otarget'] := NormIdx(NX['otarget'], NX['oview'].Length)
    NX['opos'] := NX['otarget'] + ofrac
    NX['dirty'] := true
}
NormIdx(t, n) {
    if (n < 1)
        return 0
    t := Mod(Round(t), n)
    if (t < 0)
        t += n
    return t
}
SortArr(arr) {
    n := arr.Length
    i := 2
    while (i <= n) {
        cur := arr[i]
        j := i - 1
        while (j >= 1 && StrCompare(arr[j]['title'], cur['title'], false) > 0) {
            arr[j + 1] := arr[j]
            j--
        }
        arr[j + 1] := cur
        i++
    }
}
SwitchDeck(dirn) {
    ; -1 = up into favourites, +1 = down into the library
    global NX
    want := dirn < 0 ? 'fav' : 'lib'
    if (want = NX['deck'] || !NX['oview'].Length)
        return
    tv := NX['view']
    tp := NX['pos']
    tt := NX['target']
    NX['view'] := NX['oview']
    NX['pos'] := NX['opos']
    NX['target'] := NX['otarget']
    NX['oview'] := tv
    NX['opos'] := tp
    NX['otarget'] := tt
    NX['deck'] := want
    NX['dsw'] := A_TickCount
    NX['act'] := A_TickCount
    Sfx('tick')
    NX['dirty'] := true
}
WrapDelta(i, pos, n) {
    ; shortest circular distance -> the wheel wraps, focused card always centred
    if (n < 2)
        return i - pos
    d := Mod(i - pos, n)
    if (d < 0)
        d += n
    if (d > n / 2)
        d -= n
    return d
}
SeedScat(view, tag, pos) {
    global NX
    n := view.Length
    i := 0
    while (i < n) {
        if (Abs(WrapDelta(i, pos, n)) <= 6.5) {
            ang := Random(0.0, 6.283)
            NX['scat'][tag '_' i] := [Cos(ang) * 1.15, Abs(Sin(ang)) * 0.85 + 0.35]
        }
        i++
    }
}
Current() {
    global NX
    v := NX['view']
    if !v.Length
        return 0
    return v[NormIdx(NX['pos'], v.Length) + 1]
}
OpenCsv() {
    global NX
    if !FileExist(NX['csv']) {
        try {
            if !DirExist(NX['data'])
                DirCreate(NX['data'])
            FileAppend('id,title,source,launch,workdir,cover,fav,hidden`r`n'
                . '# one row per game. cover: full path or file inside data\art\. hidden=1 removes from the wheel.`r`n'
                . '# example:`r`n'
                . '# mygame1,My Game,manual,"D:\Games\game.exe",D:\Games,coolart.jpg,0,0`r`n', NX['csv'], 'UTF-8')
        }
    }
    if FileExist(NX['csv'])
        Run('notepad.exe "' NX['csv'] '"')
}
ShowDiag() {
    global NX
    MsgBox('Script folder:`n' NX['dir']
        . '`n`nScanner cache:`n' NX['index'] '  ->  ' (FileExist(NX['index']) ? 'found' : 'missing')
        . '`n`nYour library (edit me):`n' NX['csv'] '  ->  ' (FileExist(NX['csv']) ? 'found' : 'not created yet')
        . '`n`nGames loaded: ' NX['games'].Length '   visible: ' NX['view'].Length
        . '`nScan running: ' (NX['scanpid'] ? 'yes' : 'no')
        , 'Ludoria - diagnostics', '0x40')
}

; ============================================================== scanning
StartScan(force) {
    global NX
    if NX['scanpid']
        return
    if !FileExist(NX['ps1']) {
        NX['msg'] := 'LudoriaNexus.ps1 is missing next to the tool'
        NX['dirty'] := true
        return
    }
    args := '-NoProfile -ExecutionPolicy Bypass -File "' NX['ps1'] '" -ScanOnly'
    if force
        args .= ' -Rescan'
    pid := 0
    try Run('powershell.exe ' args, NX['dir'], 'Hide', &pid)
    catch {
        NX['msg'] := 'Could not start PowerShell'
        NX['dirty'] := true
        return
    }
    NX['scanpid'] := pid
    NX['msg'] := 'Scanning your drives for games...'
    NX['dirty'] := true
    SetTimer(ScanWatch, 400)
}
ScanWatch() {
    global NX
    if (NX['scanpid'] && ProcessExist(NX['scanpid']))
        return
    SetTimer(ScanWatch, 0)
    NX['scanpid'] := 0
    ClearArtCaches()
    LoadAll()
    if NX['games'].Length
        SaveCsv()                 ; fold newly scanned games into the csv
}
ClearArtCaches() {
    global NX
    for , bm in NX['imgs'] {
        if bm
            DllCall('gdiplus\GdipDisposeImage', 'ptr', bm)
    }
    DisposeImgs()
    for , rec in NX['bg'] {
        if rec[1]
            DllCall('gdiplus\GdipDisposeImage', 'ptr', rec[1])
    }
    DisposeBg()
}

; ============================================================== gdi+ setup
InitGdip() {
    global NX
    DllCall('LoadLibrary', 'str', 'gdiplus', 'ptr')
    DllCall('winmm\timeBeginPeriod', 'uint', 1)   ; 1 ms timer resolution -> silky animation
    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut('uint', 1, si, 0)
    tok := 0
    DllCall('gdiplus\GdiplusStartup', 'ptr*', &tok, 'ptr', si, 'ptr', 0)
    NX['tok'] := tok
    fam := 0
    DllCall('gdiplus\GdipCreateFontFamilyFromName', 'wstr', 'Segoe UI', 'ptr', 0, 'ptr*', &fam)
    NX['fam'] := fam
    famd := 0
    DllCall('gdiplus\GdipCreateFontFamilyFromName', 'wstr', 'Bahnschrift', 'ptr', 0, 'ptr*', &famd)
    if !famd
        DllCall('gdiplus\GdipCreateFontFamilyFromName', 'wstr', 'Segoe UI Semilight', 'ptr', 0, 'ptr*', &famd)
    NX['famd'] := famd               ; display face for titles and the globe
    fc := 0
    DllCall('gdiplus\GdipCreateStringFormat', 'int', 0, 'int', 0, 'ptr*', &fc)
    DllCall('gdiplus\GdipSetStringFormatAlign', 'ptr', fc, 'int', 1)
    DllCall('gdiplus\GdipSetStringFormatLineAlign', 'ptr', fc, 'int', 1)
    DllCall('gdiplus\GdipSetStringFormatTrimming', 'ptr', fc, 'int', 3)
    DllCall('gdiplus\GdipSetStringFormatFlags', 'ptr', fc, 'int', 0x1000 | 0x4000)
    NX['fmtc'] := fc
    fl := 0
    DllCall('gdiplus\GdipCreateStringFormat', 'int', 0, 'int', 0, 'ptr*', &fl)
    DllCall('gdiplus\GdipSetStringFormatFlags', 'ptr', fl, 'int', 0x1000 | 0x4000)
    NX['fmtl'] := fl
    OnExit(OnQuit)
}
OnQuit(*) {
    global NX
    try {
        DllCall('winmm\timeEndPeriod', 'uint', 1)
        ClearArtCaches()
        if NX['gfx']
            DllCall('gdiplus\GdipDeleteGraphics', 'ptr', NX['gfx'])
        if NX['hbm']
            DllCall('DeleteObject', 'ptr', NX['hbm'])
        if NX['hdc']
            DllCall('DeleteDC', 'ptr', NX['hdc'])
        if NX['tok']
            DllCall('gdiplus\GdiplusShutdown', 'ptr', NX['tok'])
    }
    return 0
}
GetFont(px, bold) {
    ; every UI string rides the Ludoria display face (Bahnschrift) - Segoe only
    ; ever shows if Bahnschrift is genuinely missing from the machine
    global NX
    key := px '_' bold
    if NX['fonts'].Has(key)
        return NX['fonts'][key]
    f := 0
    fam := NX['famd'] ? NX['famd'] : NX['fam']
    DllCall('gdiplus\GdipCreateFont', 'ptr', fam, 'float', px, 'int', bold ? 1 : 0, 'int', 2, 'ptr*', &f)
    NX['fonts'][key] := f
    return f
}

; ============================================================== windows
EnsureWindows() {
    global NX
    if NX['blur']
        return
    NX['sw'] := A_ScreenWidth
    NX['sh'] := A_ScreenHeight
    b := Gui('-Caption +AlwaysOnTop +ToolWindow +E0x08000000', 'LudoriaNexusGlass')
    b.BackColor := '010203'   ; punched transparent so the DWM acrylic shows through
    NX['blur'] := b
    NX['hblur'] := b.Hwnd
    d := Gui('-Caption +AlwaysOnTop +ToolWindow +E0x08080000', 'LudoriaNexusCards')
    NX['draw'] := d
    NX['hdraw'] := d.Hwnd
    EnsureSurface()
    OnMessage(0x201, OnLClick)
    OnMessage(0x204, OnRClick)
}
EnsureSurface() {
    ; the full-screen 32-bit canvas (~14 MB at 1440p) is created on demand
    ; and released when Ludoria hides, so that RAM is only held while open
    global NX
    if NX['gfx']
        return
    sdc := DllCall('GetDC', 'ptr', 0, 'ptr')
    bi := Buffer(40, 0)
    NumPut('uint', 40, bi, 0)
    NumPut('int', NX['sw'], bi, 4)
    NumPut('int', -NX['sh'], bi, 8)
    NumPut('ushort', 1, bi, 12)
    NumPut('ushort', 32, bi, 14)
    bits := 0
    NX['hbm'] := DllCall('CreateDIBSection', 'ptr', sdc, 'ptr', bi, 'uint', 0, 'ptr*', &bits, 'ptr', 0, 'uint', 0, 'ptr')
    NX['hdc'] := DllCall('CreateCompatibleDC', 'ptr', sdc, 'ptr')
    DllCall('SelectObject', 'ptr', NX['hdc'], 'ptr', NX['hbm'])
    DllCall('ReleaseDC', 'ptr', 0, 'ptr', sdc)
    g := 0
    DllCall('gdiplus\GdipCreateFromHDC', 'ptr', NX['hdc'], 'ptr*', &g)
    DllCall('gdiplus\GdipSetSmoothingMode', 'ptr', g, 'int', 4)
    DllCall('gdiplus\GdipSetTextRenderingHint', 'ptr', g, 'int', 4)
    DllCall('gdiplus\GdipSetInterpolationMode', 'ptr', g, 'int', 6)
    DllCall('gdiplus\GdipSetPixelOffsetMode', 'ptr', g, 'int', 2)
    NX['gfx'] := g
}
FreeSurface() {
    global NX
    if NX['gfx'] {
        try DllCall('gdiplus\GdipDeleteGraphics', 'ptr', NX['gfx'])
        NX['gfx'] := 0
    }
    if NX['hdc'] {
        try DllCall('DeleteDC', 'ptr', NX['hdc'])
        NX['hdc'] := 0
    }
    if NX['hbm'] {
        try DllCall('DeleteObject', 'ptr', NX['hbm'])
        NX['hbm'] := 0
    }
}
SetAcrylic(hwnd, tint) {
    accent := Buffer(16, 0)
    NumPut('int', 4, accent, 0)
    NumPut('int', 2, accent, 4)
    NumPut('uint', tint, accent, 8)
    data := Buffer(A_PtrSize * 3, 0)
    NumPut('uint', 19, data, 0)
    NumPut('ptr', accent.Ptr, data, A_PtrSize)
    NumPut('uptr', 16, data, A_PtrSize * 2)
    try DllCall('user32\SetWindowCompositionAttribute', 'ptr', hwnd, 'ptr', data)
}
PushFrame(alpha := 255) {
    global NX
    if !NX['hdc']
        return
    bf := Buffer(4, 0)
    NumPut('uchar', 0, bf, 0)
    NumPut('uchar', 0, bf, 1)
    NumPut('uchar', alpha, bf, 2)
    NumPut('uchar', 1, bf, 3)
    pd := Buffer(8, 0)
    ps := Buffer(8, 0)
    sz := Buffer(8, 0)
    NumPut('int', NX['sw'], sz, 0)
    NumPut('int', NX['sh'], sz, 4)
    DllCall('UpdateLayeredWindow', 'ptr', NX['hdraw'], 'ptr', 0, 'ptr', pd, 'ptr', sz
        , 'ptr', NX['hdc'], 'ptr', ps, 'uint', 0, 'ptr', bf, 'uint', 2)
}
GameActive() {
    try {
        if WinActive('ahk_exe VALORANT-Win64-Shipping.exe')
            return true
    }
    return false
}
ToggleOverlay() {
    global NX
    if NX['shown']
        HideOverlay()
    else
        ShowOverlay()
}
ShowOverlay() {
    global NX
    if NX['shown']
        return
    if GameActive()
        return
    EnsureWindows()
    EnsureSurface()
    NX['deck'] := 'fav'   ; favourites deck is the default whenever it exists
    NX['fly'] := 0
    NX['dsw'] := 0
    NX['gtitle'] := ''
    NX['gt0'] := A_TickCount
    NX['gdelay'] := 1500
    LoadAll()
    NX['shown'] := true
    NX['act'] := A_TickCount
    NX['pos'] := NX['target']
    NX['opos'] := NX['otarget']
    NX['focus'] := -1
    NX['anim'] := 'open'
    NX['anim0'] := A_TickCount
    NX['ptab'] := false
    NX['pconf'] := 0
    NX['pt0'] := 0
    NX['psel'] := 1
    NX['sheet'] := false
    NX['ssel'] := 1
    NX['st0'] := 0
    NX['repair'] := false
    NX['rsel'] := 1
    NX['rt0'] := 0
    NX['ripple'] := 0
    NX['navdir'] := 0
    NX['dirty'] := true
    NX['blur'].Show('x0 y0 w' NX['sw'] ' h' NX['sh'] ' NA')
    NX['tint'] := 0xB0141018
    SetAcrylic(NX['hblur'], NX['tint'])
    try WinSetTransColor('010203', NX['hblur'])
    NX['draw'].Show('x0 y0 w' NX['sw'] ' h' NX['sh'] ' NA')
    Render()
    PushFrame()
    Sfx('open')
    SetTimer(Frame, 8)
    SetTimer(PadPoll, 25)
}
HideOverlay() {
    global NX
    if !NX['shown']
        return
    if (NX['anim'] = 'close' || NX['anim'] = 'launch')
        return
    NX['scat'] := Map()
    SeedScat(NX['view'], 'v', NX['pos'])
    SeedScat(NX['oview'], 'o', NX['opos'])
    NX['anim'] := 'close'
    NX['anim0'] := A_TickCount
    Sfx('close')
}
FinishHide() {
    global NX
    NX['shown'] := false
    NX['anim'] := ''
    NX['ptab'] := false
    NX['pconf'] := 0
    NX['pt0'] := 0
    NX['sheet'] := false
    NX['st0'] := 0
    NX['repair'] := false
    NX['rt0'] := 0
    NX['ripple'] := 0
    NX['fly'] := 0
    NX['gtitle'] := ''
    NX['gt0'] := 0
    SetTimer(Frame, 0)
    SetTimer(PadPoll, 120)
    try NX['draw'].Hide()
    try NX['blur'].Hide()
    FreeVisuals()
}

; ============================================================== frame loop
; critically damped: position eases toward target, never overshoots (no bounce)
Frame() {
    global NX
    Critical('On')
    static lastT := 0, fast := true
    now := A_TickCount
    dt := lastT ? (now - lastT) / 1000.0 : 0.016
    if (dt > 0.05)
        dt := 0.05
    lastT := now
    if !NX['shown']
        return
    ; exponential ease blended into a constant glide near the target:
    ; removes the asymptotic sub-pixel crawl that looked jittery at the end
    k := 1 - Exp(-dt * 10.5)
    mn := dt * 1.15
    if NX['view'].Length {
        diff := NX['target'] - NX['pos']
        if (Abs(diff) > 0.0012) {
            step := diff * k
            if (Abs(step) < mn)
                step := (diff > 0 ? 1 : -1) * Min(Abs(diff), mn)
            NX['pos'] := NX['pos'] + step
        } else
            NX['pos'] := NX['target']
    }
    if NX['oview'].Length {
        diff2 := NX['otarget'] - NX['opos']
        if (Abs(diff2) > 0.0012) {
            step2 := diff2 * k
            if (Abs(step2) < mn)
                step2 := (diff2 > 0 ? 1 : -1) * Min(Abs(diff2), mn)
            NX['opos'] := NX['opos'] + step2
        } else
            NX['opos'] := NX['otarget']
    }
    a := NX['anim']
    el := now - NX['anim0']
    if (a = 'open' && el > 1600)
        NX['anim'] := ''
    else if (a = 'close' && el > 300) {
        FinishHide()
        return
    } else if (a = 'launch' && el > 460) {
        DoLaunch()
        return
    }
    if (NX['pconf'] && PowerHoldP() >= 1.0) {
        PowerExec(NX['psel'])
        return
    }
    if (a = '' && now - NX['act'] > NX['idle']) {
        HideOverlay()
        return
    }
    ; ~120 fps while ANY motion is live (scroll, panels, hold-bar, fav fly...)
    moving := (a != '') || (NX['pos'] != NX['target']) || (NX['opos'] != NX['otarget']) || (now - NX['dsw'] < 420) || (now - NX['pt0'] < 560) || (now - NX['gt0'] < NX['gdelay'] + 460) || IsObject(NX['fly']) || (now - NX['st0'] < 560) || (now - NX['rt0'] < 560) || NX['pconf'] || NX['ptab'] || NX['sheet'] || NX['repair'] || IsObject(NX['ripple'])
    if (moving && !fast) {
        SetTimer(Frame, 8)
        fast := true
    } else if (!moving && fast) {
        SetTimer(Frame, 14)
        fast := false
    }
    Render()
    fade := 255
    if (a = 'close')
        fade := Round(255 * Max(0, 1 - el / 280.0))
    else if (a = 'launch')
        fade := Round(255 * Max(0, 1 - Max(0, el - 280) / 180.0))
    PushFrame(fade)
}

; ============================================================== background art
GetBg(game) {
    global NX
    id := game['id']
    if NX['bg'].Has(id)
        return NX['bg'][id]
    src := GetHero(game)
    if !src
        src := GetArt(game)
    rec := [0, 0xFF3A7EBE]
    if src {
        ; two-stage resample: crush to 24x14 first (heavy blur baked in),
        ; then lift to 160x90. The fullscreen stretch is now ~17x instead of
        ; ~55x, so the Ken Burns drift glides instead of stepping between
        ; giant source texels.
        sm := 0
        DllCall('gdiplus\GdipCreateBitmapFromScan0', 'int', 24, 'int', 14, 'int', 0, 'int', 0x26200A, 'ptr', 0, 'ptr*', &sm)
        sg := 0
        DllCall('gdiplus\GdipGetImageGraphicsContext', 'ptr', sm, 'ptr*', &sg)
        DllCall('gdiplus\GdipSetInterpolationMode', 'ptr', sg, 'int', 7)
        iw := 0
        ih := 0
        DllCall('gdiplus\GdipGetImageWidth', 'ptr', src, 'uint*', &iw)
        DllCall('gdiplus\GdipGetImageHeight', 'ptr', src, 'uint*', &ih)
        scale := Max(24 / iw, 14 / ih)
        sw := 24 / scale
        sh := 14 / scale
        sx := (iw - sw) / 2
        sy := (ih - sh) / 2
        DllCall('gdiplus\GdipDrawImageRectRect', 'ptr', sg, 'ptr', src
            , 'float', 0, 'float', 0, 'float', 24, 'float', 14
            , 'float', sx, 'float', sy, 'float', sw, 'float', sh
            , 'int', 2, 'ptr', 0, 'ptr', 0, 'ptr', 0)
        DllCall('gdiplus\GdipDeleteGraphics', 'ptr', sg)
        bm := 0
        DllCall('gdiplus\GdipCreateBitmapFromScan0', 'int', 160, 'int', 90, 'int', 0, 'int', 0x26200A, 'ptr', 0, 'ptr*', &bm)
        bgg := 0
        DllCall('gdiplus\GdipGetImageGraphicsContext', 'ptr', bm, 'ptr*', &bgg)
        DllCall('gdiplus\GdipSetInterpolationMode', 'ptr', bgg, 'int', 7)
        DllCall('gdiplus\GdipDrawImageRectRect', 'ptr', bgg, 'ptr', sm
            , 'float', -8, 'float', -5, 'float', 176, 'float', 100
            , 'float', 0, 'float', 0, 'float', 24, 'float', 14
            , 'int', 2, 'ptr', 0, 'ptr', 0, 'ptr', 0)
        DllCall('gdiplus\GdipDeleteGraphics', 'ptr', bgg)
        try DllCall('gdiplus\GdipDisposeImage', 'ptr', sm)
        rec := [bm, SampleAccent(src)]
    }
    if (src && src != NX['imgs'].Get(id, 0)) {
        ; the full-size hero only feeds this 48x27 thumb - free it right away
        try DllCall('gdiplus\GdipDisposeImage', 'ptr', src)
        NX['imgs']['hero|' id] := 0
    }
    NX['bg'][id] := rec
    return rec
}
SampleAccent(src) {
    bm := 0
    DllCall('gdiplus\GdipCreateBitmapFromScan0', 'int', 1, 'int', 1, 'int', 0, 'int', 0x26200A, 'ptr', 0, 'ptr*', &bm)
    g := 0
    DllCall('gdiplus\GdipGetImageGraphicsContext', 'ptr', bm, 'ptr*', &g)
    DllCall('gdiplus\GdipSetInterpolationMode', 'ptr', g, 'int', 7)
    iw := 0
    ih := 0
    DllCall('gdiplus\GdipGetImageWidth', 'ptr', src, 'uint*', &iw)
    DllCall('gdiplus\GdipGetImageHeight', 'ptr', src, 'uint*', &ih)
    DllCall('gdiplus\GdipDrawImageRectRect', 'ptr', g, 'ptr', src
        , 'float', 0, 'float', 0, 'float', 1, 'float', 1
        , 'float', 0, 'float', 0, 'float', iw, 'float', ih
        , 'int', 2, 'ptr', 0, 'ptr', 0, 'ptr', 0)
    px := 0
    DllCall('gdiplus\GdipBitmapGetPixel', 'ptr', bm, 'int', 0, 'int', 0, 'uint*', &px)
    DllCall('gdiplus\GdipDeleteGraphics', 'ptr', g)
    DllCall('gdiplus\GdipDisposeImage', 'ptr', bm)
    return BoostColor(px)
}
BoostColor(argb) {
    r := (argb >> 16) & 0xFF
    g := (argb >> 8) & 0xFF
    b := argb & 0xFF
    mx := Max(r, g, b, 1)
    f := 235 / mx
    r := Min(Round(r * f), 255)
    g := Min(Round(g * f), 255)
    b := Min(Round(b * f), 255)
    return 0xFF000000 | (r << 16) | (g << 8) | b
}

; ============================================================== rendering
Render() {
    global NX
    if !NX['gfx']
        return
    g := NX['gfx']
    DllCall('gdiplus\GdipGraphicsClear', 'ptr', g, 'uint', 0x00000000)
    NX['rects'] := []
    w := NX['sw']
    h := NX['sh']
    cx := w / 2
    cur := Current()
    if cur
        UpdateGlobeTitle(cur['id'], cur['title'])
    else
        UpdateGlobeTitle('', '')
    accent := 0xFF3A7EBE
    if cur {
        rec := GetBg(cur)
        accent := rec[2]
        if rec[1] {
            ; Ken Burns drift: each game gets ONE slow, cinematic motion,
            ; hash-picked from its id - a horizontal drift, a diagonal drift
            ; or a gentle zoom. Sinusoidal, so it never jump-cuts, and the
            ; overscan always exceeds the travel so edges can never show.
            bt := A_TickCount
            seed := Mod(StrLen(cur['id']) * 7 + Ord(SubStr(cur['id'], -1)) * 13, 997)
            bmode := Mod(seed, 3)
            phs := seed / 158.0
            bsc := 1.13
            bdx := 0.0
            bdy := 0.0
            if (bmode = 0) {
                bdx := Sin(bt / 9300.0 + phs) * w * 0.0446
                bdy := Sin(bt / 15700.0 + phs) * h * 0.0124
            } else if (bmode = 1) {
                bdx := Sin(bt / 13900.0 + phs) * w * 0.0186
                bdy := Sin(bt / 8700.0 + phs) * h * 0.0384
            } else {
                bsc := 1.13 + 0.055 * Sin(bt / 10600.0 + phs)
            }
            bdw := w * bsc
            bdh := h * bsc
            DllCall('gdiplus\GdipDrawImageRectRect', 'ptr', g, 'ptr', rec[1]
                , 'float', (w - bdw) / 2 + bdx, 'float', (h - bdh) / 2 + bdy, 'float', bdw, 'float', bdh
                , 'float', 0, 'float', 0, 'float', 160, 'float', 90
                , 'int', 2, 'ptr', 0, 'ptr', 0, 'ptr', 0)
        }
    }
    UpdateTint(accent)
    FillRect(g, 0, 0, w, h, 0xB2050810)
    DrawGlobe(g, w, h, accent, cur)
    FillRect(g, 0, h - 190, w, 65, 0x12000000)
    FillRect(g, 0, h - 125, w, 65, 0x1E000000)
    FillRect(g, 0, h - 60, w, 60, 0x2E000000)
    ti := IntroE(200, 700)
    if (ti > 0.01)
        DrawTxtD(g, 'L U D O R I A', 44 - 26 * (1 - ti), 30, 400, 30, 15, (Round(0xB4 * ti) << 24) | 0xE8F4FF, false)
    FillRR(g, 46, 64, 116 + 28 * (0.5 + 0.5 * Sin(A_TickCount / 2100.0)), 2.0, 1.0, 0xC0000000 | (accent & 0xFFFFFF))
    DrawTxt(g, 'H O T S H O T', w - 214, h - 37, 178, 22, 11.5, 0x36C8DCF4, false)
    v := NX['view']
    ov := NX['oview']
    if (!v.Length && !ov.Length) {
        msg := NX['msg'] != '' ? NX['msg'] : 'No games yet  -  press R to scan'
        DrawTxt(g, msg, 0, h * 0.47 - 24, w, 48, 20, 0xD8EAF2FF)
        DrawTxt(g, 'Press M for actions  -  tray icon to rescan', 0, h * 0.47 + 26, w, 30, 12, 0x88AFC6E8)
        return
    }
    sp := NX['cw'] * 0.58
    rs := Min(1.0, h / 1080.0)
    dp := NX['dsw'] ? SmoothStep(Min((A_TickCount - NX['dsw']) / 380.0, 1.0)) : 1.0
    if ov.Length {
        ; favourites always live on the top row; 'activeness' (scale, glow,
        ; shadow) cross-fades smoothly between the rows when switching decks
        fa := NX['deck'] = 'fav' ? dp : 1 - dp
        la := 1 - fa
        favV := NX['deck'] = 'fav' ? v : ov
        favP := NX['deck'] = 'fav' ? NX['pos'] : NX['opos']
        favT := NX['deck'] = 'fav' ? 'v' : 'o'
        libV := NX['deck'] = 'lib' ? v : ov
        libP := NX['deck'] = 'lib' ? NX['pos'] : NX['opos']
        libT := NX['deck'] = 'lib' ? 'v' : 'o'
        mulF := (0.46 + 0.54 * fa) * rs
        mulL := (0.46 + 0.54 * la) * rs
        if (fa >= la) {
            DrawDeck(g, libV, libT, cx, h * 0.72, sp * mulL, accent, libP, mulL, la)
            DrawDeck(g, favV, favT, cx, h * 0.30, sp * mulF, accent, favP, mulF, fa)
        } else {
            DrawDeck(g, favV, favT, cx, h * 0.30, sp * mulF, accent, favP, mulF, fa)
            DrawDeck(g, libV, libT, cx, h * 0.72, sp * mulL, accent, libP, mulL, la)
        }
        favY := h * 0.30 - NX['ch'] * 0.62 * mulF - 30
        libY := h * 0.72 - NX['ch'] * 0.62 * mulL - 30
        ia := IntroE(500, 650)
        favA := Round((0x50 + 0x68 * fa) * ia)
        libA := Round((0x50 + 0x68 * la) * ia)
        DrawTxt(g, (fa > 0.5 ? '' : Chr(0x2191) '  ') 'FAVOURITES', 46, favY, 420, 20, 10, (favA << 24) | 0xC8DCF0, false)
        DrawTxt(g, (la > 0.5 ? '' : Chr(0x2193) '  ') 'LIBRARY', 46, libY, 420, 20, 10, (libA << 24) | 0xC8DCF0, false)
    } else {
        DrawDeck(g, v, 'v', cx, h * 0.47, sp, accent, NX['pos'], 1.0, 1.0)
    }
    DrawFly(g)
    DrawRipple(g, accent)
    if v.Length
        DrawTxt(g, Format('{:02}   /   {:02}', NormIdx(NX['pos'], v.Length) + 1, v.Length), 0, h - 100, w, 22, 11, (Round(0x5A * IntroE(700, 600)) << 24) | 0xAFC6E8)
    DrawHints(g, w, h)
    DrawPowerTab(g, w, h, accent)
    DrawSheet(g, w, h, accent)
    DrawRepair(g, w, h, accent)
    if NX['scanpid']
        DrawTxt(g, 'SCANNING...', w - 280, 34, 240, 26, 12, 0x99FFD479, false)
}
DrawDeck(g, view, tag, cx, rowy, sp, accent, pos, mul, act) {
    global NX
    n := view.Length
    if !n
        return
    order := []
    i := 0
    while (i < n) {
        d := WrapDelta(i, pos, n)
        if (Abs(d) <= 6.5)
            order.Push([i, d])
        i++
    }
    m := order.Length
    a := 1
    while (a < m) {
        b := 1
        while (b <= m - a) {
            if (Abs(order[b][2]) < Abs(order[b + 1][2])) {
                tmp := order[b]
                order[b] := order[b + 1]
                order[b + 1] := tmp
            }
            b++
        }
        a++
    }
    for , it in order
        DrawCard(g, view, it[1], it[2], tag, cx, rowy, sp, accent, mul, act)
}
DrawCard(g, view, idx, d, tag, cx, cy, sp, accent, mul, act) {
    global NX
    game := view[idx + 1]
    ad := Abs(d)

    ; ---- smooth focus: 0 = far away, 1 = dead center ----
    rawFocus := Max(0, 1 - ad / 0.80)
    focus := SmoothStep(rawFocus)

    ; ---- scale flows with focus and shrinks with distance ----
    sc := (0.84 - 0.045 * Min(ad, 4) + focus * 0.32) * mul
    cw := NX['cw'] * sc
    ch := NX['ch'] * sc
    ; gaps shrink geometrically with distance -> fanned hand of cards
    dir := d >= 0 ? 1 : -1
    off := sp * (1 - Exp(-0.3567 * ad)) / 0.30
    x := cx + dir * off - cw / 2

    yLift := -18 * focus * mul
    yDrop := (1 - focus) * Min(ad, 3) * 8 * mul
    y := cy - ch / 2 + yLift + yDrop
    ; resting micro-motion: cards breathe gently even when nothing happens
    y += Sin(A_TickCount / 1700.0 + idx * 1.1) * 2.2 * mul + Sin(A_TickCount / 1300.0) * 1.6 * focus * act

    r := 16 * sc

    ; ---- entrance / exit choreography ----
    ldim := 0
    anim := NX['anim']
    key := tag '_' idx
    if (anim = 'open') {
        stag := Min(Round(ad) * 110, 660) + (act > 0.5 ? 0 : 220)
        p := Min(Max((A_TickCount - NX['anim0'] - stag) / 560.0, 0), 1)
        ; ease-out-back, softened: cards drift up and settle without haste
        c1 := 1.55
        e := 1 + (c1 + 1) * (p - 1) ** 3 + c1 * (p - 1) ** 2
        y += (1 - e) * (NX['sh'] * 0.65)
        ; per-game personality: each title drifts in from its own angle
        x += (1 - e) * (Mod(Ord(SubStr(game['id'], -1)), 3) - 1) * 46 * mul
    } else if (anim = 'close') {
        p := Min((A_TickCount - NX['anim0']) / 280.0, 1)
        e := p * p * p
        if NX['scat'].Has(key) {
            sv := NX['scat'][key]
            x += sv[1] * e * NX['sw'] * 0.55
            y += sv[2] * e * NX['sh'] * 0.65
        } else {
            y += e * NX['sh'] * 0.65
        }
    } else if (anim = 'launch') {
        p := Min((A_TickCount - NX['anim0']) / 420.0, 1)
        if (act > 0.5 && focus > 0.5) {
            ; signature send-off: a quick pop, then the card flies into the
            ; globe and melts away while the logo takes over up there
            pop := SmoothStep(Min(p / 0.40, 1.0))
            fl := SmoothStep(Max(p - 0.40, 0) / 0.60)
            sc2 := (1 + 0.38 * pop) * (1 - 0.86 * fl)
            ccx := x + cw / 2 + (NX['sw'] * 0.80 - x - cw / 2) * fl
            ccy := y + ch / 2 + (NX['sh'] * 0.105 - y - ch / 2) * fl
            nw := cw * sc2
            nh := ch * sc2
            x := ccx - nw / 2
            y := ccy - nh / 2
            cw := nw
            ch := nh
            r := r * sc2
        } else {
            ; everyone else recedes and dims so the chosen one owns the frame
            e := 1 - (1 - p) ** 3
            y += e * NX['sh'] * 0.55
            ldim := e
        }
    }

    ; while a fav-toggle ghost is in flight its destination card stays
    ; invisible (only the hitbox registers) so the card never appears twice
    if (IsObject(NX['fly']) && NX['fly']['tag'] = tag && NX['fly']['i'] = idx) {
        NX['rects'].Push(Map('x', x, 'y', y, 'w', cw, 'h', ch, 'i', idx, 't', tag))
        return
    }

    ; ---- breathing glow, active deck only ----
    if (act > 0.02 && focus > 0.02) {
        pulse := (Sin(A_TickCount / 900.0) + 1) / 2
        base := (17 + 13 * pulse) * focus * act
        ; 18 tightly overlapping layers with a quadratic falloff read as one
        ; continuous halo instead of visible rings
        k := 18
        while (k >= 1) {
            spread := k * 2.9 * (0.72 + 0.28 * pulse) * mul
            fall := (19 - k) / 18.0
            al := Round(base * fall * fall / 1.6)
            if (al >= 1)
                FillRR(g, x - spread, y - spread, cw + spread * 2, ch + spread * 2, r + spread * 0.8, (al << 24) | (accent & 0xFFFFFF))
            k--
        }
    }

    ; shadow + card body
    FillRR(g, x + 4, y + 9, cw, ch, r, 0x66000000)
    FillRR(g, x, y, cw, ch, r, 0xF00C1119)

    ; cover art or generated mono tile
    bm := GetArt(game)
    if bm
        DrawCover(g, bm, x, y, cw, ch, r)
    else
        DrawMono(g, game, x, y, cw, ch, r)

    ; ---- smooth distance dimming; inactive deck is dimmed further ----
    dimAlpha := Round(120 * (1 - focus))
    dimAlpha := Min(dimAlpha + Round(70 * (1 - act)), 190)
    if ldim
        dimAlpha := Min(dimAlpha + Round(150 * ldim), 235)
    if (dimAlpha > 2)
        FillRR(g, x, y, cw, ch, r, (dimAlpha << 24))

    ; ---- border smoothly transitions from dim accent to bright white ----
    ufA := 0x40, ufR := 0xAF, ufG := 0xC6, ufB := 0xE8
    fcA := 0xF2, fcR := 0xFF, fcG := 0xFF, fcB := 0xFF
    ba := Round(ufA + (fcA - ufA) * focus)
    br := Round(ufR + (fcR - ufR) * focus)
    bg := Round(ufG + (fcG - ufG) * focus)
    bb := Round(ufB + (fcB - ufB) * focus)
    borderColor := (ba << 24) | (br << 16) | (bg << 8) | bb
    borderWidth := 1.0 + 0.9 * focus
    StrokeRR(g, x, y, cw, ch, r, borderColor, borderWidth)

    ; source glyph
    DrawSourceGlyph(g, game['source'], x + 9, y + 9, Round(12 + 8 * act))

    ; favourite star
    if game['fav'] {
        sz := Round(14 + 10 * act)
        FillRR(g, x + cw - sz - 9, y + 9, sz, sz, 7, 0xC0241A06)
        DrawTxt(g, Chr(0x2605), x + cw - sz - 9, y + 10, sz, sz - 2, Round(8 + 4 * act), 0xF0FFD479)
    }

    NX['rects'].Push(Map('x', x, 'y', y, 'w', cw, 'h', ch, 'i', idx, 't', tag))
}
ArtStem(title) {
    ; Friendly Windows-safe filenames: Forza Horizon 6_logo.png
    stem := RegExReplace(title, '[<>:"/\|?*]', '')
    stem := Trim(RegExReplace(stem, '\s+', ' '), ' .')
    return SubStr(stem, 1, 100)
}
FindNamedArt(game, kind, exts) {
    global NX
    stem := ArtStem(game['title'])
    for ext in exts {
        p := NX['data'] '\art\' stem '_' kind '.' ext
        if FileExist(p)
            return p
    }
    ; backward compatibility with pre-v1.9 ID-based art
    for ext in exts {
        p := NX['data'] '\art\' game['id'] '_' kind '.' ext
        if FileExist(p)
            return p
    }
    ; forgiving match: nobody should need the exact title. Case, spaces,
    ; hyphens, colons, trademark marks, punctuation, edition suffixes and
    ; even a hidden double extension like _logo.png.jpg are all tolerated.
    want := NormKey(game['title'])
    if (want = '')
        return ''
    best := ''
    bestlen := -1
    for f in ArtFiles() {
        lf := StrLower(f)
        pos := InStr(lf, '_' kind)
        if !pos
            continue
        if !(lf ~= '\.(png|jpe?g|bmp|gif)$')
            continue
        key := NormKey(SubStr(f, 1, pos - 1))
        if (key = '')
            continue
        if (key = want)
            return NX['data'] '\art\' f
        ; prefix containment either way covers edition-name mismatches,
        ; e.g. a Nier Automata file for the title Nier Automata Game of the Year
        if (StrLen(key) >= 6 && (InStr(want, key) = 1 || InStr(key, want) = 1) && StrLen(key) > bestlen) {
            best := f
            bestlen := StrLen(key)
        }
    }
    return best != '' ? NX['data'] '\art\' best : ''
}
NormKey(str) {
    ; the essence of a title: lowercase letters and digits only
    return RegExReplace(StrLower(str), '[^a-z0-9]', '')
}
ArtFiles() {
    ; one cached listing of data\art per session; refreshed on every summon,
    ; library reload and rescan, and dropped from memory while hidden
    global NX
    if IsObject(NX['artfl'])
        return NX['artfl']
    fl := []
    Loop Files NX['data'] '\art\*.*'
        fl.Push(A_LoopFileName)
    NX['artfl'] := fl
    return fl
}
LoadArtFile(path) {
    bm := 0
    if (path != '' && FileExist(path))
        DllCall('gdiplus\GdipCreateBitmapFromFile', 'wstr', path, 'ptr*', &bm)
    return bm
}
GetArt(game) {
    global NX
    id := game['id']
    if NX['imgs'].Has(id)
        return NX['imgs'][id]
    ; a manually dropped Game Name_cover file wins after reload
    p := FindNamedArt(game, 'cover', ['png', 'jpg', 'jpeg'])
    if (p = '')
        p := game['cover']
    bm := ShrinkArt(LoadArtFile(p), 460)
    NX['imgs'][id] := bm
    return bm
}
ShrinkArt(bm, maxw) {
    ; big source art is resampled once to card size: a 600x900 cover drops
    ; from ~2.1 MB to ~1.2 MB in RAM and draws faster afterwards
    if !bm
        return bm
    iw := 0
    ih := 0
    DllCall('gdiplus\GdipGetImageWidth', 'ptr', bm, 'uint*', &iw)
    DllCall('gdiplus\GdipGetImageHeight', 'ptr', bm, 'uint*', &ih)
    if (iw <= maxw || iw <= 0 || ih <= 0)
        return bm
    nw := maxw
    nh := Round(ih * maxw / iw)
    nb := 0
    DllCall('gdiplus\GdipCreateBitmapFromScan0', 'int', nw, 'int', nh, 'int', 0, 'int', 0x26200A, 'ptr', 0, 'ptr*', &nb)
    gg := 0
    DllCall('gdiplus\GdipGetImageGraphicsContext', 'ptr', nb, 'ptr*', &gg)
    DllCall('gdiplus\GdipSetInterpolationMode', 'ptr', gg, 'int', 7)
    DllCall('gdiplus\GdipDrawImageRectRect', 'ptr', gg, 'ptr', bm
        , 'float', 0, 'float', 0, 'float', nw, 'float', nh
        , 'float', 0, 'float', 0, 'float', iw, 'float', ih
        , 'int', 2, 'ptr', 0, 'ptr', 0, 'ptr', 0)
    DllCall('gdiplus\GdipDeleteGraphics', 'ptr', gg)
    DllCall('gdiplus\GdipDisposeImage', 'ptr', bm)
    return nb
}
GetHero(game) {
    global NX
    key := 'hero|' game['id']
    if NX['imgs'].Has(key)
        return NX['imgs'][key]
    p := FindNamedArt(game, 'hero', ['png', 'jpg', 'jpeg'])
    bm := LoadArtFile(p)
    NX['imgs'][key] := bm
    return bm
}
DrawCover(g, bm, x, y, w, h, r) {
    iw := 0
    ih := 0
    DllCall('gdiplus\GdipGetImageWidth', 'ptr', bm, 'uint*', &iw)
    DllCall('gdiplus\GdipGetImageHeight', 'ptr', bm, 'uint*', &ih)
    if (!iw || !ih)
        return
    path := RoundPath(x, y, w, h, r)
    DllCall('gdiplus\GdipSetClipPath', 'ptr', g, 'ptr', path, 'int', 0)
    scale := Max(w / iw, h / ih)
    sw := w / scale
    sh := h / scale
    sx := (iw - sw) / 2
    sy := (ih - sh) * 0.18
    DllCall('gdiplus\GdipDrawImageRectRect', 'ptr', g, 'ptr', bm
        , 'float', x, 'float', y, 'float', w, 'float', h
        , 'float', sx, 'float', sy, 'float', sw, 'float', sh
        , 'int', 2, 'ptr', 0, 'ptr', 0, 'ptr', 0)
    DllCall('gdiplus\GdipResetClip', 'ptr', g)
    DllCall('gdiplus\GdipDeletePath', 'ptr', path)
}
DrawMono(g, game, x, y, w, h, r) {
    ; missing art, treated elegantly: deep graphite tile, faint top light,
    ; a thin inner keyline and a big translucent monogram - no loud colours
    t := game['title']
    hs := 0
    loop parse, StrLower(t)
        hs := Mod(hs * 31 + Ord(A_LoopField), 100000)
    tone := 14 + Mod(hs, 7)
    path := RoundPath(x, y, w, h, r)
    DllCall('gdiplus\GdipSetClipPath', 'ptr', g, 'ptr', path, 'int', 0)
    FillRect(g, x, y, w, h, 0xFF000000 | (tone << 16) | ((tone + 3) << 8) | (tone + 9))
    FillRect(g, x, y, w, h / 2, 0x10FFFFFF)
    ini := ''
    for , word in StrSplit(Trim(t), ' ') {
        if (word != '' && StrLen(ini) < 2)
            ini .= SubStr(word, 1, 1)
    }
    DrawTxtD(g, StrUpper(ini), x, y + h * 0.30, w, h * 0.4, w * 0.30, 0x30FFFFFF)
    StrokeRR(g, x + 6, y + 6, w - 12, h - 12, Max(r - 5, 4), 0x1CFFFFFF, 1)
    DllCall('gdiplus\GdipResetClip', 'ptr', g)
    DllCall('gdiplus\GdipDeletePath', 'ptr', path)
}
SrcName(s) {
    if (s = 'steam')
        return 'STEAM'
    if (s = 'epic')
        return 'EPIC GAMES'
    if (s = 'local')
        return 'LOCAL'
    return 'CUSTOM'
}
DrawSourceGlyph(g, src, x, y, s) {
    FillRR(g, x, y, s + 8, s + 8, 7, 0xB4070C15)
    cx := x + (s + 8) / 2
    cy := y + (s + 8) / 2
    col := 0xFFDCECFF
    dk := 0xFF0C1119
    if (src = 'steam') {
        ; ring + valve dot + piston arm to the lower-left, like the Steam mark
        StrokeEllipse(g, cx - s * 0.34, cy - s * 0.34, s * 0.68, s * 0.68, col, 1.5)
        FillEllipse(g, cx - s * 0.02, cy - s * 0.26, s * 0.28, s * 0.28, col)
        StrokeLine(g, cx + s * 0.10, cy - s * 0.10, cx - s * 0.28, cy + s * 0.22, col, 2.4)
        FillEllipse(g, cx - s * 0.38, cy + s * 0.14, s * 0.18, s * 0.18, col)
    } else if (src = 'epic') {
        ; tall shield tapering to a point, dark E inside - the Epic badge
        FillRR(g, cx - s * 0.28, cy - s * 0.38, s * 0.56, s * 0.58, s * 0.10, col)
        FillRect(g, cx - s * 0.24, cy + s * 0.18, s * 0.48, s * 0.09, col)
        FillRect(g, cx - s * 0.15, cy + s * 0.26, s * 0.30, s * 0.08, col)
        FillRect(g, cx - s * 0.06, cy + s * 0.33, s * 0.12, s * 0.05, col)
        FillRect(g, cx - s * 0.12, cy - s * 0.26, s * 0.24, s * 0.055, dk)
        FillRect(g, cx - s * 0.12, cy - s * 0.08, s * 0.20, s * 0.055, dk)
        FillRect(g, cx - s * 0.12, cy + s * 0.10, s * 0.24, s * 0.055, dk)
        FillRect(g, cx - s * 0.12, cy - s * 0.26, s * 0.055, s * 0.42, dk)
    } else if (src = 'local') {
        FillRR(g, cx - s * 0.34, cy - s * 0.30, s * 0.68, s * 0.46, s * 0.06, col)
        FillRR(g, cx - s * 0.25, cy - s * 0.22, s * 0.50, s * 0.30, s * 0.03, dk)
        FillRect(g, cx - s * 0.08, cy + s * 0.16, s * 0.16, s * 0.09, col)
        FillRect(g, cx - s * 0.22, cy + s * 0.25, s * 0.44, s * 0.06, col)
    } else {
        FillRect(g, cx - s * 0.05, cy - s * 0.26, s * 0.10, s * 0.52, col)
        FillRect(g, cx - s * 0.26, cy - s * 0.05, s * 0.52, s * 0.10, col)
    }
}

; ============================================================== gdi+ helpers
RoundPath(x, y, w, h, r) {
    path := 0
    DllCall('gdiplus\GdipCreatePath', 'int', 0, 'ptr*', &path)
    d := r * 2
    DllCall('gdiplus\GdipAddPathArc', 'ptr', path, 'float', x, 'float', y, 'float', d, 'float', d, 'float', 180, 'float', 90)
    DllCall('gdiplus\GdipAddPathArc', 'ptr', path, 'float', x + w - d, 'float', y, 'float', d, 'float', d, 'float', 270, 'float', 90)
    DllCall('gdiplus\GdipAddPathArc', 'ptr', path, 'float', x + w - d, 'float', y + h - d, 'float', d, 'float', d, 'float', 0, 'float', 90)
    DllCall('gdiplus\GdipAddPathArc', 'ptr', path, 'float', x, 'float', y + h - d, 'float', d, 'float', d, 'float', 90, 'float', 90)
    DllCall('gdiplus\GdipClosePathFigure', 'ptr', path)
    return path
}
FillRR(g, x, y, w, h, r, argb) {
    path := RoundPath(x, y, w, h, r)
    br := 0
    DllCall('gdiplus\GdipCreateSolidFill', 'uint', argb, 'ptr*', &br)
    DllCall('gdiplus\GdipFillPath', 'ptr', g, 'ptr', br, 'ptr', path)
    DllCall('gdiplus\GdipDeleteBrush', 'ptr', br)
    DllCall('gdiplus\GdipDeletePath', 'ptr', path)
}
FillRect(g, x, y, w, h, argb) {
    br := 0
    DllCall('gdiplus\GdipCreateSolidFill', 'uint', argb, 'ptr*', &br)
    DllCall('gdiplus\GdipFillRectangle', 'ptr', g, 'ptr', br, 'float', x, 'float', y, 'float', w, 'float', h)
    DllCall('gdiplus\GdipDeleteBrush', 'ptr', br)
}
StrokeRR(g, x, y, w, h, r, argb, pw) {
    path := RoundPath(x, y, w, h, r)
    pen := 0
    DllCall('gdiplus\GdipCreatePen1', 'uint', argb, 'float', pw, 'int', 2, 'ptr*', &pen)
    DllCall('gdiplus\GdipDrawPath', 'ptr', g, 'ptr', pen, 'ptr', path)
    DllCall('gdiplus\GdipDeletePen', 'ptr', pen)
    DllCall('gdiplus\GdipDeletePath', 'ptr', path)
}
FillEllipse(g, x, y, w, h, argb) {
    br := 0
    DllCall('gdiplus\GdipCreateSolidFill', 'uint', argb, 'ptr*', &br)
    DllCall('gdiplus\GdipFillEllipse', 'ptr', g, 'ptr', br, 'float', x, 'float', y, 'float', w, 'float', h)
    DllCall('gdiplus\GdipDeleteBrush', 'ptr', br)
}
StrokeEllipse(g, x, y, w, h, argb, pw) {
    pen := 0
    DllCall('gdiplus\GdipCreatePen1', 'uint', argb, 'float', pw, 'int', 2, 'ptr*', &pen)
    DllCall('gdiplus\GdipDrawEllipse', 'ptr', g, 'ptr', pen, 'float', x, 'float', y, 'float', w, 'float', h)
    DllCall('gdiplus\GdipDeletePen', 'ptr', pen)
}
DrawTxt(g, txt, x, y, w, h, px, argb, center := true) {
    global NX
    f := GetFont(px, true)
    br := 0
    DllCall('gdiplus\GdipCreateSolidFill', 'uint', argb, 'ptr*', &br)
    rc := Buffer(16, 0)
    NumPut('float', x, rc, 0)
    NumPut('float', y, rc, 4)
    NumPut('float', w, rc, 8)
    NumPut('float', h, rc, 12)
    DllCall('gdiplus\GdipDrawString', 'ptr', g, 'wstr', txt, 'int', -1, 'ptr', f, 'ptr', rc
        , 'ptr', center ? NX['fmtc'] : NX['fmtl'], 'ptr', br)
    DllCall('gdiplus\GdipDeleteBrush', 'ptr', br)
}
HSL(hue, s, l) {
    c := (1 - Abs(2 * l - 1)) * s
    xx := c * (1 - Abs(Mod(hue / 60.0, 2) - 1))
    m := l - c / 2
    if (hue < 60) {
        rr := c
        gg := xx
        bb := 0
    } else if (hue < 120) {
        rr := xx
        gg := c
        bb := 0
    } else if (hue < 180) {
        rr := 0
        gg := c
        bb := xx
    } else if (hue < 240) {
        rr := 0
        gg := xx
        bb := c
    } else if (hue < 300) {
        rr := xx
        gg := 0
        bb := c
    } else {
        rr := c
        gg := 0
        bb := xx
    }
    return (Round((rr + m) * 255) << 16) | (Round((gg + m) * 255) << 8) | Round((bb + m) * 255)
}

SmoothStep(t) {
    ; 3t^2 - 2t^3  -  zero derivative at 0 and 1 for silky ease-in-out
    if (t <= 0)
        return 0
    if (t >= 1)
        return 1
    return t * t * (3 - 2 * t)
}

; ============================================================== actions
Nudge(step) {
    global NX
    if (NX['view'].Length < 2)
        return
    NX['act'] := A_TickCount
    NX['gdir'] := step > 0 ? 1 : -1
    NX['target'] := NX['target'] + step   ; wheel wraps, no ends to clamp
    Sfx('tick')
    NX['dirty'] := true
}
JumpTo(i) {
    global NX
    n := NX['view'].Length
    if !n
        return
    NX['act'] := A_TickCount
    i := Min(Max(i, 0), n - 1)
    delta := WrapDelta(i, NormIdx(NX['target'], n), n)
    if delta {
        NX['gdir'] := delta > 0 ? 1 : -1
        NX['target'] := NX['target'] + Round(delta)
        Sfx('tick')
    }
    NX['dirty'] := true
}
LaunchCurrent() {
    global NX
    if (NX['anim'] = 'close' || NX['anim'] = 'launch')
        return
    cur := Current()
    if !cur
        return
    if (cur['launch'] = '')
        return
    NX['lncmd'] := cur['launch']
    NX['lnwd'] := cur['workdir']
    NX['anim'] := 'launch'
    NX['anim0'] := A_TickCount
    Sfx('launch')
}
DoLaunch() {
    global NX
    cmd := NX['lncmd']
    wd := NX['lnwd']
    NX['lncmd'] := ''
    FinishHide()
    if (cmd = '')
        return
    DllCall('user32\AllowSetForegroundWindow', 'int', -1)
    try {
        if (wd != '' && DirExist(wd))
            Run(cmd, wd)
        else
            Run(cmd)
    }
}
ToggleFav() {
    global NX
    cur := Current()
    if !cur
        return
    ; capture the focused card's on-screen rect before the lists change
    src := 0
    ci := NormIdx(NX['pos'], NX['view'].Length)
    for rc in NX['rects'] {
        if (rc['t'] = 'v' && rc['i'] = ci)
            src := rc
    }
    cur['fav'] := !cur['fav']
    SaveCsv()
    RebuildView()
    if src {
        ; find where the game landed so the ghost knows its destination
        dtag := ''
        didx := -1
        for i2, g2 in NX['view'] {
            if (g2['id'] = cur['id']) {
                dtag := 'v'
                didx := i2 - 1
            }
        }
        if (dtag = '') {
            for i2, g2 in NX['oview'] {
                if (g2['id'] = cur['id']) {
                    dtag := 'o'
                    didx := i2 - 1
                }
            }
        }
        if (dtag != '') {
            ; rotate the destination deck so the card visibly arrives centred
            if (dtag = 'o' && NX['oview'].Length)
                NX['otarget'] := NX['otarget'] + WrapDelta(didx, NormIdx(NX['otarget'], NX['oview'].Length), NX['oview'].Length)
            else if (dtag = 'v' && NX['view'].Length)
                NX['target'] := NX['target'] + WrapDelta(didx, NormIdx(NX['target'], NX['view'].Length), NX['view'].Length)
            NX['fly'] := Map('game', cur, 'x', src['x'], 'y', src['y'], 'w', src['w'], 'h', src['h']
                , 't0', A_TickCount, 'tag', dtag, 'i', didx)
        }
        if cur['fav']
            NX['ripple'] := Map('x', src['x'] + src['w'] / 2, 'y', src['y'] + src['h'] / 2, 't0', A_TickCount)
    }
    Sfx('tick')
    NX['act'] := A_TickCount
    NX['dirty'] := true
}
HideCurrent() {
    global NX
    cur := Current()
    if !cur
        return
    cur['hidden'] := true
    SaveCsv()
    RebuildView()
    NX['act'] := A_TickCount
}
ShowCardMenu() {
    global NX
    if (NX['ptab'] || NX['repair'])      ; one panel at a time, always
        return
    if NX['sheet']
        CloseSheet()
    else
        OpenSheet()
}

; ============================================================== mouse
HitTest(lp) {
    global NX
    mx := lp & 0xFFFF
    my := (lp >> 16) & 0xFFFF
    i := NX['rects'].Length
    while (i >= 1) {
        rc := NX['rects'][i]
        if (mx >= rc['x'] && mx <= rc['x'] + rc['w'] && my >= rc['y'] && my <= rc['y'] + rc['h'])
            return rc
        i--
    }
    return 0
}
OnLClick(wp, lp, msg, hwnd) {
    global NX
    if (!NX['shown'] || hwnd != NX['hdraw'])
        return
    NX['act'] := A_TickCount
    ht := HitTest(lp)
    if !ht
        return
    if (ht['t'] = 'o') {
        SwitchDeck(NX['deck'] = 'fav' ? 1 : -1)
        JumpTo(ht['i'])
        return
    }
    if (Abs(WrapDelta(ht['i'], NX['pos'], NX['view'].Length)) < 0.5)
        LaunchCurrent()
    else
        JumpTo(ht['i'])
}
OnRClick(wp, lp, msg, hwnd) {
    global NX
    if (!NX['shown'] || hwnd != NX['hdraw'])
        return
    NX['act'] := A_TickCount
    ht := HitTest(lp)
    if !ht
        return
    if (ht['t'] = 'o')
        SwitchDeck(NX['deck'] = 'fav' ? 1 : -1)
    JumpTo(ht['i'])
    NX['pos'] := NX['target']   ; snap so the menu opens on the clicked card
    ShowCardMenu()
}

; ============================================================== keyboard
OverlayOn() {
    global NX
    return NX['shown']
}
#HotIf OverlayOn()
Left:: KbDo('nav', -1)
Right:: KbDo('nav', 1)
+Left:: KbDo('nav', -5)
+Right:: KbDo('nav', 5)
WheelUp:: KbDo('nav', -1)
WheelDown:: KbDo('nav', 1)
Up:: KbDo('deck', -1)
Down:: KbDo('deck', 1)
Home:: KbDo('home')
End:: KbDo('end')
Enter:: KbDo('go')
Space:: KbDo('go')
Escape:: KbDo('esc')
f:: KbDo('fav')
h:: KbDo('hide')
e:: KbDo('edit')
m:: KbDo('menu')
p:: KbDo('power')
Tab:: KbDo('power')
#HotIf

; ============================================================== controller
PadState(&btns, &lx) {
    global NX
    static st := Buffer(16, 0)
    btns := 0
    lx := 0
    if !NX['xifn'] {
        hm := DllCall('LoadLibrary', 'str', 'xinput1_4.dll', 'ptr')
        if !hm
            hm := DllCall('LoadLibrary', 'str', 'xinput1_3.dll', 'ptr')
        if !hm {
            NX['xifn'] := -1
        } else {
            fn := DllCall('GetProcAddress', 'ptr', hm, 'ptr', 100, 'ptr')
            if !fn
                fn := DllCall('GetProcAddress', 'ptr', hm, 'astr', 'XInputGetState', 'ptr')
            NX['xifn'] := fn ? fn : -1
        }
    }
    if (NX['xifn'] = -1)
        return false
    i := 0
    while (i < 4) {
        if !DllCall(NX['xifn'], 'uint', i, 'ptr', st) {
            btns := NumGet(st, 4, 'ushort')
            lx := NumGet(st, 8, 'short')
            return true
        }
        i++
    }
    return false
}
PadPoll() {
    global NX
    btns := 0
    lx := 0
    if !PadState(&btns, &lx) {
        NX['btns'] := 0
        return
    }
    prev := NX['btns']
    if (btns != prev || Abs(lx) > 9830)
        NX['input'] := 'pad'
    guide := (btns & 0x0400) != 0
    if (guide && !NX['guide']) {
        NX['guide'] := guide
        NX['btns'] := btns
        ToggleOverlay()
        return
    }
    NX['guide'] := guide
    if !NX['shown'] {
        NX['btns'] := btns
        return
    }
    if (btns != prev)
        NX['act'] := A_TickCount
    if ((btns & 0x0020) && !(prev & 0x0020) && !NX['sheet'] && !NX['repair'])
        TogglePower()                       ; View/Back button -> power tab
    if ((btns & 0x10) && !(prev & 0x10)) {
        NX['btns'] := btns
        HideOverlay()
        return
    }
    if ((btns & 0x2000) && !(prev & 0x2000)) {
        NX['btns'] := btns
        PadBack()
        return
    }
    if ((btns & 0x1000) && !(prev & 0x1000)) {
        NX['btns'] := btns
        PadConfirm()
        return
    }
    if ((btns & 0x4000) && !(prev & 0x4000) && !NX['ptab'] && !NX['sheet'] && !NX['repair'])
        ToggleFav()
    if ((btns & 0x8000) && !(prev & 0x8000) && !NX['ptab'] && !NX['repair'])
        ShowCardMenu()                    ; Y opens the game action sheet
    if ((btns & 0x1) && !(prev & 0x1))
        PadUpDown(-1)
    if ((btns & 0x2) && !(prev & 0x2))
        PadUpDown(1)
    if ((btns & 0x100) && !(prev & 0x100) && !NX['ptab'] && !NX['sheet'] && !NX['repair'])
        Nudge(-5)
    if ((btns & 0x200) && !(prev & 0x200) && !NX['ptab'] && !NX['sheet'] && !NX['repair'])
        Nudge(5)
    step := 0
    if ((btns & 0x4) || lx < -9830)
        step := -1
    else if ((btns & 0x8) || lx > 9830)
        step := 1
    if step {
        if (step != NX['navdir']) {
            NX['navdir'] := step
            NX['navrep'] := A_TickCount + 340
            if (!NX['ptab'] && !NX['sheet'] && !NX['repair'])
                Nudge(step)
        } else if (A_TickCount >= NX['navrep']) {
            NX['navrep'] := A_TickCount + 130
            if (!NX['ptab'] && !NX['sheet'] && !NX['repair'])
                Nudge(step)
        }
    } else {
        NX['navdir'] := 0
    }
    NX['btns'] := btns
}
SaveCsv() {
    global NX
    out := 'id,title,source,launch,workdir,cover,fav,hidden`r`n'
    out .= '# Edit this file to add/remove/change games. Set hidden=1 to remove a game from the wheel.`r`n'
    for g in NX['games'] {
        out .= CsvEscape(g['id']) ',' CsvEscape(g['title']) ',' CsvEscape(g['source']) ','
            . CsvEscape(g['launch']) ',' CsvEscape(g['workdir']) ',' CsvEscape(PortableCover(g['cover'])) ','
            . (g['fav'] ? '1' : '0') ',' (g['hidden'] ? '1' : '0') '`r`n'
    }
    try {
        if !DirExist(NX['data'])
            DirCreate(NX['data'])
        tmp := NX['csv'] '.tmp'
        if FileExist(tmp)
            FileDelete(tmp)
        FileAppend(out, tmp, 'UTF-8')
        if FileExist(NX['csv'])
            FileDelete(NX['csv'])
        FileMove(tmp, NX['csv'])
    }
}

; ------------------------------------------------------------------
;  v1.3  -  sounds, dynamic hints, power tab
; ------------------------------------------------------------------

Sfx(name) {
    ; every alias is opened and primed BEFORE first use (see WarmSfx), so a
    ; play is just 'play from 0' on a hot device - no 200-300 ms spin-up that
    ; used to swallow the head of the clip (most audible on the launch sting)
    global NX
    if (NX['vol'] <= 0)
        return
    if !SfxReady(name)
        return
    DllCall('winmm\mciSendStringW', 'wstr', 'play lud' name ' from 0', 'ptr', 0, 'uint', 0, 'ptr', 0, 'uint')
}
SfxReady(name) {
    ; opens the MCI alias once and plays a 1-millisecond slice through it.
    ; that inaudible blip forces the device + the Windows audio endpoint fully
    ; awake, so the first REAL play starts at sample zero instead of midway
    global NX
    ok := NX['sfxok']
    if ok.Has(name)
        return ok[name]
    p := NX['dir'] '\sfx\' name '.wav'
    if !FileExist(p) {
        ok[name] := false
        return false
    }
    rc := DllCall('winmm\mciSendStringW', 'wstr', 'open "' p '" type waveaudio alias lud' name, 'ptr', 0, 'uint', 0, 'ptr', 0, 'uint')
    if (rc != 0) {
        ; MCI unavailable: remember the file path for the wide-char fallback
        ok[name] := false
        return false
    }
    DllCall('winmm\mciSendStringW', 'wstr', 'set lud' name ' time format milliseconds', 'ptr', 0, 'uint', 0, 'ptr', 0, 'uint')
    DllCall('winmm\mciSendStringW', 'wstr', 'play lud' name ' from 0 to 1', 'ptr', 0, 'uint', 0, 'ptr', 0, 'uint')
    ok[name] := true
    return true
}
WarmSfx() {
    ; open + prime every clip up front, then hold the audio endpoint open with
    ; a looping silence stream. Windows (and Bluetooth gear) parks an idle
    ; device in under ten seconds - that park/wake was the 0.2 s head loss
    for name in ['open', 'close', 'tick', 'launch']
        SfxReady(name)
    StartSilentStream()
    if !NX['hwo'] {              ; no wave device at all -> old-school silent ping
        KeepAudioAwake()
        SetTimer(KeepAudioAwake, 5000)
    }
}
KeepAudioAwake() {
    ; fallback when waveOut is unavailable: a short silent ping, self-healing
    global NX
    p := EnsureSilence()
    if (p = '')
        return
    ok := NX['sfxok']
    if !ok.Has('silence') {
        rc := DllCall('winmm\mciSendStringW', 'wstr', 'open "' p '" type waveaudio alias ludsilence', 'ptr', 0, 'uint', 0, 'ptr', 0, 'uint')
        ok['silence'] := (rc = 0)
    }
    if ok['silence']
        DllCall('winmm\mciSendStringW', 'wstr', 'play ludsilence from 0', 'ptr', 0, 'uint', 0, 'ptr', 0, 'uint')
}
StartSilentStream() {
    ; the real fix: a looping 0.5 s silence buffer on a waveOut stream that
    ; stays open for the life of the app. The Windows audio engine never goes
    ; idle while any client streams, so the endpoint can never park and every
    ; MCI play starts instantly at sample zero - no clipped head, ever.
    global NX
    if NX['hwo']
        return
    fmt := Buffer(18, 0)                        ; WAVEFORMATEX, PCM 22050 Hz mono 16-bit
    NumPut('ushort', 1, fmt, 0)
    NumPut('ushort', 1, fmt, 2)
    NumPut('uint', 22050, fmt, 4)
    NumPut('uint', 44100, fmt, 8)               ; avg bytes per second
    NumPut('ushort', 2, fmt, 12)                ; block align
    NumPut('ushort', 16, fmt, 14)               ; bits per sample
    hwo := 0
    if DllCall('winmm\waveOutOpen', 'ptr*', &hwo, 'uint', 0xFFFFFFFF, 'ptr', fmt, 'ptr', 0, 'ptr', 0, 'uint', 0)
        return                                  ; WAVE_MAPPER refused -> caller falls back
    data := Buffer(22050, 0)                    ; 0.5 s of digital black
    hdr := Buffer(A_PtrSize = 8 ? 48 : 32, 0)   ; WAVEHDR (x64 / x86 layout)
    NumPut('ptr', data.Ptr, hdr, 0)
    NumPut('uint', data.Size, hdr, 8)
    NumPut('uint', 0x4 | 0x8, hdr, A_PtrSize = 8 ? 24 : 16)   ; BEGINLOOP | ENDLOOP
    NumPut('uint', 0xFFFFFFFF, hdr, A_PtrSize = 8 ? 28 : 20)  ; loop forever
    if DllCall('winmm\waveOutPrepareHeader', 'ptr', hwo, 'ptr', hdr, 'uint', hdr.Size)
        return
    if DllCall('winmm\waveOutWrite', 'ptr', hwo, 'ptr', hdr, 'uint', hdr.Size)
        return
    NX['hwo'] := hwo                            ; keep handle + buffers alive
    NX['hwofmt'] := fmt
    NX['hwodata'] := data
    NX['hwohdr'] := hdr
}
EnsureSilence() {
    ; writes sfx\silence.wav if it is missing, so script-only updates self-heal
    global NX
    p := NX['dir'] '\sfx\silence.wav'
    if FileExist(p)
        return p
    n := 11025                                  ; 0.5 s at 22050 Hz, mono 16-bit
    b := Buffer(44 + n * 2, 0)
    NumPut('uint', 0x46464952, b, 0)            ; 'RIFF'
    NumPut('uint', 36 + n * 2, b, 4)
    NumPut('uint', 0x45564157, b, 8)            ; 'WAVE'
    NumPut('uint', 0x20746D66, b, 12)           ; 'fmt '
    NumPut('uint', 16, b, 16)
    NumPut('ushort', 1, b, 20)                  ; PCM
    NumPut('ushort', 1, b, 22)                  ; mono
    NumPut('uint', 22050, b, 24)
    NumPut('uint', 44100, b, 28)                ; byte rate
    NumPut('ushort', 2, b, 32)                  ; block align
    NumPut('ushort', 16, b, 34)                 ; bits
    NumPut('uint', 0x61746164, b, 36)           ; 'data'
    NumPut('uint', n * 2, b, 40)
    try {
        f := FileOpen(p, 'w')
        f.RawWrite(b)
        f.Close()
    } catch
        return ''
    return p
}

KbDo(what, arg := 0) {
    global NX
    NX['input'] := 'kb'
    NX['act'] := A_TickCount
    if NX['repair'] {
        if (what = 'deck' || what = 'nav')
            RepairNav(arg < 0 ? -1 : 1)
        else if (what = 'go')
            RepairGo()
        else if (what = 'esc')
            CloseRepair()
        return
    }
    if NX['sheet'] {
        if (what = 'deck')
            SheetNav(arg)
        else if (what = 'go')
            SheetGo()
        else if (what = 'esc' || what = 'menu')
            CloseSheet()
        return
    }
    if NX['ptab'] {
        ; power tab owns the keyboard: every other shortcut is dead until it closes
        if (what = 'deck')
            PowerNav(arg)
        else if (what = 'go')
            PowerGo()
        else if (what = 'esc' || what = 'power')
            TogglePower()
        return
    }
    if (what = 'nav')
        Nudge(arg)
    else if (what = 'deck')
        SwitchDeck(arg)
    else if (what = 'home')
        JumpTo(0)
    else if (what = 'end')
        JumpTo(99999)
    else if (what = 'go')
        LaunchCurrent()
    else if (what = 'esc')
        HideOverlay()
    else if (what = 'fav')
        ToggleFav()
    else if (what = 'hide')
        HideCurrent()
    else if (what = 'edit')
        OpenCsv()
    else if (what = 'menu')
        ShowCardMenu()
    else if (what = 'power')
        TogglePower()
}

TogglePower() {
    global NX
    if (!NX['ptab'] && (NX['sheet'] || NX['repair']))   ; one panel at a time
        return
    NX['ptab'] := !NX['ptab']
    NX['pt0'] := A_TickCount            ; drives the slide-in / slide-out
    NX['pconf'] := 0
    NX['act'] := A_TickCount
    Sfx('tick')
}

PowerNav(d) {
    global NX
    was := NX['psel']
    NX['psel'] := Min(Max(NX['psel'] + d, 1), 4)
    NX['pconf'] := 0
    NX['act'] := A_TickCount
    if (NX['psel'] != was)
        Sfx('tick')
}

PowerGo() {
    ; pressing only ARMS the action - you must hold the key while the bar
    ; sweeps left to right; releasing early cancels (see PowerHoldP)
    global NX
    if !NX['pconf']
        NX['pconf'] := A_TickCount
}

; bottom hint bar - key cap on top, instruction stacked beneath
DrawHints(g, w, h) {
    global NX
    ih := IntroE(850, 650)
    if (ih <= 0.01)
        return
    y := h - 80 + 16 * (1 - ih)
    if (NX['input'] = 'pad') {
        if NX['repair']
            items := [['A', 0xFF44A83C, 'PICK FILE'], ['B', 0xFFCC4444, 'BACK']]
        else if NX['sheet']
            items := [['A', 0xFF44A83C, 'SELECT'], ['B', 0xFFCC4444, 'BACK']]
        else if NX['ptab']
            items := [['A', 0xFF44A83C, 'HOLD'], ['B', 0xFFCC4444, 'BACK']]
        else
            items := [['A', 0xFF44A83C, 'PLAY'], ['B', 0xFFCC4444, 'CLOSE'], ['X', 0xFF4E8FE0, 'FAV'], ['Y', 0xFFD8B840, 'ACTIONS'], ['VIEW', 0xFF7E8AA0, 'POWER']]
        tw := 0
        for it in items
            tw += Max(34, StrLen(it[3]) * 8 + 12) + 30
        tw -= 30
        x := (w - tw) / 2
        for it in items {
            iw := Max(34, StrLen(it[3]) * 8 + 12)
            ca := (Round(0xFF * ih) << 24) | (it[2] & 0xFFFFFF)
            bw := (StrLen(it[1]) > 1) ? 40 : 26
            kx := x + (iw - bw) / 2                     ; button centred over its label
            if (StrLen(it[1]) > 1) {                    ; pill-shaped View button
                FillRR(g, kx, y + 2, 40, 22, 11, ca)
                DrawTxt(g, it[1], kx - 2, y + 6, 44, 16, 9, (Round(0xF0 * ih) << 24) | 0x0E1116)
            } else {                                    ; coloured face button
                FillEllipse(g, kx, y, 26, 26, ca)
                DrawTxt(g, it[1], kx, y + 4, 26, 19, 12, (Round(0xF0 * ih) << 24) | 0x0E1116)
            }
            DrawTxt(g, it[3], x, y + 32, iw, 16, 9.5, (Round(0x92 * ih) << 24) | 0xC8DCF4)
            x += iw + 30
        }
    } else {
        if NX['repair']
            items := [['ENTER', 'PICK FILE'], ['UP/DOWN', 'SLOT'], ['ESC', 'BACK']]
        else if NX['sheet']
            items := [['UP/DOWN', 'CHOOSE'], ['ENTER', 'SELECT'], ['ESC', 'CLOSE']]
        else if NX['ptab']
            items := [['UP/DOWN', 'CHOOSE'], ['HOLD ENTER', 'CONFIRM'], ['P', 'CLOSE']]
        else
            items := [['ENTER', 'PLAY'], ['M', 'ACTIONS'], ['F', 'FAV'], ['P', 'POWER'], ['ESC', 'CLOSE']]
        tw := 0
        for it in items {
            kw := 18 + StrLen(it[1]) * 9
            tw += Max(kw, StrLen(it[2]) * 8 + 12) + 30
        }
        tw -= 30
        x := (w - tw) / 2
        for it in items {
            kw := 18 + StrLen(it[1]) * 9                ; plain squircle key, uncoloured
            iw := Max(kw, StrLen(it[2]) * 8 + 12)
            kx := x + (iw - kw) / 2                     ; key cap centred over its label
            FillRR(g, kx, y, kw, 26, 8, (Round(0x24 * ih) << 24) | 0xFFFFFF)
            StrokeRR(g, kx, y, kw, 26, 8, (Round(0x42 * ih) << 24) | 0xFFFFFF, 1)
            DrawTxt(g, it[1], kx, y + 6, kw, 18, 10.5, (Round(0xE2 * ih) << 24) | 0xEAF2FF)
            DrawTxt(g, it[2], x, y + 32, iw, 16, 9.5, (Round(0x92 * ih) << 24) | 0xC8DCF4)
            x += iw + 30
        }
    }
}

; small system tab, bottom-right: lock / sleep / restart / shutdown
DrawPowerTab(g, w, h, accent) {
    ; vertical system panel that slides in from the right edge -
    ; solid blackhole plate, selected row wears the same rim glow as the globe
    global NX
    sp := NX['pt0'] ? SmoothStep(Min((A_TickCount - NX['pt0']) / 480.0, 1.0)) : 1.0
    vis := NX['ptab'] ? sp : 1 - sp
    if (vis <= 0.01)
        return
    pw := 236
    px := w - pw * vis
    py := h - 396
    HolePanel(g, px, py, pw + 24, 304, 16, accent, vis)
    DrawTxt(g, 'POWER', px + 24, py + 16, 120, 18, 10, (Round(0xB0 * vis) << 24) | 0xEAF2FF, false)
    names := ['LOCK', 'SLEEP', 'RESTART', 'SHUT DOWN']
    i := 1
    while (i <= 4) {
        y := py + 48 + (i - 1) * 60
        sel := (NX['psel'] = i)
        rw := pw - 32
        rx := px + 16
        if sel {
            HoleRow(g, rx, y, rw, 50, 10, accent, vis)
            if NX['pconf'] {
                hp := SmoothStep(PowerHoldP())          ; ease the fill so it glides
                if (hp > 0.01) {
                    bw := Max(rw * hp, 8)
                    FillRR(g, rx, y, bw, 50, 10, (Round(0x55 * vis) << 24) | (accent & 0xFFFFFF))
                    ; soft leading edge so the bar never looks stepped
                    FillRR(g, rx + Max(bw - 18, 0), y, Min(18, bw), 50, 10, (Round(0x38 * vis * hp) << 24) | 0xFFFFFF)
                }
            }
        } else
            FillRR(g, rx, y, rw, 50, 10, (Round(0x10 * vis) << 24) | 0xFFFFFF)
        ic := sel ? ((Round(0xF2 * vis) << 24) | 0xFFFFFF) : ((Round(0x8C * vis) << 24) | 0xDCECFF)
        DrawPowerIcon(g, i, px + 42, y + 25, ic)
        DrawTxt(g, names[i], px + 66, y + 19, pw - 88, 18, 9.5
            , sel ? ((Round(0xF0 * vis) << 24) | 0xEAF2FF) : ((Round(0x86 * vis) << 24) | 0xC8DCF4), false)
        i++
    }
}

DrawPowerIcon(g, kind, cx, cy, col) {
    if (kind = 1) {                                     ; padlock
        StrokeArc(g, cx - 5, cy - 10, 10, 11, 180, 180, col, 1.7)
        FillRR(g, cx - 8, cy - 3, 16, 11, 3, col)
    } else if (kind = 2) {                              ; sleep
        DrawTxt(g, 'zZ', cx - 11, cy - 9, 24, 18, 10, col)
    } else if (kind = 3) {                              ; restart: circular arrow
        StrokeArc(g, cx - 7, cy - 7, 14, 14, -55, 285, col, 1.7)
        StrokeLine(g, cx - 4.5, cy - 5.4, cx - 9.2, cy - 6.4, col, 1.7)
        StrokeLine(g, cx - 4.5, cy - 5.4, cx - 5.4, cy - 0.8, col, 1.7)
    } else {                                            ; power symbol
        StrokeArc(g, cx - 7, cy - 7, 14, 14, 300, 300, col, 1.7)
        FillRect(g, cx - 1.2, cy - 12, 2.6, 9, col)
    }
}

StrokeArc(g, x, y, w, h, a1, sweep, argb, pw) {
    pen := 0
    DllCall('gdiplus\GdipCreatePen1', 'uint', argb, 'float', pw, 'int', 2, 'ptr*', &pen)
    DllCall('gdiplus\GdipDrawArc', 'ptr', g, 'ptr', pen, 'float', x, 'float', y, 'float', w, 'float', h, 'float', a1, 'float', sweep)
    DllCall('gdiplus\GdipDeletePen', 'ptr', pen)
}

StrokeLine(g, x1, y1, x2, y2, argb, pw) {
    pen := 0
    DllCall('gdiplus\GdipCreatePen1', 'uint', argb, 'float', pw, 'int', 2, 'ptr*', &pen)
    DllCall('gdiplus\GdipDrawLine', 'ptr', g, 'ptr', pen, 'float', x1, 'float', y1, 'float', x2, 'float', y2)
    DllCall('gdiplus\GdipDeletePen', 'ptr', pen)
}

ShowAbout() {
    global NX
    t := 'Ludoria v1.21  -  a Hotshot tool`n(c) 2026 Hotshot`n`n'
    t .= 'Fullscreen acrylic game-launcher overlay for Windows 11.`n`n'
    t .= 'Summon:      F7  /  controller Guide button`n'
    t .= 'Browse:      Left-Right, mouse wheel, stick, d-pad`n'
    t .= 'Decks:       Up = favourites,  Down = library`n'
    t .= 'Launch:      Enter / Space / A / click centre card`n'
    t .= 'Favourite:   F / X          Hide: H`n'
    t .= 'Power tab:   P / Tab / View  (hold to confirm)`n'
    t .= 'Actions:     M / Y  (fav, rescan, repair, edit CSV)`n`n'
    t .= 'Library file:`n' NX['csv'] '`n`n'
    t .= 'Covers live in data\art\ (relative paths - the folder is portable).'
    MsgBox(t, 'About Ludoria', '0x40')
}
UpdateGlobeTitle(id, title) {
    global NX
    key := id '|' title
    if (key = NX['gtitle'])
        return
    first := (NX['gtitle'] = '')
    NX['gtitle'] := key
    NX['gt0'] := A_TickCount
    ; the very first reveal lands exactly at the end of the 1.5s intro
    NX['gdelay'] := (first && NX['anim'] = 'open') ? 1500 : 0
}
GetLogo(game) {
    ; Friendly name first, then legacy ID name. Reload clears the cache, so a
    ; manually added Game Name_logo.png/jpg is picked up automatically.
    global NX
    key := 'logo|' game['id']
    if NX['imgs'].Has(key)
        return NX['imgs'][key]
    rec := 0
    p := FindNamedArt(game, 'logo', ['png', 'jpg', 'jpeg'])
    bm := LoadArtFile(p)
    if bm {
        iw := 0
        ih := 0
        DllCall('gdiplus\GdipGetImageWidth', 'ptr', bm, 'uint*', &iw)
        DllCall('gdiplus\GdipGetImageHeight', 'ptr', bm, 'uint*', &ih)
        if (iw > 0 && ih > 0)
            rec := Map('bm', bm, 'w', iw, 'h', ih)
    }
    NX['imgs'][key] := rec
    return rec
}
DrawImgA(g, bm, x, y, w, h, iw, ih, alpha) {
    ; draws an image at a given opacity via a color matrix (for logo fades)
    static ia := 0
    if !ia
        DllCall('gdiplus\GdipCreateImageAttributes', 'ptr*', &ia)
    cm := Buffer(100, 0)
    NumPut('float', 1.0, cm, 0)
    NumPut('float', 1.0, cm, 24)
    NumPut('float', 1.0, cm, 48)
    NumPut('float', alpha, cm, 72)
    NumPut('float', 1.0, cm, 96)
    DllCall('gdiplus\GdipSetImageAttributesColorMatrix', 'ptr', ia, 'int', 0, 'int', 1, 'ptr', cm, 'ptr', 0, 'int', 0)
    DllCall('gdiplus\GdipDrawImageRectRect', 'ptr', g, 'ptr', bm
        , 'float', x, 'float', y, 'float', w, 'float', h
        , 'float', 0, 'float', 0, 'float', iw, 'float', ih
        , 'int', 2, 'ptr', ia, 'ptr', 0, 'ptr', 0)
}
DrawGlobe(g, w, h, accent, cur) {
    ; Drawn as vector gradients straight onto the full-resolution canvas:
    ; there is no cached bitmap, so nothing is ever upscaled (no pixelation)
    ; and there are no bitmap borders that could slide into view while the
    ; sphere grows or shrinks. The crescent comes from occlusion: a radial
    ; sigma-bell glow sits behind the disc, offset a touch below-left, and
    ; the disc hides its core - full circles only, no arcs, no chords.
    global NX
    t := A_TickCount
    scale := 1.0
    a := NX['anim']
    el := t - NX['anim0']
    if (a = 'open') {
        p := Min(el / 1400.0, 1.0)
        scale := 1.85 - 0.85 * (1 - (1 - p) ** 3)
    } else if (a = 'close' || a = 'launch') {
        p := Min(el / 420.0, 1.0)
        scale := 1.0 + 1.1 * p * p
    }
    scale := scale * (1.0 + 0.010 * Sin(t / 2600.0))    ; slow, subtle breathing
    r := h * 0.62 * scale
    cx := w * 0.80                 ; sphere centre is anchored on screen
    cy := -h * 0.1116
    off := r * 0.052
    ax := cx - off * 0.3           ; glow centre, slightly below-left
    ay := cy + off
    ; outer halo: one smooth radial gradient peaking right at the rim and
    ; fading over ~0.45 r outward - wide spread, zero banding
    GlowFill(g, ax, ay, r * 1.45, (0x62 << 24) | (accent & 0xFFFFFF), 0.31)
    ; the sphere itself: crisp anti-aliased vector edge at every scale
    FillEllipse(g, cx - r, cy - r, r * 2, r * 2, 0xFA050810)
    FillEllipse(g, cx - r + 2, cy - r + 2, r * 2 - 4, r * 2 - 4, 0xFF04060C)
    ; inner bloom: bright at the rim melting toward the core, clipped inside
    path := 0
    DllCall('gdiplus\GdipCreatePath', 'int', 0, 'ptr*', &path)
    DllCall('gdiplus\GdipAddPathEllipse', 'ptr', path, 'float', cx - r, 'float', cy - r, 'float', r * 2, 'float', r * 2)
    DllCall('gdiplus\GdipSetClipPath', 'ptr', g, 'ptr', path, 'int', 0)
    RimFill(g, ax, ay, r * 1.02, (0x3E << 24) | (accent & 0xFFFFFF))
    DllCall('gdiplus\GdipResetClip', 'ptr', g)
    DllCall('gdiplus\GdipDeletePath', 'ptr', path)
    ; soft warm heart of the crescent - wide pens, low alpha, no crisp line
    StrokeEllipse(g, ax - r - 3, ay - r - 3, r * 2 + 6, r * 2 + 6, 0x2A000000 | (accent & 0xFFFFFF), Max(9 * scale, 6))
    StrokeEllipse(g, ax - r, ay - r, r * 2, r * 2, 0x1CFFFFFF, Max(5.5 * scale, 4))
    ; game logo inside the dark sphere: a simple fade + settle, nothing fancy
    if !cur
        return
    age := t - NX['gt0'] - NX['gdelay']
    if (NX['gtitle'] = '' || age < 0)
        return
    e := SmoothStep(Min(age / 300.0, 1.0))
    rec := GetLogo(cur)
    if IsObject(rec) {
        s := Min(h * 0.44 / rec['w'], h * 0.15 / rec['h'])
        if (a = 'launch')
            s := s * (1 + 0.35 * SmoothStep(Min(el / 420.0, 1.0)))
        lw := rec['w'] * s
        lh := rec['h'] * s
        lx := w * 0.80 - lw / 2
        ly := h * 0.105 - lh / 2 + NX['gdir'] * 10 * (1 - e)
        DrawImgA(g, rec['bm'], lx, ly, lw, lh, rec['w'], rec['h'], e)
        return
    }
    ; no logo: keep it clean and show only the game name. If the user later
    ; drops Game Name_logo.png into data\art, reload picks it up instead.
    tw := h * 0.62
    tx := w * 0.80 - tw / 2
    ty := h * 0.055 + NX['gdir'] * 9 * (1 - e)
    ta := Round(190 * e)
    px2 := Min(h * 0.042, 38)
    est := StrLen(cur['title']) * px2 * 0.62
    if (est > tw) {
        ; marquee, only when the name does not fit: a slow glide across
        span := est - tw
        mp := (Sin(t / 2600.0) + 1) / 2
        DllCall('gdiplus\GdipSetClipRect', 'ptr', g, 'float', tx, 'float', ty, 'float', tw, 'float', h * 0.11, 'int', 0)
        DrawTxtD(g, StrUpper(cur['title']), tx - span * mp, ty, est + 40, h * 0.11, px2, (ta << 24) | 0xF2F7FF, false)
        DllCall('gdiplus\GdipResetClip', 'ptr', g)
    } else
        DrawTxtD(g, StrUpper(cur['title']), tx, ty, tw, h * 0.11, px2, (ta << 24) | 0xF2F7FF)
}
GlowFill(g, gx, gy, rad, argb, focus) {
    ; radial glow via PathGradient with a sigma bell: peak brightness sits at
    ; the focus fraction (0 = edge, 1 = centre) and melts smoothly both ways
    path := 0
    DllCall('gdiplus\GdipCreatePath', 'int', 0, 'ptr*', &path)
    DllCall('gdiplus\GdipAddPathEllipse', 'ptr', path, 'float', gx - rad, 'float', gy - rad, 'float', rad * 2, 'float', rad * 2)
    br := 0
    DllCall('gdiplus\GdipCreatePathGradientFromPath', 'ptr', path, 'ptr*', &br)
    DllCall('gdiplus\GdipSetPathGradientCenterColor', 'ptr', br, 'uint', argb)
    sc := Buffer(4, 0)
    NumPut('uint', argb & 0xFFFFFF, sc, 0)     ; same hue, alpha 0 at the edge
    cnt := Buffer(4, 0)
    NumPut('int', 1, cnt, 0)
    DllCall('gdiplus\GdipSetPathGradientSurroundColorsWithCount', 'ptr', br, 'ptr', sc, 'ptr', cnt)
    DllCall('gdiplus\GdipSetPathGradientSigmaBlend', 'ptr', br, 'float', focus, 'float', 1.0)
    DllCall('gdiplus\GdipFillPath', 'ptr', g, 'ptr', br, 'ptr', path)
    DllCall('gdiplus\GdipDeleteBrush', 'ptr', br)
    DllCall('gdiplus\GdipDeletePath', 'ptr', path)
}
RimFill(g, gx, gy, rad, argb) {
    ; inverse radial glow: full colour at the rim, transparent at the centre
    path := 0
    DllCall('gdiplus\GdipCreatePath', 'int', 0, 'ptr*', &path)
    DllCall('gdiplus\GdipAddPathEllipse', 'ptr', path, 'float', gx - rad, 'float', gy - rad, 'float', rad * 2, 'float', rad * 2)
    br := 0
    DllCall('gdiplus\GdipCreatePathGradientFromPath', 'ptr', path, 'ptr*', &br)
    DllCall('gdiplus\GdipSetPathGradientCenterColor', 'ptr', br, 'uint', argb & 0xFFFFFF)
    sc := Buffer(4, 0)
    NumPut('uint', argb, sc, 0)
    cnt := Buffer(4, 0)
    NumPut('int', 1, cnt, 0)
    DllCall('gdiplus\GdipSetPathGradientSurroundColorsWithCount', 'ptr', br, 'ptr', sc, 'ptr', cnt)
    DllCall('gdiplus\GdipFillPath', 'ptr', g, 'ptr', br, 'ptr', path)
    DllCall('gdiplus\GdipDeleteBrush', 'ptr', br)
    DllCall('gdiplus\GdipDeletePath', 'ptr', path)
}
DrawFly(g) {
    ; ghost card gliding from one deck to the other after (un)favouriting
    global NX
    fly := NX['fly']
    if !IsObject(fly)
        return
    fp := (A_TickCount - fly['t0']) / 450.0
    if (fp >= 1) {
        NX['fly'] := 0
        return
    }
    dst := 0
    for rc in NX['rects'] {
        if (rc['t'] = fly['tag'] && rc['i'] = fly['i'])
            dst := rc
    }
    if !dst {
        NX['fly'] := 0
        return
    }
    e := SmoothStep(Min(Max(fp, 0.0), 1.0))
    fx := fly['x'] + (dst['x'] - fly['x']) * e
    fy := fly['y'] + (dst['y'] - fly['y']) * e
    fw := fly['w'] + (dst['w'] - fly['w']) * e
    fh := fly['h'] + (dst['h'] - fly['h']) * e
    ; arc the path upward a little so it reads as a toss, not a slide
    fy := fy - Sin(e * 3.14159) * 60
    fr := 16 * (fw / NX['cw'])
    FillRR(g, fx + 3, fy + 7, fw, fh, fr, 0x66000000)
    FillRR(g, fx, fy, fw, fh, fr, 0xF00C1119)
    bm := GetArt(fly['game'])
    if bm
        DrawCover(g, bm, fx, fy, fw, fh, fr)
    else
        DrawMono(g, fly['game'], fx, fy, fw, fh, fr)
    StrokeRR(g, fx, fy, fw, fh, fr, 0xC8FFFFFF, 1.6)
}

DrawTxtD(g, txt, x, y, w, h, px, argb, center := true) {
    ; display-face text (Bahnschrift / Segoe UI Semilight) for premium titles
    global NX
    if !NX['famd'] {
        DrawTxt(g, txt, x, y, w, h, px, argb, center)
        return
    }
    key := 'd' px
    if NX['fonts'].Has(key)
        f := NX['fonts'][key]
    else {
        f := 0
        DllCall('gdiplus\GdipCreateFont', 'ptr', NX['famd'], 'float', px, 'int', 0, 'int', 2, 'ptr*', &f)
        NX['fonts'][key] := f
    }
    br := 0
    DllCall('gdiplus\GdipCreateSolidFill', 'uint', argb, 'ptr*', &br)
    rc := Buffer(16, 0)
    NumPut('float', x, rc, 0)
    NumPut('float', y, rc, 4)
    NumPut('float', w, rc, 8)
    NumPut('float', h, rc, 12)
    DllCall('gdiplus\GdipDrawString', 'ptr', g, 'wstr', txt, 'int', -1, 'ptr', f, 'ptr', rc
        , 'ptr', center ? NX['fmtc'] : NX['fmtl'], 'ptr', br)
    DllCall('gdiplus\GdipDeleteBrush', 'ptr', br)
}

DisposeImgs() {
    global NX
    for , v in NX['imgs'] {
        if IsObject(v) {
            try DllCall('gdiplus\GdipDisposeImage', 'ptr', v['bm'])
        } else if v {
            try DllCall('gdiplus\GdipDisposeImage', 'ptr', v)
        }
    }
    NX['imgs'] := Map()
}
DisposeBg() {
    global NX
    for , rec in NX['bg'] {
        if (IsObject(rec) && rec[1])
            try DllCall('gdiplus\GdipDisposeImage', 'ptr', rec[1])
    }
    NX['bg'] := Map()
}
FreeVisuals() {
    ; called when the overlay hides: drop every cached bitmap, the globe and
    ; the full-screen canvas, then trim the working set. Idle RAM shrinks to
    ; the bare script; everything is rebuilt lazily on the next summon.
    global NX
    DisposeImgs()
    DisposeBg()
    NX['artfl'] := 0
    FreeSurface()
    try DllCall('psapi\EmptyWorkingSet', 'ptr', DllCall('GetCurrentProcess', 'ptr'))
}

OpenArtDir() {
    global NX
    try DirCreate(NX['data'] '\art')
    Run('explorer.exe "' NX['data'] '\art"')
}

NightWatch() {
    ; Suite lesson (Hotshot tools v1.4 'night watch'): Windows silently
    ; removes a low-level hook whose callback times out - after sleep/resume
    ; or one laggy moment the script LOOKS alive but every hotkey is deaf.
    ; Force-reinstalling both hooks every 5 minutes makes long-running
    ; installs immortal; friends' PCs included.
    if A_IsSuspended
        return
    InstallKeybdHook(true, true)
    InstallMouseHook(true, true)
}
OnPowerBroadcast(wp, lp, msg, hwnd) {
    ; PBT_APMRESUMEAUTOMATIC (0x12) / PBT_APMRESUMESUSPEND (0x7): the machine
    ; just woke. Hooks and the 1ms timer resolution are both casualties of a
    ; sleep cycle - re-assert them now instead of waiting for NightWatch.
    if (wp = 0x12 || wp = 0x7) {
        try DllCall('winmm\timeBeginPeriod', 'uint', 1)
        NightWatch()
    }
    return 1
}

IntroE(st, dur) {
    ; 0..1 smoothstep window inside the 1.5s open choreography.
    ; Returns 1 whenever the overlay is not opening, so idle frames are stable.
    global NX
    if (NX['anim'] != 'open')
        return 1.0
    return SmoothStep(Min(Max((A_TickCount - NX['anim0'] - st) / (dur * 1.0), 0), 1))
}

; ============================================================== action sheet
OpenSheet() {
    global NX
    if (!NX['shown'] || NX['repair'] || !Current())
        return
    NX['ptab'] := false
    NX['sheet'] := true
    NX['ssel'] := 1
    NX['st0'] := A_TickCount
    NX['act'] := A_TickCount
    Sfx('tick')
}
CloseSheet() {
    global NX
    NX['sheet'] := false
    NX['st0'] := A_TickCount
    NX['act'] := A_TickCount
    Sfx('tick')
}
SheetItems() {
    global NX
    cur := Current()
    fav := (cur && cur['fav']) ? 'UNFAVOURITE' : 'FAVOURITE'
    return ['PLAY', 'REPAIR ARTWORK', fav, 'HIDE', 'RESCAN', 'EDIT CSV']
}
SheetNav(d) {
    global NX
    was := NX['ssel']
    NX['ssel'] := Min(Max(NX['ssel'] + d, 1), SheetItems().Length)
    NX['act'] := A_TickCount
    if (NX['ssel'] != was)
        Sfx('tick')
}
SheetGo() {
    global NX
    sel := NX['ssel']
    CloseSheet()
    if (sel = 1)
        LaunchCurrent()
    else if (sel = 2)
        OpenRepair()
    else if (sel = 3)
        ToggleFav()
    else if (sel = 4)
        HideCurrent()
    else if (sel = 5)
        StartScan(true)
    else if (sel = 6)
        OpenCsv()
}
DrawSheet(g, w, h, accent) {
    ; vertical side panel, slides in from the left - solid blackhole plate
    global NX
    sp := NX['st0'] ? SmoothStep(Min((A_TickCount - NX['st0']) / 480.0, 1.0)) : 1.0
    vis := NX['sheet'] ? sp : 1 - sp
    if (vis <= 0.01)
        return
    cur := Current()
    pw := 268
    items := SheetItems()
    ph := 76 + items.Length * 56 + 20
    px := -pw * (1 - vis)
    py := (h - ph) / 2
    HolePanel(g, px, py, pw + 24, ph, 16, accent, vis)
    DrawTxt(g, cur ? StrUpper(cur['title']) : '', px + 24, py + 20, pw - 8, 20, 10
        , (Round(0xB0 * vis) << 24) | 0xEAF2FF, false)
    i := 1
    for name in items {
        y := py + 56 + (i - 1) * 56
        sel := (NX['ssel'] = i)
        rw := pw - 16
        rx := px + 16
        if sel
            HoleRow(g, rx, y, rw, 46, 10, accent, vis)
        else
            FillRR(g, rx, y, rw, 46, 10, (Round(0x10 * vis) << 24) | 0xFFFFFF)
        DrawTxt(g, name, px + 36, y + 16, pw - 60, 20, 10.5
            , sel ? ((Round(0xF0 * vis) << 24) | 0xEAF2FF) : ((Round(0x86 * vis) << 24) | 0xC8DCF4), false)
        i++
    }
}

; ============================================================== artwork repair
OpenRepair() {
    global NX
    if !NX['shown']
        ShowOverlay()
    if !Current()
        return
    NX['sheet'] := false
    NX['ptab'] := false
    NX['repair'] := true
    NX['rsel'] := 1
    NX['rt0'] := A_TickCount
    NX['act'] := A_TickCount
    Sfx('tick')
}
CloseRepair() {
    global NX
    NX['repair'] := false
    NX['rt0'] := A_TickCount
    NX['act'] := A_TickCount
    Sfx('tick')
}
RepairNav(d) {
    global NX
    was := NX['rsel']
    NX['rsel'] := Min(Max(NX['rsel'] + d, 1), 3)
    NX['act'] := A_TickCount
    if (NX['rsel'] != was)
        Sfx('tick')
}
RepairGo() {
    global NX
    cur := Current()
    if !cur
        return
    kinds := ['cover', 'hero', 'logo']
    kind := kinds[NX['rsel']]
    NX['act'] := A_TickCount
    p := FileSelect(1, , 'Pick ' kind ' art for ' cur['title'], 'Images (*.png; *.jpg; *.jpeg; *.bmp; *.gif)')
    if (p = '' || !FileExist(p))
        return
    SplitPath(p, , , &ext)
    if !(ext ~= 'i)^(png|jpe?g|bmp|gif)$')
        return
    dir := NX['data'] '\art'
    try DirCreate(dir)
    stem := ArtStem(cur['title'])
    Loop Files dir '\' stem '_' kind '.*'
        try FileDelete(A_LoopFileFullPath)   ; the new file becomes the only match
    try FileCopy(p, dir '\' stem '_' kind '.' StrLower(ext), 1)
    RefreshArt(cur)
    Sfx('tick')
}
RefreshArt(game) {
    ; drop every cached bitmap for this game so the new art shows instantly
    global NX
    NX['artfl'] := 0
    id := game['id']
    for k in [id, 'hero|' id, 'logo|' id] {
        if NX['imgs'].Has(k) {
            v := NX['imgs'][k]
            if v
                try DllCall('gdiplus\GdipDisposeImage', 'ptr', IsObject(v) ? v['bm'] : v)
            NX['imgs'].Delete(k)
        }
    }
    if NX['bg'].Has(id) {
        rec := NX['bg'][id]
        if rec[1]
            try DllCall('gdiplus\GdipDisposeImage', 'ptr', rec[1])
        NX['bg'].Delete(id)
    }
    NX['gtitle'] := ''
    NX['gt0'] := 0
    NX['dirty'] := true
}
DrawRepair(g, w, h, accent) {
    global NX
    sp := NX['rt0'] ? SmoothStep(Min((A_TickCount - NX['rt0']) / 480.0, 1.0)) : 1.0
    vis := NX['repair'] ? sp : 1 - sp
    if (vis <= 0.01)
        return
    cur := Current()
    pw := 470
    ph := 368
    px := (w - pw) / 2
    py := (h - ph) / 2 - (1 - vis) * 36
    HolePanel(g, px, py, pw, ph, 18, accent, vis)
    DrawTxtD(g, 'ARTWORK REPAIR', px, py + 22, pw, 26, 15, (Round(0xE6 * vis) << 24) | 0xEAF2FF)
    if cur
        DrawTxt(g, StrUpper(cur['title']), px, py + 52, pw, 20, 10, (Round(0x88 * vis) << 24) | 0xAFC6E8)
    kinds := ['COVER', 'HERO', 'LOGO']
    exts := ['png', 'jpg', 'jpeg']
    i := 1
    while (i <= 3) {
        y := py + 92 + (i - 1) * 74
        sel := (NX['rsel'] = i)
        rw := pw - 48
        rx := px + 24
        if sel
            HoleRow(g, rx, y, rw, 60, 12, accent, vis)
        else
            FillRR(g, rx, y, rw, 60, 12, (Round(0x10 * vis) << 24) | 0xFFFFFF)
        have := cur && FindNamedArt(cur, StrLower(kinds[i]), exts) != ''
        ; status pip stays semantic green/red; the SELECTED glow is always accent
        FillEllipse(g, px + 44, y + 21, 18, 18
            , have ? ((Round(0xFF * vis) << 24) | 0x44A83C) : ((Round(0xFF * vis) << 24) | 0xCC4444))
        DrawTxt(g, kinds[i], px + 80, y + 12, 160, 20, 12, (Round(0xE6 * vis) << 24) | 0xEAF2FF, false)
        DrawTxt(g, have ? 'FOUND  -  ENTER TO REPLACE' : 'MISSING  -  ENTER TO PICK A FILE', px + 80, y + 34, pw - 130, 18, 9
            , have ? ((Round(0x99 * vis) << 24) | 0xA9E6B4) : ((Round(0x99 * vis) << 24) | 0xE6A9A9), false)
        i++
    }
    DrawTxt(g, 'ENTER PICKS A FILE   -   ART UPDATES INSTANTLY   -   ESC BACK', px, py + ph - 34, pw, 18, 9, (Round(0x66 * vis) << 24) | 0xC8DCF4)
}

; ============================================================== pad modal routing
PadUpDown(d) {
    global NX
    if NX['repair']
        RepairNav(d)
    else if NX['sheet']
        SheetNav(d)
    else if NX['ptab']
        PowerNav(d)
    else
        SwitchDeck(d)
}
PadConfirm() {
    global NX
    if NX['repair']
        RepairGo()
    else if NX['sheet']
        SheetGo()
    else if NX['ptab']
        PowerGo()
    else
        LaunchCurrent()
}
PadBack() {
    global NX
    if NX['repair']
        CloseRepair()
    else if NX['sheet']
        CloseSheet()
    else if NX['ptab']
        TogglePower()
    else
        HideOverlay()
}

; ============================================================== v1.17 helpers
HolePanel(g, x, y, w, h, r, accent, vis := 1.0) {
    ; solid blackhole plate - same deep void as the globe disc, with a soft
    ; accent halo so the panel feels lit by the same ring light
    a := Max(Min(vis, 1.0), 0.0)
    ; outer drop so it lifts off the hero
    FillRR(g, x + 5, y + 10, w, h, r, (Round(0x70 * a) << 24))
    ; body: near-opaque void (no frost / no see-through)
    FillRR(g, x, y, w, h, r, (Round(0xF6 * a) << 24) | 0x050810)
    FillRR(g, x + 1.5, y + 1.5, w - 3, h - 3, Max(r - 1, 2), (Round(0xFF * a) << 24) | 0x04060C)
    ; soft accent bloom hugging the edge (blackhole ring language)
    StrokeRR(g, x - 3, y - 3, w + 6, h + 6, r + 3, (Round(0x28 * a) << 24) | (accent & 0xFFFFFF), 5.5)
    StrokeRR(g, x - 1, y - 1, w + 2, h + 2, r + 1, (Round(0x40 * a) << 24) | (accent & 0xFFFFFF), 2.4)
    StrokeRR(g, x, y, w, h, r, (Round(0x22 * a) << 24) | 0xFFFFFF, 1.1)
    ; faint top sheen so the void still reads as a surface
    StrokeRR(g, x + 2, y + 2, w - 4, Min(h * 0.42, 54), Max(r - 2, 2), (Round(0x14 * a) << 24) | 0xFFFFFF, 1)
}
HoleRow(g, x, y, w, h, r, accent, vis := 1.0) {
    ; selected menu row: dark fill + the same glowy rim light the blackhole uses
    a := Max(Min(vis, 1.0), 0.0)
    ac := accent & 0xFFFFFF
    FillRR(g, x, y, w, h, r, (Round(0x22 * a) << 24) | ac)          ; soft accent wash
    FillRR(g, x + 1, y + 1, w - 2, h - 2, Max(r - 1, 2), (Round(0xE8 * a) << 24) | 0x070A12)
    ; multi-layer rim glow (wide soft -> tight bright) - mirrors globe strokes
    StrokeRR(g, x - 2, y - 2, w + 4, h + 4, r + 2, (Round(0x30 * a) << 24) | ac, 4.5)
    StrokeRR(g, x - 0.5, y - 0.5, w + 1, h + 1, r + 0.5, (Round(0x70 * a) << 24) | ac, 2.2)
    StrokeRR(g, x, y, w, h, r, (Round(0xC8 * a) << 24) | ac, 1.5)
    StrokeRR(g, x + 1.5, y + 1.5, w - 3, h - 3, Max(r - 1.5, 2), (Round(0x28 * a) << 24) | 0xFFFFFF, 1.0)
}
DrawRipple(g, accent) {
    ; favourite feedback: one accent ring blooms out of the card and fades
    global NX
    rp := NX['ripple']
    if !IsObject(rp)
        return
    p := (A_TickCount - rp['t0']) / 520.0
    if (p >= 1) {
        NX['ripple'] := 0
        return
    }
    e := SmoothStep(Min(Max(p, 0.0), 1.0))
    rr := 30 + e * 150
    al := Round(0x9C * (1 - e))
    StrokeEllipse(g, rp['x'] - rr, rp['y'] - rr, rr * 2, rr * 2, (al << 24) | (accent & 0xFFFFFF), 2.5 * (1 - e) + 1)
    StrokeEllipse(g, rp['x'] - rr * 0.7, rp['y'] - rr * 0.7, rr * 1.4, rr * 1.4, (Round(al * 0.6) << 24) | 0xFFFFFF, 1.2)
}
UpdateTint(accent) {
    ; theme extraction: the acrylic frost leans 16% toward the current hero
    ; accent, staying dark enough for text. DWM is only touched on change.
    global NX
    if !NX['shown']
        return
    b2 := Round((accent & 0xFF) * 0.16 + 0x14 * 0.84)
    g2 := Round(((accent >> 8) & 0xFF) * 0.16 + 0x10 * 0.84)
    r2 := Round(((accent >> 16) & 0xFF) * 0.16 + 0x18 * 0.84)
    tint := 0xB0000000 | (b2 << 16) | (g2 << 8) | r2
    if (tint = NX['tint'])
        return
    NX['tint'] := tint
    try SetAcrylic(NX['hblur'], tint)
}
SetVol(v) {
    ; per-app wave volume: quieter by default, adjustable from the tray
    global NX, VolMenu
    NX['vol'] := v
    lv := Round(v * 0xFFFF)
    try DllCall('winmm\waveOutSetVolume', 'ptr', -1, 'uint', (lv << 16) | lv)
    for nm in ['Normal', 'Soft', 'Off']
        try VolMenu.Uncheck(nm)
    try VolMenu.Check(v >= 0.5 ? 'Normal' : (v > 0 ? 'Soft' : 'Off'))
}
PowerExec(sel) {
    global NX
    NX['pconf'] := 0
    NX['ptab'] := false
    FinishHide()
    if (sel = 1)
        DllCall('user32\LockWorkStation')
    else if (sel = 2)
        Run('rundll32.exe powrprof.dll,SetSuspendState 0,1,0', , 'Hide')
    else if (sel = 3)
        Run('shutdown.exe /r /t 0', , 'Hide')
    else
        Run('shutdown.exe /s /t 0', , 'Hide')
}
PowerHoldP() {
    ; 0..1 while the confirm key is physically held on the armed action;
    ; releasing early disarms - that is the whole safety of hold-to-confirm
    global NX
    if !NX['pconf']
        return 0.0
    held := GetKeyState('Enter', 'P') || GetKeyState('Space', 'P') || (NX['btns'] & 0x1000)
    if !held {
        NX['pconf'] := 0
        return 0.0
    }
    return Min((A_TickCount - NX['pconf']) / 1050.0, 1.0)
}
