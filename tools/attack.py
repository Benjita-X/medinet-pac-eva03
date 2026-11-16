"""Ataque controlado al módulo PAC (solo contra NUESTRO ambiente de evaluación).

Intenta vulnerar las reglas críticas del módulo y muestra si fueron bloqueadas:
  1. Condición de carrera: N altas simultáneas del mismo RUN contra los 2 nodos.
  2. Inyección SQL / XSS / caracteres de control / campos extra (mass assignment).
  3. Manipulación de tokens: sin token, firma falsa, alg=none, roles alterados, expirado.
  4. Escalada de privilegios: token de solo lectura intentando escribir.

Uso:
    python tools/attack.py https://pac.TU-DOMINIO --token "$(python tools/dev_token.py)" \
        --readonly-token "$(python tools/dev_token.py --roles pac:read)"
"""
import argparse
import base64
import json
import random
import urllib.error
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor


def request(method, url, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, r.read().decode(), r.headers.get("X-PAC-Node", "?")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(), e.headers.get("X-PAC-Node", "?")


def random_run():
    body = random.randint(10_000_000, 25_000_000)
    total = sum(int(d) * (2 + i % 6) for i, d in enumerate(reversed(str(body))))
    r = 11 - total % 11
    return f"{body}-{'0' if r == 11 else 'K' if r == 10 else r}"


def b64(obj):
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).rstrip(b"=").decode()


def patient(run, **extra):
    return {"run": run, "nombres": "Prueba", "apellido_paterno": "Ataque", "fecha_nacimiento": "1990-01-01",
            "prevision": "FONASA", **extra}


results = []


def check(name, ok, detail):
    results.append((name, ok))
    print(f"[{'BLOQUEADO' if ok else 'VULNERABLE':10}] {name}: {detail}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("base_url")
    p.add_argument("--token", required=True, help="Token con pac:read y pac:write")
    p.add_argument("--readonly-token", required=True, help="Token solo con pac:read")
    p.add_argument("--concurrency", type=int, default=50)
    a = p.parse_args()
    api = a.base_url.rstrip("/") + "/patients"

    # 1. Condición de carrera
    run = random_run()
    with ThreadPoolExecutor(max_workers=a.concurrency) as pool:
        outs = list(pool.map(lambda _: request("POST", api, a.token, patient(run)), range(a.concurrency)))
    codes = Counter(o[0] for o in outs)
    nodes = Counter(o[2] for o in outs)
    status, body, _ = request("GET", f"{api}?run={run}", a.token)
    total = json.loads(body)["total"] if status == 200 else "?"
    check("Carrera: altas simultáneas del mismo RUN", codes.get(201) == 1 and total == 1,
          f"códigos={dict(codes)} nodos={dict(nodes)} filas_en_RDS={total}")

    # 2. Payloads maliciosos
    payloads = {
        "SQLi en apellido (búsqueda)": ("GET", f"{api}?apellido_paterno=%27%20OR%201%3D1%20--", None, {200}),
        "SQLi en RUN": ("POST", api, patient("1' OR '1'='1"), {422}),
        "XSS almacenado en nombres": ("POST", api, patient(random_run(), nombres="<script>alert(1)</script>"), {422}),
        "Caracter de control": ("POST", api, patient(random_run(), nombres="Ana\u0000"), {422}),
        "Mass assignment (campo id)": ("POST", api, patient(random_run(), id=1), {422}),
        "Payload sobredimensionado": ("POST", api, patient(random_run(), direccion="A" * 5000), {422}),
    }
    for name, (method, url, body, expected) in payloads.items():
        status, text, _ = request(method, url, a.token, body)
        leaks = any(s in text.lower() for s in ("traceback", "sqlalchemy", "psycopg", "select ", "<script>"))
        extra = ""
        if name.startswith("SQLi en apellido") and status == 200:
            extra = f" total={json.loads(text)['total']}"
            ok = json.loads(text)["total"] == 0 and not leaks
        else:
            ok = status in expected and not leaks
        check(name, ok, f"HTTP {status}{extra}{' (filtra detalles internos)' if leaks else ''}")

    # 3. Manipulación de tokens
    header, payload_b64, sig = a.token.split(".")
    claims = json.loads(base64.urlsafe_b64decode(payload_b64 + "=="))
    forged = {
        "Sin token": None,
        "Firma inventada": f"{header}.{payload_b64}.{'A' * len(sig)}",
        "alg=none": b64({"alg": "none", "typ": "JWT"}) + "." + payload_b64 + ".",
        "Roles alterados sin refirmar": f"{header}.{b64(claims | {'roles': ['pac:read', 'pac:write', 'admin']})}.{sig}",
        "Expirado alterado sin refirmar": f"{header}.{b64(claims | {'exp': 9999999999})}.{sig}",
    }
    for name, tok in forged.items():
        status, _, _ = request("GET", api, tok)
        check(f"Token: {name}", status == 401, f"HTTP {status}")

    # 4. Escalada de privilegios
    status, _, _ = request("POST", api, a.readonly_token, patient(random_run()))
    check("Rol pac:read intentando crear paciente", status == 403, f"HTTP {status}")

    blocked = sum(ok for _, ok in results)
    print(f"\nResultado: {blocked}/{len(results)} ataques bloqueados")
    raise SystemExit(0 if blocked == len(results) else 1)


if __name__ == "__main__":
    main()
