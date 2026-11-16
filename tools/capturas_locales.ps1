# Ejecuta las pruebas locales del modulo PAC en esta ventana de PowerShell
# y guarda una captura real de la ventana despues de cada paso.
# Uso: powershell -ExecutionPolicy Bypass -File tools\capturas_locales.ps1 -OutDir <carpeta>
param([string]$OutDir = "$PSScriptRoot\..\docs\evidencias\capturas", [string[]]$Solo = @())

$ErrorActionPreference = 'Continue'
$env:DOCKER_CLI_HINTS = "false"
Set-Location (Split-Path $PSScriptRoot)
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public class Win {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
}
"@
[void][Win]::SetProcessDPIAware()

function Foto([string]$Nombre) {
    Start-Sleep -Milliseconds 900
    $h = [Win]::GetForegroundWindow()
    $r = New-Object Win+RECT
    [void][Win]::DwmGetWindowAttribute($h, 9, [ref]$r, 16)   # bordes reales, sin sombra
    $w = $r.R - $r.L; $hgt = $r.B - $r.T
    $bmp = New-Object System.Drawing.Bitmap $w, $hgt
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
    $bmp.Save((Join-Path $OutDir "$Nombre.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}

function Paso([string]$Nombre, [string]$Titulo, [string[]]$Comandos) {
    if ($Solo.Count -and -not ($Solo -contains $Nombre)) { return }
    Clear-Host
    Write-Host "# $Titulo" -ForegroundColor DarkGray
    foreach ($c in $Comandos) {
        Write-Host "PS $((Get-Location).Path)> " -NoNewline
        Write-Host $c -ForegroundColor Yellow
        Invoke-Expression $c
        Write-Host ""
    }
    Foto $Nombre
}

# ---------- Preparacion (no se fotografia) ----------
$Host.UI.RawUI.WindowTitle = "MediNet-Core PAC - pruebas locales"
Write-Host "Preparando contenedores (1-2 minutos)..."
& "$env:USERPROFILE\.pacvenv\Scripts\Activate.ps1"
docker build -q -t medinet-pac:local . | Out-Null
docker network create pacnet 2>$null | Out-Null
$S = Join-Path $env:TEMP 'pacsec'
New-Item -ItemType Directory -Force $S | Out-Null
python -I -c "import secrets,sys,pathlib;d=pathlib.Path(sys.argv[1]);[(d/n).write_text(secrets.token_urlsafe(40)) for n in ('admin_password','api_password','jwt_secret')]" $S
docker rm -f pacdb pacapi pac-test-db 2>$null | Out-Null
docker run -d --name pacdb --network pacnet -e POSTGRES_DB=pac -e POSTGRES_USER=pacadmin -e POSTGRES_PASSWORD_FILE=/run/secrets/admin_password -v "$S\admin_password:/run/secrets/admin_password:ro" --tmpfs /var/lib/postgresql postgres:17-alpine | Out-Null
docker run -d --name pac-test-db -e POSTGRES_DB=pac_test -e POSTGRES_USER=pac_test_admin -e POSTGRES_PASSWORD=solo-pruebas-locales -p 127.0.0.1:55434:5432 --tmpfs /var/lib/postgresql postgres:17-alpine | Out-Null
Start-Sleep 8

# ---------- 1. Migraciones ----------
Paso '01_migracion' 'Migraciones Alembic y rol de minimo privilegio (contenedor endurecido)' @(
  'docker run --rm --network pacnet --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true -e DB_HOST=pacdb -e DB_PORT=5432 -e POSTGRES_DB=pac -e POSTGRES_USER=pacadmin -e PAC_DB_USER=pac_api -v "$S\admin_password:/run/secrets/admin_password:ro" -v "$S\api_password:/run/secrets/api_password:ro" medinet-pac:local admin'
)

docker run -d --name pacapi --network pacnet -p 127.0.0.1:8000:8000 --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true -e DB_HOST=pacdb -e DB_PORT=5432 -e POSTGRES_DB=pac -e PAC_DB_USER=pac_api -e PAC_NODE_ID=node-a -v "$S\api_password:/run/secrets/api_password:ro" -v "$S\jwt_secret:/run/secrets/jwt_secret:ro" medinet-pac:local api | Out-Null
for ($i = 0; $i -lt 30; $i++) { try { Invoke-WebRequest http://127.0.0.1:8000/health -UseBasicParsing -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep 1 } }

# ---------- 2. Contenedor endurecido ----------
Paso '02_contenedor' 'Endurecimiento del contenedor' @(
  'docker inspect pacapi --format ''User={{.Config.User}}  ReadonlyRootfs={{.HostConfig.ReadonlyRootfs}}  CapDrop={{.HostConfig.CapDrop}}  SecurityOpt={{.HostConfig.SecurityOpt}}''',
  'docker exec pacapi id',
  'docker exec pacapi touch /srv/pac/prueba'
)

# ---------- 3. Cabeceras y 401 ----------
Paso '03a_cabeceras' 'Cabeceras de seguridad HTTP' @('curl.exe -si http://127.0.0.1:8000/health')
Paso '03b_401' 'Acceso sin token: 401 sin filtrar informacion' @('curl.exe -si http://127.0.0.1:8000/patients')

# ---------- 4. Pruebas ----------
Paso '04_pytest' 'Pruebas automatizadas (pytest contra PostgreSQL)' @('python -m pytest -v --no-header -p no:cacheprovider')

# ---------- 5. Ataque controlado ----------
$env:PAC_JWT_SECRET = (Get-Content "$S\jwt_secret" -Raw).Trim()
$T = python tools\dev_token.py --minutes 60
$R = python tools\dev_token.py --roles pac:read
$env:PYTHONIOENCODING = 'utf-8'
Paso '05_ataque' 'Ataque controlado: carrera, inyeccion, XSS, tokens y roles' @(
  'python tools\attack.py http://127.0.0.1:8000 --token $T --readonly-token $R --concurrency 50'
)

# ---------- 6-8. SAST e IaC ----------
Paso '06_bandit' 'SAST con Bandit' @('bandit -r app scripts/containers -ll')
Paso '07_checkov' 'Escaneo IaC con Checkov' @('python -m checkov.main --config-file .checkov.yaml --quiet')
Paso '08_terraform' 'Validacion de Terraform' @('cd infra', 'terraform fmt -check -recursive', 'terraform validate', 'cd ..')

# ---------- 9. Trivy ----------
Paso '09_trivy' 'SCA de la imagen con Trivy' @(
  'docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:0.58.1 image --scanners vuln --severity CRITICAL,HIGH --ignore-unfixed --no-progress --quiet medinet-pac:local'
)

# ---------- 10. ZAP ----------
Paso '10b_zap_despues' 'OWASP ZAP (DAST) contra la API, despues de corregir (tarda unos minutos)' @(
  'docker run --rm --network pacnet -e ZAP_AUTH_HEADER=Authorization -e "ZAP_AUTH_HEADER_VALUE=Bearer $T" ghcr.io/zaproxy/zaproxy:stable zap-api-scan.py -t http://pacapi:8000/openapi.json -f openapi -I | Select-String -Pattern "PASS: (SQL Injection|Cross Site Scripting \(|Path Traversal|Remote OS Command Injection \[|Application Error|Cross-Origin-Resource)|WARN-NEW|FAIL-NEW"'
)

# Reporte del primer escaneo (antes de corregir), abierto en el navegador
if (-not $Solo.Count -or ($Solo -contains '10a_zap_antes')) {
    Start-Process msedge -ArgumentList '--new-window', (Resolve-Path 'docs\evidencias\zap-report-inicial.html').Path
    Start-Sleep 7
    Foto '10a_zap_antes'
}

# ---------- Limpieza ----------
docker rm -f pacapi pacdb pac-test-db 2>$null | Out-Null
docker network rm pacnet 2>$null | Out-Null
Remove-Item -Recurse -Force $S
Remove-Item Env:PAC_JWT_SECRET
"listo" | Set-Content (Join-Path $OutDir 'LISTO.txt')
Write-Host "Capturas guardadas en $OutDir" -ForegroundColor Green
