# AlertQueueUI Fast Worker v4.0
#
# Призначення:
#   Швидка бойова розсилка повідомлень на РС за готовим кешем PreCheck.
#
# Ключова відмінність від старого AlertQueue-Worker.ps1:
#   Старий worker для КОЖНОЇ РС під час розсилки робив quser /server:PC,
#   а потім запускав PsExec. На 500 РС це дає хвилини.
#
#   Fast Worker НЕ робить quser під час тривоги.
#   Він читає Cache\pc_status_cache.csv, де PreCheck вже заздалегідь записав ActiveSessions.
#
# Алгоритм:
#   1. Прочитати JSON-заявку з Requests.
#   2. Прочитати Cache\pc_status_cache.csv.
#   3. Взяти тільки Ready=YES і ActiveSessions.
#   4. Розгорнути кожну активну сесію в окрему ціль доставки.
#   5. Паралельно запустити PsExec через RunspacePool.
#   6. Використовувати -d, щоб не чекати закриття червоного вікна користувачем.
#
# Важливо:
#   OK означає, що PsExec запустив процес показу червоного вікна повідомлення.
#   Це не означає, що користувач натиснув OK.
#
# Рекомендований запуск для 500 РС:
# powershell.exe -NoProfile -ExecutionPolicy Bypass -File "\\vSyncREvit\AlertQueueUI\AlertQueue-Worker-Fast.ps1" -Throttle 200 -TimeoutSec 2 -RunspaceTimeoutSec 8 -NoWait true -UseReadyOnly true

param(
    [string]$RequestFile = "",

    [string]$Root = "\\vSyncREvit\AlertQueueUI",

    [string]$CacheFile = "",

    [string]$PsExecPath = "",

    [int]$Throttle = 200,

    [int]$TimeoutSec = 2,

    [int]$RunspaceTimeoutSec = 8,

    [string]$ArchiveAfterSend = "true",

    [string]$RunAsSystem = "true",

    [string]$NoWait = "true",

    [string]$UseReadyOnly = "true",

    [string]$SendToAllSessions = "true",

    # Для Windows 10 достатньо powershell.exe.
    # Якщо потрібно жорстко: C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
    [string]$PowerShellExe = "powershell.exe",

    # true = менше виводу на екран, швидше на великих списках.
    [string]$Quiet = "true"
)

function Convert-ToBool {
    param(
        [string]$Value,
        [bool]$Default = $true
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Default
    }

    switch ($Value.ToLower()) {
        "true"  { return $true }
        "1"     { return $true }
        "yes"   { return $true }
        "y"     { return $true }

        "false" { return $false }
        "0"     { return $false }
        "no"    { return $false }
        "n"     { return $false }

        default { return $Default }
    }
}

$ArchiveAfterSendBool = Convert-ToBool -Value $ArchiveAfterSend -Default $true
$RunAsSystemBool      = Convert-ToBool -Value $RunAsSystem -Default $true
$NoWaitBool           = Convert-ToBool -Value $NoWait -Default $true
$UseReadyOnlyBool     = Convert-ToBool -Value $UseReadyOnly -Default $true
$SendToAllSessionsBool = Convert-ToBool -Value $SendToAllSessions -Default $true
$QuietBool            = Convert-ToBool -Value $Quiet -Default $true

$RequestDir = Join-Path $Root "Requests"
$LogDir     = Join-Path $Root "Logs"
$ArchiveDir = Join-Path $Root "Archive"
$CacheDir   = Join-Path $Root "Cache"

New-Item -ItemType Directory -Path $RequestDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null
New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null

if ([string]::IsNullOrWhiteSpace($CacheFile)) {
    $CacheFile = Join-Path $CacheDir "pc_status_cache.csv"
}

$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $LogDir "worker_fast_$RunId.csv"
$TextLogFile = Join-Path $LogDir "worker_fast_$RunId.log"

function Write-Info {
    param([string]$Text)

    $Line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
    $Line | Out-File -FilePath $TextLogFile -Encoding UTF8 -Append

    if (-not $QuietBool) {
        Write-Host $Line
    }
}

function Write-Important {
    param([string]$Text)

    $Line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
    $Line | Out-File -FilePath $TextLogFile -Encoding UTF8 -Append
    Write-Host $Line
}

function Stop-WithError {
    param([string]$Text)

    Write-Important "ПОМИЛКА: $Text"
    throw $Text
}

if ([string]::IsNullOrWhiteSpace($PsExecPath)) {
    $LocalPsExec = Join-Path $Root "PsExec.exe"

    if (Test-Path $LocalPsExec) {
        $PsExecPath = $LocalPsExec
    }
    else {
        $Cmd = Get-Command "psexec.exe" -ErrorAction SilentlyContinue

        if ($Cmd) {
            $PsExecPath = $Cmd.Source
        }
        else {
            Stop-WithError "Не знайдено PsExec.exe. Покладіть PsExec.exe у $Root або додайте його в PATH."
        }
    }
}

if ([string]::IsNullOrWhiteSpace($RequestFile)) {
    # Для черги беремо найстарішу заявку, а не найновішу.
    $NextRequest = Get-ChildItem -Path $RequestDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime |
        Select-Object -First 1

    if (-not $NextRequest) {
        Stop-WithError "У папці Requests немає жодної заявки *.json: $RequestDir"
    }

    $RequestFile = $NextRequest.FullName
}

if (-not (Test-Path $RequestFile)) {
    Stop-WithError "Не знайдено файл заявки: $RequestFile"
}

if (-not (Test-Path $CacheFile)) {
    Stop-WithError "Не знайдено кеш готовності РС: $CacheFile. Спочатку запустіть PreCheck."
}

try {
    $Request = Get-Content -Path $RequestFile -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Stop-WithError "Не вдалося прочитати JSON-заявку: $($_.Exception.Message)"
}

if (-not $Request.Title -or -not $Request.Text) {
    Stop-WithError "У заявці немає обов'язкових полів Title або Text: $RequestFile"
}

if (-not $Request.Icon) {
    $Request.Icon = "Information"
}

try {
    $Cache = Import-Csv -Path $CacheFile -Delimiter ";"
}
catch {
    Stop-WithError "Не вдалося прочитати cache CSV: $($_.Exception.Message)"
}

# Формуємо цілі доставки з кешу.
$TargetList = New-Object System.Collections.Generic.List[object]

foreach ($Row in $Cache) {
    if ($UseReadyOnlyBool -eq $true -and $Row.Ready -ne "YES") {
        continue
    }

    if ([string]::IsNullOrWhiteSpace($Row.Computer)) {
        continue
    }

    if ([string]::IsNullOrWhiteSpace($Row.ActiveSessions)) {
        continue
    }

    $Sessions = @(
        $Row.ActiveSessions -split ";" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match "^\d+$" -and [int]$_ -gt 0 } |
            Sort-Object -Unique
    )

    if (@($Sessions).Count -eq 0) {
        continue
    }

    if ($SendToAllSessionsBool -eq $false) {
        $Sessions = @($Sessions | Select-Object -First 1)
    }

    $OSPriorityValue = 9
    try {
        if ($Row.OSPriority) {
            $OSPriorityValue = [int]$Row.OSPriority
        }
    }
    catch {
        $OSPriorityValue = 9
    }

    foreach ($SessionId in $Sessions) {
        $TargetList.Add([PSCustomObject]@{
            Computer           = [string]$Row.Computer
            SessionId          = [string]$SessionId
            WindowsVersionText = [string]$Row.WindowsVersionText
            OSPriority         = $OSPriorityValue
            DeliveryProfile    = [string]$Row.DeliveryProfile
        })
    }
}

$Targets = @(
    $TargetList |
        Sort-Object `
            @{Expression = "OSPriority"; Descending = $false}, `
            @{Expression = "Computer"; Descending = $false}, `
            @{Expression = "SessionId"; Descending = $false}
)

if (@($Targets).Count -eq 0) {
    Stop-WithError "У кеші немає Ready=YES з ActiveSessions. Перевірте PreCheck і pc_status_cache.csv."
}

# Віддалений код без ConvertFrom-Json, сумісний з Windows PowerShell 2.0.
$Title64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$Request.Title))
$Text64  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$Request.Text))
$Icon64  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$Request.Icon))

$RemoteCode = @"
`$Title = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$Title64'))
`$Text = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$Text64'))
`$IconName = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$Icon64'))

[void][System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
[void][System.Reflection.Assembly]::LoadWithPartialName("System.Drawing")

# Визначення типу повідомлення за Title/Text/IconName.
# Пріоритет: ТЕСТ -> ВІДБІЙ -> ТРИВОГА -> DEFAULT.
`$AllText = ((`$Title + " " + `$Text + " " + `$IconName).ToLowerInvariant())
`$AlertKind = "DEFAULT"

if (`$AllText -match "тест|тестове|тестовий|перевірка|перевiрка|навчальн|test|check") {
    `$AlertKind = "TEST"
}
elseif (`$AllText -match "відбій|видбій|вiдбiй|отбой|скасування|скасовано|відміна|вiдмiна|закінчення|закiнчення|all clear|alarm off") {
    `$AlertKind = "CLEAR"
}
elseif (`$AllText -match "тривога|тревога|повітряна|повiтряна|небезпека|укриття|alarm|alert") {
    `$AlertKind = "ALARM"
}

switch (`$AlertKind) {
    "ALARM" {
        `$ConsoleBack = "DarkRed"
        `$ConsoleFore = "White"
        `$BackColor = [System.Drawing.Color]::DarkRed
        `$ForeColor = [System.Drawing.Color]::White
        `$ButtonBackColor = [System.Drawing.Color]::White
        `$ButtonForeColor = [System.Drawing.Color]::DarkRed
        `$BorderColor = [System.Drawing.Color]::White
        `$HeaderPrefix = "УВАГА"
        `$SoundName = "Exclamation"
    }
    "CLEAR" {
        `$ConsoleBack = "DarkGreen"
        `$ConsoleFore = "White"
        `$BackColor = [System.Drawing.Color]::DarkGreen
        `$ForeColor = [System.Drawing.Color]::White
        `$ButtonBackColor = [System.Drawing.Color]::White
        `$ButtonForeColor = [System.Drawing.Color]::DarkGreen
        `$BorderColor = [System.Drawing.Color]::White
        `$HeaderPrefix = "ВІДБІЙ"
        `$SoundName = "Asterisk"
    }
    "TEST" {
        `$ConsoleBack = "DarkBlue"
        `$ConsoleFore = "White"
        `$BackColor = [System.Drawing.Color]::DarkBlue
        `$ForeColor = [System.Drawing.Color]::White
        `$ButtonBackColor = [System.Drawing.Color]::White
        `$ButtonForeColor = [System.Drawing.Color]::DarkBlue
        `$BorderColor = [System.Drawing.Color]::White
        `$HeaderPrefix = "ТЕСТ"
        `$SoundName = "Asterisk"
    }
    default {
        `$ConsoleBack = "DarkGray"
        `$ConsoleFore = "White"
        `$BackColor = [System.Drawing.Color]::DimGray
        `$ForeColor = [System.Drawing.Color]::White
        `$ButtonBackColor = [System.Drawing.Color]::White
        `$ButtonForeColor = [System.Drawing.Color]::DimGray
        `$BorderColor = [System.Drawing.Color]::White
        `$HeaderPrefix = "ПОВІДОМЛЕННЯ"
        `$SoundName = "Asterisk"
    }
}

# Колір саме викликаного віддалено PowerShell-вікна.
# Якщо консоль невидима або запуск іде без повноцінного host UI — помилка ігнорується.
try {
    `$Host.UI.RawUI.BackgroundColor = `$ConsoleBack
    `$Host.UI.RawUI.ForegroundColor = `$ConsoleFore
    `$Host.UI.RawUI.WindowTitle = `$Title
    Clear-Host
}
catch {
}

try {
    switch (`$SoundName) {
        "Exclamation" { [System.Media.SystemSounds]::Exclamation.Play() }
        "Asterisk"    { [System.Media.SystemSounds]::Asterisk.Play() }
        default        { [System.Media.SystemSounds]::Asterisk.Play() }
    }
}
catch {
}

`$Form = New-Object System.Windows.Forms.Form
`$Form.Text = `$Title
`$Form.Width = 780
`$Form.Height = 380
`$Form.StartPosition = "CenterScreen"
`$Form.TopMost = `$true
`$Form.ShowInTaskbar = `$true
`$Form.BackColor = `$BackColor
`$Form.ForeColor = `$ForeColor
`$Form.FormBorderStyle = "FixedDialog"
`$Form.MaximizeBox = `$false
`$Form.MinimizeBox = `$false

`$Header = New-Object System.Windows.Forms.Label
`$Header.Text = if (`$Title -match "^\s*`$HeaderPrefix") { `$Title } else { `$HeaderPrefix + " — " + `$Title }
`$Header.Dock = "Top"
`$Header.Height = 75
`$Header.TextAlign = "MiddleCenter"
`$Header.BackColor = `$BackColor
`$Header.ForeColor = `$ForeColor
`$Header.Font = New-Object System.Drawing.Font("Arial", 26, [System.Drawing.FontStyle]::Bold)

`$Label = New-Object System.Windows.Forms.Label
`$Label.Text = `$Text
`$Label.Dock = "Fill"
`$Label.TextAlign = "MiddleCenter"
`$Label.BackColor = `$BackColor
`$Label.ForeColor = `$ForeColor
`$Label.Font = New-Object System.Drawing.Font("Arial", 22, [System.Drawing.FontStyle]::Bold)
`$Label.AutoSize = `$false

`$BottomPanel = New-Object System.Windows.Forms.Panel
`$BottomPanel.Dock = "Bottom"
`$BottomPanel.Height = 80
`$BottomPanel.BackColor = `$BackColor

`$Button = New-Object System.Windows.Forms.Button
`$Button.Text = "OK"
`$Button.Width = 150
`$Button.Height = 44
`$Button.Top = 16
`$Button.Font = New-Object System.Drawing.Font("Arial", 14, [System.Drawing.FontStyle]::Bold)
`$Button.BackColor = `$ButtonBackColor
`$Button.ForeColor = `$ButtonForeColor
`$Button.DialogResult = [System.Windows.Forms.DialogResult]::OK

`$BottomPanel.Controls.Add(`$Button)

`$Form.Controls.Add(`$Label)
`$Form.Controls.Add(`$BottomPanel)
`$Form.Controls.Add(`$Header)
`$Form.AcceptButton = `$Button

`$Form.Add_Shown({
    `$Button.Left = [int]((`$BottomPanel.ClientSize.Width - `$Button.Width) / 2)
    `$Form.Activate()
})

`$Form.ShowDialog() | Out-Null
"@
$EncodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($RemoteCode))

Write-Important "Старт Fast Worker."
Write-Important "RequestFile: $RequestFile"
Write-Important "CacheFile: $CacheFile"
Write-Important "Цілей доставки: $(@($Targets).Count)"
Write-Important "Throttle: $Throttle"
Write-Important "TimeoutSec PsExec -n: $TimeoutSec"
Write-Important "RunspaceTimeoutSec: $RunspaceTimeoutSec"
Write-Important "NoWait (-d): $NoWaitBool"
Write-Important "RunAsSystem (-s): $RunAsSystemBool"
Write-Important "PowerShellExe: $PowerShellExe"
Write-Important "Log CSV: $LogFile"

$SendScript = {
    param(
        [string]$Computer,
        [string]$SessionId,
        [string]$WindowsVersionText,
        [int]$OSPriority,
        [string]$DeliveryProfile,
        [string]$PsExecPath,
        [string]$PowerShellExe,
        [string]$EncodedCommand,
        [int]$TimeoutSec,
        [bool]$RunAsSystemBool,
        [bool]$NoWaitBool
    )

    $Started = Get-Date
    $Sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $Args = @(
            "\\$Computer",
            "-accepteula",
            "-nobanner",
            "-n", "$TimeoutSec"
        )

        if ($RunAsSystemBool -eq $true) {
            $Args += "-s"
        }

        $Args += @(
            "-i", "$SessionId"
        )

        if ($NoWaitBool -eq $true) {
            $Args += "-d"
        }

        $Args += @(
            $PowerShellExe,
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-EncodedCommand", $EncodedCommand
        )

        $Out = & $PsExecPath @Args 2>&1
        $Exit = $LASTEXITCODE
        $OutText = ($Out | ForEach-Object { $_.ToString() }) -join " "
        $Sw.Stop()

        $StartedOk = $false

        if ($Exit -eq 0) {
            $StartedOk = $true
        }

        if ($OutText -match "started on\s+$([regex]::Escape($Computer))\s+with process ID") {
            $StartedOk = $true
        }

        if ($OutText -match "powershell\.exe started on\s+$([regex]::Escape($Computer))") {
            $StartedOk = $true
        }

        if ($OutText -match "started with process ID") {
            $StartedOk = $true
        }

        if ($StartedOk -eq $true) {
            return [PSCustomObject]@{
                Computer           = $Computer
                SessionId          = $SessionId
                WindowsVersionText = $WindowsVersionText
                OSPriority         = $OSPriority
                DeliveryProfile    = $DeliveryProfile
                Status             = "OK"
                ErrorCategory      = "ALERT_WINDOW_STARTED"
                ExitCode           = $Exit
                DurationMs         = $Sw.ElapsedMilliseconds
                Detail             = "PsExec started alert window; SessionId=$SessionId; NoWait=$NoWaitBool"
                Time               = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
        }
        else {
            return [PSCustomObject]@{
                Computer           = $Computer
                SessionId          = $SessionId
                WindowsVersionText = $WindowsVersionText
                OSPriority         = $OSPriority
                DeliveryProfile    = $DeliveryProfile
                Status             = "ERROR"
                ErrorCategory      = "PSEXEC_FAILED"
                ExitCode           = $Exit
                DurationMs         = $Sw.ElapsedMilliseconds
                Detail             = (($OutText -replace "`r", " ") -replace "`n", " ").Trim()
                Time               = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
        }
    }
    catch {
        $Sw.Stop()

        return [PSCustomObject]@{
            Computer           = $Computer
            SessionId          = $SessionId
            WindowsVersionText = $WindowsVersionText
            OSPriority         = $OSPriority
            DeliveryProfile    = $DeliveryProfile
            Status             = "ERROR"
            ErrorCategory      = "EXCEPTION"
            ExitCode           = 9999
            DurationMs         = $Sw.ElapsedMilliseconds
            Detail             = $_.Exception.Message
            Time               = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
}

$Pool = [RunspaceFactory]::CreateRunspacePool(1, $Throttle)
$Pool.Open()

$Tasks = @()
$Results = New-Object System.Collections.Generic.List[object]
$StartedAll = Get-Date
$Submitted = 0
$Completed = 0

function Receive-FinishedAndTimeoutTasks {
    $Now = Get-Date

    $TimedOut = @(
        $script:Tasks | Where-Object {
            -not $_.Handle.IsCompleted -and
            (($Now - $_.Started).TotalSeconds -gt $RunspaceTimeoutSec)
        }
    )

    foreach ($Task in $TimedOut) {
        try {
            $Task.PS.Dispose()
        }
        catch {
        }

        $Result = [PSCustomObject]@{
            Computer           = $Task.Computer
            SessionId          = $Task.SessionId
            WindowsVersionText = $Task.WindowsVersionText
            OSPriority         = $Task.OSPriority
            DeliveryProfile    = $Task.DeliveryProfile
            Status             = "ERROR"
            ErrorCategory      = "RUNSPACE_TIMEOUT"
            ExitCode           = 9998
            DurationMs         = [int](($Now - $Task.Started).TotalMilliseconds)
            Detail             = "Runspace перевищив таймаут $RunspaceTimeoutSec секунд"
            Time               = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }

        $Results.Add($Result)
        $script:Completed++
        Write-Important "$($Task.Computer) session=$($Task.SessionId): ERROR — RUNSPACE_TIMEOUT"
    }

    $Finished = @(
        $script:Tasks | Where-Object { $_.Handle.IsCompleted }
    )

    foreach ($Task in $Finished) {
        try {
            $Data = $Task.PS.EndInvoke($Task.Handle)

            foreach ($Item in $Data) {
                $Results.Add($Item)

                if ($Item.Status -ne "OK") {
                    Write-Important "$($Item.Computer) session=$($Item.SessionId): $($Item.Status) — $($Item.ErrorCategory) — $($Item.Detail)"
                }
                elseif (-not $QuietBool) {
                    Write-Info "$($Item.Computer) session=$($Item.SessionId): OK — $($Item.DurationMs) ms"
                }
            }
        }
        catch {
            $Result = [PSCustomObject]@{
                Computer           = $Task.Computer
                SessionId          = $Task.SessionId
                WindowsVersionText = $Task.WindowsVersionText
                OSPriority         = $Task.OSPriority
                DeliveryProfile    = $Task.DeliveryProfile
                Status             = "ERROR"
                ErrorCategory      = "ENDINVOKE_EXCEPTION"
                ExitCode           = 9997
                DurationMs         = [int](((Get-Date) - $Task.Started).TotalMilliseconds)
                Detail             = $_.Exception.Message
                Time               = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }

            $Results.Add($Result)
            Write-Important "$($Task.Computer) session=$($Task.SessionId): ERROR — ENDINVOKE_EXCEPTION — $($_.Exception.Message)"
        }
        finally {
            try { $Task.PS.Dispose() } catch {}
        }

        $script:Completed++
    }

    $RemoveKeys = @()
    $RemoveKeys += @($TimedOut | ForEach-Object { $_.Key })
    $RemoveKeys += @($Finished | ForEach-Object { $_.Key })

    if ($RemoveKeys.Count -gt 0) {
        $script:Tasks = @(
            $script:Tasks | Where-Object { $RemoveKeys -notcontains $_.Key }
        )
    }
}

try {
    foreach ($Target in $Targets) {
        while (@($Tasks).Count -ge $Throttle) {
            Receive-FinishedAndTimeoutTasks
            Start-Sleep -Milliseconds 20
        }

        $PS = [PowerShell]::Create()
        $PS.RunspacePool = $Pool

        [void]$PS.AddScript($SendScript)
        [void]$PS.AddArgument([string]$Target.Computer)
        [void]$PS.AddArgument([string]$Target.SessionId)
        [void]$PS.AddArgument([string]$Target.WindowsVersionText)
        [void]$PS.AddArgument([int]$Target.OSPriority)
        [void]$PS.AddArgument([string]$Target.DeliveryProfile)
        [void]$PS.AddArgument([string]$PsExecPath)
        [void]$PS.AddArgument([string]$PowerShellExe)
        [void]$PS.AddArgument([string]$EncodedCommand)
        [void]$PS.AddArgument([int]$TimeoutSec)
        [void]$PS.AddArgument([bool]$RunAsSystemBool)
        [void]$PS.AddArgument([bool]$NoWaitBool)

        $Handle = $PS.BeginInvoke()
        $Submitted++

        $Tasks += [PSCustomObject]@{
            Key                = [Guid]::NewGuid().ToString("N")
            PS                 = $PS
            Handle             = $Handle
            Computer           = [string]$Target.Computer
            SessionId          = [string]$Target.SessionId
            WindowsVersionText = [string]$Target.WindowsVersionText
            OSPriority         = [int]$Target.OSPriority
            DeliveryProfile    = [string]$Target.DeliveryProfile
            Started            = Get-Date
        }

        if (($Submitted % 100) -eq 0) {
            Write-Important "Submitted: $Submitted / $(@($Targets).Count), Completed: $Completed"
        }
    }

    while (@($Tasks).Count -gt 0) {
        Receive-FinishedAndTimeoutTasks
        Start-Sleep -Milliseconds 20
    }
}
finally {
    try { $Pool.Close() } catch {}
    try { $Pool.Dispose() } catch {}
}

$TotalSeconds = [math]::Round(((Get-Date) - $StartedAll).TotalSeconds, 2)

$Results |
    Sort-Object `
        @{Expression = { [int]$_.OSPriority }; Descending = $false}, `
        @{Expression = "Computer"; Descending = $false}, `
        @{Expression = "SessionId"; Descending = $false} |
    Export-Csv -Path $LogFile -NoTypeInformation -Encoding UTF8 -Delimiter ";"

$OkCount = @($Results | Where-Object { $_.Status -eq "OK" }).Count
$ErrCount = @($Results | Where-Object { $_.Status -ne "OK" }).Count

Write-Important "Готово."
Write-Important "Targets: $(@($Targets).Count)"
Write-Important "OK: $OkCount"
Write-Important "ERROR: $ErrCount"
Write-Important "ElapsedSec: $TotalSeconds"
Write-Important "Log CSV: $LogFile"

if ($ArchiveAfterSendBool -eq $true) {
    try {
        $RequestName = Split-Path $RequestFile -Leaf
        $ArchiveFile = Join-Path $ArchiveDir $RequestName

        if (Test-Path $ArchiveFile) {
            $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($RequestName)
            $ArchiveFile = Join-Path $ArchiveDir ("{0}_{1}.json" -f $BaseName, $RunId)
        }

        Move-Item -Path $RequestFile -Destination $ArchiveFile -Force
        Write-Important "Заявку перенесено в архів: $ArchiveFile"
    }
    catch {
        Write-Important "Не вдалося перенести заявку в архів: $($_.Exception.Message)"
    }
}
else {
    Write-Important "Архівування вимкнено параметром -ArchiveAfterSend false"
}
