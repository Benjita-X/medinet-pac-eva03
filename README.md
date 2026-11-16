# MediNet-Core · Módulo PAC · EVA03

Grupo 6 · Desarrollo Seguro (CI3064) · INACAP Temuco

API de pacientes desplegada en AWS en alta disponibilidad (2 zonas), creada con Terraform.

## Carpetas

- `app/` código de la API (FastAPI)
- `infra/` infraestructura en Terraform
- `tests/` pruebas
- `tools/` scripts de ataque, failover y capturas
- `docs/` evidencias

## Desplegar

```bash
cd infra
terraform init
terraform apply
```

## Apagar

```bash
terraform destroy
```
