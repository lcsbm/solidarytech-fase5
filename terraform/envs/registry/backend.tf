terraform {
  backend "s3" {
    bucket       = "solidarytech-tfstate"
    key          = "envs/registry/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
