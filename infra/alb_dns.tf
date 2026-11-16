# --- DNS y certificado TLS ---
resource "aws_route53_zone" "main" {
  # checkov:skip=CKV2_AWS_38:DNSSEC requiere publicar un registro DS en el proveedor del dominio gratuito, que no lo soporta
  # checkov:skip=CKV2_AWS_39:El query logging de Route 53 exige un log group en us-east-1; los accesos ya quedan en logs del ALB
  count = var.create_hosted_zone ? 1 : 0
  name  = var.domain_name
}

locals {
  zone_id = var.create_hosted_zone ? aws_route53_zone.main[0].zone_id : var.existing_zone_id
}

resource "aws_acm_certificate" "pac" {
  domain_name       = var.domain_name
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for o in aws_acm_certificate.pac.domain_validation_options : o.domain_name => {
      name = o.resource_record_name, type = o.resource_record_type, value = o.resource_record_value
    }
  }
  zone_id         = local.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.value]
  ttl             = 60
  allow_overwrite = true
}

# Espera hasta que ACM emita el certificado (requiere la delegación NS hecha).
resource "aws_acm_certificate_validation" "pac" {
  certificate_arn         = aws_acm_certificate.pac.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_route53_record" "service" {
  zone_id = local.zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = aws_lb.pac.dns_name
    zone_id                = aws_lb.pac.zone_id
    evaluate_target_health = true
  }
}

# --- Logs de acceso del ALB (bucket cifrado, privado, solo TLS) ---
data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket" "alb_logs" {
  bucket        = "${local.name}-alb-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # los logs de ALB solo admiten SSE-S3
    }
  }
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expirar-90-dias"
    status = "Enabled"
    filter {}
    expiration {
      days = 90
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EntregaDeLogsDelALB"
        Effect    = "Allow"
        Principal = { AWS = data.aws_elb_service_account.main.arn }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Sid       = "SoloTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.alb_logs.arn, "${aws_s3_bucket.alb_logs.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

# --- Application Load Balancer en 2 AZs ---
resource "aws_lb" "pac" {
  name                       = "${local.name}-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.public[*].id
  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection
  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }
  depends_on = [aws_s3_bucket_policy.alb_logs]
}

resource "aws_lb_target_group" "pac" {
  name                 = "${local.name}-tg"
  port                 = 8000
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 15
  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2 # ~20 s para sacar un nodo caído (failover)
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.pac.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.pac.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06" # solo TLS 1.2 y 1.3
  certificate_arn   = aws_acm_certificate_validation.pac.certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.pac.arn
  }
}
