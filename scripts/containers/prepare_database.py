"""Migraciones y permisos mínimos del rol de la API; nunca desde la API.

EVA03: ambos nodos EC2 ejecutan este paso al arrancar. Un advisory lock de
PostgreSQL garantiza que solo uno migra a la vez; el otro espera y luego
encuentra todo ya aplicado (operación idempotente).
"""
import os
import re

from alembic import command
from alembic.config import Config
from psycopg import sql
from sqlalchemy import text

from app.admin_database import create_admin_engine

LOCK_ID = 2026_0602  # identificador arbitrario y fijo del lock de migración PAC
IDENT = re.compile(r'^[a-z_][a-z0-9_]{0,62}$')


def main():
    database = os.environ['POSTGRES_DB']
    admin = os.environ['POSTGRES_USER']
    api_user = os.environ['PAC_DB_USER']
    if not all(IDENT.fullmatch(name) for name in (database, admin, api_user)) or api_user == admin:
        raise RuntimeError('Nombres de base o roles no válidos')
    engine = create_admin_engine()
    with engine.connect() as conn:
        if tuple(conn.execute(text('SELECT current_database(), current_user')).one()) != (database, admin):
            raise RuntimeError('Identidad administrativa incorrecta')
        conn.execute(text('SELECT pg_advisory_lock(:id)'), {'id': LOCK_ID})
        try:
            config = Config('alembic.ini')
            config.attributes['connection'] = conn
            command.upgrade(config, 'head')
            conn.commit()
            grant_runtime_role(conn, database, api_user)
            conn.commit()
        finally:
            conn.execute(text('SELECT pg_advisory_unlock(:id)'), {'id': LOCK_ID})
            conn.commit()
    engine.dispose()
    print('Migraciones y permisos preparados; sin mostrar credenciales.')


def grant_runtime_role(conn, database, api_user):
    role = sql.Identifier(api_user)
    exists = conn.scalar(text('SELECT EXISTS (SELECT FROM pg_roles WHERE rolname=:r)'), {'r': api_user})
    if not exists:
        conn.exec_driver_sql(sql.SQL('CREATE ROLE {} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE '
                                     'NOREPLICATION NOINHERIT').format(role).as_string())
    # La contraseña se recalcula en cada arranque desde el secreto actual: permite rotarla.
    raw = conn.connection.driver_connection
    verifier = raw.pgconn.encrypt_password(os.environ['PAC_DB_PASSWORD'].encode(),
                                           api_user.encode(), b'scram-sha-256').decode()
    conn.exec_driver_sql(sql.SQL('ALTER ROLE {} PASSWORD {}').format(role, sql.Literal(verifier)).as_string())
    db = sql.Identifier(database)
    for statement in (
        sql.SQL('REVOKE TEMPORARY ON DATABASE {} FROM PUBLIC').format(db),
        sql.SQL('GRANT CONNECT ON DATABASE {} TO {}').format(db, role),
        sql.SQL('GRANT USAGE ON SCHEMA public TO {}').format(role),
        sql.SQL('GRANT SELECT, INSERT, UPDATE ON public.patients TO {}').format(role),
        sql.SQL('GRANT USAGE ON SEQUENCE public.patients_id_seq TO {}').format(role),
    ):
        conn.exec_driver_sql(statement.as_string())


if __name__ == '__main__':
    # No imprimir excepciones SQL que puedan contener verificadores de contraseña.
    try:
        main()
    except Exception:
        raise SystemExit('Preparación administrativa fallida; revisar estado sin volcar secretos.') from None
