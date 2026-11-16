terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = var.project
      Module      = "PAC"
      Owner       = "Grupo6"
      ManagedBy   = "Terraform"
      Environment = var.environment
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  # checkov:skip=CKV_AWS_394:Solo se usan las 2 primeras AZs (slice); una AZ nueva no altera la topología ya creada
  state = "available"
  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

locals {
  name = "${var.project}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
}
