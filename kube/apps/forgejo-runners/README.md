# Independent Forgejo runners for Codeberg

Two independent Deployments share the workload definition in `base/`. Each has
its own UUID/token, target URL, and 10Gi `longhorn-r1` Actions cache. Both target
`https://codeberg.org/`; no local Forgejo server or database is required.
Each enabled Deployment runs one
pod and one job at a time; `Recreate` avoids concurrent use of an identity or
cache database. Do not increase a Deployment above one replica; add another
runner overlay with its own credentials and cache instead.

Runners connect outbound to Codeberg over HTTPS. No public IP, SSH exposure,
Cloudflare tunnel, or VPS proxy is needed. Use HTTPS checkout URLs in workflows;
the egress policy does not allow SSH on port 22.

| Setting | Location |
| --- | --- |
| Target instance and activation | `runner-1/kustomization.yaml`, `runner-2/kustomization.yaml` |
| Labels, timeouts, and Actions cache | `base/config.yaml` |
| Images, Docker sidecar, and resource limits | `base/deployment.yaml` |
| Cache size and storage class | `base/cache-pvc.yaml` |

## Credentials and activation

Both Deployments start at **zero replicas** until their credentials are supplied.
For each runner, prepare the following for a later approved deployment:

1. On Codeberg, enable Actions under the repository's **Settings → Units →
   Overview**. Use **Settings → Actions → Runners → Create new runner** at
   repository, organization, or account scope. Prefer the narrowest scope that
   covers your trusted repositories. Create a distinct runner for each Deployment
   (for example `homelab-1` and `homelab-2`). Copy its UUID and token (not a legacy
   registration token). Account-scoped runners are managed at
   `https://codeberg.org/user/settings/actions/runners`.
2. Copy that runner's `credentials.yaml.example` to `credentials.sops.yaml`
   in the same directory, fill in the UUID/token, and immediately encrypt it
   from the repository root, for example:

   ```sh
   sops --encrypt --in-place kube/apps/forgejo-runners/runner-1/credentials.sops.yaml
   ```

   Add `runner-1/credentials.sops.yaml` to the **parent** `kustomization.yaml`
   resources; repeat for runner 2. Never commit plaintext credentials. Secrets
   are deliberately added in the parent so the overlay does not suffix their
   already distinct names again.
3. Both overlays already set `FORGEJO_INSTANCE_URL=https://codeberg.org/`.
   If retargeting later, use a public HTTPS URL
   reachable without an interactive access challenge. Private endpoints also
   need a narrow egress exception in `networkpolicy.yaml`.
4. Set that overlay's `replicas[].count` to `1`. Enable Actions on the repository
   and use `runs-on: debian-bookworm` in workflows. This label supplies Node on
   Debian, not the full GitHub hosted toolchain.

## Deployment and first job

After preparing credentials, verify the enforcing CNI requirement below, then
run the local validation commands. Review all new files and confirm that each
`credentials.sops.yaml` contains encrypted values before staging anything.
When you approve deployment, commit and publish the reviewed changes to the
Flux GitRepository's tracked branch. Publishing to that branch can deploy
automatically; the commands below only accelerate and check reconciliation:

```sh
flux reconcile kustomization apps -n flux-system --with-source --timeout=15m
kubectl -n forgejo-runners rollout status deployment/forgejo-runner-1 --timeout=5m
kubectl -n forgejo-runners rollout status deployment/forgejo-runner-2 --timeout=5m
kubectl -n forgejo-runners get pods,pvc
```

Check that both runners appear online in Codeberg. In a trusted test repository,
add `.forgejo/workflows/runner-smoke.yaml` and start it manually in Actions:

```yaml
name: Runner smoke test
on:
  workflow_dispatch:
jobs:
  smoke:
    runs-on: debian-bookworm
    steps:
      - run: node --version
```

This checks job execution, not checkout or caching. Follow the runtime validation
below for those. These are future operator steps; no deployment or Codeberg
registration is performed by adding the manifests.

## Identity and configuration changes

The runner reads the token from a Secret file and UUID from a Secret-backed
environment variable. No registration Job, init script, or persistent identity
file is used. Replacing a pod preserves its identity through the Secret. The two
target URLs can be different. To retarget a runner, drain and disable it, revoke
the old identity, replace its credentials and URL, and discard its old cache
before enabling it against the new instance.

Kustomize hashes ConfigMaps, so config changes trigger a rollout. After changing
credentials, bump `dokkae.com/config-revision` on the affected Deployment through
its overlay patch (or in the base to restart both). Schedule rollouts while idle:
running jobs get 60 seconds to finish before cancellation.

## Caching

The built-in Actions cache is enabled at `/cache/actions`, with a separate 10Gi
`longhorn-r1` PVC per runner. Compatible cache actions save dependency/build
archives using workflow-selected keys. No cache Service or shared cache server
is installed. Job containers reach their own runner's cache proxy at
`runner-cache:8088`, mapped to Docker's host gateway. The backend listens on
8089; the proxy adds per-job authentication. Cross-pod ingress remains denied.

Runner 13.2.0 performs automatic garbage collection at startup and after requests
(at most hourly): entries unused for seven days and entries older than thirty
days are removed, along with stale/incomplete uploads and superseded entries.
This is age-based cleanup, **not a disk quota or size-based eviction policy**.
Monitor volume usage; 10Gi can fill before entries expire. Enlarge the cache PVC
or drain the affected runner and recreate its disposable cache PVC when needed.
Do not delete individual cache files while the runner is using its cache database.
Avoid caching secrets, large outputs, or whole workspaces. Disable Actions caching
for both runners with `cache.enabled: false` in `base/config.yaml` if unwanted.

Cache loss only causes cold builds, so these PVCs have one Longhorn replica and
no retention annotation or backup requirement. Removing the app lets Flux prune
them. Caches are not shared: a job assigned to the other runner can have a miss.
Do not reuse one cache across different Forgejo instances or trust boundaries.

Docker images, build layers, and job workspaces use a bounded 20Gi `emptyDir`;
they survive container restarts but are discarded on pod replacement. Actions
cache does not automatically persist Docker/BuildKit caches. Container image
build caching can be designed separately once workflow requirements are known.

## Isolation and requirements

Requires Kubernetes 1.29+ with native sidecars enabled (stable in 1.33). Docker
becomes ready before the runner and stops after it. The Docker API uses only a
pod-local Unix socket. Jobs get no socket, arbitrary bind mounts, or privileged
mode. Pods have no hostPath, host networking, or Kubernetes API credentials.

The Docker sidecar itself is privileged: use these runners only for trusted
workflows. NetworkPolicy is defense in depth, not isolation against a kernel
escape. The policy allows DNS and public HTTP/HTTPS, while blocking cluster,
LAN, tailnet, and link-local destinations. It needs an enforcing CNI; default
Flannel alone does not enforce it. Verify this before activation. Use dedicated
machines/VMs outside this cluster for untrusted public workflows.

## Validation

```sh
kustomize build kube/apps/forgejo-runners >/dev/null
kustomize build kube/apps >/dev/null
git diff --check
```

After an approved deployment, test a job on each runner. Test a compatible cache
action twice on the same runner, then replace that pod and confirm another hit
with the same cache key and unchanged UUID. Temporarily disable the other runner
to make scheduling deterministic. Verify public HTTPS/DNS work and private
network access is denied. No runtime or cluster tests are performed by these
local build commands.

References: [Codeberg self-hosted Actions](https://docs.codeberg.org/ci/actions/),
[registration](https://forgejo.org/docs/latest/admin/actions/registration/),
[cache configuration](https://forgejo.org/docs/latest/admin/actions/configuration/#cache-configuration),
[pinned cache cleanup implementation](https://code.forgejo.org/forgejo/runner/src/tag/v13.2.0/act/artifactcache/caches.go).
