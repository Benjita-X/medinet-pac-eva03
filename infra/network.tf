# VPC con 3 capas por cada una de las 2 zonas de disponibilidad:
#   public  -> ALB y NAT Gateway
#   app     -> instancias EC2 (sin IP pública)
#   db      -> Amazon RDS (sin ruta a Internet)

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

# El SG por defecto queda sin reglas: nada puede usarlo por descuido.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-default-locked" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.name}-public-${local.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "app" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 10 + count.index)
  tags              = { Name = "${local.name}-app-${local.azs[count.index]}", Tier = "app" }
}

resource "aws_subnet" "db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 20 + count.index)
  tags              = { Name = "${local.name}-db-${local.azs[count.index]}", Tier = "db" }
}

# Un NAT Gateway (en la AZ a) para que las EC2 privadas descarguen la imagen y
# los secretos. Ahorra costo; si la AZ a cae, las instancias siguen sirviendo
# tráfico, solo pierden salida a Internet hasta que vuelva.
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${local.name}-nat" }
  depends_on    = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${local.name}-rt-public" }
}

resource "aws_route_table" "app" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "${local.name}-rt-app" }
}

# Tabla sin ruta por defecto: la BD no tiene ningún camino hacia Internet.
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-rt-db" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "app" {
  count          = 2
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app.id
}

resource "aws_route_table_association" "db" {
  count          = 2
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

# VPC Flow Logs: registro de todo el tráfico aceptado y rechazado (evidencia forense).
resource "aws_flow_log" "vpc" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow.arn
  iam_role_arn         = var.aws_academy ? data.aws_iam_role.academy[0].arn : aws_iam_role.flow[0].arn
}
