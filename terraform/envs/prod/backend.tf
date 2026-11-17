# State remoto: o bucket e a tabela de lock devem existir antes do primeiro init.
# Veja terraform/bootstrap/README.md para criá-los.
terraform {
  backend "s3" {
    bucket       = "solidarytech-tfstate"
    key          = "envs/prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
