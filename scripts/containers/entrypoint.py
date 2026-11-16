"""Adaptador exclusivo de contenedores; la API nunca carga secretos administrativos."""
import os
from pathlib import Path
import sys


def load_secret(variable, filename):
    value = Path('/run/secrets/' + filename).read_text().strip()
    if not value:
        raise RuntimeError('Secreto vacío')
    os.environ[variable] = value


if sys.argv[1:] == ['api']:
    load_secret('PAC_DB_PASSWORD', 'api_password')
    load_secret('PAC_JWT_SECRET', 'jwt_secret')
    if any(key in os.environ for key in ('POSTGRES_USER', 'POSTGRES_PASSWORD')):
        raise RuntimeError('La API no debe recibir credenciales administrativas')
    # --proxy-headers: confía en X-Forwarded-Proto del ALB para generar URLs https.
    # Solo se acepta desde la VPC (el SG impide cualquier otro origen).
    # 0.0.0.0 dentro del contenedor es necesario para recibir tráfico del ALB;
    # el Security Group del nodo solo admite el puerto 8000 desde el SG del ALB.
    os.execvp('python', ['python', '-m', 'uvicorn', 'app.main:app', '--host',
                        '0.0.0.0', '--port', '8000', '--no-access-log',  # nosec B104
                        '--proxy-headers', '--forwarded-allow-ips',
                        os.environ.get('PAC_TRUSTED_PROXIES', '127.0.0.1'),
                        '--no-server-header', '--workers', os.environ.get('PAC_WORKERS', '2')])
elif sys.argv[1:] == ['admin']:
    load_secret('POSTGRES_PASSWORD', 'admin_password')
    load_secret('PAC_DB_PASSWORD', 'api_password')
    os.execvp('python', ['python', '-m', 'container_tools.prepare_database'])
else:
    raise SystemExit('Modo permitido: api o admin')
