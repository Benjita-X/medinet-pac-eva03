"""Prueba de resiliencia (failover) contra el FQDN del ALB.

Envía peticiones continuas y muestra qué nodo respondió cada una. Mientras
corre, detén una instancia EC2 desde la consola; el ALB debe dejar de enviarle
tráfico y el servicio seguir respondiendo desde el otro nodo.

Uso:
    python tools/failover.py https://pac.TU-DOMINIO --token "$(python tools/dev_token.py)"
    (Ctrl+C para terminar y ver el resumen)
"""
import argparse
import json
import time
import urllib.error
import urllib.request
from collections import Counter
from datetime import datetime


def call(url, token):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"} if token else {})
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.headers.get("X-PAC-Node", "?"), time.perf_counter() - started
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("X-PAC-Node", "?"), time.perf_counter() - started
    except Exception as e:  # timeout, conexión rechazada
        return type(e).__name__, "-", time.perf_counter() - started


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("base_url")
    p.add_argument("--token", default="")
    p.add_argument("--interval", type=float, default=0.5)
    a = p.parse_args()
    url = a.base_url.rstrip("/") + ("/patients?page_size=1" if a.token else "/health")
    stats, nodes, total = Counter(), Counter(), 0
    print(f"Consultando {url} cada {a.interval}s. Detén una EC2 ahora. Ctrl+C para terminar.\n")
    try:
        while True:
            status, node, elapsed = call(url, a.token)
            total += 1
            stats[status] += 1
            nodes[node] += 1
            mark = "OK " if status == 200 else "ERR"
            print(f"{datetime.now():%H:%M:%S}  {mark} {status}  nodo={node:<7} {elapsed*1000:6.0f} ms")
            time.sleep(a.interval)
    except KeyboardInterrupt:
        pass
    ok = stats.get(200, 0)
    print("\nResumen:", json.dumps({"total": total, "exitosas": ok,
                                    "disponibilidad_%": round(100 * ok / max(total, 1), 2),
                                    "por_codigo": {str(k): v for k, v in stats.items()},
                                    "por_nodo": dict(nodes)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
