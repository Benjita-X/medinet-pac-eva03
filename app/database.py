import os
from sqlalchemy import URL, create_engine
from sqlalchemy.orm import sessionmaker

url = URL.create(
    drivername="postgresql+psycopg",
    # No cargar .env administrativo ni usar sus credenciales como alternativa.
    username=os.environ["PAC_DB_USER"],
    password=os.environ["PAC_DB_PASSWORD"],
    host=os.environ["DB_HOST"],
    port=int(os.environ["DB_PORT"]),
    database=os.environ["POSTGRES_DB"],
)

# EVA03: DB_SSLMODE=verify-full en AWS (cifrado en tránsito hacia RDS con su CA).
connect_args = {"sslmode": os.environ.get("DB_SSLMODE", "prefer")}
if os.environ.get("DB_SSLROOTCERT"):
    connect_args["sslrootcert"] = os.environ["DB_SSLROOTCERT"]

engine = create_engine(url, pool_pre_ping=True, hide_parameters=True, connect_args=connect_args)
SessionLocal = sessionmaker(bind=engine, autoflush=False)


def get_db():
    """Una sesión por solicitud; cierre y rollback de trabajo pendiente garantizados."""
    with SessionLocal() as session:
        yield session
