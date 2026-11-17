# Add-ons que os manifestos GitOps pressupõem existir no cluster.
# Sem eles o ArgoCD não sobe, os ExternalSecrets não têm controlador que os
# interprete, o Ingress não tem controller e o HPA não tem métricas.
#
# Estes são instalados por Terraform, e não por GitOps, porque o próprio ArgoCD
# está entre eles — não há como o ArgoCD instalar a si mesmo.

# Fonte das métricas de CPU que alimentam o HPA do donation-service.
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.14.0"

  depends_on = [module.eks]
}

# Controller do Ingress. Provisiona um Network Load Balancer na AWS.
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  version          = "4.15.1"

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  # Expõe as métricas do controller para o ServiceMonitor em gitops/monitoring.
  set {
    name  = "controller.metrics.enabled"
    value = "true"
  }

  depends_on = [module.eks]
}

# Sincroniza as secrets do AWS Secrets Manager para dentro do cluster.
# Autentica por IRSA — nenhuma credencial estática é armazenada.
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  version          = "2.15.0"

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_secrets_irsa.iam_role_arn
  }

  depends_on = [module.eks, module.external_secrets_irsa]
}

# Motor de GitOps. A partir do app-of-apps ele assume a entrega de todo o resto.
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "10.18.0"

  # ClusterIP: o painel não é exposto à internet. Acesso por port-forward:
  #   kubectl port-forward svc/argocd-server -n argocd 8080:443
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  depends_on = [module.eks]
}
