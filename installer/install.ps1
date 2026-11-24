#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$source    = Split-Path -Parent $MyInvocation.MyCommand.Path
$target    = Join-Path $env:LOCALAPPDATA 'Well AI'
$configDir = Join-Path $env:APPDATA 'Well AI'
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'

New-Item -ItemType Directory -Force -Path $target | Out-Null
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
New-Item -ItemType Directory -Force -Path $startMenu | Out-Null

Copy-Item -LiteralPath (Join-Path $source 'WellAI.ps1')  -Destination (Join-Path $target 'WellAI.ps1')  -Force
Copy-Item -LiteralPath (Join-Path $source 'wellai.ico')  -Destination (Join-Path $target 'wellai.ico')  -Force
Copy-Item -LiteralPath (Join-Path $source 'uninstall.ps1') -Destination (Join-Path $target 'uninstall.ps1') -Force

$configTarget = Join-Path $configDir 'config.json'
if (-not (Test-Path -LiteralPath $configTarget)) {
    Copy-Item -LiteralPath (Join-Path $source 'config.default.json') -Destination $configTarget -Force
}

$shell = New-Object -ComObject WScript.Shell

$appLink = Join-Path $startMenu 'Well AI.lnk'
$sc = $shell.CreateShortcut($appLink)
$sc.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sc.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + (Join-Path $target 'WellAI.ps1') + '"'
$sc.IconLocation = (Join-Path $target 'wellai.ico') + ',0'
$sc.WorkingDirectory = $target
$sc.Description = 'Well AI — локальный чат-ассистент'
$sc.Save()

$deskLink = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Well AI.lnk'
try {
    $sc2 = $shell.CreateShortcut($deskLink)
    $sc2.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $sc2.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + (Join-Path $target 'WellAI.ps1') + '"'
    $sc2.IconLocation = (Join-Path $target 'wellai.ico') + ',0'
    $sc2.WorkingDirectory = $target
    $sc2.Description = 'Well AI — локальный чат-ассистент'
    $sc2.Save()
} catch {}

$unLink = Join-Path $startMenu 'Uninstall Well AI.lnk'
$sc3 = $shell.CreateShortcut($unLink)
$sc3.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sc3.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $target 'uninstall.ps1') + '"'
$sc3.IconLocation = (Join-Path $target 'wellai.ico') + ',0'
$sc3.WorkingDirectory = $target
$sc3.Description = 'Удалить Well AI'
$sc3.Save()

Write-Host ''
Write-Host 'Well AI установлен.' -ForegroundColor Green
Write-Host ("Программа: " + $target)
Write-Host ("Настройки: " + $configTarget)
Write-Host ''
Write-Host 'Запуск: меню «Пуск» -> Well AI, или ярлык на рабочем столе.' -ForegroundColor Cyan
Write-Host 'Первым делом откройте «Настройки» и вставьте API-ключ.' -ForegroundColor Cyan
