from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Path, Query, Response, Request
from sqlalchemy.orm import Session

from app.audit import audit
from app.database import get_db
from app.schemas import (
    ErrorResponse, PatientCreate, PatientList, PatientPatch, PatientRead,
    Prevision, Run, RunValidation, RunValidationResult, Surname, clean_run,
)
from app.security import ROLE_READ, ROLE_WRITE, Principal, require_role
from app.services import patients

router = APIRouter(prefix="/patients", tags=["Pacientes"], responses={
    401: {"model": ErrorResponse, "description": "Token ausente, inválido o expirado"},
    403: {"model": ErrorResponse, "description": "El token no tiene el rol requerido"},
    503: {"model": ErrorResponse, "description": "Base de datos no disponible"},
})
DB = Annotated[Session, Depends(get_db)]
Reader = Annotated[Principal, Depends(require_role(ROLE_READ))]
Writer = Annotated[Principal, Depends(require_role(ROLE_WRITE))]
# le=2147483647: el ID es INTEGER en PostgreSQL. Sin este límite, un ID gigante
# llegaba a la BD y provocaba un 500 (hallazgo del escaneo OWASP ZAP).
PatientID = Annotated[int, Path(gt=0, le=2147483647, description="ID entero positivo del paciente")]
errors = {404: {"model": ErrorResponse, "description": "Paciente inexistente"},
          409: {"model": ErrorResponse, "description": "RUN ya registrado"},
          500: {"model": ErrorResponse, "description": "Error interno sin datos sensibles"}}


def rid(request: Request):
    return getattr(request.state, "request_id", None)


@router.post("/validate-run", response_model=RunValidationResult,
             summary="Validar formato y Módulo 11 sin consultar existencia")
def validate_run(payload: RunValidation, user: Reader):
    try:
        normalized = clean_run(payload.run)
    except ValueError:
        return {"valid": False, "normalized_run": None}
    return {"valid": True, "normalized_run": normalized}


@router.post("", response_model=PatientRead, status_code=201, responses=errors,
             summary="Crear paciente con RUN normalizado (rol pac:write)")
def create_patient(payload: PatientCreate, response: Response, request: Request, db: DB, user: Writer):
    try:
        patient = patients.create_patient(db, payload)
    except HTTPException as exc:
        audit("patient.create", "failure", actor=user.subject, request_id=rid(request),
              run=payload.run, status=exc.status_code)
        raise
    audit("patient.create", "success", actor=user.subject, request_id=rid(request),
          patient_id=patient.id, run=patient.run)
    response.headers["Location"] = str(request.url_for("get_patient", patient_id=patient.id))
    return patient


@router.get("", response_model=PatientList, summary="Buscar y paginar pacientes (rol pac:read)",
            description="Filtros combinados con AND. Apellidos por prefijo literal, sin distinguir "
                        "mayúsculas; las tildes sí se distinguen. Orden: apellido paterno, materno e ID.")
def list_patients(
    request: Request,
    db: DB,
    user: Reader,
    run: Annotated[Run | None, Query(description="RUN exacto; admite puntos y guion", examples=["12.345.678-5"])] = None,
    apellido_paterno: Annotated[Surname | None, Query(description="Prefijo literal; %, _ y \\ no son comodines")] = None,
    apellido_materno: Annotated[Surname | None, Query(description="Prefijo literal de apellido materno")] = None,
    prevision: Annotated[Prevision | None, Query(description="FONASA, ISAPRE, CAPREDENA o DIPRECA")] = None,
    page: Annotated[int, Query(ge=1, le=100000, description="Página: 1 a 100000; sin resultados devuelve items vacío")] = 1,
    page_size: Annotated[int, Query(ge=1, le=100, description="Tamaño: 1 a 100; predeterminado 20")] = 20,
):
    result = patients.list_patients(db, run=run, apellido_paterno=apellido_paterno,
                                    apellido_materno=apellido_materno, prevision=prevision,
                                    page=page, page_size=page_size)
    audit("patient.search", "success", actor=user.subject, request_id=rid(request),
          run=run, results=len(result["items"]))
    return result


@router.get("/{patient_id}", response_model=PatientRead, responses=errors,
            summary="Consultar por ID (rol pac:read)", name="get_patient")
def get_patient(patient_id: PatientID, request: Request, db: DB, user: Reader):
    patient = patients.get_patient(db, patient_id)
    # Ley 20.584: todo acceso a la ficha queda registrado (quién, cuándo, qué paciente).
    audit("patient.read", "success", actor=user.subject, request_id=rid(request),
          patient_id=patient.id, run=patient.run)
    return patient


@router.patch("/{patient_id}", response_model=PatientRead, responses=errors,
              summary="Actualizar campos enviados (rol pac:write)",
              description="Ausencia conserva el valor. null solo borra campos opcionales. "
                          "Objeto vacío y null en obligatorios producen 422. RUN se revalida.")
def patch_patient(patient_id: PatientID, payload: PatientPatch, request: Request, db: DB, user: Writer):
    try:
        patient = patients.patch_patient(db, patient_id, payload)
    except HTTPException as exc:
        audit("patient.update", "failure", actor=user.subject, request_id=rid(request),
              patient_id=patient_id, status=exc.status_code)
        raise
    audit("patient.update", "success", actor=user.subject, request_id=rid(request),
          patient_id=patient.id, run=patient.run, fields=sorted(payload.model_fields_set))
    return patient
