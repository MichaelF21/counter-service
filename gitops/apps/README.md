# gitops/apps

Argo CD Application manifests live here. The Argo CD instance (installed by
Terraform via Helm) auto-syncs Applications in this directory through a root
"app-of-apps" pattern.

## Bootstrap

After `terraform apply` finishes and Argo CD is up:

```bash
kubectl apply -n argocd -f gitops/apps/counter-service-app.yaml
```

After that, Argo CD owns drift detection. `argocd-image-updater` is configured
to commit a tag bump to `deploy/overlays/prod/kustomization.yaml` on every
successful CI build; a known issue with its ECR auth-helper output format
means the auto-bump path has a one-line fix outstanding (see root README),
so the current demo flow has been driven by small `deploy/v*` PRs that bump
the tag manually — end-state on the cluster is identical to image-updater's.

## Verifying CD

1. Get the Argo CD UI:
   ```bash
   kubectl -n argocd port-forward svc/argocd-server 8080:80
   # initial admin password:
   kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d
   ```
   then open <http://localhost:8080> (user: `admin`).
2. Make any commit to `service/app/main.py` (e.g. change the response body) → push to main.
3. Watch `service-ci` build → push image to ECR.
4. Bump `deploy/overlays/prod/kustomization.yaml` `newTag` (or wait for
   image-updater once the auth script is fixed).
5. Argo CD reconciles; `kubectl get pods -n prod -w` shows the rolling update.
6. `curl http://<alb-host>/version` returns the new version string.

## Rollback

```bash
argocd app rollback counter-service <prior-rev-id>
# or
git revert <commit-sha> && git push
```
