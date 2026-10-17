$ErrorActionPreference = 'Continue'
$venv = "$PSScriptRoot\.venv-quicksand"
$py = "$venv\Scripts\python.exe"
function FreeMB { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB) }

"== 1. install Quicksand (isolated venv next to this script)"
if (-not (Test-Path $py)) { & uv venv $venv --python 3.12 2>&1 | Select-Object -Last 1 }
& uv pip install --python $py "quick-sandbox[qemu,alpine]" psutil 2>&1 | Select-Object -Last 4
"installed: " + (& $py -c "import importlib.metadata as m; print('quick-sandbox', m.version('quick-sandbox'))" 2>&1)
"venv size: {0:N0} MB" -f ((Get-ChildItem $venv -Recurse -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB)
"free RAM: $(FreeMB) MB"

foreach ($n in 1, 5) {
  if ((FreeMB) -lt 1800) { "SKIPPING N=${n}: free RAM $(FreeMB) MB is below 1800 MB"; continue }
  "== 2. N=$n sandboxes"
  $sw = [Diagnostics.Stopwatch]::StartNew()
  & $py "$PSScriptRoot\qs_measure.py" $n 2>&1 | Select-Object -Last 6
  "   (whole run $([math]::Round($sw.Elapsed.TotalSeconds))s, free RAM afterwards $(FreeMB) MB)"
  Start-Sleep 5
}
"leftover qemu processes: " + @(Get-Process | Where-Object { $_.Name -like '*qemu*' }).Count
"== done"
