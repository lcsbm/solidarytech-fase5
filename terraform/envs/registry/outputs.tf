output "primary_repository_urls" {
  description = "Repositórios na região primária — onde o CI publica"
  value       = module.primary.repository_urls
}

output "dr_repository_urls" {
  description = "Repositórios na região de DR — de onde o cluster espelho puxa"
  value       = module.dr.repository_urls
}

output "registry_hosts" {
  description = "Host do registro por região — usados nos overlays Kustomize"
  value = {
    primary = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.primary_region}.amazonaws.com"
    dr      = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.dr_region}.amazonaws.com"
  }
}
