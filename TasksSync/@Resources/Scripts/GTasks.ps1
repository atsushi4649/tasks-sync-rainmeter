# Tasks Sync for Rainmeter - Google Tasks two-way sync helper
# License: MIT
param(
    [string]$Action = 'sync',
    [string]$TaskId = '',
    [string]$Lang = 'ja',
    [int]$Width = 320,
    [int]$MaxTasks = 15,
    [string]$Rainmeter = '',
    [string]$Config = '',
    # personal data (token, client_secret, task cache) lives OUTSIDE the skin folder,
    # so updating / sharing the skin never touches it. Default: %APPDATA%\Rainmeter\TasksSync
    [string]$DataDir = '',
    # layout (px) - from Variables.inc
    [int]$HeaderH = 34, [int]$RowH = 20, [int]$FooterH = 30, [int]$PadX = 10, [int]$Inset = 5
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Res = Split-Path $PSScriptRoot -Parent
if (-not $DataDir) { $DataDir = Join-Path $env:APPDATA 'Rainmeter\TasksSync' }
$SetupUrl  = 'https://atsushi4649.github.io/tasks-sync-rainmeter/setup.html'
$TokenFile = Join-Path $DataDir 'token.dat'
$StateFile = Join-Path $DataDir 'state.json'
$InputFile = Join-Path $DataDir 'input.ini'
$TasksInc  = Join-Path $DataDir 'Tasks.inc'
$StateInc  = Join-Path $DataDir 'State.inc'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }

# Layout (px)
$RowTop = $HeaderH + 4; $Indent = [int]($RowH * 0.7); $CheckR = [Math]::Round($RowH * 0.27, 1); $CheckC = $CheckR + 1.5; $InputH = $RowH + 4

$Strings = @{
    ja = @{
        noclient    = 'はじめに設定が必要です。クリックすると手順が開きます。ダウンロード後に ⟳ を押すと client_secret の JSON を自動で読み込みます。'
        noauth      = 'クリックして Google にログイン'
        empty       = 'タスクはありません'
        more        = '他 {0} 件'
        untitled    = '(タイトルなし)'
        loading     = '読み込み中…'
        authConsole = 'ブラウザで Google アカウントへのアクセスを許可してください。（このウィンドウは自動で閉じます）'
        authDone    = 'ログインしました。'
        authFail    = 'ログインに失敗しました'
        pressEnter  = 'Enter キーで閉じます'
        browserOk   = 'ログインしました。このタブを閉じて Rainmeter に戻ってください。'
    }
    en = @{
        noclient    = 'Setup needed. Click to open the guide. After downloading the client_secret JSON, press the sync button to load it automatically.'
        noauth      = 'Click to sign in to Google'
        empty       = 'No tasks'
        more        = '+{0} more'
        untitled    = '(untitled)'
        loading     = 'Loading...'
        authConsole = 'Please allow access to your Google account in the browser. (This window closes automatically.)'
        authDone    = 'Signed in.'
        authFail    = 'Sign-in failed'
        pressEnter  = 'Press Enter to close'
        browserOk   = 'Signed in. You can close this tab and return to Rainmeter.'
    }
}
function Tr([string]$k) {
    $d = $Strings[$Lang]; if (-not $d) { $d = $Strings['en'] }
    return $d[$k]
}

# ---------- helpers ----------
function Esc-Text($s) {
    if ($null -eq $s) { $s = '' }
    $s = [string]$s -replace "[\r\n\t]+", ' '
    # keep #Name# literal (Rainmeter variable escape)
    $s = [regex]::Replace($s, '#(\w+)#', '#*$1*#')
    return $s.Trim()
}
function Write-IfChanged([string]$path, [string]$content) {
    $old = ''
    if (Test-Path $path) { $old = [IO.File]::ReadAllText($path) }
    if ($old -ne $content) {
        [IO.File]::WriteAllText($path, $content, [Text.Encoding]::Unicode)  # UTF-16 LE + BOM
        return $true
    }
    return $false
}
function Refresh-Skin {
    if ($Rainmeter -and (Test-Path $Rainmeter) -and $Config) { & $Rainmeter '!Refresh' $Config }
}
function Get-ErrorText($err) {
    if ($err.ErrorDetails -and $err.ErrorDetails.Message) {
        try {
            $j = $err.ErrorDetails.Message | ConvertFrom-Json
            if ($j.error.message) { return [string]$j.error.message }
            if ($j.error_description) { return [string]$j.error_description }
            if ($j.error) { return [string]$j.error }
        } catch {}
        return $err.ErrorDetails.Message
    }
    return $err.Exception.Message
}
function New-RandomString([int]$len) {
    $bytes = New-Object byte[] ($len)
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return (ConvertTo-B64Url $bytes).Substring(0, $len)
}
function ConvertTo-B64Url([byte[]]$b) {
    return [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# ---------- input / state ----------
function Clear-Input {
    [IO.File]::WriteAllText($InputFile, "[Input]`r`nTaskId=`r`nTitle=`r`n", [Text.Encoding]::Unicode)
}
function Read-Input {
    $r = @{}
    if (Test-Path $InputFile) {
        foreach ($l in [IO.File]::ReadAllLines($InputFile)) {
            if ($l -match '^(\w+)=(.*)$') { $r[$matches[1]] = $matches[2] }
        }
    }
    return $r
}
function Read-State {
    if (Test-Path $StateFile) {
        try { return (Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
    }
    return [pscustomobject]@{ listId = '' }
}
function Save-State($s) {
    [IO.File]::WriteAllText($StateFile, ($s | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
}

# ---------- OAuth ----------
function Find-ClientFile([string]$dir) {
    if (-not $dir -or -not (Test-Path $dir)) { return $null }
    return Get-ChildItem -Path $dir -Filter 'client_secret*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
function Get-Client {
    $f = Find-ClientFile $DataDir
    if (-not $f) {
        # pick up the JSON straight from Downloads (or legacy @Resources) and move it to DataDir
        $dl = $null
        try { $dl = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path } catch {}
        if (-not $dl) { $dl = Join-Path $env:USERPROFILE 'Downloads' }
        foreach ($d in @($dl, $Res)) {
            $src = Find-ClientFile $d
            if ($src) {
                $j = $null
                try { $j = Get-Content $src.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
                if ($j -and $j.installed) {
                    Move-Item $src.FullName (Join-Path $DataDir $src.Name) -Force
                    $f = Find-ClientFile $DataDir
                    break
                }
            }
        }
    }
    if (-not $f) { return $null }
    $j = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $c = $j.installed
    if (-not $c) { $c = $j.web }
    return $c
}
function Save-RefreshToken([string]$rt) {
    $sec = ConvertTo-SecureString $rt -AsPlainText -Force
    # DPAPI: only this Windows user on this PC can decrypt
    [IO.File]::WriteAllText($TokenFile, (ConvertFrom-SecureString $sec))
}
function Read-RefreshToken {
    if (-not (Test-Path $TokenFile)) { return $null }
    $sec = ([IO.File]::ReadAllText($TokenFile)).Trim() | ConvertTo-SecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
function Get-AccessToken($c) {
    $rt = $null
    try { $rt = Read-RefreshToken } catch { $rt = $null }
    if (-not $rt) { throw 'NOAUTH' }
    try {
        $r = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' -Body @{
            client_id = $c.client_id; client_secret = $c.client_secret
            refresh_token = $rt; grant_type = 'refresh_token'
        }
    } catch {
        if ((Get-ErrorText $_) -match 'invalid_grant|expired|revoked') {
            Remove-Item $TokenFile -ErrorAction SilentlyContinue
            throw 'NOAUTH'
        }
        throw
    }
    return $r.access_token
}
function Send-HttpResponse($client, [string]$html) {
    $body = [Text.Encoding]::UTF8.GetBytes("<!doctype html><meta charset=utf-8><body style='font-family:sans-serif;padding:3em'>$html</body>")
    $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
    $s = $client.GetStream()
    $s.Write($head, 0, $head.Length); $s.Write($body, 0, $body.Length); $s.Flush()
    $client.Close()
}
function Invoke-Auth($c) {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        $port = $listener.LocalEndpoint.Port
        $redirect = "http://127.0.0.1:$port"
        $verifier = New-RandomString 64
        $challenge = ConvertTo-B64Url ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))
        $state = New-RandomString 24
        $q = @(
            'client_id=' + [Uri]::EscapeDataString($c.client_id)
            'redirect_uri=' + [Uri]::EscapeDataString($redirect)
            'response_type=code'
            'scope=' + [Uri]::EscapeDataString('https://www.googleapis.com/auth/tasks')
            'code_challenge=' + $challenge
            'code_challenge_method=S256'
            'access_type=offline'
            'prompt=consent'
            'state=' + $state
        ) -join '&'
        Write-Host (Tr 'authConsole')
        Start-Process ('https://accounts.google.com/o/oauth2/v2/auth?' + $q)

        $deadline = (Get-Date).AddMinutes(5)
        $code = $null
        while (-not $code) {
            $left = [int]($deadline - (Get-Date)).TotalMilliseconds
            if ($left -le 0) { throw 'Timeout' }
            $t = $listener.AcceptTcpClientAsync()
            if (-not $t.Wait($left)) { throw 'Timeout' }
            $client = $t.Result
            $client.ReceiveTimeout = 5000
            $line = $null
            try { $line = (New-Object IO.StreamReader($client.GetStream())).ReadLine() } catch {}
            if (-not $line -or $line -notmatch '^GET (\S+)') { $client.Close(); continue }
            $path = $matches[1]
            $params = @{}
            if ($path.Contains('?')) {
                foreach ($kv in $path.Substring($path.IndexOf('?') + 1).Split('&')) {
                    $p = $kv.Split('=', 2)
                    if ($p.Length -eq 2) { $params[$p[0]] = [Uri]::UnescapeDataString($p[1].Replace('+', ' ')) }
                }
            }
            if ($params['error']) { Send-HttpResponse $client $params['error']; throw $params['error'] }
            if ($params['code'] -and $params['state'] -eq $state) {
                $code = $params['code']
                Send-HttpResponse $client (Tr 'browserOk')
            } else {
                Send-HttpResponse $client ''
            }
        }
    } finally { $listener.Stop() }

    $tok = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' -Body @{
        code = $code; client_id = $c.client_id; client_secret = $c.client_secret
        redirect_uri = $redirect; grant_type = 'authorization_code'; code_verifier = $verifier
    }
    if (-not $tok.refresh_token) { throw 'No refresh_token returned' }
    Save-RefreshToken $tok.refresh_token
    Write-Host (Tr 'authDone')
}

# ---------- Tasks API ----------
function Api([string]$method, [string]$path, $body) {
    $uri = 'https://tasks.googleapis.com/tasks/v1/' + $path
    $h = @{ Authorization = "Bearer $script:Access" }
    if ($null -ne $body) {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress -Depth 5))
        return Invoke-RestMethod -Method $method -Uri $uri -Headers $h -Body $bytes -ContentType 'application/json; charset=utf-8'
    }
    return Invoke-RestMethod -Method $method -Uri $uri -Headers $h
}
function Get-Paged([string]$path) {
    $items = @(); $pt = $null
    do {
        $p = $path
        if ($pt) { $p += '&pageToken=' + [Uri]::EscapeDataString($pt) }
        $r = Api 'Get' $p $null
        if ($r.items) { $items += @($r.items) }
        $pt = $r.nextPageToken
    } while ($pt)
    return ,$items
}
function Enc([string]$s) { return [Uri]::EscapeDataString($s) }

# ---------- rendering ----------
function Build-State($o) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('[Variables]')
    foreach ($k in $o.Keys) { [void]$sb.AppendLine("$k=$($o[$k])") }
    return $sb.ToString()
}
function Get-BaseVars([int]$rows, [string]$title, [string]$arrow, [int]$addHidden) {
    $bg = $RowTop + $rows * $RowH + $FooterH
    $footerY = $bg - $Inset - [int](($FooterH - $Inset) / 2)
    $v = [ordered]@{
        BGHeight = $bg; FooterY = $footerY; InputH = $InputH
        AddInputX = $PadX + 14; AddInputY = $footerY - [int]($InputH / 2); InputW = $Width - 2 * $PadX - 14
        ListTitle = (Esc-Text $title); ListArrow = $arrow
        AddHidden = $addHidden; ErrorHidden = 1; ErrorMsg = ''
        Demo = [int]($Action -eq 'demo')
    }
    return $v
}
function Message-Meter([int]$y, [int]$h, [string]$text, [string]$action) {
    $a = ''
    if ($action) { $a = "LeftMouseUpAction=$action`r`nMouseOverAction=[!SetOption MeterMsg FontColor `"#ColorAccent#`"][!UpdateMeter MeterMsg][!Redraw]`r`nMouseLeaveAction=[!SetOption MeterMsg FontColor `"#ColorSub#`"][!UpdateMeter MeterMsg][!Redraw]" }
    return @"
[MeterMsg]
Meter=String
X=$PadX
Y=$($y + 2)
W=$($Width - 2 * $PadX)
H=$($h - 4)
ClipString=2
Text=$(Esc-Text $text)
MeterStyle=StyleText
FontColor=#ColorSub#
SolidColor=0,0,0,1
$a

"@
}
function Render-Message([string]$key, [string]$action) {
    $rows = 3
    $v = Get-BaseVars $rows 'Tasks' '' 1
    $inc = Message-Meter $RowTop ($rows * $RowH) (Tr $key) $action
    $c1 = Write-IfChanged $StateInc (Build-State $v)
    $c2 = Write-IfChanged $TasksInc $inc
    if ($c1 -or $c2) { Refresh-Skin }
}
function Render-Error([string]$msg) {
    if (-not (Test-Path $StateInc)) { return }
    $s = [IO.File]::ReadAllText($StateInc)
    $m = (Esc-Text $msg)
    if ($m.Length -gt 200) { $m = $m.Substring(0, 200) }
    $s = [regex]::Replace($s, '(?m)^ErrorHidden=.*$', 'ErrorHidden=0')
    $s = [regex]::Replace($s, '(?m)^ErrorMsg=.*$', ('ErrorMsg=' + $m.Replace('$', '$$')))
    if (Write-IfChanged $StateInc $s) { Refresh-Skin }
}
function Render-Tasks($lists, $list, $tasks) {
    # order: top-level by position, children right after their parent
    $ids = @{}; foreach ($t in $tasks) { $ids[$t.id] = $true }
    $ordered = New-Object System.Collections.ArrayList
    $top = @($tasks | Where-Object { -not $_.parent -or -not $ids.ContainsKey($_.parent) } | Sort-Object position)
    foreach ($t in $top) {
        [void]$ordered.Add(@{ Task = $t; Depth = 0 })
        foreach ($ch in @($tasks | Where-Object { $_.parent -eq $t.id } | Sort-Object position)) {
            [void]$ordered.Add(@{ Task = $ch; Depth = 1 })
        }
    }
    $total = $ordered.Count
    $shown = [Math]::Min($total, $MaxTasks)
    $extraRow = 0; if ($total -gt $shown -or $total -eq 0) { $extraRow = 1 }
    $rowsN = $shown + $extraRow

    $arrow = ''; if ($lists.Count -gt 1) { $arrow = [string][char]0x25BE }
    $v = Get-BaseVars $rowsN $list.title $arrow 0

    $sb = New-Object Text.StringBuilder
    $iconDel = '[\xE711]'
    for ($i = 1; $i -le $shown; $i++) {
        $r = $ordered[$i - 1]; $t = $r.Task
        $y = $RowTop + ($i - 1) * $RowH
        $cy = $y + [int]($RowH / 2)
        $x = $PadX + $r.Depth * $Indent
        $title = Esc-Text $t.title
        if (-not $title) { $title = Tr 'untitled' }
        $v["T$i"] = $title
        $id = $t.id

        $due = ''; $dueColor = '#ColorSub#'
        if ($t.due) {
            if ($t.due -is [datetime]) { $dd = $t.due.ToUniversalTime().Date }
            else { $dd = [datetime]::ParseExact(([string]$t.due).Substring(0, 10), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
            $due = $dd.ToString('M/d')
            if ($dd -lt [datetime]::Today) { $dueColor = '#ColorDanger#' }
            elseif ($dd -eq [datetime]::Today) { $dueColor = '#ColorAccent#' }
        }
        $tx = $x + [int](2 * $CheckC) + 6
        $reserve = 22; if ($due) { $reserve += 32 }
        $tw = $Width - $tx - $reserve

        [void]$sb.Append(@"
[TaskCheck$i]
Meter=Shape
Group=Task$i
X=$x
Y=$($cy - $CheckC)
Shape=Ellipse $CheckC,$CheckC,$CheckR | Extend CheckStyle
CheckStyle=Fill Color 0,0,0,1 | StrokeWidth 1.2 | Stroke Color #ColorSub#
MouseOverAction=[!SetOption TaskCheck$i CheckStyle "Fill Color #ColorAccentSoft# | StrokeWidth 1.2 | Stroke Color #ColorAccent#"][!UpdateMeter TaskCheck$i][!Redraw]
MouseLeaveAction=[!SetOption TaskCheck$i CheckStyle "Fill Color 0,0,0,1 | StrokeWidth 1.2 | Stroke Color #ColorSub#"][!UpdateMeter TaskCheck$i][!Redraw]
LeftMouseUpAction=[!SetOption TaskCheck$i CheckStyle "Fill Color #ColorAccent# | StrokeWidth 1.2 | Stroke Color #ColorAccent#"][!SetOption TaskCheck$i MouseLeaveAction ""][!SetOption TaskTitle$i MouseLeaveAction ""][!SetOption TaskTitle$i InlineSetting "Strikethrough"][!SetOption TaskTitle$i FontColor "#ColorSub#"][!UpdateMeterGroup Task$i][!Redraw][!CommandMeasure MeasureDone$i "Run"]

[TaskTitle$i]
Meter=String
Group=Task$i
X=$tx
Y=$cy
W=$tw
ClipString=1
StringAlign=LeftCenter
Text=$title
ToolTipText=$title
MeterStyle=StyleText
SolidColor=0,0,0,1
MouseOverAction=[!SetOption TaskTitle$i FontColor "#ColorAccent#"][!UpdateMeter TaskTitle$i][!Redraw]
MouseLeaveAction=[!SetOption TaskTitle$i FontColor "#ColorText#"][!UpdateMeter TaskTitle$i][!Redraw]
LeftMouseUpAction=[!WriteKeyValue Input TaskId $id "#DataDir#input.ini"][!SetOption MeasureInput DefaultValue "#*T$i*#"][!SetOption MeasureInput X $($tx - 3)][!SetOption MeasureInput Y $($cy - [int]($InputH / 2))][!SetOption MeasureInput W $($tw + 8)][!UpdateMeasure MeasureInput][!CommandMeasure MeasureInput "ExecuteBatch 2"]

[TaskDel$i]
Meter=String
Group=Task$i
X=$($Width - $PadX - 6)
Y=$cy
StringAlign=CenterCenter
Text=$iconDel
FontFace=#IconFont#
FontSize=7
FontColor=#ColorFaint#
AntiAlias=1
SolidColor=0,0,0,1
Padding=4,3,4,3
MouseOverAction=[!SetOption TaskDel$i FontColor "#ColorDanger#"][!UpdateMeter TaskDel$i][!Redraw]
MouseLeaveAction=[!SetOption TaskDel$i FontColor "#ColorFaint#"][!UpdateMeter TaskDel$i][!Redraw]
LeftMouseUpAction=[!HideMeterGroup Task$i][!Redraw][!CommandMeasure MeasureDel$i "Run"]

[MeasureDone$i]
Measure=Plugin
Plugin=RunCommand
Program=powershell.exe
Parameter=#PS# -Action complete -TaskId $id
State=Hide

[MeasureDel$i]
Measure=Plugin
Plugin=RunCommand
Program=powershell.exe
Parameter=#PS# -Action delete -TaskId $id
State=Hide


"@)
        if ($due) {
            [void]$sb.Append(@"
[TaskDue$i]
Meter=String
Group=Task$i
X=$($Width - $PadX - 16)
Y=$cy
StringAlign=RightCenter
Text=$due
MeterStyle=StyleText
FontSize=#FontSizeSmall#
FontColor=$dueColor


"@)
        }
    }
    if ($total -eq 0) {
        [void]$sb.Append((Message-Meter $RowTop $RowH (Tr 'empty') ''))
    } elseif ($total -gt $shown) {
        [void]$sb.Append((Message-Meter ($RowTop + $shown * $RowH) $RowH ((Tr 'more') -f ($total - $shown)) ''))
    }

    $c1 = Write-IfChanged $StateInc (Build-State $v)
    $c2 = Write-IfChanged $TasksInc $sb.ToString()
    if ($c1 -or $c2) { Refresh-Skin }
}

# ---------- main ----------
$mutex = New-Object Threading.Mutex($false, 'Local\RainmeterTasksSync')
$owned = $false
try { $owned = $mutex.WaitOne(60000) } catch [Threading.AbandonedMutexException] { $owned = $true }
try {
    if (-not (Test-Path $InputFile)) { Clear-Input }
    if ($Action -eq 'demo') {
        # offline sample data (for layout check / screenshots)
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $demo = @(
            [pscustomobject]@{ id = 'd1'; title = '牛乳を買う'; position = '001'; due = "$($today)T00:00:00.000Z" }
            [pscustomobject]@{ id = 'd2'; title = 'Rainmeter skin を公開する'; position = '002' }
            [pscustomobject]@{ id = 'd3'; title = 'README を書く'; position = '001'; parent = 'd2' }
            [pscustomobject]@{ id = 'd4'; title = 'とても長いタイトルのタスクはこのように省略記号で切り詰めて表示されます'; position = '003'; due = '2026-01-01T00:00:00.000Z' }
        )
        Render-Tasks @([pscustomobject]@{ title = 'マイタスク' }, [pscustomobject]@{ title = 'Work' }) ([pscustomobject]@{ title = 'マイタスク' }) $demo
        return
    }
    $client = Get-Client
    if (-not $client) { Render-Message 'noclient' "[`"$SetupUrl`"]"; return }

    if ($Action -eq 'auth') {
        try { Invoke-Auth $client }
        catch {
            Write-Host ((Tr 'authFail') + ': ' + (Get-ErrorText $_)) -ForegroundColor Red
            Read-Host (Tr 'pressEnter') | Out-Null
            return
        }
        $Action = 'sync'
    }

    $script:Access = Get-AccessToken $client
    $lists = Get-Paged 'users/@me/lists?maxResults=100'
    if ($lists.Count -eq 0) { Render-Message 'empty' ''; return }
    $state = Read-State
    $idx = 0
    for ($k = 0; $k -lt $lists.Count; $k++) { if ($lists[$k].id -eq $state.listId) { $idx = $k } }
    if ($Action -eq 'nextlist') { $idx = ($idx + 1) % $lists.Count }
    $list = $lists[$idx]
    if ($state.listId -ne $list.id) { Save-State ([pscustomobject]@{ listId = $list.id }) }
    $lid = Enc $list.id

    switch ($Action) {
        'complete' { if ($TaskId) { [void](Api 'Patch' "lists/$lid/tasks/$(Enc $TaskId)" @{ status = 'completed' }) } }
        'delete'   { if ($TaskId) { [void](Api 'Delete' "lists/$lid/tasks/$(Enc $TaskId)" $null) } }
        'add' {
            $in = Read-Input; Clear-Input
            $title = ([string]$in['Title']).Trim()
            if ($title) { [void](Api 'Post' "lists/$lid/tasks" @{ title = $title }) }
        }
        'edit' {
            $in = Read-Input; Clear-Input
            $title = ([string]$in['Title']).Trim()
            $tid = [string]$in['TaskId']
            if ($title -and $tid) { [void](Api 'Patch' "lists/$lid/tasks/$(Enc $tid)" @{ title = $title }) }
        }
    }

    $tasks = Get-Paged "lists/$lid/tasks?showCompleted=false&showHidden=false&maxResults=100"
    Render-Tasks $lists $list $tasks
}
catch {
    if ($_.Exception.Message -eq 'NOAUTH') { Render-Message 'noauth' '[!CommandMeasure MeasureAuth "Run"]' }
    else { Render-Error (Get-ErrorText $_) }
}
finally {
    if ($owned) { $mutex.ReleaseMutex() }
}
