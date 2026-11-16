"""Pruebas contra un PostgreSQL desechable (servicio de CI o contenedor local).

Variables esperadas (con valores por defecto para el contenedor local de pruebas):
TEST_DB_HOST, TEST_DB_PORT, TEST_DB_NAME, TEST_DB_ADMIN, TEST_DB_ADMIN_PASSWORD.
Nunca apuntar estas pruebas a una base con datos reales: se vacía la tabla.
"""
import os
import secrets
import time
from datetime import datetime, timedelta, timezone

import jwt
import pytest

ADMIN = os.environ.get("TEST_DB_ADMIN", "pac_test_admin")
API_USER = "pac_test_api"
JWT_SECRET = secrets.token_urlsafe(48)

os.environ.update({
    "POSTGRES_DB": os.environ.get("TEST_DB_NAME", "pac_test"),
    "POSTGRES_USER": ADMIN,
    "POSTGRES_PASSWORD": os.environ.get("TEST_DB_ADMIN_PASSWORD", "solo-pruebas-locales"),
    "DB_HOST": os.environ.get("TEST_DB_HOST", "127.0.0.1"),
    "DB_PORT": os.environ.get("TEST_DB_PORT", "55434"),
    "PAC_DB_USER": API_USER,
    "PAC_DB_PASSWORD": secrets.token_urlsafe(32),
    "PAC_JWT_SECRET": JWT_SECRET,
    "PAC_CORS_ORIGINS": "https://frontend.medinet.example",
})

from sqlalchemy import text  # noqa: E402

from app.admin_database import create_admin_engine  # noqa: E402


def _wait_for_db(engine):
    for _ in range(60):
        try:
            with engine.connect() as conn:
                conn.execute(text("SELECT 1"))
            return
        except Exception:
            time.sleep(1)
    raise RuntimeError("PostgreSQL de pruebas no disponible")


@pytest.fixture(scope="session")
def admin_engine():
    from scripts.containers import prepare_database

    engine = create_admin_engine()
    _wait_for_db(engine)
    with engine.connect() as conn:
        name = conn.scalar(text("SELECT current_database()"))
    assert name.endswith("_test"), "Las pruebas solo corren sobre bases *_test"
    prepare_database.main()       # migraciones + rol mínimo, igual que en EC2
    yield engine
    engine.dispose()


@pytest.fixture()
def client(admin_engine):
    with admin_engine.begin() as conn:
        conn.execute(text("TRUNCATE patients RESTART IDENTITY"))
    from fastapi.testclient import TestClient
    from app.main import app

    with TestClient(app, base_url="https://testserver") as c:
        yield c


def make_token(roles=("pac:read", "pac:write"), *, sub="medico.prueba", secret=None,
               aud="medinet-pac", iss="medinet-iam", minutes=10, alg="HS256"):
    now = datetime.now(timezone.utc)
    payload = {"sub": sub, "roles": list(roles), "aud": aud, "iss": iss,
               "iat": now, "exp": now + timedelta(minutes=minutes)}
    return jwt.encode(payload, secret or JWT_SECRET, algorithm=alg)


def auth(roles=("pac:read", "pac:write"), **kwargs):
    return {"Authorization": "Bearer " + make_token(roles, **kwargs)}


VALID_PATIENT = {
    "run": "12.345.678-5",
    "nombres": "Ana María",
    "apellido_paterno": "Muñoz",
    "apellido_materno": "Soto",
    "fecha_nacimiento": "1990-05-10",
    "prevision": "fonasa",
    "email": "ana@Ejemplo.CL",
    "telefono": "+56 9 1234 5678",
}
