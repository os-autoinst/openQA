variable "region" {
  # preferred region: Frankfurt, Germany
  type    = string
  default = "eu-central-1"
}

variable "instance_count" {
  type    = number
  default = 1
}

variable "name" {
  type    = string
  default = "openqa-vm"
}

variable "type" {
  type    = string
  default = "t3.large"
}

variable "image_id" {
  type        = string
  description = "AMI (id of machine image) to use"
  default     = "ami-08199c714a509d3bc"

  validation {
    condition     = length(var.image_id) > 4 && substr(var.image_id, 0, 4) == "ami-"
    error_message = "The image_id value must be a valid AMI id, starting with \"ami-\"."
  }
}

variable "root-disk-size" {
  type        = number
  description = "Root volume size in GB"
  default     = 10
}

variable "extra-disk-size" {
  type        = number
  description = "Data volume size in GB"
  default     = 100
}

variable "extra-disk-type" {
  type    = string
  default = "gp2"
}

variable "create-extra-disk" {
  type    = bool
  default = true
}

variable "tags" {
  type = map(string)
  default = {
    team = "qa-tools"
  }
}
