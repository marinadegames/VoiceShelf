$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$env:XDG_CONFIG_HOME = "$PSScriptRoot\.tools\config"
$env:PUB_CACHE = "$PSScriptRoot\.tools\pub-cache"
$env:FLUTTER_SUPPRESS_ANALYTICS = "true"
$env:DART_SUPPRESS_ANALYTICS = "true"
$env:FLUTTER_NO_UPDATE_CHECK = "true"
$env:HF_HOME = "$PSScriptRoot\.tools\huggingface"

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
  Write-Error "Установите Python 3.9 или новее."
}
$FlutterBin = "$PSScriptRoot\.tools\flutter\bin\flutter.bat"
if (-not (Test-Path $FlutterBin) -and (Get-Command flutter -ErrorAction SilentlyContinue)) {
  $FlutterBin = (Get-Command flutter).Source
}
if (-not (Test-Path $FlutterBin)) {
  Write-Error "Установите Flutter SDK: https://docs.flutter.dev/get-started/install"
}
if (-not (Test-Path ".venv")) { python -m venv .venv }
& .\.venv\Scripts\Activate.ps1
python -c "import faster_whisper" 2>$null
if ($LASTEXITCODE -ne 0) { python -m pip install -r requirements.txt }
if (-not (Test-Path "desktop_ui\windows")) {
  Push-Location desktop_ui; & $FlutterBin create --platforms=windows,macos,linux .; Pop-Location
}
$env:VOICESHELF_PYTHON = "$PSScriptRoot\.venv\Scripts\python.exe"
$env:VOICESHELF_ROOT = $PSScriptRoot
Push-Location desktop_ui; & $FlutterBin run -d windows; Pop-Location

