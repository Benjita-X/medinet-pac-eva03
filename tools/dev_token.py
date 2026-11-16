"""Genera un JWT de demostración, como lo emitiría el módulo IAM.

Uso (el secreto se lee de AWS SSM, nunca se escribe en archivos):
    python tools/dev_token.py --roles pac:read pac:write
    python tools/dev_token.py --roles pac:read --minutes 5

Requiere AWS CLI con sesión iniciada, o la variable PAC_JWT_SECRET.
"""
import argparse
import os
import subprocess
from datetime import datetime, timedelta, timezone

import jwt


def secret_from_ssm(name: str, region: str) -> str:
    return subprocess.run(
        ["aws", "ssm", "get-parameter", "--region", region, "--with-decryption",
         "--name", name, "--query", "Parameter.Value", "--output", "text"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--roles", nargs="+", default=["pac:read", "pac:write"])
    p.add_argument("--sub", default="admision.demo")
    p.add_argument("--minutes", type=int, default=30)
    p.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    p.add_argument("--param", default="/medinet-pac/jwt/secret")
    a = p.parse_args()
    secret = os.environ.get("PAC_JWT_SECRET") or secret_from_ssm(a.param, a.region)
    now = datetime.now(timezone.utc)
    token = jwt.encode({"sub": a.sub, "roles": a.roles, "iss": "medinet-iam", "aud": "medinet-pac",
                        "iat": now, "exp": now + timedelta(minutes=a.minutes)}, secret, algorithm="HS256")
    print(token)


if __name__ == "__main__":
    main()
