#requires -Version 5.1
$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class WellAiShortPath {
    [DllImport("kernel32.dll", CharSet=CharSet.Auto)]
    public static extern int GetShortPathName(string longPath, StringBuilder shortPath, int bufferSize);
}
"@

function Get-ShortPath {
    param([string]$Path)
    $sb = New-Object System.Text.StringBuilder 2048
    [void][WellAiShortPath]::GetShortPathName($Path, $sb, $sb.Capacity)
    return $sb.ToString()
}

$root      = Split-Path -Parent $PSScriptRoot
$src       = Join-Path $root 'src'
$installer = Join-Path $root 'installer'
$dist      = Join-Path $root 'dist'
$payload   = Join-Path (Join-Path $env:USERPROFILE 'AppData\Local\Temp') 'wellai-payload'

New-Item -ItemType Directory -Force -Path $dist | Out-Null
if (Test-Path -LiteralPath $payload) { Remove-Item -LiteralPath $payload -Recurse -Force }
New-Item -ItemType Directory -Force -Path $payload | Out-Null

$files = @(
    (Join-Path $src 'WellAI.ps1'),
    (Join-Path $src 'wellai.ico'),
    (Join-Path $installer 'install.ps1'),
    (Join-Path $installer 'install.bat'),
    (Join-Path $installer 'uninstall.ps1'),
    (Join-Path $installer 'config.default.json')
)
foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing file: $f" }
    Copy-Item -LiteralPath $f -Destination $payload -Force
}

$setupPath = Join-Path $dist 'WellAI-Setup.exe'
if (Test-Path -LiteralPath $setupPath) { Remove-Item -LiteralPath $setupPath -Force }

$shortPayload = Get-ShortPath $payload
$shortSetup   = Join-Path (Get-ShortPath (Split-Path -Parent $setupPath)) (Split-Path -Leaf $setupPath)

$sed = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=1
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=
DisplayLicense=
FinishMessage=Well AI installed
TargetName=$shortSetup
FriendlyName=Well AI Setup
AppLaunched=cmd.exe /c install.bat
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
SourceFiles=SourceFiles
[Strings]
FILE0="WellAI.ps1"
FILE1="wellai.ico"
FILE2="install.ps1"
FILE3="install.bat"
FILE4="uninstall.ps1"
FILE5="config.default.json"
[SourceFiles]
SourceFiles0=$shortPayload
[SourceFiles0]
%FILE0%=
%FILE1%=
%FILE2%=
%FILE3%=
%FILE4%=
%FILE5%=
"@

$sedPath = Join-Path $payload 'wellai.sed'
Set-Content -LiteralPath $sedPath -Value $sed -Encoding ASCII

& C:\Windows\System32\iexpress.exe /N $sedPath

$deadline = (Get-Date).AddSeconds(45)
while (-not (Test-Path -LiteralPath $setupPath) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
}
if (-not (Test-Path -LiteralPath $setupPath)) { throw 'IExpress did not create the setup EXE.' }

$zipPath = Join-Path $dist 'WellAI-portable.zip'
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $zipPath -Force | Out-Null

$setupHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $setupPath).Hash
$zipHash   = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash

Write-Host ''
Write-Host "SETUP: $setupPath"
Write-Host "SIZE:  $((Get-Item -LiteralPath $setupPath).Length)"
Write-Host "SHA256: $setupHash"
Write-Host ''
Write-Host "ZIP:   $zipPath"
Write-Host "SIZE:  $((Get-Item -LiteralPath $zipPath).Length)"
Write-Host "SHA256: $zipHash"
