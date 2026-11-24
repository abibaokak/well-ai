#requires -Version 5.1
<#
    Well AI — локальный чат-ассистент с генерацией кода и картинок.
    Использует только стандартные возможности Windows PowerShell 5.1.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:AppName    = 'Well AI'
$script:AppVersion = '1.0.0'
$script:ConfigDir  = Join-Path $env:APPDATA 'Well AI'
$script:ConfigPath = Join-Path $script:ConfigDir 'config.json'
$script:HistoryPath= Join-Path $script:ConfigDir 'history.json'
$script:ImagesDir  = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Well AI'
$script:InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$script:DefaultSystemPrompt = @'
Ты Well AI — полезный локальный ассистент, который особенно хорошо пишет код.
Отвечай на языке пользователя (если пишут по-русски — отвечай по-русски).
Когда просят код:
1. Давай готовый рабочий пример, а не только идею.
2. Указывай язык блока кода и, если важно, версию/окружение (Windows, PowerShell 5.1, Python 3, Minecraft Paper 1.21 и т.д.).
3. Кратко объясняй, как запустить и где взять секреты/ключи.
4. Не выдумывай несуществующие библиотеки и API.
5. Если нужно изменить чужой код — показывай конкретные правки.
Будь дружелюбным, но не слишком многословным.
'@

$script:DefaultConfig = @{
    apiBase      = 'https://api.openai.com/v1'
    apiKey       = ''
    chatModel    = 'gpt-4o-mini'
    imageModel   = 'gpt-image-1'
    imageSize    = '1024x1024'
    temperature  = 0.7
    maxTokens    = 2000
    saveHistory  = $true
    systemPrompt = $script:DefaultSystemPrompt
}

# ---------------------------------------------------------------------------
# Конфиг и история
# ---------------------------------------------------------------------------

function Get-WellConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        return ($script:DefaultConfig.Clone())
    }
    try {
        $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8
        $loaded = $raw | ConvertFrom-Json
        $result = @{}
        foreach ($key in $script:DefaultConfig.Keys) {
            $value = $script:DefaultConfig[$key]
            if ($loaded.PSObject.Properties.Name -contains $key -and $null -ne $loaded.$key) {
                $value = $loaded.$key
            }
            $result[$key] = $value
        }
        return $result
    } catch {
        return ($script:DefaultConfig.Clone())
    }
}

function Save-WellConfig {
    param([hashtable]$Config)
    New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null
    $Config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
}

function Get-WellHistory {
    if (-not $script:Config.saveHistory) { return @() }
    if (-not (Test-Path -LiteralPath $script:HistoryPath)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $script:HistoryPath -Raw -Encoding UTF8
        $items = @($raw | ConvertFrom-Json)
        if ($items.Count -gt 60) { $items = $items[($items.Count - 60)..($items.Count - 1)] }
        return @($items | ForEach-Object { @{ role = [string]$_.role; content = [string]$_.content } })
    } catch {
        return @()
    }
}

function Save-WellHistory {
    param([object[]]$Messages)
    if (-not $script:Config.saveHistory) { return }
    New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null
    @($Messages | Select-Object -Last 60) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:HistoryPath -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Вспомогательное для UI
# ---------------------------------------------------------------------------

function Add-ChatLine {
    param(
        [string]$Prefix,
        [string]$Text,
        [System.Drawing.Color]$Color
    )
    $box = $script:ChatBox
    $box.SelectionStart = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionColor = $Color
    $box.AppendText($Prefix + $Text + [Environment]::NewLine + [Environment]::NewLine)
    $box.SelectionColor = $script:ChatBox.ForeColor
    $box.ScrollToCaret()
}

function Set-Status {
    param([string]$Text, [System.Drawing.Color]$Color = [System.Drawing.Color]::FromArgb(90, 90, 90))
    $script:StatusLabel.Text = $Text
    $script:StatusLabel.ForeColor = $Color
}

function Set-Busy {
    param([bool]$Busy)
    $script:SendButton.Enabled   = -not $Busy
    $script:ImageButton.Enabled  = -not $Busy
    $script:SettingsButton.Enabled = -not $Busy
    $script:InputBox.Enabled     = -not $Busy
    if ($Busy) { $script:MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    else { $script:MainForm.Cursor = [System.Windows.Forms.Cursors]::Default }
}

function Test-ApiKey {
    if ([string]::IsNullOrWhiteSpace($script:Config.apiKey)) {
        Add-ChatLine 'Well AI: ' 'Сначала введите API-ключ: меню «Настройки» или кнопка «⚙». Ключ хранится только локально.' ([System.Drawing.Color]::FromArgb(190, 90, 40))
        Set-Status 'Нет API-ключа' ([System.Drawing.Color]::FromArgb(190, 90, 40))
        return $false
    }
    return $true
}

# ---------------------------------------------------------------------------
# API-запросы (в фоновом задании, чтобы окно не подвисало)
# ---------------------------------------------------------------------------

function Start-ChatRequest {
    param([string]$UserText)

    if (-not (Test-ApiKey)) { return }
    if ([string]::IsNullOrWhiteSpace($UserText)) { return }

    Add-ChatLine 'Вы: ' $UserText ([System.Drawing.Color]::FromArgb(30, 90, 170))
    $script:InputBox.Clear()

    $messages = @()
    foreach ($m in $script:History) {
        $messages += @{ role = [string]$m.role; content = [string]$m.content }
    }
    $messages += @{ role = 'user'; content = $UserText }

    $payload = @{
        config   = $script:Config
        messages = $messages
    } | ConvertTo-Json -Depth 20 -Compress

    Set-Busy $true
    Set-Status 'Well AI думает...' ([System.Drawing.Color]::FromArgb(40, 120, 90))

    $script:ActiveJob = Start-Job -ScriptBlock {
        param($json)
        $data = $json | ConvertFrom-Json
        $bodyObj = @{
            model       = [string]$data.config.chatModel
            messages    = $data.messages
            temperature = [double]$data.config.temperature
            max_tokens  = [int]$data.config.maxTokens
        }
        $body = $bodyObj | ConvertTo-Json -Depth 20 -Compress
        $headers = @{
            Authorization = 'Bearer ' + [string]$data.config.apiKey
            'Content-Type' = 'application/json'
        }
        try {
            $resp = Invoke-RestMethod -Method Post -Uri ([string]$data.config.apiBase + '/chat/completions') -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec 180
            $text = ''
            if ($resp.choices -and $resp.choices.Count -gt 0) {
                $text = [string]$resp.choices[0].message.content
                if ([string]::IsNullOrWhiteSpace($text)) { $text = [string]$resp.choices[0].text }
            }
            if ([string]::IsNullOrWhiteSpace($text)) { throw 'Пустой ответ от модели.' }
            [pscustomobject]@{ ok = $true; text = $text }
        } catch {
            $msg = $_.Exception.Message
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $_.ErrorDetails.Message }
            [pscustomobject]@{ ok = $false; text = $msg }
        }
    } -ArgumentList $payload

    $script:JobTimer.Start()
}

function Start-ImageRequest {
    param([string]$Prompt)

    if (-not (Test-ApiKey)) { return }
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        Add-ChatLine 'Well AI: ' 'Напишите, какую картинку сгенерировать, например: «кошмарный бургер в стиле пиксель-арт».' ([System.Drawing.Color]::FromArgb(190, 90, 40))
        return
    }

    Add-ChatLine 'Вы (картинка): ' $Prompt ([System.Drawing.Color]::FromArgb(120, 70, 170))
    $script:InputBox.Clear()

    New-Item -ItemType Directory -Force -Path $script:ImagesDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $outPath = Join-Path $script:ImagesDir ("wellai_$stamp.png")

    $payload = @{
        config = $script:Config
        prompt = $Prompt
        out    = $outPath
    } | ConvertTo-Json -Depth 20 -Compress

    Set-Busy $true
    Set-Status 'Генерирую картинку...' ([System.Drawing.Color]::FromArgb(120, 70, 170))

    $script:ActiveJob = Start-Job -ScriptBlock {
        param($json)
        $data = $json | ConvertFrom-Json
        $bodyObj = @{
            model  = [string]$data.config.imageModel
            prompt = [string]$data.prompt
            n      = 1
            size   = [string]$data.config.imageSize
        }
        if ([string]$data.config.imageModel -notlike 'gpt-image*') {
            $bodyObj.response_format = 'b64_json'
        }
        $body = $bodyObj | ConvertTo-Json -Depth 10 -Compress
        $headers = @{
            Authorization = 'Bearer ' + [string]$data.config.apiKey
            'Content-Type' = 'application/json'
        }
        try {
            $resp = Invoke-RestMethod -Method Post -Uri ([string]$data.config.apiBase + '/images/generations') -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec 240
            $item = $resp.data[0]
            if ($item.b64_json) {
                $bytes = [Convert]::FromBase64String([string]$item.b64_json)
                [IO.File]::WriteAllBytes([string]$data.out, $bytes)
            } elseif ($item.url) {
                Invoke-WebRequest -Uri ([string]$item.url) -OutFile ([string]$data.out) -UseBasicParsing -TimeoutSec 120
            } else {
                throw 'API вернул ни base64, ни ссылку.'
            }
            [pscustomobject]@{ ok = $true; path = [string]$data.out }
        } catch {
            $msg = $_.Exception.Message
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $_.ErrorDetails.Message }
            [pscustomobject]@{ ok = $false; text = $msg }
        }
    } -ArgumentList $payload

    $script:JobTimer.Start()
}

function On-JobTimerTick {
    $job = $script:ActiveJob
    if (-not $job) { return }
    $state = [string]$job.JobStateInfo.State
    if ($state -in @('Running', 'Pending', 'NotStarted')) { return }

    $script:JobTimer.Stop()
    $result = @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    $script:ActiveJob = $null
    Set-Busy $false

    $r = if ($result.Count -gt 0) { $result[0] } else { $null }
    if (-not $r) {
        Add-ChatLine 'Well AI: ' 'Не удалось получить ответ. Попробуйте ещё раз.' ([System.Drawing.Color]::FromArgb(190, 60, 60))
        Set-Status 'Ошибка запроса' ([System.Drawing.Color]::FromArgb(190, 60, 60))
        return
    }

    if (-not $r.ok) {
        Add-ChatLine 'Well AI (ошибка): ' ([string]$r.text) ([System.Drawing.Color]::FromArgb(190, 60, 60))
        Set-Status 'Ошибка API' ([System.Drawing.Color]::FromArgb(190, 60, 60))
        return
    }

    if ($r.PSObject.Properties.Name -contains 'path') {
        Add-ChatLine 'Well AI: ' ('Картинка сохранена: ' + $r.path) ([System.Drawing.Color]::FromArgb(40, 130, 90))
        Set-Status 'Картинка готова' ([System.Drawing.Color]::FromArgb(40, 130, 90))
    } else {
        $answer = [string]$r.text
        Add-ChatLine 'Well AI: ' $answer ([System.Drawing.Color]::FromArgb(30, 120, 80))
        $script:History += @{ role = 'assistant'; content = $answer }
        Save-WellHistory $script:History
        Set-Status 'Готово' ([System.Drawing.Color]::FromArgb(40, 130, 90))
    }
}

# ---------------------------------------------------------------------------
# Окно настроек
# ---------------------------------------------------------------------------

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 120)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, 22)
    return $l
}

function New-TextBox {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 24, [bool]$Password = $false, [bool]$Multi = $false)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Text = $Text
    $t.Location = New-Object System.Drawing.Point($X, $Y)
    $t.Size = New-Object System.Drawing.Size($W, $H)
    $t.Multiline = $Multi
    $t.ScrollBars = if ($Multi) { [System.Windows.Forms.ScrollBars]::Vertical } else { [System.Windows.Forms.ScrollBars]::None }
    if ($Password) { $t.UseSystemPasswordChar = $true }
    return $t
}

function Show-SettingsDialog {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Well AI — настройки'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(700, 620)
    $form.MinimumSize = $form.Size
    $form.FormBorderStyle = 'FixedDialog'

    $form.Controls.Add((New-Label 'API Base (OpenAI-совместимый)' 20 20 300))
    $tbBase = New-TextBox ([string]$script:Config.apiBase) 20 45 640

    $form.Controls.Add((New-Label 'API-ключ' 20 85 300))
    $tbKey = New-TextBox ([string]$script:Config.apiKey) 20 110 640 24 $true

    $form.Controls.Add((New-Label 'Модель для чата' 20 150 200))
    $tbChat = New-TextBox ([string]$script:Config.chatModel) 200 147 460

    $form.Controls.Add((New-Label 'Модель для картинок' 20 182 200))
    $tbImage = New-TextBox ([string]$script:Config.imageModel) 200 179 460

    $form.Controls.Add((New-Label 'Размер картинки' 20 214 200))
    $cbSize = New-Object System.Windows.Forms.ComboBox
    $cbSize.Location = New-Object System.Drawing.Point(200, 211)
    $cbSize.Size = New-Object System.Drawing.Size(220, 24)
    $cbSize.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    @('1024x1024', '1536x1024', '1024x1536', '1792x1024', '1024x1792') | ForEach-Object { [void]$cbSize.Items.Add($_) }
    if ($cbSize.Items.Contains([string]$script:Config.imageSize)) { $cbSize.SelectedItem = [string]$script:Config.imageSize } else { $cbSize.SelectedIndex = 0 }

    $form.Controls.Add((New-Label 'Temperature' 20 248 200))
    $tbTemp = New-TextBox ([string]$script:Config.temperature) 200 245 100

    $form.Controls.Add((New-Label 'Max tokens' 330 248 200))
    $tbMax = New-TextBox ([string]$script:Config.maxTokens) 440 245 100

    $form.Controls.Add((New-Label 'Системный промпт' 20 282 300))
    $tbPrompt = New-TextBox ([string]$script:Config.systemPrompt) 20 307 640 180 $false $true

    $cbHistory = New-Object System.Windows.Forms.CheckBox
    $cbHistory.Text = 'Сохранять историю диалога локально'
    $cbHistory.Location = New-Object System.Drawing.Point(20, 500)
    $cbHistory.Size = New-Object System.Drawing.Size(400, 24)
    $cbHistory.Checked = [bool]$script:Config.saveHistory
    $form.Controls.Add($cbHistory)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = 'Сохранить'
    $btnSave.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnSave.Location = New-Object System.Drawing.Point(390, 535)
    $btnSave.Size = New-Object System.Drawing.Size(125, 34)
    $form.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Отмена'
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancel.Location = New-Object System.Drawing.Point(535, 535)
    $btnCancel.Size = New-Object System.Drawing.Size(125, 34)
    $form.Controls.Add($btnCancel)

    $form.AcceptButton = $btnSave
    $form.CancelButton = $btnCancel

    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:Config.apiBase      = $tbBase.Text.Trim()
        $script:Config.apiKey       = $tbKey.Text.Trim()
        $script:Config.chatModel    = $tbChat.Text.Trim()
        $script:Config.imageModel   = $tbImage.Text.Trim()
        $script:Config.imageSize    = [string]$cbSize.SelectedItem
        $script:Config.systemPrompt = $tbPrompt.Text
        $script:Config.saveHistory  = $cbHistory.Checked
        $number = 0.7
        if ([double]::TryParse($tbTemp.Text, [ref]$number)) { $script:Config.temperature = $number }
        $intNumber = 2000
        if ([int]::TryParse($tbMax.Text, [ref]$intNumber)) { $script:Config.maxTokens = $intNumber }
        Save-WellConfig $script:Config
        Set-Status 'Настройки сохранены' ([System.Drawing.Color]::FromArgb(40, 130, 90))
    }
}

# ---------------------------------------------------------------------------
# Главное окно
# ---------------------------------------------------------------------------

$script:Config = Get-WellConfig
$script:History = @()
if ($script:Config.saveHistory) { $script:History = @(Get-WellHistory) }
$script:ActiveJob = $null

$form = New-Object System.Windows.Forms.Form
$script:MainForm = $form
$form.Text = "$script:AppName $script:AppVersion"
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(900, 680)
$form.MinimumSize = New-Object System.Drawing.Size(700, 500)

$iconPath = Join-Path $script:InstallDir 'wellai.ico'
if (Test-Path -LiteralPath $iconPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch {}
}

# Меню
$menu = New-Object System.Windows.Forms.MainMenu
$miFile = New-Object System.Windows.Forms.MenuItem('Файл')
$miSettings = New-Object System.Windows.Forms.MenuItem('Настройки...')
$miClear = New-Object System.Windows.Forms.MenuItem('Очистить диалог')
$miExit = New-Object System.Windows.Forms.MenuItem('Выход')
$miFile.MenuItems.AddRange(@($miSettings, $miClear, $miExit))
$miHelp = New-Object System.Windows.Forms.MenuItem('Помощь')
$miAbout = New-Object System.Windows.Forms.MenuItem('О Well AI')
$miHelp.MenuItems.Add($miAbout)
$menu.MenuItems.AddRange(@($miFile, $miHelp))
$form.Menu = $menu

# Верхняя панель
$top = New-Object System.Windows.Forms.Panel
$top.Dock = [System.Windows.Forms.DockStyle]::Top
$top.Height = 48
$top.BackColor = [System.Drawing.Color]::FromArgb(32, 38, 52)
$form.Controls.Add($top)

$title = New-Object System.Windows.Forms.Label
$title.Text = "$script:AppName — код, ответы, картинки"
$title.ForeColor = [System.Drawing.Color]::White
$title.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(16, 6)
$title.Size = New-Object System.Drawing.Size(420, 28)
$top.Controls.Add($title)

$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.Text = 'Готов'
$script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(180, 190, 205)
$script:StatusLabel.Location = New-Object System.Drawing.Point(470, 12)
$script:StatusLabel.Size = New-Object System.Drawing.Size(410, 24)
$script:StatusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$top.Controls.Add($script:StatusLabel)

# Чат
$script:ChatBox = New-Object System.Windows.Forms.RichTextBox
$script:ChatBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:ChatBox.ReadOnly = $true
$script:ChatBox.BackColor = [System.Drawing.Color]::White
$script:ChatBox.Font = New-Object System.Drawing.Font('Consolas', 10)
$script:ChatBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$form.Controls.Add($script:ChatBox)

# Нижняя панель ввода
$bottom = New-Object System.Windows.Forms.Panel
$bottom.Dock = [System.Windows.Forms.DockStyle]::Bottom
$bottom.Height = 108
$bottom.Padding = New-Object System.Windows.Forms.Padding(10)
$form.Controls.Add($bottom)

$script:InputBox = New-Object System.Windows.Forms.TextBox
$script:InputBox.Multiline = $true
$script:InputBox.AcceptsReturn = $true
$script:InputBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$script:InputBox.Location = New-Object System.Drawing.Point(10, 8)
$script:InputBox.Size = New-Object System.Drawing.Size(880, 56)
$script:InputBox.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.Controls.Add($script:InputBox) # будет перемещён в bottom ниже
$bottom.Controls.Add($script:InputBox)
$script:InputBox.Location = New-Object System.Drawing.Point(10, 8)
$script:InputBox.Size = New-Object System.Drawing.Size(660, 56)

$script:SendButton = New-Object System.Windows.Forms.Button
$script:SendButton.Text = 'Отправить'
$script:SendButton.Location = New-Object System.Drawing.Point(680, 8)
$script:SendButton.Size = New-Object System.Drawing.Size(100, 26)
$bottom.Controls.Add($script:SendButton)

$script:ImageButton = New-Object System.Windows.Forms.Button
$script:ImageButton.Text = 'Картинка'
$script:ImageButton.Location = New-Object System.Drawing.Point(790, 8)
$script:ImageButton.Size = New-Object System.Drawing.Size(90, 26)
$bottom.Controls.Add($script:ImageButton)

$script:SettingsButton = New-Object System.Windows.Forms.Button
$script:SettingsButton.Text = '⚙'
$script:SettingsButton.Location = New-Object System.Drawing.Point(845, 40)
$script:SettingsButton.Size = New-Object System.Drawing.Size(35, 26)
$bottom.Controls.Add($script:SettingsButton)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = 'Копировать'
$btnCopy.Location = New-Object System.Drawing.Point(680, 40)
$btnCopy.Size = New-Object System.Drawing.Size(100, 26)
$bottom.Controls.Add($btnCopy)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = 'Папка картинок'
$btnFolder.Location = New-Object System.Drawing.Point(790, 40)
$btnFolder.Size = New-Object System.Drawing.Size(50, 26)
$bottom.Controls.Add($btnFolder)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Enter — отправить · Shift+Enter — новая строка'
$hint.Location = New-Object System.Drawing.Point(10, 70)
$hint.Size = New-Object System.Drawing.Size(400, 22)
$hint.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
$bottom.Controls.Add($hint)

# Таймер опроса фонового задания
$script:JobTimer = New-Object System.Windows.Forms.Timer
$script:JobTimer.Interval = 250
$script:JobTimer.add_Tick({ On-JobTimerTick })

# События
$script:SendButton.add_Click({
    $text = $script:InputBox.Text
    Start-ChatRequest -UserText $text
})

$script:ImageButton.add_Click({
    $text = $script:InputBox.Text
    Start-ImageRequest -Prompt $text
})

$script:SettingsButton.add_Click({ Show-SettingsDialog })
$miSettings.add_Click({ Show-SettingsDialog })

$miClear.add_Click({
    $script:ChatBox.Clear()
    $script:History = @()
    if (Test-Path -LiteralPath $script:HistoryPath) { Remove-Item -LiteralPath $script:HistoryPath -Force }
    Set-Status 'Диалог очищен'
})

$miExit.add_Click({ $form.Close() })
$miAbout.add_Click({
    [System.Windows.Forms.MessageBox]::Show(
        "$script:AppName $script:AppVersion`n`nЛокальный чат-ассистент с генерацией кода и картинок.`nAPI-ключ хранится только на этом компьютере.",
        'О Well AI',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
})

$btnCopy.add_Click({
    try {
        [System.Windows.Forms.Clipboard]::SetText($script:ChatBox.Text)
        Set-Status 'Скопировано в буфер'
    } catch {
        Set-Status 'Не удалось скопировать' ([System.Drawing.Color]::FromArgb(190, 60, 60))
    }
})

$btnFolder.add_Click({
    New-Item -ItemType Directory -Force -Path $script:ImagesDir | Out-Null
    Start-Process explorer.exe $script:ImagesDir
})

$script:InputBox.add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter -and -not $e.Shift) {
        $e.SuppressKeyPress = $true
        Start-ChatRequest -UserText $script:InputBox.Text
    }
})

# Приветствие
Add-ChatLine 'Well AI: ' 'Привет! Я Well AI. Спроси меня про код, напиши «напиши скрипт...» или введи описание и нажми «Картинка».' ([System.Drawing.Color]::FromArgb(30, 120, 80))
foreach ($m in $script:History) {
    if ([string]$m.role -eq 'user') {
        Add-ChatLine 'Вы: ' ([string]$m.content) ([System.Drawing.Color]::FromArgb(30, 90, 170))
    } elseif ([string]$m.role -eq 'assistant') {
        Add-ChatLine 'Well AI: ' ([string]$m.content) ([System.Drawing.Color]::FromArgb(30, 120, 80))
    }
}
if ([string]::IsNullOrWhiteSpace($script:Config.apiKey)) {
    Set-Status 'Нужно указать API-ключ' ([System.Drawing.Color]::FromArgb(190, 90, 40))
}

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
