# Dos nodos backend, uno por zona de disponibilidad, sin IP pública.
# Se administran por SSM Session Manager: no hay puerto 22 ni llave .pem.

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region         = data.aws_region.current.region
    project        = var.project
    ecr_registry   = split("/", aws_ecr_repository.pac.repository_url)[0]
    ecr_repository = aws_ecr_repository.pac.repository_url
    db_host        = aws_db_instance.pac.address
    db_name        = aws_db_instance.pac.db_name
    db_secret_arn  = aws_db_instance.pac.master_user_secret[0].secret_arn
    log_group      = aws_cloudwatch_log_group.app.name
    cors_origins   = var.cors_origins
    target_group   = aws_lb_target_group.pac.arn
  })
}

resource "aws_instance" "pac" {
  count                       = 2
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.app[count.index].id
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = local.instance_profile_name
  associate_public_ip_address = false
  monitoring                  = true
  ebs_optimized               = true
  user_data_base64            = base64encode(local.user_data)
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2: mitiga SSRF contra las credenciales de la instancia
    http_put_response_hop_limit = 1          # los contenedores no alcanzan el endpoint de metadatos
    instance_metadata_tags      = "enabled"  # pac-deploy lee el tag NodeId
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = aws_kms_key.main.arn
    delete_on_termination = true
  }

  tags = {
    Name   = "${local.name}-node-${local.azs[count.index]}"
    Role   = "pac-backend"
    NodeId = "node-${count.index == 0 ? "a" : "b"}"
  }

  lifecycle {
    ignore_changes = [ami] # una AMI nueva no debe recrear ambos nodos a la vez
  }

  depends_on = [aws_nat_gateway.nat, aws_route_table_association.app]
}

resource "aws_lb_target_group_attachment" "pac" {
  count            = 2
  target_group_arn = aws_lb_target_group.pac.arn
  target_id        = aws_instance.pac[count.index].id
  port             = 8000
}
