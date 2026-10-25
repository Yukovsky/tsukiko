# Скачать официальные нативные сборки NeMo-Speech.cpp для Windows.
# Vulkan используется первым, CPU остаётся гарантированным фоллбэком.
# Python в дистрибутив не входит и для запуска GGUF не нужен.
[CmdletBinding()]
param (
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
Set-Location $RootDir

$VERSION = "0.2.0"
$BASE_URL = "https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v$VERSION"
$ASSETS = @(
    @{
        Name = "nemo-speech-$VERSION-windows-x86_64-vulkan.zip"
        Sha = "edf15a04ba98740aa0ab75ae4681ac7ad0a488b22b35ce2cbebd10590bb1c1e1"
        Folder = "nemo-vulkan"
    },
    @{
        Name = "nemo-speech-$VERSION-windows-x86_64-cpu.zip"
        Sha = "82c80451086e86194aba9af19f800da77cd66d1c28d993d0efceffd6cdb49bb8"
        Folder = "nemo-cpu"
    }
)
$OUT = "windows/Engine"
$WORK = "build/nemo-engine"
$STAMP = "$OUT/.nemo-version"

if (-not $Force -and (Test-Path $STAMP) -and
    ((Get-Content $STAMP -Raw).Trim() -eq $VERSION) -and
    (Test-Path "$OUT/nemo-vulkan/bin/nemo-speech.exe") -and
    (Test-Path "$OUT/nemo-cpu/bin/nemo-speech.exe")) {
    Write-Host "NeMo-Speech.cpp $VERSION уже подготовлен — $OUT"
    exit 0
}

New-Item -ItemType Directory -Force -Path $OUT, $WORK | Out-Null
foreach ($asset in $ASSETS) {
    $archive = Join-Path $WORK $asset.Name
    if (-not (Test-Path $archive)) {
        Write-Host "Скачиваем NeMo-Speech.cpp $($asset.Name)..."
        Invoke-WebRequest -Uri "$BASE_URL/$($asset.Name)" -OutFile $archive
    }
    $actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLower()
    if ($actual -ne $asset.Sha) {
        Remove-Item $archive -Force
        throw "Контрольная сумма $($asset.Name) не совпала: $actual"
    }
    $target = Join-Path $OUT $asset.Folder
    if (Test-Path $target) {
        Remove-Item $target -Recurse -Force
    }
    Expand-Archive -Path $archive -DestinationPath $target -Force
    # С 0.2.0 всё лежит в папке с версией и платформой
    # (`nemo-speech-0.2.0-windows-x86_64-cpu/bin/...`), а приложение ищет
    # `nemo-cpu/bin/nemo-speech.exe` — поднимаем содержимое на уровень выше.
    $inner = Get-ChildItem -Path $target -Directory |
        Where-Object { $_.Name -like "nemo-speech-*" } | Select-Object -First 1
    if ($inner) {
        Get-ChildItem -Path $inner.FullName -Force | Move-Item -Destination $target
        Remove-Item $inner.FullName -Recurse -Force
    }
    if (-not (Test-Path "$target/bin/nemo-speech.exe")) {
        throw "В $($asset.Name) нет bin/nemo-speech.exe"
    }
}

Set-Content -Path $STAMP -Value $VERSION -NoNewline
Write-Host "NeMo-Speech.cpp $VERSION подготовлен: Vulkan и CPU, без Python."
