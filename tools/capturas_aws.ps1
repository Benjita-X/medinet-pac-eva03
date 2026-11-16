# Pruebas contra el FQDN en AWS desde esta ventana de PowerShell, con captura
# real de la ventana despues de cada paso.
# Uso: powershell -ExecutionPolicy Bypass -File tools\capturas_aws.ps1 -Fqdn medinetpacg6.dpdns.org
param([string]$Fqdn = 'medinetpacg6.dpdns.org',
      [string]$OutDir = "$PSScriptRoot\..\docs\evidencias\capturas_aws",
      [string[]]$Solo = @())

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path $PSScriptRoot)
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$env:PYTHONIOENCODING = 'utf-8'
& "$env:USERPROFILE\.pacvenv\Scripts\Activate.ps1"

$Captura = @'
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
function Foto([string]$Ruta) {
    $h = [Win]::GetForegroundWindow(); $r = New-Object Win+RECT
    [void][Win]::DwmGetWindowAttribute($h, 9, [ref]$r, 16)
    $bmp = New-Object System.Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
    $bmp.Save($Ruta, [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
}
'@
Invoke-Expression $Captura

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
    Start-Sleep -Milliseconds 900
    Foto (Join-Path $OutDir "$Nombre.png")
}

$Host.UI.RawUI.WindowTitle = "MediNet-Core PAC - pruebas en AWS"

Paso 'a1_http_a_https' 'HTTP 80 redirige a HTTPS 443 (ALB)' @("curl.exe -sI http://$Fqdn/health")
Paso 'a2_https_cabeceras' 'HTTPS con TLS valido y cabeceras de seguridad' @("curl.exe -si https://$Fqdn/health")
Paso 'a3_401' 'Sin token: 401' @("curl.exe -si https://$Fqdn/patients")
Paso 'i_frontend' 'Frontend por HTTPS y ruteo del ALB: / al frontend, /health y /patients a la API' @(
  "curl.exe -sI https://$Fqdn/",
  "curl.exe -s -o NUL -w `"/        -> HTTP %{http_code}  %{content_type}`n`" https://$Fqdn/",
  "curl.exe -s -w `"  <- /health (API)`n`" https://$Fqdn/health",
  "curl.exe -s -o NUL -w `"/patients -> HTTP %{http_code} (API, sin token)`n`" https://$Fqdn/patients"
)

Paso 'g_certificado' 'Certificado TLS del FQDN (validacion estricta de Windows)' @(
  "python -c `"import ssl,socket;h='$Fqdn';c=ssl.create_default_context();s=c.wrap_socket(socket.create_connection((h,443)),server_hostname=h);x=s.getpeercert();print('Sujeto :',dict(i[0] for i in x['subject'])['commonName']);print('Emisor :',dict(i[0] for i in x['issuer'])['organizationName'],'-',dict(i[0] for i in x['issuer'])['commonName']);print('Valido :',x['notBefore'],'->',x['notAfter']);print('TLS    :',s.version(),s.cipher()[0])`"",
  "curl.exe -s -o NUL -w `"TLS 1.1 -> %{http_code}`n`" --tlsv1.1 --tls-max 1.1 https://$Fqdn/health"
)

# Tokens de prueba emitidos con el secreto de SSM (archivo temporal, se borra al final).
$TokFile = Join-Path $env:USERPROFILE 'Downloads\pac_tokens.txt'
if (Test-Path $TokFile) { $tok = Get-Content $TokFile; $T = $tok[0].Trim(); $R = $tok[1].Trim() }

Paso 'b_ataque' 'Ataque controlado contra el FQDN: carrera entre los 2 nodos, inyeccion, XSS, tokens y roles' @(
  "python tools\attack.py https://$Fqdn --token `$T --readonly-token `$R --concurrency 50"
)

Paso 'e_zap' 'OWASP ZAP (DAST) contra el FQDN por HTTPS (tarda unos minutos)' @(
  "docker run --rm -e ZAP_AUTH_HEADER=Authorization -e `"ZAP_AUTH_HEADER_VALUE=Bearer `$T`" ghcr.io/zaproxy/zaproxy:stable zap-api-scan.py -t https://$Fqdn/openapi.json -f openapi -I | Select-String -Pattern `"Number of Imported|PASS: (SQL Injection \[|SQL Injection - PostgreSQL|Cross Site Scripting \(Reflected|Cross Site Scripting \(Persistent\) \[|Path Traversal|Remote OS Command Injection \[|Application Error|Strict-Transport|Cross-Origin-Resource)|WARN-NEW|FAIL-NEW`""
)

# Failover: avisa con un archivo que empezo, para que se detenga node-a; fotos durante y al final.
if (-not $Solo.Count -or ($Solo -contains 'c_failover')) {
    Clear-Host
    Write-Host "# Failover: peticiones continuas al FQDN mientras se detiene node-a" -ForegroundColor DarkGray
    $cmd = "python -u tools\failover.py https://$Fqdn --interval 0.5 --duration 110"
    Write-Host "PS $((Get-Location).Path)> " -NoNewline; Write-Host $cmd -ForegroundColor Yellow
    $job = Start-Job -ScriptBlock {
        param($Captura, $OutDir)
        Invoke-Expression $Captura
        Start-Sleep 45; Foto (Join-Path $OutDir 'c1_failover_durante.png')
        Start-Sleep 30; Foto (Join-Path $OutDir 'c2_failover_solo_node_b.png')
    } -ArgumentList $Captura, $OutDir
    Get-Date -Format o | Set-Content (Join-Path $OutDir 'FAILOVER_START.txt')
    Invoke-Expression $cmd
    Start-Sleep 1
    Foto (Join-Path $OutDir 'c3_failover_resumen.png')
    Wait-Job $job | Out-Null; Remove-Job $job
}

"listo" | Set-Content (Join-Path $OutDir 'LISTO.txt')
Write-Host "Capturas guardadas en $OutDir" -ForegroundColor Green
