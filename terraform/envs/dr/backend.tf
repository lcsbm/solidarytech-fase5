# O state do DR fica no mesmo bucket do primario, em chave separada.
# O bucket vive em us-east-1 mesmo o ambiente sendo us-east-2.
terraform {
  backend "s3" {
    bucket       = "solidarytech-tfstate"
    key          = "envs/dr/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
