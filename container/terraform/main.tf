terraform {
  required_providers {
    aws = {
      version = ">= 4.38"
      source  = "hashicorp/aws"
    }
    random = {
      version = ">= 3.4.3"
      source  = "hashicorp/random"
    }
  }
}

locals {
  use_localstack = (terraform.workspace == "ci")
  aws_settings = (
    local.use_localstack ? {
      skip_credentials_validation = true
      skip_metadata_api_check     = true
      skip_requesting_account_id  = true
      override_endpoint           = "http://localhost:4566"
    } : {
      skip_credentials_validation = null
      skip_metadata_api_check     = null
      skip_requesting_account_id  = null
      override_endpoint           = null
    }
  )
}

provider "aws" {
  region                      = var.region
  access_key                  = var.aws_access_key_id
  secret_key                  = var.aws_secret_access_key
  token                       = var.aws_session_token
  s3_use_path_style           = true

  skip_credentials_validation = local.aws_settings.skip_credentials_validation
  skip_metadata_api_check     = local.aws_settings.skip_metadata_api_check
  skip_requesting_account_id  = local.aws_settings.skip_requesting_account_id

  dynamic "endpoints" {
    for_each = local.aws_settings.override_endpoint[*]
    content {
      apigateway     = endpoints.value
      apigatewayv2   = endpoints.value
      cloudformation = endpoints.value
      cloudwatch     = endpoints.value
      dynamodb       = endpoints.value
      ec2            = endpoints.value
      es             = endpoints.value
      elasticache    = endpoints.value
      firehose       = endpoints.value
      iam            = endpoints.value
      kinesis        = endpoints.value
      lambda         = endpoints.value
      rds            = endpoints.value
      redshift       = endpoints.value
      route53        = endpoints.value
      s3             = endpoints.value
      secretsmanager = endpoints.value
      ses            = endpoints.value
      sns            = endpoints.value
      sqs            = endpoints.value
      ssm            = endpoints.value
      stepfunctions  = endpoints.value
      sts            = endpoints.value
    }
  }
}

resource "random_id" "service" {
  count = var.instance_count
  keepers = {
    name = var.name
  }
  byte_length = 8
}

resource "aws_security_group" "basic_sg" {
  name        = "webui-${element(random_id.service.*.hex, 0)}"
  description = "Allow inbound ssh/http/https traffic"

  tags = merge({
    openqa_create_by    = var.name
    openqa_created_date = timestamp()
    openqa_created_id   = element(random_id.service.*.hex, 0)
  }, var.tags)
}

resource "aws_security_group_rule" "public_out" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.basic_sg.id
}

resource "aws_security_group_rule" "public_in_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.basic_sg.id
}

resource "aws_security_group_rule" "public_in_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.basic_sg.id
}

resource "aws_security_group_rule" "public_in_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.basic_sg.id
}

resource "aws_instance" "webui" {
  count           = var.instance_count
  ami             = var.image_id
  instance_type   = var.type
  security_groups = [aws_security_group.basic_sg.name]

  user_data = <<EOF
		#! /bin/bash
        curl -s https://raw.githubusercontent.com/os-autoinst/openQA/master/script/openqa-bootstrap | bash -x
EOF

  ebs_block_device {
    device_name = "/dev/sda1"
    volume_size = var.root-disk-size
  }

  tags = merge({
    openqa_create_by    = var.name
    openqa_created_date = timestamp()
    openqa_created_id   = element(random_id.service.*.hex, count.index)
  }, var.tags)
}

resource "aws_volume_attachment" "ebs_att" {
  count       = var.create-extra-disk ? var.instance_count : 0
  device_name = "/dev/sdb"
  volume_id   = element(aws_ebs_volume.ssd_disk.*.id, count.index)
  instance_id = element(aws_instance.webui.*.id, count.index)
}

resource "aws_ebs_volume" "ssd_disk" {
  count             = var.create-extra-disk ? var.instance_count : 0
  availability_zone = element(aws_instance.webui.*.availability_zone, count.index)
  size              = var.extra-disk-size
  type              = var.extra-disk-type

  tags = merge({
    openqa_created_by   = var.name
    openqa_created_date = timestamp()
    openqa_created_id   = element(random_id.service.*.hex, count.index)
  }, var.tags)
}

output "public_ip" {
  value = aws_instance.webui.*.public_ip
}

output "vm_name" {
  value = aws_instance.webui.*.id
}
