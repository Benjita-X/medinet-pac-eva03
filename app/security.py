"""Validación de tokens JWT emitidos por el módulo IAM de MediNet-Core.

PAC no emite tokens ni maneja contraseñas de usuarios (eso es de IAM): solo
verifica firma, emisor, audiencia, expiración y roles de cada solicitud.
"""
import os
from dataclasses import dataclass

import jwt
from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.audit import audit

ALGORITHM = "HS256"
ISSUER = os.environ.get("PAC_JWT_ISSUER", "medinet-iam")
AUDIENCE = os.environ.get("PAC_JWT_AUDIENCE", "medinet-pac")
ROLE_READ = "pac:read"
ROLE_WRITE = "pac:write"

bearer = HTTPBearer(auto_error=False, description="Token JWT emitido por el módulo IAM")


def _secret() -> str:
    secret = os.environ.get("PAC_JWT_SECRET", "")
    # Una clave corta haría viable la fuerza bruta offline del HMAC.
    if len(secret) < 32:
        raise RuntimeError("PAC_JWT_SECRET ausente o demasiado corto (mínimo 32 caracteres)")
    return secret


@dataclass(frozen=True)
class Principal:
    subject: str
    roles: frozenset[str]


def _deny(request: Request, status: int, reason: str, actor: str | None = None):
    audit("auth.denied", "failure", actor=actor, request_id=getattr(request.state, "request_id", None),
          reason=reason, path=request.url.path, method=request.method)
    headers = {"WWW-Authenticate": "Bearer"} if status == 401 else None
    raise HTTPException(status, "No autorizado" if status == 401 else "Permiso insuficiente",
                        headers=headers)


def current_principal(request: Request,
                      credentials: HTTPAuthorizationCredentials | None = Depends(bearer)) -> Principal:
    if credentials is None:
        _deny(request, 401, "missing_token")
    try:
        claims = jwt.decode(
            credentials.credentials, _secret(),
            algorithms=[ALGORITHM],          # lista cerrada: bloquea "alg": "none" y confusión de algoritmo
            audience=AUDIENCE, issuer=ISSUER,
            options={"require": ["exp", "iat", "sub", "iss", "aud"]},
            leeway=30,
        )
    except jwt.ExpiredSignatureError:
        _deny(request, 401, "expired_token")
    except jwt.PyJWTError:
        _deny(request, 401, "invalid_token")
    roles = claims.get("roles", [])
    if not isinstance(roles, list) or not all(isinstance(r, str) for r in roles):
        _deny(request, 401, "invalid_roles_claim", actor=str(claims.get("sub")))
    return Principal(subject=str(claims["sub"]), roles=frozenset(roles))


def require_role(role: str):
    def checker(request: Request, principal: Principal = Depends(current_principal)) -> Principal:
        if role not in principal.roles:
            _deny(request, 403, f"missing_role:{role}", actor=principal.subject)
        return principal
    return checker
