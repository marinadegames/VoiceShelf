from pathlib import Path

from PyInstaller.utils.hooks import collect_all


root = Path(SPECPATH).parent
datas = []
binaries = []
hiddenimports = []

for package in (
    "av",
    "ctranslate2",
    "faster_whisper",
    "huggingface_hub",
    "onnxruntime",
    "tokenizers",
):
    package_datas, package_binaries, package_hiddenimports = collect_all(package)
    datas += package_datas
    binaries += package_binaries
    hiddenimports += package_hiddenimports

analysis = Analysis(
    [str(root / "run.py")],
    pathex=[str(root)],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    excludes=["torch", "tensorflow"],
    noarchive=False,
)

pyz = PYZ(analysis.pure)

executable = EXE(
    pyz,
    analysis.scripts,
    [],
    exclude_binaries=True,
    name="voiceshelf-worker",
    console=False,
    target_arch="arm64",
)

bundle = COLLECT(
    executable,
    analysis.binaries,
    analysis.datas,
    strip=False,
    upx=False,
    name="voiceshelf-worker",
)
