"""Funcionalidad PAC (EVA02) y regla de negocio crítica bajo concurrencia (EVA03)."""
from concurrent.futures import ThreadPoolExecutor

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import VALID_PATIENT, auth


def test_crear_normaliza_y_devuelve_location(client):
    r = client.post("/patients", json=VALID_PATIENT, headers=auth())
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["run"] == "12345678-5"
    assert body["prevision"] == "FONASA"
    assert body["email"] == "ana@ejemplo.cl"
    assert body["telefono"] == "56912345678"
    assert r.headers["location"].startswith("https://testserver/patients/")


def test_run_duplicado_409(client):
    assert client.post("/patients", json=VALID_PATIENT, headers=auth()).status_code == 201
    dup = VALID_PATIENT | {"run": "12345678-5"}
    r = client.post("/patients", json=dup, headers=auth())
    assert r.status_code == 409


def test_dv_incorrecto_422(client):
    r = client.post("/patients", json=VALID_PATIENT | {"run": "12.345.678-9"}, headers=auth())
    assert r.status_code == 422


def test_campo_extra_rechazado(client):
    r = client.post("/patients", json=VALID_PATIENT | {"is_admin": True}, headers=auth())
    assert r.status_code == 422


def test_xss_almacenado_rechazado(client):
    for campo in ("nombres", "apellido_paterno", "direccion"):
        r = client.post("/patients", json=VALID_PATIENT | {campo: "<script>alert(1)</script>"}, headers=auth())
        assert r.status_code == 422, campo
    # Apóstrofes y tildes siguen permitidos (O'Higgins, Muñoz).
    ok = VALID_PATIENT | {"apellido_paterno": "O'Higgins"}
    assert client.post("/patients", json=ok, headers=auth()).status_code == 201


def test_validate_run(client):
    r = client.post("/patients/validate-run", json={"run": "12.345.678-5"}, headers=auth(["pac:read"]))
    assert r.json() == {"valid": True, "normalized_run": "12345678-5"}
    r = client.post("/patients/validate-run", json={"run": "1-1"}, headers=auth(["pac:read"]))
    assert r.json() == {"valid": False, "normalized_run": None}


def test_busqueda_inyeccion_sql_es_literal(client):
    client.post("/patients", json=VALID_PATIENT, headers=auth())
    r = client.get("/patients", params={"apellido_paterno": "' OR 1=1 --"}, headers=auth())
    assert r.status_code == 200 and r.json()["total"] == 0
    r = client.get("/patients", params={"apellido_paterno": "%"}, headers=auth())
    assert r.json()["total"] == 0          # % no es comodín
    r = client.get("/patients", params={"apellido_paterno": "muñ"}, headers=auth())
    assert r.json()["total"] == 1


def test_id_fuera_de_rango_422_no_500(client):
    # Hallazgo ZAP: un ID mayor que INTEGER provocaba un error 500 en la base de datos.
    for metodo in ("get", "patch"):
        r = getattr(client, metodo)("/patients/1180935187466295391", headers=auth(),
                                     **({"json": {"nombres": "X"}} if metodo == "patch" else {}))
        assert r.status_code == 422, metodo


def test_patch_y_404(client):
    pid = client.post("/patients", json=VALID_PATIENT, headers=auth()).json()["id"]
    r = client.patch(f"/patients/{pid}", json={"direccion": "Av. Alemania 123, Temuco"}, headers=auth())
    assert r.status_code == 200 and r.json()["direccion"] == "Av. Alemania 123, Temuco"
    assert client.patch(f"/patients/{pid}", json={"nombres": None}, headers=auth()).status_code == 422
    r = client.get("/patients/999999", headers=auth())
    assert r.status_code == 404 and r.json() == {"detail": "Paciente no encontrado"}


def test_condicion_de_carrera_mismo_run(client):
    """Ataque controlado: 25 altas simultáneas del mismo RUN. Solo una puede ganar."""
    headers = auth()

    def alta(_):
        with TestClient(app, base_url="https://testserver") as c:
            return c.post("/patients", json=VALID_PATIENT, headers=headers).status_code

    with ThreadPoolExecutor(max_workers=25) as pool:
        codes = list(pool.map(alta, range(25)))
    assert codes.count(201) == 1
    assert codes.count(409) == 24
    r = client.get("/patients", params={"run": "12345678-5"}, headers=headers)
    assert r.json()["total"] == 1
