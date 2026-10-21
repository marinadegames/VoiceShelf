$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
  Write-Error "Установите Python 3.9 или новее."
}
if (-not (Test-Path ".venv")) {
  Write-Host "Один раз создаю локальное окружение…"
  python -m venv .venv
}
& .\.venv\Scripts\Activate.ps1
python -c "import faster_whisper" 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Один раз устанавливаю локальный Whisper…"
  python -m pip install -r requirements.txt
}
python -m voiceshelf.cli @args

