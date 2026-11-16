variable "region" {
  description = "Región AWS (AWS Academy suele usar us-east-1)"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  type    = string
  default = "medinet-pac"
}

variable "environment" {
  type    = string
  default = "eva03"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "domain_name" {
  description = "FQDN gratuito del servicio, ej. pac.grupo6.dpdns.org"
  type        = string
}

variable "create_hosted_zone" {
  description = "true: Terraform crea la zona Route 53 del dominio y debes delegar los NS en el proveedor gratuito. false: usar existing_zone_id."
  type        = bool
  default     = true
}

variable "existing_zone_id" {
  description = "ID de una zona Route 53 existente (solo si create_hosted_zone = false)"
  type        = string
  default     = ""
}

variable "aws_academy" {
  description = "true en AWS Academy: no se crean roles IAM y se usa LabInstanceProfile / LabRole."
  type        = bool
  default     = false
}

variable "academy_instance_profile" {
  type    = string
  default = "LabInstanceProfile"
}

variable "academy_role_name" {
  type    = string
  default = "LabRole"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_engine_version" {
  type    = string
  default = "17"
}

variable "db_multi_az" {
  description = "Réplica standby de RDS en la otra AZ (duplica el costo de la BD)"
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "Días de respaldos automáticos de RDS. Las cuentas con plan gratuito de AWS solo admiten 1."
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "Protege ALB y RDS contra borrado accidental. Dejar false en la evaluación para poder destruir y no gastar."
  type        = bool
  default     = false
}

variable "cors_origins" {
  description = "Orígenes permitidos por CORS (frontend de MediNet-Core), separados por coma"
  type        = string
  default     = ""
}

variable "github_repository" {
  description = "owner/repo para federación OIDC de GitHub Actions (vacío = no crear). No aplica en AWS Academy."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  type    = number
  default = 365
}
