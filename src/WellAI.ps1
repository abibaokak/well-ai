#requires -Version 5.1
<#
    Well AI — локальный чат-ассистент с генерацией кода и картинок.
    Интерфейс в стиле современных чат-ассистентов: боковая панель,
    пузыри сообщений, блоки кода, новые чаты и вложение файлов.
    Только стандартные возможности Windows PowerShell 5.1.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:AppName    = 'Well AI'
$script:AppVersion = '1.1.0'
$script:ConfigDir  = Join-Path $env:APPDATA 'Well AI'
$script:ConfigPath = Join-Path $script:ConfigDir 'config.json'
$script:ChatsDir   = Join-Path $script:ConfigDir 'chats'
$script:HistoryPath= Join-Path $script:ConfigDir 'history.json'
$script:ImagesDir  = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Well AI'
$script:InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$script:Bg        = [System.Drawing.Color]::FromArgb(13, 17, 28)
$script:SidebarBg = [System.Drawing.Color]::FromArgb(20, 26, 42)
$script:PanelBg   = [System.Drawing.Color]::FromArgb(24, 31, 50)
$script:TextColor = [System.Drawing.Color]::FromArgb(232, 237, 248)
$script:MutedColor= [System.Drawing.Color]::FromArgb(138, 151, 181)
$script:Accent    = [System.Drawing.Color]::FromArgb(65, 130, 255)
$script:Accent2   = [System.Drawing.Color]::FromArgb(125, 105, 255)
$script:Green     = [System.Drawing.Color]::FromArgb(62, 207, 142)
$script:Red       = [System.Drawing.Color]::FromArgb(240, 90, 90)

$script:DefaultSystemPrompt = @'
Ты Well AI — локальный ассистент, который особенно хорошо пишет код.
ПРАВИЛО ЯЗЫКА: если пользователь пишет по-русски, ВЕСЬ ответ без исключений должен быть на русском языке. Никогда не отвечай на английском, если вопрос задан по-русски.
ПРАВИЛО КОДА: когда просят код, сначала дай готовый рабочий код в блоке с указанием языка, затем коротко объясни по-русски, как его запустить.
Не выдумывай несуществующие библиотеки и API. Отвечай кратко и по делу.
'@

$script:DefaultConfig = @{
    apiBase      = 'http://127.0.0.1:11434/v1'
    imageApiBase = 'https://api.openai.com/v1'
    apiKey       = ''
    chatModel    = 'qwen2.5-coder:3b'
    imageModel   = 'gpt-image-1'
    imageSize    = '1024x1024'
    temperature  = 0.3
    maxTokens    = 2000
    saveHistory  = $true
    systemPrompt = $script:DefaultSystemPrompt
}

# ---------------------------------------------------------------------------
# Конфиг и хранилище чатов
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
        if ([string]$result.systemPrompt -match 'полезный локальный ассистент') {
            $result.systemPrompt = $script:DefaultSystemPrompt
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

function Initialize-ChatStorage {
    New-Item -ItemType Directory -Force -Path $script:ChatsDir | Out-Null
    # Старый history.json мог содержать ответы с "???" — в новые чаты его не переносим.
}

function Get-ChatPath {
    param([string]$ChatId)
    $safe = [string]$ChatId -replace '[^A-Za-z0-9_-]', '_'
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'chat_empty' }
    return (Join-Path $script:ChatsDir ($safe + '.json'))
}

function Get-ChatTitle {
    param([object[]]$Messages)
    foreach ($m in $Messages) {
        if ([string]$m.role -eq 'user') {
            $text = ([string]$m.content) -replace "`r?`n", ' ' -replace '```.*', ''
            $text = $text.Trim()
            if ($text.Length -gt 42) { $text = $text.Substring(0, 42) + '…' }
            if ($text.Length -gt 0) { return $text }
        }
    }
    return 'Новый чат'
}

function Save-Chat {
    if (-not $script:CurrentChatId) { return }
    $chat = @{
        id       = [string]$script:CurrentChatId
        title    = Get-ChatTitle -Messages $script:Messages
        messages = @($script:Messages)
        updated  = (Get-Date).ToString('o')
    }
    $chat | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Get-ChatPath $script:CurrentChatId) -Encoding UTF8
}

function Load-Chat {
    param([string]$ChatId)
    $path = Get-ChatPath $ChatId
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:CurrentChatId = $ChatId
        $script:Messages = @()
        foreach ($m in @($data.messages)) {
            $script:Messages += @{
                role    = [string]$m.role
                content = [string]$m.content
                type    = if ($m.PSObject.Properties.Name -contains 'type') { [string]$m.type } else { 'text' }
            }
        }
        Clear-Browser
        foreach ($m in $script:Messages) {
            if ($m.type -eq 'image') {
                Add-BrowserMessage -Role 'assistant' -Html (Get-ImageHtml -Path $m.content) -Meta 'картинка'
            } else {
                Add-BrowserMessage -Role ([string]$m.role) -Html (ConvertTo-ChatHtml -Text $m.content)
            }
        }
        $script:TitleLabel.Text = Get-ChatTitle -Messages $script:Messages
        Set-Status 'Чат загружен'
    } catch {
        Set-Status 'Не удалось загрузить чат' $script:Red
    }
}

function New-Chat {
    $script:CurrentChatId = 'chat_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
    $script:Messages = @()
    Save-Chat
    Clear-Browser
    $script:TitleLabel.Text = 'Новый чат'
    Refresh-ChatButtons
    Set-Status 'Новый чат' $script:Green
}

function Refresh-ChatButtons {
    if (-not $script:ChatListPanel) { return }
    foreach ($c in @($script:ChatButtons)) {
        $script:ChatListPanel.Controls.Remove($c)
        $c.Dispose()
    }
    $script:ChatButtons = @()
    $files = @(Get-ChildItem -LiteralPath $script:ChatsDir -Filter 'chat_*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 12)
    foreach ($f in $files) {
        try {
            $data = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch { continue }
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = Get-ChatTitle -Messages @($data.messages)
        $btn.Tag = [string]$data.id
        $btn.Dock = [System.Windows.Forms.DockStyle]::Top
        $btn.Height = 46
        $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btn.FlatAppearance.BorderSize = 0
        $btn.BackColor = if ([string]$data.id -eq [string]$script:CurrentChatId) { $script:PanelBg } else { $script:SidebarBg }
        $btn.ForeColor = $script:TextColor
        $btn.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $btn.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $btn.Padding = New-Object System.Windows.Forms.Padding(12, 0, 8, 0)
        $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
        $btn.add_Click({
            param($sender, $e)
            Load-Chat -ChatId ([string]$sender.Tag)
            Refresh-ChatButtons
        })
        $script:ChatListPanel.Controls.Add($btn)
        $script:ChatButtons += $btn
    }
}

# ---------------------------------------------------------------------------
# HTML-отображение чата
# ---------------------------------------------------------------------------

function Convert-PlainHtml {
    param([string]$Text)
    $encoded = [System.Net.WebUtility]::HtmlEncode($Text)
    return [regex]::Replace($encoded, "`r`n|`n", '<br>')
}

function ConvertTo-ChatHtml {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $sb = New-Object System.Text.StringBuilder
    $index = 0
    foreach ($m in [regex]::Matches($Text, '(?s)```([A-Za-z0-9_+#.-]*)\r?\n(.*?)```')) {
        if ($m.Index -gt $index) {
            [void]$sb.Append((Convert-PlainHtml -Text $Text.Substring($index, $m.Index - $index)))
        }
        [void]$sb.Append('<pre><code>')
        [void]$sb.Append([System.Net.WebUtility]::HtmlEncode($m.Groups[2].Value))
        [void]$sb.Append('</code></pre>')
        $index = $m.Index + $m.Length
    }
    if ($index -lt $Text.Length) {
        [void]$sb.Append((Convert-PlainHtml -Text $Text.Substring($index)))
    }
    return $sb.ToString()
}

function Get-ImageHtml {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '[Картинка не найдена]' }
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $base64 = [Convert]::ToBase64String($bytes)
        return '<img src="data:image/png;base64,' + $base64 + '">'
    } catch {
        return '[Не удалось прочитать картинку]'
    }
}

function Clear-Browser {
    if (-not $script:Browser -or -not $script:Browser.Document) { return }
    try { $script:Browser.Document.InvokeScript('clearChat') } catch {}
}

function Add-BrowserMessage {
    param([string]$Role, [string]$Html, [string]$Meta = '')
    if (-not $script:Browser -or -not $script:Browser.Document) { return }
    try {
        [void]$script:Browser.Document.InvokeScript('addMessage', @($Role, $Html, $Meta))
    } catch {}
}

function Get-ChatTemplate {
    return @'
<html><head><meta charset="utf-8"><style>
html,body{margin:0;padding:0;height:100%;background:#0d111c;color:#e8edf8;font-family:'Segoe UI',Arial,sans-serif;font-size:14px;line-height:1.55}
#chat{padding:26px 34px 34px 34px}
.msg{margin:0 0 18px;display:flex;justify-content:flex-start}
.msg.user{justify-content:flex-end}
.bubble{max-width:78%;padding:12px 16px;border-radius:14px;background:#182033;border:1px solid #26314d;box-shadow:0 6px 18px rgba(0,0,0,.18);word-wrap:break-word;overflow-wrap:break-word}
.msg.user .bubble{background:#2b6cf5;border-color:#2b6cf5;color:#fff;border-bottom-right-radius:4px}
.msg.assistant .bubble{border-bottom-left-radius:4px}
pre{margin:8px 0 4px 0;background:#0a0e18;border:1px solid #26314d;border-radius:9px;padding:11px 13px;overflow:auto;white-space:pre-wrap;word-wrap:break-word;font-family:Consolas,'Courier New',monospace;font-size:13px;color:#d8e4ff}
code{font-family:Consolas,'Courier New',monospace}
img{max-width:100%;border-radius:10px;border:1px solid #26314d;display:block}
.meta{font-size:11px;color:#8a97b5;margin-top:5px}
</style></head><body>
<div id="chat"></div>
<script>
function addMessage(role, html, meta){
  var wrap=document.createElement('div'); wrap.className='msg '+role;
  var bub=document.createElement('div'); bub.className='bubble'; bub.innerHTML=html;
  wrap.appendChild(bub);
  if(meta){ var m=document.createElement('div'); m.className='meta'; m.innerHTML=meta; bub.appendChild(m); }
  document.getElementById('chat').appendChild(wrap);
  window.scrollTo(0, document.body.scrollHeight);
}
function clearChat(){ document.getElementById('chat').innerHTML=''; }
</script>
</body></html>
'@
}

# ---------------------------------------------------------------------------
# Вспомогательное для UI
# ---------------------------------------------------------------------------

function Set-Status {
    param([string]$Text, [System.Drawing.Color]$Color = $script:MutedColor)
    if ($script:StatusLabel) {
        $script:StatusLabel.Text = $Text
        $script:StatusLabel.ForeColor = $Color
    }
}

function Set-Busy {
    param([bool]$Busy)
    $script:SendButton.Enabled = -not $Busy
    $script:AttachButton.Enabled = -not $Busy
    $script:NewChatButton.Enabled = -not $Busy
    $script:SettingsButton.Enabled = -not $Busy
    $script:InputBox.Enabled = -not $Busy
    if ($Busy) { $script:MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    else { $script:MainForm.Cursor = [System.Windows.Forms.Cursors]::Default }
}

function Test-ApiKey {
    param([bool]$ForImages = $false)
    $base = if ($ForImages) { [string]$script:Config.imageApiBase } else { [string]$script:Config.apiBase }
    $isLocal = $base -match '^https?://(127\.0\.0\.1|localhost)'
    if ([string]::IsNullOrWhiteSpace($script:Config.apiKey) -and -not $isLocal) {
        Add-BrowserMessage -Role 'assistant' -Html (ConvertTo-ChatHtml -Text 'Для этого API нужен ключ. Открой «Настройки» — для чата ключ не нужен, он нужен только для генерации картинок.') -Meta 'настройки'
        Set-Status 'Нет API-ключа' $script:Red
        return $false
    }
    return $true
}

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 120, [System.Drawing.Color]$Color = $script:TextColor)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, 22)
    $l.ForeColor = $Color
    return $l
}

function New-TextBox {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 26, [bool]$Password = $false, [bool]$Multi = $false)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Text = $Text
    $t.Location = New-Object System.Drawing.Point($X, $Y)
    $t.Size = New-Object System.Drawing.Size($W, $H)
    $t.Multiline = $Multi
    $t.ScrollBars = if ($Multi) { [System.Windows.Forms.ScrollBars]::Vertical } else { [System.Windows.Forms.ScrollBars]::None }
    $t.BackColor = $script:PanelBg
    $t.ForeColor = $script:TextColor
    $t.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    if ($Password) { $t.UseSystemPasswordChar = $true }
    return $t
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [bool]$Primary = $false)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = if ($Primary) { $script:Accent } else { $script:PanelBg }
    $b.ForeColor = if ($Primary) { [System.Drawing.Color]::White } else { $script:TextColor }
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}

# ---------------------------------------------------------------------------
# Запросы
# ---------------------------------------------------------------------------

function Start-ChatRequest {
    param([string]$UserText)

    if (-not (Test-ApiKey)) { return }
    if ([string]::IsNullOrWhiteSpace($UserText)) { return }

    $script:Messages += @{ role = 'user'; content = $UserText; type = 'text' }
    Save-Chat
    Refresh-ChatButtons
    Add-BrowserMessage -Role 'user' -Html (ConvertTo-ChatHtml -Text $UserText)
    $script:InputBox.Clear()

    $messages = @()
    $systemPrompt = [string]$script:Config.systemPrompt
    if (-not [string]::IsNullOrWhiteSpace($systemPrompt)) {
        $messages += @{ role = 'system'; content = $systemPrompt }
    }
    foreach ($m in $script:Messages) {
        if ([string]$m.type -eq 'image') { continue }
        $messages += @{ role = [string]$m.role; content = [string]$m.content }
    }

    # Дополнительно страхуем язык прямо в последнем сообщении: локальные
    # код-модели иногда игнорируют system-промпт.
    $payloadMessages = @()
    for ($i = 0; $i -lt $messages.Count; $i++) {
        $m = $messages[$i]
        $content = [string]$m.content
        if ([string]$m.role -eq 'user' -and $i -eq ($messages.Count - 1)) {
            $content = $content + [Environment]::NewLine + 'Отвечай строго по-русски, коротко. Если нужен код — дай его в блоке с указанием языка.'
        }
        $payloadMessages += @{ role = [string]$m.role; content = $content }
    }

    $payload = @{
        config   = $script:Config
        messages = $payloadMessages
    } | ConvertTo-Json -Depth 20 -Compress

    Set-Busy $true
    Set-Status 'Well AI думает...' $script:Green

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
            Authorization  = 'Bearer ' + [string]$data.config.apiKey
            'Content-Type' = 'application/json'
        }
        try {
            # PowerShell 5.1 декодирует JSON без charset как ANSI — читаем байты как UTF-8 сами.
            $rawPath = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'wellai-chat-' + [Guid]::NewGuid().ToString('N') + '.json')
            $bodyBytes = [Text.Encoding]::UTF8.GetBytes($body)
            Invoke-WebRequest -Method Post -Uri ([string]$data.config.apiBase + '/chat/completions') -Headers $headers -Body $bodyBytes -ContentType 'application/json; charset=utf-8' -OutFile $rawPath -UseBasicParsing -TimeoutSec 180
            $resp = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($rawPath)) | ConvertFrom-Json
            Remove-Item -LiteralPath $rawPath -Force -ErrorAction SilentlyContinue
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

    if (-not (Test-ApiKey -ForImages $true)) { return }
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        Add-BrowserMessage -Role 'assistant' -Html (ConvertTo-ChatHtml -Text 'Напиши, какую картинку сгенерировать, например: «кошмарный бургер в стиле пиксель-арт».') -Meta 'картинка'
        return
    }

    $script:Messages += @{ role = 'user'; content = ('Картинка: ' + $Prompt); type = 'text' }
    Save-Chat
    Add-BrowserMessage -Role 'user' -Html (ConvertTo-ChatHtml -Text ('Картинка: ' + $Prompt))
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
    Set-Status 'Генерирую картинку...' $script:Accent2

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
            Authorization  = 'Bearer ' + [string]$data.config.apiKey
            'Content-Type' = 'application/json'
        }
        try {
            $rawPath = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'wellai-image-' + [Guid]::NewGuid().ToString('N') + '.json')
            $bodyBytes = [Text.Encoding]::UTF8.GetBytes($body)
            Invoke-WebRequest -Method Post -Uri ([string]$data.config.imageApiBase + '/images/generations') -Headers $headers -Body $bodyBytes -ContentType 'application/json; charset=utf-8' -OutFile $rawPath -UseBasicParsing -TimeoutSec 240
            $resp = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($rawPath)) | ConvertFrom-Json
            Remove-Item -LiteralPath $rawPath -Force -ErrorAction SilentlyContinue
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
        Add-BrowserMessage -Role 'assistant' -Html (ConvertTo-ChatHtml -Text 'Не удалось получить ответ. Попробуй ещё раз.') -Meta 'ошибка'
        Set-Status 'Ошибка запроса' $script:Red
        return
    }
    if (-not $r.ok) {
        Add-BrowserMessage -Role 'assistant' -Html (ConvertTo-ChatHtml -Text ([string]$r.text)) -Meta 'ошибка API'
        Set-Status 'Ошибка API' $script:Red
        return
    }

    if ($r.PSObject.Properties.Name -contains 'path') {
        $path = [string]$r.path
        $script:Messages += @{ role = 'assistant'; content = $path; type = 'image' }
        Save-Chat
        Add-BrowserMessage -Role 'assistant' -Html (Get-ImageHtml -Path $path) -Meta ([IO.Path]::GetFileName($path))
        Set-Status 'Картинка готова' $script:Green
    } else {
        $answer = [string]$r.text
        $script:Messages += @{ role = 'assistant'; content = $answer; type = 'text' }
        Save-Chat
        Refresh-ChatButtons
        Add-BrowserMessage -Role 'assistant' -Html (ConvertTo-ChatHtml -Text $answer)
        Set-Status 'Готово' $script:Green
    }
}

function Attach-File {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Прикрепить файл к сообщению'
    $dlg.Filter = 'Текст и код (*.txt;*.ps1;*.py;*.js;*.ts;*.json;*.md;*.java;*.yml;*.yaml;*.xml;*.html;*.css;*.cpp;*.cs;*.sql;*.sh;*.bat;*.cmd)|*.txt;*.ps1;*.py;*.js;*.ts;*.json;*.md;*.java;*.yml;*.yaml;*.xml;*.html;*.css;*.cpp;*.cs;*.sql;*.sh;*.bat;*.cmd|Все файлы (*.*)|*.*'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        $f = Get-Item -LiteralPath $dlg.FileName
        $maxBytes = 200000
        $text = ''
        if ($f.Length -le $maxBytes) {
            $bytes = [IO.File]::ReadAllBytes($f.FullName)
            $text = [Text.Encoding]::UTF8.GetString($bytes)
            if ($text -match [char]0xFFFD) {
                $text = [Text.Encoding]::GetEncoding(1251).GetString($bytes)
            }
        } else {
            $text = '[Файл слишком большой для вставки в сообщение.]'
        }
        $ext = $f.Extension.TrimStart('.')
        if (-not $ext) { $ext = 'text' }
        $nl = [Environment]::NewLine
        $addition = 'Файл: ' + $f.Name + $nl + $nl + '```' + $ext + $nl + $text + '```'
        if (-not [string]::IsNullOrWhiteSpace($script:InputBox.Text)) {
            $addition = $script:InputBox.Text + $nl + $nl + $addition
        }
        $script:InputBox.Text = $addition
        Set-Status "Файл добавлен: $($f.Name)" $script:Green
    } catch {
        Set-Status 'Не удалось прочитать файл' $script:Red
    }
}

# ---------------------------------------------------------------------------
# Настройки
# ---------------------------------------------------------------------------

function Show-SettingsDialog {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Well AI — настройки'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(720, 700)
    $form.MinimumSize = $form.Size
    $form.FormBorderStyle = 'FixedDialog'
    $form.BackColor = $script:Bg
    $form.ForeColor = $script:TextColor

    $form.Controls.Add((New-Label 'API Base для чата (локальная модель)' 20 20 360))
    $tbBase = New-TextBox ([string]$script:Config.apiBase) 20 45 660

    $form.Controls.Add((New-Label 'API Base для картинок' 20 82 360))
    $tbImageBase = New-TextBox ([string]$script:Config.imageApiBase) 20 107 660

    $form.Controls.Add((New-Label 'API-ключ (нужен только для картинок)' 20 146 360))
    $tbKey = New-TextBox ([string]$script:Config.apiKey) 20 171 660 26 $true

    $form.Controls.Add((New-Label 'Модель для чата' 20 212 200))
    $tbChat = New-TextBox ([string]$script:Config.chatModel) 200 209 480

    $form.Controls.Add((New-Label 'Модель для картинок' 20 246 200))
    $tbImage = New-TextBox ([string]$script:Config.imageModel) 200 243 480

    $form.Controls.Add((New-Label 'Размер картинки' 20 280 200))
    $cbSize = New-Object System.Windows.Forms.ComboBox
    $cbSize.Location = New-Object System.Drawing.Point(200, 277)
    $cbSize.Size = New-Object System.Drawing.Size(240, 26)
    $cbSize.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cbSize.BackColor = $script:PanelBg
    $cbSize.ForeColor = $script:TextColor
    @('1024x1024', '1536x1024', '1024x1536', '1792x1024', '1024x1792') | ForEach-Object { [void]$cbSize.Items.Add($_) }
    if ($cbSize.Items.Contains([string]$script:Config.imageSize)) { $cbSize.SelectedItem = [string]$script:Config.imageSize } else { $cbSize.SelectedIndex = 0 }

    $form.Controls.Add((New-Label 'Temperature' 20 318 200))
    $tbTemp = New-TextBox ([string]$script:Config.temperature) 200 315 100

    $form.Controls.Add((New-Label 'Max tokens' 330 318 200))
    $tbMax = New-TextBox ([string]$script:Config.maxTokens) 460 315 100

    $form.Controls.Add((New-Label 'Системный промпт' 20 356 300))
    $tbPrompt = New-TextBox ([string]$script:Config.systemPrompt) 20 381 660 165 $false $true

    $btnSave = New-Button 'Сохранить' 410 570 130 36 $true
    $btnSave.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnSave)

    $btnCancel = New-Button 'Отмена' 560 570 120 36 $false
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)

    $form.AcceptButton = $btnSave
    $form.CancelButton = $btnCancel

    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:Config.apiBase      = $tbBase.Text.Trim()
        $script:Config.imageApiBase = $tbImageBase.Text.Trim()
        $script:Config.apiKey       = $tbKey.Text.Trim()
        $script:Config.chatModel    = $tbChat.Text.Trim()
        $script:Config.imageModel   = $tbImage.Text.Trim()
        $script:Config.imageSize    = [string]$cbSize.SelectedItem
        $script:Config.systemPrompt = $tbPrompt.Text
        $number = 0.3
        if ([double]::TryParse($tbTemp.Text, [ref]$number)) { $script:Config.temperature = $number }
        $intNumber = 2000
        if ([int]::TryParse($tbMax.Text, [ref]$intNumber)) { $script:Config.maxTokens = $intNumber }
        Save-WellConfig $script:Config
        Set-Status 'Настройки сохранены' $script:Green
    }
}

# ---------------------------------------------------------------------------
# Инициализация
# ---------------------------------------------------------------------------

$script:Config = Get-WellConfig
Initialize-ChatStorage
$script:Messages = @()
$script:CurrentChatId = ''
$script:ActiveJob = $null
$script:ChatButtons = @()

$script:MainForm = New-Object System.Windows.Forms.Form
$form = $script:MainForm
$form.Text = "$script:AppName $script:AppVersion"
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1120, 760)
$form.MinimumSize = New-Object System.Drawing.Size(820, 560)
$form.BackColor = $script:Bg
$form.ForeColor = $script:TextColor

$iconPath = Join-Path $script:InstallDir 'wellai.ico'
if (Test-Path -LiteralPath $iconPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch {}
}

# Боковая панель
$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Dock = [System.Windows.Forms.DockStyle]::Left
$sidebar.Width = 258
$sidebar.BackColor = $script:SidebarBg
$form.Controls.Add($sidebar)

$logo = New-Object System.Windows.Forms.Label
$logo.Text = 'W  Well AI'
$logo.ForeColor = [System.Drawing.Color]::White
$logo.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
$logo.Location = New-Object System.Drawing.Point(18, 18)
$logo.Size = New-Object System.Drawing.Size(220, 38)
$sidebar.Controls.Add($logo)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'локальная модель · код · картинки'
$subtitle.ForeColor = $script:MutedColor
$subtitle.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$subtitle.Location = New-Object System.Drawing.Point(19, 54)
$subtitle.Size = New-Object System.Drawing.Size(220, 20)
$sidebar.Controls.Add($subtitle)

$script:NewChatButton = New-Button '+  Новый чат' 14 86 230 40 $true
$script:NewChatButton.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$script:NewChatButton.Padding = New-Object System.Windows.Forms.Padding(14, 0, 0, 0)
$sidebar.Controls.Add($script:NewChatButton)

$chatsLabel = New-Label 'Недавние чаты' 18 146 200 $script:MutedColor
$chatsLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
$sidebar.Controls.Add($chatsLabel)

$script:ChatListPanel = New-Object System.Windows.Forms.Panel
$script:ChatListPanel.Location = New-Object System.Drawing.Point(10, 170)
$script:ChatListPanel.Size = New-Object System.Drawing.Size(238, 500)
$script:ChatListPanel.AutoScroll = $true
$script:ChatListPanel.BackColor = $script:SidebarBg
$sidebar.Controls.Add($script:ChatListPanel)

$versionLabel = New-Label ("v" + $script:AppVersion + "  ·  " + $script:Config.chatModel) 18 706 240 $script:MutedColor
$versionLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$sidebar.Controls.Add($versionLabel)

# Основная область
$main = New-Object System.Windows.Forms.Panel
$main.Dock = [System.Windows.Forms.DockStyle]::Fill
$main.BackColor = $script:Bg
$form.Controls.Add($main)

$header = New-Object System.Windows.Forms.Panel
$header.Dock = [System.Windows.Forms.DockStyle]::Top
$header.Height = 58
$header.BackColor = $script:SidebarBg
$main.Controls.Add($header)

$script:TitleLabel = New-Object System.Windows.Forms.Label
$script:TitleLabel.Text = 'Новый чат'
$script:TitleLabel.ForeColor = [System.Drawing.Color]::White
$script:TitleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$script:TitleLabel.Location = New-Object System.Drawing.Point(22, 12)
$script:TitleLabel.Size = New-Object System.Drawing.Size(620, 32)
$header.Controls.Add($script:TitleLabel)

$script:SettingsButton = New-Button '⚙  Настройки' 838 12 145 34 $false
$header.Controls.Add($script:SettingsButton)

$script:Browser = New-Object System.Windows.Forms.WebBrowser
$script:Browser.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:Browser.ScriptErrorsSuppressed = $true
$script:Browser.IsWebBrowserContextMenuEnabled = $false
$script:Browser.WebBrowserShortcutsEnabled = $false
$main.Controls.Add($script:Browser)

$script:Browser.Navigate('about:blank')
$deadline = (Get-Date).AddSeconds(10)
while ($script:Browser.ReadyState -ne [System.Windows.Forms.WebBrowserReadyState]::Complete -and (Get-Date) -lt $deadline) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 40
}
[void]$script:Browser.Document.OpenNew($true)
[void]$script:Browser.Document.Write((Get-ChatTemplate))

$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.Text = 'Готов'
$script:StatusLabel.ForeColor = $script:MutedColor
$script:StatusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$script:StatusLabel.Location = New-Object System.Drawing.Point(22, 82)
$script:StatusLabel.Size = New-Object System.Drawing.Size(420, 18)
$main.Controls.Add($script:StatusLabel)
$script:StatusLabel.BringToFront()

$inputPanel = New-Object System.Windows.Forms.Panel
$inputPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
$inputPanel.Height = 124
$inputPanel.BackColor = $script:SidebarBg
$main.Controls.Add($inputPanel)

$script:AttachButton = New-Button '📎  Файл' 18 16 110 34 $false
$inputPanel.Controls.Add($script:AttachButton)

$script:InputBox = New-Object System.Windows.Forms.TextBox
$script:InputBox.Multiline = $true
$script:InputBox.AcceptsReturn = $true
$script:InputBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$script:InputBox.Location = New-Object System.Drawing.Point(18, 56)
$script:InputBox.Size = New-Object System.Drawing.Size(880, 54)
$script:InputBox.BackColor = $script:PanelBg
$script:InputBox.ForeColor = $script:TextColor
$script:InputBox.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$script:InputBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$inputPanel.Controls.Add($script:InputBox)

$script:SendButton = New-Button 'Отправить' 912 56 168 54 $true
$inputPanel.Controls.Add($script:SendButton)

$hint = New-TextBox 'Enter — отправить · Shift+Enter — новая строка' 140 19 400 26
$hint.ReadOnly = $true
$hint.BackColor = $script:SidebarBg
$hint.ForeColor = $script:MutedColor
$hint.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$inputPanel.Controls.Add($hint)

$script:JobTimer = New-Object System.Windows.Forms.Timer
$script:JobTimer.Interval = 250
$script:JobTimer.add_Tick({ On-JobTimerTick })

# События
$script:SendButton.add_Click({ Start-ChatRequest -UserText $script:InputBox.Text })
$script:NewChatButton.add_Click({ New-Chat })
$script:AttachButton.add_Click({ Attach-File })
$script:SettingsButton.add_Click({ Show-SettingsDialog })

$script:InputBox.add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter -and -not $e.Shift) {
        $e.SuppressKeyPress = $true
        Start-ChatRequest -UserText $script:InputBox.Text
    }
})

$form.add_FormClosing({
    if ($script:ActiveJob) {
        Stop-Job -Job $script:ActiveJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:ActiveJob -Force -ErrorAction SilentlyContinue
    }
})

$files = @(Get-ChildItem -LiteralPath $script:ChatsDir -Filter 'chat_*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if ($files.Count -gt 0) {
    Load-Chat -ChatId ([string](Get-Content -LiteralPath $files[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json).id)
} else {
    New-Chat
}
Refresh-ChatButtons

Set-Status ('Локальная модель: ' + [string]$script:Config.chatModel) $script:Green

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
