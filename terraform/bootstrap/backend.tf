# O bootstrap guarda o próprio state no bucket que ele cria. Na primeira
# execução o workflow move este arquivo de lado, aplica com state local e,
# com o bucket já existindo, o traz de volta e migra o state para cá.
terraform {
  backend "s3" {
    bucket       = "solidarytech-tfstate"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
