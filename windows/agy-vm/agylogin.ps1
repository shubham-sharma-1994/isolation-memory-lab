# Sign one Google account into agy inside its own smolvm VM. Run it in your own PowerShell window.
#   .\agylogin.ps1 -Account c -Exe C:\path\to\smolvm.exe
param([Parameter(Mandatory)][ValidateSet('a','b','c','d','e')][string]$Account, [Parameter(Mandatory)][string]$Exe)

$Name = "agyvm-$Account"
$free = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB)
Write-Host "Free RAM: $free MB"
if ($free -lt 1200) { Write-Host "Not enough free memory to start a VM safely. Close something (Java uses about 4 GB) and run again." -ForegroundColor Yellow; return }

Write-Host "Starting $Name (about 10 s)..."
$o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
$p = Start-Process -FilePath $Exe -ArgumentList @('machine','start','--name',$Name) -RedirectStandardOutput $o -RedirectStandardError $e -WindowStyle Hidden -PassThru
$null = $p.Handle
if (-not $p.WaitForExit(120000)) { Write-Host "VM did not start in 2 minutes." -ForegroundColor Red; return }

Write-Host ""
Write-Host "agy opens now. Sign in with the Google account for slot '$Account' (copy the link into your browser, then paste the code back)." -ForegroundColor Cyan
Write-Host "Finish any first-run questions (theme, terms), then type /quit." -ForegroundColor Cyan
Write-Host ""
& $Exe machine exec --name $Name -i -t -- env HOME=/home/agent TERM=xterm-256color /opt/agy/agy

Write-Host ""
$cmd = 'f=/home/agent/.gemini/antigravity-cli/antigravity-oauth-token; if [ -f $f ]; then echo "login file present, fingerprint $(sha256sum $f | cut -c1-8)"; else echo "NO login file found"; fi'
$chk = [IO.Path]::GetTempFileName()
cmd /c "`"$Exe`" machine exec --name $Name -- sh -c `"$cmd`" > `"$chk`" 2>&1"
Write-Host ("Check for slot '$Account': " + (Get-Content $chk -Raw).Trim()) -ForegroundColor Green

Write-Host "Stopping $Name to give the memory back..."
& $Exe machine stop --name $Name 2>&1 | Out-Null
Write-Host "Done. Tell Claude when slot '$Account' is finished."
