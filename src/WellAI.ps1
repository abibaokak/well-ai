#requires -Version 5.1
<#
    Well AI — локальный чат-ассистент с генерацией кода и картинок.
    Интерфейс в стиле современных чат-ассистентов: боковая панель,
    пузыри сообщений, блоки кода, новые чаты и вложение файлов.
    Только стандартные возможности Windows PowerShell 5.1.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

[ComVisible(true)]
public class WellAiJsBridge
{
    public static Action<string> PromptHandler;

    public void UsePrompt(string text)
    {
        if (PromptHandler != null) { PromptHandler(text); }
    }

    public void CopyText(string text)
    {
        if (!String.IsNullOrEmpty(text)) { Clipboard.SetText(text); }
    }
}
"@ -ReferencedAssemblies 'System.Windows.Forms'

$script:AppName    = 'Well AI'
$script:AppVersion = '1.4.0'
$script:ConfigDir  = Join-Path $env:APPDATA 'Well AI'
$script:ConfigPath = Join-Path $script:ConfigDir 'config.json'
$script:ChatsDir   = Join-Path $script:ConfigDir 'chats'
$script:HistoryPath= Join-Path $script:ConfigDir 'history.json'
$script:ImagesDir  = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Well AI'
$script:InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$script:Bg        = [System.Drawing.Color]::FromArgb(10, 15, 30)
$script:SidebarBg = [System.Drawing.Color]::FromArgb(15, 21, 39)
$script:PanelBg   = [System.Drawing.Color]::FromArgb(22, 30, 53)
$script:TextColor = [System.Drawing.Color]::FromArgb(232, 238, 249)
$script:MutedColor= [System.Drawing.Color]::FromArgb(139, 157, 190)
$script:Accent    = [System.Drawing.Color]::FromArgb(61, 220, 186)
$script:Accent2   = [System.Drawing.Color]::FromArgb(139, 123, 255)
$script:Gold      = [System.Drawing.Color]::FromArgb(255, 196, 107)
$script:Green     = [System.Drawing.Color]::FromArgb(61, 220, 186)
$script:Red       = [System.Drawing.Color]::FromArgb(242, 109, 109)
$script:OnAccent  = [System.Drawing.Color]::FromArgb(8, 19, 31)

$script:DefaultSystemPrompt = @'
Ты Well AI — дружелюбный, грамотный чат-ассистент, который работает локально на компьютере пользователя.

ЯЗЫК: отвечай на языке последнего сообщения пользователя. Если вопрос по-русски — весь ответ по-русски, без английских вступлений.

СТИЛЬ:
- Отвечай как хороший современный ассистент: сначала суть, потом детали. Кратко и по делу, без лишних «Конечно!», «Чем могу помочь» и повторов вопроса.
- Используй короткие абзацы и простые списки. Не пиши длинные однообразные инструкции, если спросили простое.
- Не называй себя языковой моделью, не упоминай Ollama и технику, если пользователь сам не спросил.
- Если не уверен — честно скажи и предложи, что уточнить. Не выдумывай факты, библиотеки и API.

КОД: код или команды давай только когда их просят или когда они реально нужны, в блоке с указанием языка, затем одно короткое пояснение по-русски.
'@

$script:DefaultConfig = @{
    apiBase      = 'http://127.0.0.1:11434/v1'
    imageApiBase = 'https://api.openai.com/v1'
    apiKey       = ''
    chatModel    = 'qwen2.5:3b'
    imageModel   = 'gpt-image-1'
    imageSize    = '1024x1024'
    temperature  = 0.6
    maxTokens    = 900
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
        if ([string]$result.systemPrompt -match 'полезный локальный ассистент' -or [string]$result.systemPrompt -match 'особенно хорошо пишет код') {
            $result.systemPrompt = $script:DefaultSystemPrompt
        }
        if ([string]$result.chatModel -in @('qwen2.5-coder:3b', 'qwen3:4b')) { $result.chatModel = 'qwen2.5:3b' }
        if ([double]$result.temperature -eq 0.3) { $result.temperature = 0.6 }
        if ([int]$result.maxTokens -gt 1200) { $result.maxTokens = 900 }
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
        $btn.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(34, 51, 80)
        $btn.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(27, 41, 66)
        $btn.BackColor = if ([string]$data.id -eq [string]$script:CurrentChatId) { [System.Drawing.Color]::FromArgb(29, 43, 72) } else { $script:SidebarBg }
        $btn.ForeColor = if ([string]$data.id -eq [string]$script:CurrentChatId) { $script:Accent } else { $script:TextColor }
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
        $lang = [System.Net.WebUtility]::HtmlEncode($m.Groups[1].Value)
        if (-not $lang) { $lang = 'код' }
        [void]$sb.Append('<pre data-lang="').Append($lang).Append('"><code>')
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

function Show-Typing {
    if (-not $script:Browser -or -not $script:Browser.Document) { return }
    try { $script:Browser.Document.InvokeScript('showTyping') } catch {}
}

function Hide-Typing {
    if (-not $script:Browser -or -not $script:Browser.Document) { return }
    try { $script:Browser.Document.InvokeScript('hideTyping') } catch {}
}

function Begin-BrowserStream {
    if (-not $script:Browser -or -not $script:Browser.Document) { return }
    try { [void]$script:Browser.Document.InvokeScript('beginStream') } catch {}
}

function Update-BrowserStream {
    param([string]$Html)
    if (-not $script:Browser -or -not $script:Browser.Document) { return }
    try { [void]$script:Browser.Document.InvokeScript('updateStream', @($Html)) } catch {}
}

function Finish-BrowserStream {
    param([string]$Html, [string]$Meta = '')
    if (-not $script:Browser -or -not $script:Browser.Document) { return }
    try { [void]$script:Browser.Document.InvokeScript('finishStream', @($Html, $Meta)) } catch {}
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
html,body{margin:0;padding:0;height:100%;color:#e8eef9;font-family:'Segoe UI',Arial,sans-serif;font-size:14px;line-height:1.6;background:#0a0f1e}
body{background:radial-gradient(circle at 10% 5%,rgba(61,220,186,.13),transparent 32%),radial-gradient(circle at 92% 2%,rgba(139,123,255,.17),transparent 30%),linear-gradient(160deg,#0d1426 0%,#0a0f1e 45%,#0c1122 100%);background-attachment:fixed}
#chat{max-width:880px;margin:0 auto;padding:34px 38px 56px 38px}
.empty{text-align:center;padding:74px 20px 44px 20px}
.mark{width:76px;height:76px;line-height:76px;margin:0 auto 22px auto;border-radius:24px;font-size:36px;font-weight:800;letter-spacing:-2px;color:#08131f;background:linear-gradient(135deg,#3ddcba 0%,#6f8dff 58%,#a878ff 100%);box-shadow:0 20px 55px rgba(61,220,186,.22),inset 0 1px 0 rgba(255,255,255,.45)}
.empty h1{margin:0 0 10px 0;font-size:32px;font-weight:700;letter-spacing:-1px}
.empty .sub{color:#93a3c1;font-size:15px;margin-bottom:32px}
.chips{width:100%;max-width:700px;margin:0 auto}
.chip{display:inline-block;margin:6px;padding:12px 18px;border-radius:14px;background:rgba(255,255,255,.045);border:1px solid rgba(139,123,255,.28);color:#d3dcf0;cursor:pointer;font-size:13px;box-shadow:0 6px 18px rgba(0,0,0,.12)}
.chip:hover{background:rgba(61,220,186,.1);border-color:rgba(61,220,186,.55);color:#fff}
.row{display:table;width:100%;margin:0 0 22px 0}
.msg.user .row{direction:rtl}
.ava-cell{display:table-cell;width:48px;vertical-align:top;padding-top:18px}
.bub-cell{display:table-cell;vertical-align:top;width:100%}
.ava-cell,.bub-cell{direction:ltr}
.avatar{width:34px;height:34px;line-height:34px;text-align:center;border-radius:11px;font-size:13px;font-weight:800;color:#08131f;display:inline-block}
.msg.assistant .avatar{background:linear-gradient(135deg,#3ddcba,#7b8dff);box-shadow:0 8px 22px rgba(61,220,186,.24)}
.msg.user .avatar{background:linear-gradient(135deg,#38496e,#5b6d9b);color:#dfe8ff;box-shadow:0 8px 20px rgba(0,0,0,.26)}
.who{font-size:10px;letter-spacing:1.4px;text-transform:uppercase;color:#6f82a8;font-weight:700;margin:0 0 7px 2px}
.msg.user .who{text-align:right;margin-right:2px;color:#5fbbab}
.bubble{display:inline-block;max-width:84%;padding:15px 18px;border-radius:18px;word-wrap:break-word;overflow-wrap:break-word}
.msg.assistant .bubble{background:linear-gradient(180deg,rgba(29,39,66,.94),rgba(20,28,49,.96));border:1px solid rgba(139,123,255,.2);border-left:3px solid #3ddcba;border-top-left-radius:6px;box-shadow:0 16px 36px rgba(0,0,0,.26)}
.msg.user .bubble{background:linear-gradient(135deg,rgba(61,220,186,.18),rgba(123,141,255,.16));border:1px solid rgba(61,220,186,.3);border-top-right-radius:6px;color:#eef7ff}
.codewrap{margin:12px 0 6px 0;border:1px solid rgba(139,123,255,.24);border-radius:12px;overflow:hidden;background:#080d1a}
.codebar{height:32px;line-height:32px;padding:0 11px;background:linear-gradient(90deg,#1a2647,#151d35);border-bottom:1px solid rgba(255,255,255,.06);font-size:11px;color:#9fb2d6;text-transform:uppercase;letter-spacing:.7px}
.codebar .lang{color:#3ddcba;font-weight:700}
.copy{float:right;margin-top:5px;padding:2px 10px;border-radius:7px;border:1px solid rgba(61,220,186,.35);background:rgba(61,220,186,.1);color:#a9f0df;font-size:11px;cursor:pointer}
.copy:hover{background:rgba(61,220,186,.2);color:#fff}
pre{margin:0;padding:13px 15px;background:transparent;border:0;border-radius:0;overflow:auto;white-space:pre-wrap;word-wrap:break-word;font-family:Consolas,'Courier New',monospace;font-size:13px;color:#dce7fb;line-height:1.5}
code{font-family:Consolas,'Courier New',monospace}
img{max-width:100%;border-radius:12px;border:1px solid rgba(61,220,186,.25);display:block;margin-top:8px}
.meta{font-size:11px;color:#7184a8;margin-top:9px;padding-left:9px;border-left:2px solid rgba(139,123,255,.35)}
.typing{display:inline-block;padding:14px 18px;border-radius:16px;border-top-left-radius:6px;background:linear-gradient(180deg,rgba(29,39,66,.94),rgba(20,28,49,.96));border:1px solid rgba(139,123,255,.2);border-left:3px solid #3ddcba}
.dot{display:inline-block;width:7px;height:7px;margin:0 3px;border-radius:50%;background:#3ddcba;box-shadow:0 0 8px rgba(61,220,186,.55);animation:pulse 1.1s infinite}
.dot.d2{animation-delay:.18s}.dot.d3{animation-delay:.36s}
@keyframes pulse{0%{opacity:.25;transform:translateY(0)}50%{opacity:1;transform:translateY(-4px)}100%{opacity:.25;transform:translateY(0)}}
.cursor{display:inline-block;width:7px;height:15px;margin-left:2px;vertical-align:-2px;background:#3ddcba;border-radius:2px;box-shadow:0 0 9px rgba(61,220,186,.6);animation:blink .8s steps(2) infinite}
@keyframes blink{0%,100%{opacity:1}50%{opacity:.15}}
</style></head><body>
<div id="chat"></div>
<script>
function scrollBottom(){window.scrollTo(0,document.body.scrollHeight)}
function renderEmpty(){
 var c=document.getElementById('chat');
 c.innerHTML='<div class="empty" id="empty"><div class="mark">W</div><h1>Well AI</h1>'+
 '<div class="sub">Локальная модель, код и картинки. С чего начнём?</div><div class="chips">'+
 '<div class="chip" onclick="window.external.UsePrompt(\'Напиши PowerShell-скрипт, который выводит Hello World\')">Напиши скрипт</div>'+
 '<div class="chip" onclick="window.external.UsePrompt(\'Объясни этот код простыми словами\')">Объясни код</div>'+
 '<div class="chip" onclick="window.external.UsePrompt(\'Придумай идею для Minecraft-плагина\')">Идея для плагина</div>'+
 '</div></div>';
}
function removeEmpty(){var e=document.getElementById('empty');if(e){e.parentNode.removeChild(e)}}
function decorateCode(bub){
 var pres=bub.getElementsByTagName('pre');
 for(var i=0;i<pres.length;i++){
  var pre=pres[i]; var lang=pre.getAttribute('data-lang')||'код';
  var wrap=document.createElement('div'); wrap.className='codewrap';
  var bar=document.createElement('div'); bar.className='codebar';
  var lab=document.createElement('span'); lab.className='lang'; lab.innerHTML=lang; bar.appendChild(lab);
  var btn=document.createElement('button'); btn.className='copy'; btn.innerHTML='Копировать';
  btn.onclick=function(){
   var code=this.parentNode.parentNode.getElementsByTagName('code')[0].innerText;
   try{window.external.CopyText(code);this.innerHTML='Скопировано';}catch(e){this.innerHTML='Ошибка';}
  };
  bar.appendChild(btn); wrap.appendChild(bar);
  pre.parentNode.insertBefore(wrap,pre); wrap.appendChild(pre);
 }
}
function addMessage(role,html,meta){
 removeEmpty(); hideTyping();
 var wrap=document.createElement('div'); wrap.className='msg '+role;
 var row=document.createElement('div'); row.className='row';
 var ac=document.createElement('div'); ac.className='ava-cell';
 var av=document.createElement('div'); av.className='avatar'; av.innerHTML=(role==='user')?'В':'W'; ac.appendChild(av);
 var bc=document.createElement('div'); bc.className='bub-cell';
 var w=document.createElement('div'); w.className='who'; w.innerHTML=(role==='user')?'вы':'well ai'; bc.appendChild(w);
 var bub=document.createElement('div'); bub.className='bubble'; bub.innerHTML=html;
 decorateCode(bub);
 if(meta){var m=document.createElement('div');m.className='meta';m.innerHTML=meta;bub.appendChild(m)}
 bc.appendChild(bub); row.appendChild(ac); row.appendChild(bc); wrap.appendChild(row);
 document.getElementById('chat').appendChild(wrap); scrollBottom();
}
function clearChat(){document.getElementById('chat').innerHTML='';renderEmpty()}
function showTyping(){
 removeEmpty();
 if(document.getElementById('typing'))return;
 var wrap=document.createElement('div');wrap.className='msg assistant';wrap.id='typing';
 var row=document.createElement('div');row.className='row';
 var ac=document.createElement('div');ac.className='ava-cell';
 var av=document.createElement('div');av.className='avatar';av.innerHTML='W';ac.appendChild(av);
 var bc=document.createElement('div');bc.className='bub-cell';
 var w=document.createElement('div');w.className='who';w.innerHTML='well ai';bc.appendChild(w);
 var t=document.createElement('div');t.className='typing';
 t.innerHTML='<span class="dot"></span><span class="dot d2"></span><span class="dot d3"></span>';
 bc.appendChild(t);row.appendChild(ac);row.appendChild(bc);wrap.appendChild(row);
 document.getElementById('chat').appendChild(wrap);scrollBottom();
}
function hideTyping(){var t=document.getElementById('typing');if(t){t.parentNode.removeChild(t)}}
function beginStream(){
 removeEmpty(); hideTyping();
 if(document.getElementById('streammsg'))return;
 var wrap=document.createElement('div');wrap.className='msg assistant';wrap.id='streammsg';
 var row=document.createElement('div');row.className='row';
 var ac=document.createElement('div');ac.className='ava-cell';
 var av=document.createElement('div');av.className='avatar';av.innerHTML='W';ac.appendChild(av);
 var bc=document.createElement('div');bc.className='bub-cell';
 var w=document.createElement('div');w.className='who';w.innerHTML='well ai';bc.appendChild(w);
 var bub=document.createElement('div');bub.className='bubble';bub.id='streambubble';
 bub.innerHTML='<span class="cursor"></span>';
 bc.appendChild(bub);row.appendChild(ac);row.appendChild(bc);wrap.appendChild(row);
 document.getElementById('chat').appendChild(wrap);scrollBottom();
}
function updateStream(html){
 var b=document.getElementById('streambubble');if(!b)return;
 b.innerHTML=html+'<span class="cursor"></span>';scrollBottom();
}
function finishStream(html,meta){
 var b=document.getElementById('streambubble');if(!b){addMessage('assistant',html,meta);return;}
 b.innerHTML=html;decorateCode(b);
 if(meta){var m=document.createElement('div');m.className='meta';m.innerHTML=meta;b.appendChild(m)}
 b.removeAttribute('id');
 var w=document.getElementById('streammsg');if(w){w.removeAttribute('id')}
 scrollBottom();
}
renderEmpty();
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

function Get-LocalModels {
    $result = @()
    $base = ([string]$script:Config.apiBase).TrimEnd('/')
    if ($base -notmatch '127\.0\.0\.1|localhost') { return $result }
    try {
        $r = Invoke-RestMethod -Uri (($base -replace '/v1$', '') + '/api/tags') -TimeoutSec 3
        foreach ($m in @($r.models)) { $result += [string]$m.name }
    } catch {}
    return $result
}

function Ensure-Ollama {
    $base = ([string]$script:Config.apiBase).TrimEnd('/')
    if ($base -notmatch '127\.0\.0\.1|localhost') { return }
    try {
        $null = Invoke-RestMethod -Uri (($base -replace '/v1$', '') + '/api/tags') -TimeoutSec 2
        return
    } catch {}
    $exe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (Test-Path -LiteralPath $exe) {
        Start-Process -FilePath $exe -ArgumentList 'serve' -WindowStyle Hidden -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 4
    }
    # Если модели ещё нет на новом ПК — скачиваем её автоматически.
    try {
        $need = [string]$script:Config.chatModel
        if ($need -and @(Get-LocalModels) -notcontains $need -and (Test-Path -LiteralPath $exe)) {
            Start-Process -FilePath $exe -ArgumentList @('pull', $need) -WindowStyle Hidden -ErrorAction SilentlyContinue
        }
    } catch {}
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
    $b.ForeColor = if ($Primary) { $script:OnAccent } else { $script:TextColor }
    $b.FlatAppearance.MouseOverBackColor = if ($Primary) { [System.Drawing.Color]::FromArgb(94, 238, 206) } else { [System.Drawing.Color]::FromArgb(34, 51, 80) }
    $b.FlatAppearance.MouseDownBackColor = if ($Primary) { [System.Drawing.Color]::FromArgb(43, 192, 163) } else { [System.Drawing.Color]::FromArgb(27, 41, 66) }
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
    Begin-BrowserStream
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

    # Страховка языка только для русскоязычного вопроса.
    $payloadMessages = @()
    for ($i = 0; $i -lt $messages.Count; $i++) {
        $m = $messages[$i]
        $content = [string]$m.content
        if ([string]$m.role -eq 'user' -and $i -eq ($messages.Count - 1) -and $content -match '[\u0400-\u04FF]') {
            $content = $content + [Environment]::NewLine + 'Отвечай по-русски, кратко и по делу.'
        }
        $payloadMessages += @{ role = [string]$m.role; content = $content }
    }

    $script:StreamingActive = $true
    $script:StreamFile = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'wellai-stream-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $script:LastStreamText = ''
    [IO.File]::WriteAllText($script:StreamFile, '', (New-Object Text.UTF8Encoding($false)))

    $payload = @{
        config     = $script:Config
        messages   = $payloadMessages
        streamFile = $script:StreamFile
    } | ConvertTo-Json -Depth 20 -Compress

    Set-Busy $true
    Set-Status ("Well AI думает · " + [string]$script:Config.chatModel) $script:Green

    $script:ActiveJob = Start-Job -ScriptBlock {
        param($json)
        $data = $json | ConvertFrom-Json
        $base = ([string]$data.config.apiBase).TrimEnd('/')
        $model = [string]$data.config.chatModel
        $isLocalOllama = ($base -match '127\.0\.0\.1|localhost')
        if ($isLocalOllama) {
            # Нативный API Ollama быстрее и не кладёт ответ в reasoning.
            $bodyObj = @{
                model    = $model
                messages = $data.messages
                stream   = $true
                options  = @{
                    temperature = [double]$data.config.temperature
                    num_predict = [int]$data.config.maxTokens
                }
            }
            if ($model -like 'qwen3*') { $bodyObj.think = $false }
            $uri = ($base -replace '/v1$', '') + '/api/chat'
        } else {
            $bodyObj = @{
                model       = $model
                messages    = $data.messages
                temperature = [double]$data.config.temperature
                max_tokens  = [int]$data.config.maxTokens
                stream      = $true
            }
            $uri = $base + '/chat/completions'
        }
        $body = $bodyObj | ConvertTo-Json -Depth 20 -Compress
        $streamFile = [string]$data.streamFile
        $utf8 = New-Object Text.UTF8Encoding($false)
        $text = New-Object Text.StringBuilder
        $shownLength = 0
        # qwen3 иногда всё равно рассуждает вслух, несмотря на think=false.
        # Показываем пользователю только текст после </think>.
        $stripThinking = ($model -like 'qwen3*')
        $visibleText = {
            param([string]$Raw)
            if ($stripThinking) {
                $i = $Raw.IndexOf('</think>')
                if ($i -ge 0) { return $Raw.Substring($i + 8).TrimStart() }
                return ''
            }
            return $Raw
        }
        # FileShare.ReadWrite нужен, чтобы таймер окна читал файл во время записи.
        $fs = New-Object -TypeName IO.FileStream -ArgumentList @($streamFile, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $writer = New-Object -TypeName IO.StreamWriter -ArgumentList @($fs, $utf8)
        $writer.AutoFlush = $true
        try {
            $req = [Net.HttpWebRequest]::Create($uri)
            $req.Method = 'POST'
            $req.ContentType = 'application/json; charset=utf-8'
            $req.Headers.Add('Authorization', 'Bearer ' + [string]$data.config.apiKey)
            $req.Timeout = 180000
            $req.ReadWriteTimeout = 180000
            $bodyBytes = [Text.Encoding]::UTF8.GetBytes($body)
            $req.ContentLength = $bodyBytes.Length
            $out = $req.GetRequestStream()
            $out.Write($bodyBytes, 0, $bodyBytes.Length)
            $out.Close()

            $resp = $req.GetResponse()
            $rs = $resp.GetResponseStream()
            $reader = New-Object -TypeName IO.StreamReader -ArgumentList @($rs, [Text.Encoding]::UTF8)
            while ($null -ne ($line = $reader.ReadLine())) {
                $delta = $null
                if ($isLocalOllama) {
                    if (-not $line.StartsWith('{')) { continue }
                    try { $chunk = $line | ConvertFrom-Json } catch { continue }
                    $delta = $chunk.message.content
                } else {
                    if (-not $line.StartsWith('data:')) { continue }
                    $chunkText = $line.Substring(5).Trim()
                    if ($chunkText -eq '[DONE]') { break }
                    if (-not $chunkText) { continue }
                    try { $chunk = $chunkText | ConvertFrom-Json } catch { continue }
                    if ($chunk.choices -and $chunk.choices.Count -gt 0) {
                        $delta = $chunk.choices[0].delta.content
                        if ($null -eq $delta) { $delta = $chunk.choices[0].text }
                    }
                }
                if ($delta) {
                    [void]$text.Append($delta)
                    $visible = & $visibleText $text.ToString()
                    if ($visible.Length -gt $shownLength) {
                        $writer.Write($visible.Substring($shownLength))
                        $writer.Flush()
                        $shownLength = $visible.Length
                    }
                }
            }
            $reader.Close()
            $resp.Close()
            $finalText = & $visibleText $text.ToString()
            if ([string]::IsNullOrWhiteSpace($finalText)) { $finalText = $text.ToString().Trim() }
            if ($finalText.Length -eq 0) { throw 'Пустой ответ от модели.' }
            if ($finalText.Length -gt $shownLength) { $writer.Write($finalText.Substring($shownLength)) }
            [pscustomobject]@{ ok = $true; text = $finalText; partial = $finalText }
        } catch {
            $msg = $_.Exception.Message
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $_.ErrorDetails.Message }
            $partial = & $visibleText $text.ToString()
            if ([string]::IsNullOrWhiteSpace($partial)) { $partial = '' }
            [pscustomobject]@{ ok = $false; text = $msg; partial = $partial }
        } finally {
            $writer.Close()
            $fs.Close()
        }
    } -ArgumentList $payload

    $script:JobTimer.Start()
}

function Start-ImageRequest {
    param([string]$Prompt)

    $script:StreamingActive = $false
    $script:StreamFile = $null
    if (-not (Test-ApiKey -ForImages $true)) { return }
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        Add-BrowserMessage -Role 'assistant' -Html (ConvertTo-ChatHtml -Text 'Напиши, какую картинку сгенерировать, например: «кошмарный бургер в стиле пиксель-арт».') -Meta 'картинка'
        return
    }

    $script:Messages += @{ role = 'user'; content = ('Картинка: ' + $Prompt); type = 'text' }
    Save-Chat
    Add-BrowserMessage -Role 'user' -Html (ConvertTo-ChatHtml -Text ('Картинка: ' + $Prompt))
    Show-Typing
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
    if ($script:StreamingActive -and $script:StreamFile -and (Test-Path -LiteralPath $script:StreamFile)) {
        try { $partialNow = [IO.File]::ReadAllText($script:StreamFile, [Text.Encoding]::UTF8) } catch { $partialNow = '' }
        if ($partialNow -ne $script:LastStreamText) {
            $script:LastStreamText = $partialNow
            Update-BrowserStream -Html (ConvertTo-ChatHtml -Text $partialNow)
        }
    }
    Hide-Typing

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
    $streaming = [bool]$script:StreamingActive
    $streamFile = $script:StreamFile
    $script:StreamingActive = $false
    $script:StreamFile = $null

    if (-not $r) {
        $msg = 'Не удалось получить ответ. Попробуй ещё раз.'
        if ($streaming) { Finish-BrowserStream -Html (ConvertTo-ChatHtml -Text $msg) -Meta 'ошибка' }
        else { Add-BrowserMessage -Role 'assistant' -Html (ConvertTo-ChatHtml -Text $msg) -Meta 'ошибка' }
        Set-Status 'Ошибка запроса' $script:Red
        if ($streamFile) { Remove-Item -LiteralPath $streamFile -Force -ErrorAction SilentlyContinue }
        return
    }

    if ($r.PSObject.Properties.Name -contains 'path') {
        $path = [string]$r.path
        $script:Messages += @{ role = 'assistant'; content = $path; type = 'image' }
        Save-Chat
        Add-BrowserMessage -Role 'assistant' -Html (Get-ImageHtml -Path $path) -Meta ([IO.Path]::GetFileName($path))
        Set-Status 'Картинка готова' $script:Green
        if ($streamFile) { Remove-Item -LiteralPath $streamFile -Force -ErrorAction SilentlyContinue }
        return
    }

    $answer = [string]$r.text
    $partial = ''
    if ($r.PSObject.Properties.Name -contains 'partial') { $partial = [string]$r.partial }
    if (-not $r.ok -and [string]::IsNullOrWhiteSpace($partial)) {
        if ($streaming) { Finish-BrowserStream -Html (ConvertTo-ChatHtml -Text ([string]$r.text)) -Meta 'ошибка API' }
        else { Add-BrowserMessage -Role 'assistant' -Html (ConvertTo-ChatHtml -Text ([string]$r.text)) -Meta 'ошибка API' }
        Set-Status 'Ошибка API' $script:Red
        if ($streamFile) { Remove-Item -LiteralPath $streamFile -Force -ErrorAction SilentlyContinue }
        return
    }
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $partial }
    if ($streaming) {
        $meta = if ($r.ok) { [string]$script:Config.chatModel } else { 'ответ прерван' }
        $script:Messages += @{ role = 'assistant'; content = $answer; type = 'text' }
        Save-Chat
        Refresh-ChatButtons
        Finish-BrowserStream -Html (ConvertTo-ChatHtml -Text $answer) -Meta $meta
    } else {
        Add-BrowserMessage -Role 'assistant' -Html (ConvertTo-ChatHtml -Text $answer)
    }
    Set-Status 'Готово' $script:Green
    if ($streamFile) { Remove-Item -LiteralPath $streamFile -Force -ErrorAction SilentlyContinue }
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
    $cbChat = New-Object System.Windows.Forms.ComboBox
    $cbChat.Location = New-Object System.Drawing.Point(200, 209)
    $cbChat.Size = New-Object System.Drawing.Size(480, 26)
    $cbChat.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $cbChat.BackColor = $script:PanelBg
    $cbChat.ForeColor = $script:TextColor
    foreach ($m in @(Get-LocalModels)) { [void]$cbChat.Items.Add([string]$m) }
    $cbChat.Text = [string]$script:Config.chatModel

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
        $script:Config.chatModel    = $cbChat.Text.Trim()
        if (-not $script:ModelCombo.Items.Contains($script:Config.chatModel)) {
            [void]$script:ModelCombo.Items.Add($script:Config.chatModel)
        }
        $script:ModelCombo.SelectedItem = $script:Config.chatModel
        $script:VersionLabel.Text = 'v' + $script:AppVersion + '  ·  ' + $script:Config.chatModel
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
Ensure-Ollama
Initialize-ChatStorage
$script:Messages = @()
$script:CurrentChatId = ''
$script:ActiveJob = $null
$script:ChatButtons = @()
$script:StreamingActive = $false
$script:StreamFile = $null
$script:LastStreamText = ''

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

$logoMark = New-Object System.Windows.Forms.Label
$logoMark.Text = 'W'
$logoMark.ForeColor = $script:OnAccent
$logoMark.BackColor = $script:Accent
$logoMark.Font = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Bold)
$logoMark.Location = New-Object System.Drawing.Point(18, 16)
$logoMark.Size = New-Object System.Drawing.Size(38, 38)
$logoMark.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$sidebar.Controls.Add($logoMark)

$logo = New-Object System.Windows.Forms.Label
$logo.Text = 'Well AI'
$logo.ForeColor = [System.Drawing.Color]::White
$logo.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
$logo.Location = New-Object System.Drawing.Point(64, 18)
$logo.Size = New-Object System.Drawing.Size(180, 38)
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

$script:VersionLabel = New-Label ("v" + $script:AppVersion + "  ·  " + $script:Config.chatModel) 18 706 240 $script:MutedColor
$script:VersionLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$sidebar.Controls.Add($script:VersionLabel)

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

$accentStrip = New-Object System.Windows.Forms.Panel
$accentStrip.Dock = [System.Windows.Forms.DockStyle]::Top
$accentStrip.Height = 3
$accentStrip.BackColor = $script:Accent
$header.Controls.Add($accentStrip)

$accentGlow = New-Object System.Windows.Forms.Panel
$accentGlow.Location = New-Object System.Drawing.Point(0, 3)
$accentGlow.Size = New-Object System.Drawing.Size(330, 2)
$accentGlow.BackColor = $script:Gold
$header.Controls.Add($accentGlow)

$script:TitleLabel = New-Object System.Windows.Forms.Label
$script:TitleLabel.Text = 'Новый чат'
$script:TitleLabel.ForeColor = [System.Drawing.Color]::White
$script:TitleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$script:TitleLabel.Location = New-Object System.Drawing.Point(22, 12)
$script:TitleLabel.Size = New-Object System.Drawing.Size(620, 32)
$header.Controls.Add($script:TitleLabel)

$script:ModelCombo = New-Object System.Windows.Forms.ComboBox
$script:ModelCombo.Location = New-Object System.Drawing.Point(650, 13)
$script:ModelCombo.Size = New-Object System.Drawing.Size(178, 28)
$script:ModelCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$script:ModelCombo.BackColor = $script:PanelBg
$script:ModelCombo.ForeColor = $script:TextColor
$script:ModelCombo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$script:ModelCombo.Cursor = [System.Windows.Forms.Cursors]::Hand
foreach ($m in @(Get-LocalModels)) { [void]$script:ModelCombo.Items.Add([string]$m) }
if (-not $script:ModelCombo.Items.Contains([string]$script:Config.chatModel)) {
    [void]$script:ModelCombo.Items.Add([string]$script:Config.chatModel)
}
$script:ModelCombo.SelectedItem = [string]$script:Config.chatModel
$script:ModelCombo.add_SelectedIndexChanged({
    $script:Config.chatModel = [string]$script:ModelCombo.SelectedItem
    Save-WellConfig $script:Config
    $script:VersionLabel.Text = 'v' + $script:AppVersion + '  ·  ' + $script:Config.chatModel
    Set-Status ('Модель: ' + $script:Config.chatModel) $script:Green
})
$header.Controls.Add($script:ModelCombo)

$script:SettingsButton = New-Button '⚙  Настройки' 838 12 145 34 $false
$header.Controls.Add($script:SettingsButton)

$script:Browser = New-Object System.Windows.Forms.WebBrowser
$script:Browser.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:Browser.ScriptErrorsSuppressed = $true
$script:Browser.IsWebBrowserContextMenuEnabled = $false
$script:Browser.WebBrowserShortcutsEnabled = $false
$script:Browser.ObjectForScripting = (New-Object WellAiJsBridge)
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
$script:StatusLabel.ForeColor = $script:Accent
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

$inputLine = New-Object System.Windows.Forms.Panel
$inputLine.Dock = [System.Windows.Forms.DockStyle]::Top
$inputLine.Height = 2
$inputLine.BackColor = $script:Accent2
$inputPanel.Controls.Add($inputLine)

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

[WellAiJsBridge]::PromptHandler = {
    param([string]$Text)
    $script:InputBox.Text = $Text
    $script:InputBox.Focus()
}

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
