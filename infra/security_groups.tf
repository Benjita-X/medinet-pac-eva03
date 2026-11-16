# Encadenamiento estricto de Security Groups (SG chaining):
#   Internet --80/443--> ALB --8000--> EC2 (app) --5432--> RDS
# Cada capa solo acepta tráfico desde el SG de la capa anterior, nunca por IP.

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "ALB publico: HTTP (redireccion) y HTTPS desde Internet"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-sg-alb" }
}

resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "EC2 backend PAC: solo puerto 8000 desde el ALB"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-sg-app" }
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "RDS PostgreSQL: solo 5432 desde el backend"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-sg-db" }
}

# --- ALB ---
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS publico"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP solo para redirigir a HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Hacia el backend y sus health checks"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

# --- APP (EC2) ---
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Solo trafico proveniente del SG del ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "Hacia PostgreSQL"
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS saliente via NAT: ECR, SSM, Secrets Manager, CloudWatch, paquetes"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# --- DB (RDS) ---
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "Solo desde los nodos backend"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
