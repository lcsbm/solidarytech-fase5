# Semente — a única coisa criada fora de um workflow

Nenhum workflow consegue tocar a AWS sem uma role que ele possa assumir. Para
criar essa role por workflow seria preciso outra role antes dela — e assim
indefinidamente. A regressão termina aqui: **uma** role, criada com três
comandos cujos inputs estão versionados neste diretório.

```bash
aws iam create-role \
  --role-name SolidaryTech-CICD-terraform \
  --assume-role-policy-document file://terraform/bootstrap/seed/trust-policy.json \
  --max-session-duration 7200 \
  --tags Key=Project,Value=SolidaryTech Key=Environment,Value=Bootstrap Key=CostCenter,Value=NGO-Core Key=ManagedBy,Value=Seed

aws iam attach-role-policy \
  --role-name SolidaryTech-CICD-terraform \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

A trust restringe a confiança a `lcsbm/solidarytech-fase5` nos dois formatos de
`sub` que o GitHub pode emitir (com e sem IDs numéricos). A sessão de 2 h cobre
um destroy com duas passadas.

**Por que AdministratorAccess:** provisionar EKS, VPC, RDS e IAM exige permissão
ampla, e qualquer role capaz de criar outras roles é Admin na prática. A proteção
efetiva é a trust policy — quem pode assumir —, não a política de permissões.

Esta role não entra no state do Terraform: ela existe antes do state. Para
removê-la ao fim do projeto, os mesmos comandos ao contrário (`detach-role-policy`,
`delete-role`).
