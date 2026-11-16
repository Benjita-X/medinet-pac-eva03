# MediNet-Core · Módulo PAC · EVA03

Grupo 6 · Desarrollo Seguro (CI3064) · INACAP Temuco

Frontend y API de pacientes desplegados en AWS en alta disponibilidad (2 zonas), creada con Terraform.

## Carpetas

- `app/` código de la API (FastAPI)
- `frontend/` página de admisión (registro con validación de RUN, búsqueda paginada) servida por nginx sin privilegios
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
