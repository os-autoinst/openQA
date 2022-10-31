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

provider "aws" {
  region = var.region
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
  from_port         = 0
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.basic_sg.id
}

resource "aws_security_group_rule" "public_in_http" {
  type              = "ingress"
  from_port         = 0
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.basic_sg.id
}

resource "aws_security_group_rule" "public_in_https" {
  type              = "ingress"
  from_port         = 0
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
