resource "helm_release" "nginx" {
  name       = "nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = "ingress"
  # version    = "4.7.0"

  create_namespace = true
  values = [
    file("values.yml")
  ]
}