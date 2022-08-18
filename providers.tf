provider "aws" {
  alias = "virginia"
  region = "us-east-1"
  profile = "default"
}

terraform {
  backend "s3" {
    profile = "default"
    bucket = "tv-tf-state-dev"
    key    = "devops-cluster/terraform.tfstate"
    region = "us-east-1"
  }
}
