terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "local" {}

resource "local_file" "interview_lab" {
  filename = "${path.module}/interview-lab.txt"
  content  = "Terraform lab created by dizal8"
}
