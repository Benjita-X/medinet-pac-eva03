# En AWS Academy no se pueden crear roles: se usa LabRole / LabInstanceProfile.
# En una cuenta propia se crean roles de mínimo privilegio.

data "aws_iam_role" "academy" {
  count = var.aws_academy ? 1 : 0
  name  = var.academy_role_name
}

locals {
  instance_profile_name = var.aws_academy ? var.academy_instance_profile : aws_iam_instance_profile.ec2[0].name
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  count              = var.aws_academy ? 0 : 1
  name               = "${local.name}-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  count      = var.aws_academy ? 0 : 1
  role       = aws_iam_role.ec2[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ec2_app" {
  statement {
    sid       = "LeerImagen"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "LeerRepositorio"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [aws_ecr_repository.pac.arn]
  }
  statement {
    sid       = "LeerSecretosDelModulo"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/*"]
  }
  statement {
    sid       = "LeerSecretoMaestroRDS"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.pac.master_user_secret[0].secret_arn]
  }
  statement {
    sid       = "Descifrar"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.main.arn]
  }
  statement {
    sid       = "EnviarLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
}

resource "aws_iam_role_policy" "ec2_app" {
  count  = var.aws_academy ? 0 : 1
  name   = "pac-runtime"
  role   = aws_iam_role.ec2[0].id
  policy = data.aws_iam_policy_document.ec2_app.json
}

resource "aws_iam_instance_profile" "ec2" {
  count = var.aws_academy ? 0 : 1
  name  = "${local.name}-ec2"
  role  = aws_iam_role.ec2[0].name
}

# --- Rol para VPC Flow Logs ---
data "aws_iam_policy_document" "flow_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow" {
  count              = var.aws_academy ? 0 : 1
  name               = "${local.name}-flowlogs"
  assume_role_policy = data.aws_iam_policy_document.flow_assume.json
}

resource "aws_iam_role_policy" "flow" {
  count = var.aws_academy ? 0 : 1
  name  = "flowlogs"
  role  = aws_iam_role.flow[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow.arn}:*"
    }]
  })
}

# --- GitHub Actions sin llaves de acceso (OIDC) ---
resource "aws_iam_openid_connect_provider" "github" {
  count          = (!var.aws_academy && var.github_repository != "") ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_role" "github_deploy" {
  count = (!var.aws_academy && var.github_repository != "") ? 1 : 0
  name  = "${local.name}-github-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github[0].arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        # Solo la rama main del repositorio indicado puede desplegar.
        StringLike = { "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:ref:refs/heads/main" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_deploy" {
  count = (!var.aws_academy && var.github_repository != "") ? 1 : 0
  name  = "deploy"
  role  = aws_iam_role.github_deploy[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      { Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage"], Resource = aws_ecr_repository.pac.arn },
      { Effect = "Allow", Action = ["ssm:PutParameter"], Resource = aws_ssm_parameter.image_tag.arn },
      { Effect = "Allow", Action = ["ssm:SendCommand"], Resource = [
        "arn:aws:ssm:${data.aws_region.current.region}::document/AWS-RunShellScript",
      "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*"] },
      { Effect = "Allow", Action = ["ssm:GetCommandInvocation", "ec2:DescribeInstances", "elasticloadbalancing:DescribeTargetHealth"], Resource = "*" },
      { Effect = "Allow", Action = ["kms:Encrypt", "kms:GenerateDataKey", "kms:Decrypt"], Resource = aws_kms_key.main.arn },
    ]
  })
}
