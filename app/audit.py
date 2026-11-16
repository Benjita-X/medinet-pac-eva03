"""Eventos de seguridad en JSON (una línea por evento) hacia stdout.

En AWS, Docker los envía a CloudWatch Logs (driver awslogs), desde donde el
módulo de Auditoría (AUD) los consume. Nunca se registran datos clínicos ni
personales en claro: el RUN va enmascarado y no se incluyen nombres, emails,
teléfonos ni direcciones.
"""
import json
import logging
import os
import socket
from datetime import datetime, timezone

from app.validators.run import mask_run

_logger = logging.getLogger("medinet.pac.audit")
if not _logger.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(logging.Formatter("%(message)s"))
    _logger.addHandler(_handler)
    _logger.setLevel(logging.INFO)
    _logger.propagate = False

NODE = os.environ.get("PAC_NODE_ID") or socket.gethostname()


def audit(event: str, outcome: str, *, actor: str | None = None, request_id: str | None = None,
          patient_id: int | None = None, run: str | None = None, **extra) -> None:
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "module": "PAC",
        "node": NODE,
        "event": event,
        "outcome": outcome,
        "actor": actor,
        "request_id": request_id,
        "patient_id": patient_id,
        "run_masked": mask_run(run),
    }
    # Solo metadatos no sensibles (códigos, rutas, roles).
    record.update({k: v for k, v in extra.items() if v is not None})
    _logger.info(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
