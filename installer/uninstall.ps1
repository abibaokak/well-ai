#requires -Version 5.1
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms

$target    = Join-Path $env:LOCALAPPDATA 'Well AI'
$configDir = Join-Path $env:APPDATA 'Well AI'
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'

Remove-Item -LiteralPath (Join-Path $startMenu 'Well AI.lnk') -Force
Remove-Item -LiteralPath (Join-Path $startMenu 'Uninstall Well AI.lnk') -Force
Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Well AI.lnk') -Force

$answer = [System.Windows.Forms.MessageBox]::Show(
    'Удалить также настройки и историю диалога?',
    'Well AI — удаление',
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question)

if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
    Remove-Item -LiteralPath $configDir -Recurse -Force
}

Remove-Item -LiteralPath $target -Recurse -Force

Write-Host 'Well AI удалён.'
