# Escaneo DAST con OWASP ZAP contra el FQDN HTTPS del ALB (ambiente controlado propio).
# Uso (PowerShell, con Docker Desktop encendido):
#   $env:PAC_TOKEN = python tools/dev_token.py
#   .\tools\zap_scan.ps1 -Url https://pac.TU-DOMINIO
# Genera evidence\zap-report.html y evidence\zap-report.json
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [string]$Token = $env:PAC_TOKEN
)
$ErrorActionPreference = "Stop"
$Url = $Url.TrimEnd("/")
$evidence = Join-Path (Get-Location) "evidence"
New-Item -ItemType Directory -Force $evidence | Out-Null

# El token se pasa como variable de entorno al contenedor (no queda en el reporte).
$auth = @()
if ($Token) {
    $auth = @("-e", "ZAP_AUTH_HEADER=Authorization", "-e", "ZAP_AUTH_HEADER_VALUE=Bearer $Token")
}

# API scan: ZAP lee el contrato OpenAPI y ataca cada endpoint documentado.
docker run --rm -v "${evidence}:/zap/wrk:rw" @auth ghcr.io/zaproxy/zaproxy:stable `
    zap-api-scan.py -t "$Url/openapi.json" -f openapi -r zap-report.html -J zap-report.json -I

# Baseline: revisa cabeceras y configuración de la página de documentación.
docker run --rm -v "${evidence}:/zap/wrk:rw" ghcr.io/zaproxy/zaproxy:stable `
    zap-baseline.py -t "$Url/docs" -r zap-baseline.html -I

Write-Host "Reportes en $evidence"
