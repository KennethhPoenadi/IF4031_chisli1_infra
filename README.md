# infra

Konfigurasi infrastruktur dan deployment untuk platform agregasi informasi kebencanaan (tujuh service Go, MongoDB, RabbitMQ). Repositori ini berisi cluster Kubernetes (kind) yang ditulis sebagai Terraform, platform pendukungnya, chart Helm, konfigurasi dev dan prod, definisi Argo CD, policy Kyverno, dan pipeline yang menjalankan semuanya.

Kode aplikasi dan pipeline build image ada di repositori aplikasi. Dokumentasi lengkap (arsitektur, bukti, keterbatasan) ada di repositori `docs`.

## Struktur

| Path | Isi |
| --- | --- |
| `terraform/` | Cluster kind sebagai resource Terraform: node, label ingress, pemetaan port 80/443, kubeconfig |
| `platform/` | Values dan versi chart Traefik, metrics-server, Kyverno, dan Argo CD (`versions.env`) |
| `charts/microservice/` | Satu chart generik: Deployment atau StatefulSet, Service, Ingress, HPA, ConfigMap, NetworkPolicy, PodDisruptionBudget |
| `envs/dev`, `envs/prod` | Values per service dan per environment |
| `envs/<env>/tags/` | Tag image per service, ditulis oleh job `release-*` dan dibaca Argo CD |
| `argocd/` | `ApplicationSet` yang menghasilkan 18 Application (9 workload × 2 environment) |
| `policies/kyverno/` | Tujuh ClusterPolicy dan satu ClusterRole untuk membaca HPA |
| `policies/tests/` | Tes Kyverno CLI dan manifest pelanggaran untuk uji penolakan di cluster |
| `scripts/` | Script yang dipanggil pipeline, dan dapat dijalankan lokal |
| `tests/k6/` | Skrip uji beban untuk HPA |
| `hpa-evidence/` | Data mentah uji autoscaling |

## Desain singkat

- **GitOps, pull.** Pipeline hanya menulis ke Git. Argo CD di dalam cluster menarik konfigurasi dari repositori ini (`main`) dan menerapkannya dengan `prune` dan `selfHeal`, sehingga runner CI tidak memerlukan akses ke API server.
- **Rilis adalah commit tag.** Pipeline aplikasi memicu pipeline repo ini dengan `IMAGE_TAG`. Job `release-dev` menulis `envs/dev/tags/<service>.yaml` lalu commit `[skip ci]`. Promosi ke prod dilakukan job manual `release-prod`, yang menyalin tag dari dev dan hanya berjalan sukses untuk akun `PROD_APPROVER`.
- **Satu chart untuk semua workload.** Perbedaan antar service dan environment hanya ada di `envs/`.
- **Dua environment dalam satu cluster.** Namespace `dev` dan `prod`.
- **Kyverno `Enforce`.** Pelanggaran ditolak saat admission, meskipun lolos CI.

### Policy Kyverno

| Policy | Menegakkan |
| --- | --- |
| `restrict-image-repositories` | Image hanya dari repositori Docker Hub kelompok |
| `disallow-latest-tag` | Tag harus versi, bukan `latest` atau `<service>-latest` |
| `require-container-security` | `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false` |
| `require-resource-limits` | Limit CPU dan memory pada setiap container |
| `require-health-probes` | Liveness dan readiness probe |
| `require-minimum-replicas` | Replika Deployment, StatefulSet, dan `minReplicas` HPA minimal 1 |
| `require-hpa` | Setiap Deployment harus ditarget oleh sebuah HPA (StatefulSet tidak termasuk) |

`require-hpa` membaca daftar HPA lewat `apiCall`, sehingga Kyverno memerlukan ClusterRole `allow-hpa-read.yaml`. HPA diberi `sync-wave: "-1"` agar Argo CD membuatnya sebelum Deployment. Keberadaan HPA juga dicek di CI oleh `scripts/validate-hpa-coverage.sh`.

## Pipeline

| Stage | Job | Fungsi |
| --- | --- | --- |
| `validate` | `validate` | Sintaks script, `terraform validate`, `helm lint`, cakupan HPA, `kubeconform`, `kyverno test` |
| `mirror` | `mirror-images` | Menyalin MongoDB dan RabbitMQ ke repositori Docker Hub kelompok |
| `cluster` | `cluster` | `terraform apply` untuk cluster kind |
| `platform` | `platform` | Traefik, metrics-server, Kyverno, Argo CD, dan namespace `dev` dan `prod` |
| `policies` | `policies` | Menerapkan policy, menunggu Ready, lalu menguji penolakan manifest pelanggaran di cluster |
| `secrets` | `secrets-dev`, `secrets-prod` | Secret `gitlab-registry` dan `app-secrets` per namespace |
| `bootstrap` | `bootstrap-argocd` | Menerapkan `ApplicationSet` |
| `release` | `release-dev` | Menulis tag dev, dipicu oleh pipeline aplikasi |
| `promote` | `release-prod` | Menyalin tag dev ke prod, manual |

Push ke `main` menjalankan stage `validate` sampai `bootstrap`. Pipeline yang dipicu aplikasi hanya menjalankan `release-dev` dan `release-prod`. Job yang menyentuh cluster berjalan di runner lokal bertag `k8s-local`, karena API server kind hanya terbuka di `127.0.0.1`.

## Variabel CI/CD

Diisi di Settings → CI/CD → Variables project ini. Nilainya tidak disimpan di Git.

| Variabel | Fungsi |
| --- | --- |
| `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` | Mirror image database dan `imagePullSecret` di cluster |
| `APP_IMAGE_NAME` | Nama repositori image aplikasi di Docker Hub |
| `GITOPS_TOKEN` | Push commit tag dari job `release-*` |
| `PROD_APPROVER` | Username GitLab penyetuju promosi ke prod (scope environment `prod`) |
| Daftar di `scripts/secret-keys.txt` | Isi Secret `app-secrets` |
| `GITOPS_RUNNER_TAG` | Opsional, tag runner untuk job `release-*` |

## Menjalankan lokal

Prasyarat: Docker (misalnya Colima), `terraform`, `kubectl`, `helm`, dan `kyverno` CLI. Semua script memuat `scripts/env.sh`, yang mengarahkan `KUBECONFIG` ke `~/.kube/xops-config`.

```
./scripts/validate.sh                    # lint, validasi HPA, kubeconform, kyverno test
./scripts/cluster-up.sh                  # terraform apply, membuat cluster kind
./scripts/platform.sh                    # Traefik, metrics-server, Kyverno, Argo CD

export DOCKERHUB_USERNAME=<username> DOCKERHUB_TOKEN=<token> APP_IMAGE_NAME=<nama-repo-image>
# create-secrets.sh juga membaca setiap variabel di secret-keys.txt; bisa dimuat lewat ENV_FILE=<file>
./scripts/create-secrets.sh dev          # ulangi untuk prod
./scripts/bootstrap-argocd.sh            # ApplicationSet, lalu Argo CD mulai sinkronisasi
```

Cek hasilnya:

```
export KUBECONFIG=~/.kube/xops-config
kubectl get applications -n argocd
kubectl get pods,hpa,ingress -n dev
curl http://api.dev.localtest.me/health
```

Aplikasi dapat diakses lewat Traefik pada `api.<env>.localtest.me` dan `auth.<env>.localtest.me`, dengan `<env>` berupa `dev` atau `prod`.

Menghapus cluster:

```
./scripts/cluster-down.sh
```

`scripts/cluster-up-kind.sh` adalah jalur cadangan yang membuat cluster langsung dengan CLI kind, bila Terraform tidak dapat dipakai.

### Uji autoscaling

```
export CLIENT_ID=<AUTH_CLIENT_MEDIA_ID> CLIENT_SECRET=<AUTH_CLIENT_MEDIA_SECRET>
./scripts/hpa-demo.sh dev
```

Script menjalankan k6 ke `client-facing-api` dan menyimpan keadaan HPA sebelum, selama, dan sesudah beban ke `hpa-evidence/`. Butuh `k6` terpasang.

### Uji policy Kyverno

```
kyverno test policies/tests
export IMAGE_REPO=<username>/<nama-repo-image>
./scripts/test-kyverno-admission.sh      # sembilan manifest pelanggaran harus ditolak
```
