"""Controles de seguridad EVA03: JWT, roles, cabeceras, CORS y fugas de información."""
import base64
import json

from tests.conftest import VALID_PATIENT, auth, make_token


def test_health_es_publico_y_tiene_cabeceras(client):
    r = client.get("/health")
    assert r.status_code == 200 and r.json() == {"status": "ok"}
    h = r.headers
    assert h["strict-transport-security"].startswith("max-age=31536000")
    assert h["x-content-type-options"] == "nosniff"
    assert h["x-frame-options"] == "DENY"
    assert "frame-ancestors 'none'" in h["content-security-policy"]
    assert h["cross-origin-resource-policy"] == "same-origin"
    assert "server" not in h


def test_datos_clinicos_no_se_cachean(client):
    r = client.get("/patients", headers=auth())
    assert r.headers["cache-control"] == "no-store"


def test_sin_token_401(client):
    r = client.get("/patients")
    assert r.status_code == 401
    assert r.headers["www-authenticate"] == "Bearer"


def test_firma_invalida_401(client):
    r = client.get("/patients", headers=auth(secret="x" * 48))
    assert r.status_code == 401


def test_token_expirado_401(client):
    r = client.get("/patients", headers=auth(minutes=-5))
    assert r.status_code == 401


def test_audiencia_o_emisor_incorrectos_401(client):
    assert client.get("/patients", headers=auth(aud="otro-modulo")).status_code == 401
    assert client.get("/patients", headers=auth(iss="atacante")).status_code == 401


def test_alg_none_rechazado(client):
    def b64(d):
        return base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
    forged = b64({"alg": "none", "typ": "JWT"}) + "." + b64(
        {"sub": "x", "roles": ["pac:write"], "aud": "medinet-pac", "iss": "medinet-iam",
         "iat": 1, "exp": 9999999999}) + "."
    r = client.get("/patients", headers={"Authorization": "Bearer " + forged})
    assert r.status_code == 401


def test_rol_lectura_no_puede_escribir_403(client):
    r = client.post("/patients", json=VALID_PATIENT, headers=auth(["pac:read"]))
    assert r.status_code == 403


def test_escalada_por_manipulacion_de_roles_401(client):
    # Cambiar el claim "roles" sin volver a firmar invalida la firma.
    token = make_token(["pac:read"])
    header, payload, sig = token.split(".")
    data = json.loads(base64.urlsafe_b64decode(payload + "=="))
    data["roles"] = ["pac:read", "pac:write"]
    tampered = base64.urlsafe_b64encode(json.dumps(data).encode()).rstrip(b"=").decode()
    r = client.post("/patients", json=VALID_PATIENT,
                    headers={"Authorization": f"Bearer {header}.{tampered}.{sig}"})
    assert r.status_code == 401


def test_cors_solo_origen_permitido(client):
    ok = client.options("/patients", headers={
        "Origin": "https://frontend.medinet.example", "Access-Control-Request-Method": "GET"})
    assert ok.headers.get("access-control-allow-origin") == "https://frontend.medinet.example"
    bad = client.options("/patients", headers={
        "Origin": "https://evil.example", "Access-Control-Request-Method": "GET"})
    assert "access-control-allow-origin" not in bad.headers


def test_errores_no_reflejan_datos(client):
    payload = VALID_PATIENT | {"run": "<script>alert(1)</script>"}
    r = client.post("/patients", json=payload, headers=auth())
    assert r.status_code == 422
    assert "<script>" not in r.text and "alert" not in r.text


def test_auditoria_enmascara_run(client, caplog):
    with caplog.at_level("INFO", logger="medinet.pac.audit"):
        client.post("/patients", json=VALID_PATIENT, headers=auth())
    out = "\n".join(r.getMessage() for r in caplog.records)
    assert '"event":"patient.create"' in out
    assert "12345678-5" not in out          # nunca el RUN completo
    assert "******78-5" in out              # solo enmascarado
    assert "Ana María" not in out and "ana@" not in out
