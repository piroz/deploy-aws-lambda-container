# AWS Providerの設定
provider "aws" {
  region = "ap-northeast-1"
  default_tags {
    tags = {
      env = "piroz"
    }
  }
}

data "aws_caller_identity" "current" {}
locals {
  account_id = data.aws_caller_identity.current.account_id
  ecr_tag    = "latest"
}

# security_group
variable "security_group_id" {
  type = string
}

data "aws_security_group" "main" {
  id = var.security_group_id
}

# subnets
variable "subnet_ids" {
  type = list(string)
}
data "aws_subnet" "main" {
  for_each = toset(var.subnet_ids)
  id       = each.value
}

# function_name
variable "function_name" {
  type = string
}

# Lambda関数用のIAMロールの設定
data "aws_iam_policy_document" "main" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "main" {
  name               = "lambda-role-${var.function_name}"
  assume_role_policy = data.aws_iam_policy_document.main.json
}

resource "aws_iam_role_policy_attachment" "main" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  role       = aws_iam_role.main.name
}

# lambda function
resource "aws_ecr_repository" "main" {
  name                 = var.function_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "null_resource" "main" {
  triggers = {
    docker_file = md5(file("${path.module}/../docker/Dockerfile"))
  }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "docker images && docker build -t ${aws_ecr_repository.main.repository_url}:${local.ecr_tag} ${path.module}/../docker && docker images && docker login --username AWS --password `aws ecr get-login-password --region ap-northeast-1` ${local.account_id}.dkr.ecr.ap-northeast-1.amazonaws.com && docker push ${aws_ecr_repository.main.repository_url}:${local.ecr_tag}"
  }
  depends_on = [
    aws_ecr_repository.main
  ]
}

resource "aws_lambda_function" "main" {
  function_name = var.function_name
  role          = aws_iam_role.main.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.main.repository_url}:${local.ecr_tag}"
  vpc_config {
    security_group_ids = [data.aws_security_group.main.id]
    subnet_ids         = [for o in data.aws_subnet.main : o.id]
  }
  depends_on = [
    null_resource.main
  ]
}

# CloudWatchイベントの設定
resource "aws_cloudwatch_event_rule" "main" {
  name                = "event-${var.function_name}"
  description         = "Run Lambda function every week"
  schedule_expression = "cron(0 17 * * ? *)"
}

resource "aws_cloudwatch_event_target" "main" {
  target_id = "main"
  rule      = aws_cloudwatch_event_rule.main.name
  arn       = aws_lambda_function.main.arn
}

data "aws_iam_policy_document" "ci" {
  statement {
    actions = [
      "lambda:UpdateFunctionCode"
    ]
    resources = [
      "*"
    ]
  }
}

variable "group_name_ci" {
  type = string
}

data "aws_iam_group" "ci" {
  group_name = var.group_name_ci
}

resource "aws_iam_policy" "ci" {
  name        = "UpdateLambdaFunction"
  description = "the ci role can update Lambda function"
  policy      = data.aws_iam_policy_document.ci.json
}

resource "aws_iam_group_policy_attachment" "ci" {
  group      = data.aws_iam_group.ci.group_name
  policy_arn = aws_iam_policy.ci.arn
}
