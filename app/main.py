import os
import uuid

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy.exc import DisconnectionError, OperationalError, SQLAlchemyError, TimeoutError
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.audit import audit
from app.routers.patients import router as patients_router


app = FastAPI(
    title="MediNet-Core – Módulo PAC",
    description="Gestión de Pacientes y Admisión (Grupo 6). Requiere token JWT del módulo IAM.",
    version="0.3.0",
    docs_url="/docs",
    redoc_url=None,
)

# CORS restrictivo: solo los orígenes declarados (frontend de MediNet-Core).
# Vacío = ningún origen cruzado permitido.
_origins = [o.strip() for o in os.environ.get("PAC_CORS_ORIGINS", "").split(",") if o.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins,
    allow_methods=["GET", "POST", "PATCH"],
    allow_headers=["Authorization", "Content-Type"],
    allow_credentials=False,
    max_age=600,
)

# Swagger UI carga JS/CSS desde jsDelivr; la CSP lo permite solo en /docs.
_DOCS_CSP = ("default-src 'self'; script-src 'self' https://cdn.jsdelivr.net 'unsafe-inline'; "
             "style-src 'self' https://cdn.jsdelivr.net 'unsafe-inline'; "
             "img-src 'self' data: https://fastapi.tiangolo.com; frame-ancestors 'none'")
_API_CSP = "default-src 'none'; frame-ancestors 'none'"
_NODE_LABEL = os.environ.get("PAC_NODE_ID", "")[:20]


@app.middleware("http")
async def security_headers(request: Request, call_next):
    # El ALB añade X-Amzn-Trace-Id; se reutiliza para correlacionar logs entre nodos.
    request.state.request_id = (request.headers.get("x-amzn-trace-id") or uuid.uuid4().hex)[:100]
    response = await call_next(request)
    h = response.headers
    h["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    h["X-Content-Type-Options"] = "nosniff"
    h["X-Frame-Options"] = "DENY"
    h["Referrer-Policy"] = "no-referrer"
    h["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
    h["Cross-Origin-Opener-Policy"] = "same-origin"
    h["Cross-Origin-Resource-Policy"] = "same-origin"  # hallazgo OWASP ZAP [90004]
    h["Content-Security-Policy"] = _DOCS_CSP if request.url.path in ("/docs", "/docs/oauth2-redirect") else _API_CSP
    # Datos clínicos: nunca en caché de navegador ni de proxies intermedios.
    if request.url.path.startswith("/patients"):
        h["Cache-Control"] = "no-store"
    h["X-Request-ID"] = request.state.request_id
    # Etiqueta opaca del nodo (node-a / node-b), nunca el hostname interno:
    # permite ver en la prueba de failover qué AZ atendió cada solicitud.
    if _NODE_LABEL:
        h["X-PAC-Node"] = _NODE_LABEL
    if "server" in h:
        del h["server"]
    return response


app.include_router(patients_router)


@app.exception_handler(RequestValidationError)
async def validation_error(request: Request, exc: RequestValidationError):
    # No reflejar datos personales, SQL ni valores recibidos en errores.
    audit("input.rejected", "failure", request_id=getattr(request.state, "request_id", None),
          path=request.url.path, method=request.method)
    return JSONResponse(status_code=422, content={"detail": [
        {"loc": list(error["loc"]), "type": error["type"],
         "msg": "Valor inválido"} for error in exc.errors()
    ]})


@app.exception_handler(StarletteHTTPException)
async def http_error(request: Request, exc: StarletteHTTPException):
    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail},
                        headers=getattr(exc, "headers", None))


@app.exception_handler(SQLAlchemyError)
async def database_error(request: Request, exc: SQLAlchemyError):
    # SQLAlchemy también informa errores de programación: no todos son caídas.
    sqlstate = getattr(getattr(exc, "orig", None), "sqlstate", None)
    unavailable = isinstance(exc, (DisconnectionError, TimeoutError)) or (
        isinstance(exc, OperationalError)
        and (sqlstate is None or sqlstate.startswith("08")
             or sqlstate in {"57P01", "57P02", "57P03", "53300"})
    )
    audit("db.error", "failure", request_id=getattr(request.state, "request_id", None),
          sqlstate=sqlstate, unavailable=unavailable)
    return JSONResponse(
        status_code=503 if unavailable else 500,
        content={"detail": "Base de datos no disponible" if unavailable else "Error interno"},
    )


@app.exception_handler(Exception)
async def unexpected_error(request: Request, exc: Exception):
    # Ocultamiento de trazas: el cliente nunca recibe el stack trace.
    audit("app.error", "failure", request_id=getattr(request.state, "request_id", None),
          error_type=type(exc).__name__)
    return JSONResponse(status_code=500, content={"detail": "Error interno"})


@app.get("/health", include_in_schema=False)
def health():
    # Health check del ALB: solo el proceso HTTP, sin datos ni dependencias.
    return {"status": "ok"}
