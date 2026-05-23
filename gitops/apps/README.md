# gitops/apps

Argo CD Application manifests live here. The Argo CD instance (installed by
Terraform via Helm) auto-syncs Applications in this directory through a root
"app-of-apps" pattern.

## Bootstrap

After `terraform apply` finishes and Argo CD is up:

```bash
kubectl apply -n argocd -f gitops/apps/counter-service-app.yaml
```

After that, Argo CD owns drift detection, image-updater bumps the image tag in
`deploy/overlays/prod/kustomization.yaml` on every successful CI build,
commits it back to main, and Argo CD reconciles the cluster automatically.

## Verifying CD

1. `kubectl -n argocd port-forward svc/argocd-server 8080:80` then open
   `http://localhost:8080` (initial password: `argocd admin initial-password -n argocd`).
2. Make any commit to `service/app/main.py` (e.g. change the response body).
3. Watch `service-ci` build → push image to ECR.
4. Within ~2 minutes argocd-image-updater commits a tag bump to
   `deploy/overlays/prod/kustomization.yaml`.
5. Argo CD reconciles; `kubectl get pods -n prod -w` shows the rolling update.
6. `curl http://<alb-host>/` returns the new version string.

## Rollback

```bash
argocd app rollback counter-service <prior-rev-id>
# or
git revert <commit-sha> && git push
```
