# infra

Konfigurasi infrastruktur dan deployment untuk platform agregasi informasi kebencanaan (tujuh service Go, MongoDB, RabbitMQ). Repositori ini berisi cluster Kubernetes (kind) yang ditulis sebagai Terraform, platform pendukungnya, chart Helm, konfigurasi dev dan prod, definisi Argo CD, policy Kyverno, dan workflow GitHub Actions yang menjalankan semuanya.

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
- **Rilis adalah commit tag.** Workflow aplikasi mengirim `repository_dispatch` (`deploy-dev`) berisi `image_tag` ke repo ini. Job `release-dev` menulis `envs/dev/tags/<service>.yaml` lalu commit `[skip ci]`. Promosi ke prod dilakukan manual lewat workflow `Release` (`target: prod`), yang menyalin tag dari dev, menunggu persetujuan reviewer environment `prod-release`, dan hanya berjalan sukses untuk akun `PROD_APPROVER`.
- **Satu chart untuk semua workload.** Perbedaan antar service dan environment hanya ada di `envs/`.
- **Dua environment.** `dev` memakai namespace `dev`. `prod` memakai namespace kontrak M2, `sistem-informasi-kebencanaan-bnpb` (dipetakan oleh `ns_for` di `scripts/env.sh` dan oleh `argocd/applicationset.yaml`). Untuk demo, hanya environment `prod` yang perlu berjalan.
- **Kyverno `Enforce`.** Pelanggaran ditolak saat admission, meskipun lolos CI.

### Kontrak Milestone 2

| Aturan | Ditegakkan oleh |
| --- | --- |
| Setiap pod berlabel `role` (aggregator, store, broker, consumer, api, mock, sensor, other) | Chart (`role` wajib di `envs/`), policy `require-role-label` |
| Memori requests dan limits mengikuti kelas role (Lampiran B). CPU bebas | Chart (`resourceClasses`), policy `enforce-resource-class` |
| Data `role=store` di disk lokal node, bukan storage jaringan | Policy `store-local-storage` |
| Pod aplikasi tidak privileged dan tidak memakai jaringan atau PID host | Policy `forbid-privileged` |
| Aggregator minimal 3 instance di node berbeda | `envs/*/aggregator.yaml` (HPA 3 sampai 5, `DoNotSchedule`) |
| Tester Agent tidak dihalangi | Policy hanya mencakup namespace aplikasi. Mock menerima trafik dari namespace `tester-agent` |

`scripts/contract-check.py` (dipanggil `scripts/validate.sh`) me-render semua service dan memeriksa aturan di atas. `scripts/install-tester-agent.sh` memasang Tester Agent dari manifest yang di-pin dan menolak bila digest image berbeda. Namespace aplikasi harus ada lebih dulu, karena manifest Tester Agent membuat Role di dalamnya (`scripts/platform.sh` membuatnya).

### Policy Kyverno

| Policy | Menegakkan |
| --- | --- |
| `restrict-image-repositories` | Image hanya dari repositori image kelompok di `ghcr.io` |
| `disallow-latest-tag` | Tag harus versi, bukan `latest` atau `<service>-latest` |
| `require-container-security` | `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false` |
| `require-resource-limits` | Limit CPU dan memory pada setiap container |
| `require-health-probes` | Liveness dan readiness probe |
| `require-minimum-replicas` | Replika Deployment, StatefulSet, dan `minReplicas` HPA minimal 1 |
| `require-hpa` | Setiap Deployment harus ditarget oleh sebuah HPA (StatefulSet tidak termasuk) |

`require-hpa` membaca daftar HPA lewat `apiCall`, sehingga Kyverno memerlukan ClusterRole `allow-hpa-read.yaml`. HPA diberi `sync-wave: "-1"` agar Argo CD membuatnya sebelum Deployment. Keberadaan HPA juga dicek di CI oleh `scripts/validate-hpa-coverage.sh`.

## Workflow

Didefinisikan di `.github/workflows/ci.yml` (validate dan platform) dan `.github/workflows/release.yml` (rilis dev dan prod).

| Stage | Job | Fungsi |
| --- | --- | --- |
| `validate` | `validate` | Sintaks script, `terraform validate`, `helm lint`, cakupan HPA, `kubeconform`, `kyverno test` |
| `mirror` | `mirror-images` | Menyalin MongoDB dan RabbitMQ ke repositori image kelompok di `ghcr.io` |
| `cluster` | `cluster` | `terraform apply` untuk cluster kind |
| `platform` | `platform` | Traefik, metrics-server, Kyverno, Argo CD, dan namespace `dev` dan `prod` |
| `policies` | `policies` | Menerapkan policy, menunggu Ready, lalu menguji penolakan manifest pelanggaran di cluster |
| `secrets` | `secrets` (matriks `dev`, `prod`) | Secret `registry-credentials` (pull image) dan `app-secrets` per namespace |
| `bootstrap` | `bootstrap-argocd` | Menerapkan `ApplicationSet` |
| `release` | `release-dev` | Menulis tag dev, dipicu oleh workflow aplikasi |
| `promote` | `release-prod` | Menyalin tag dev ke prod, manual |

Push ke `main` menjalankan `validate` sampai `bootstrap`; pull request hanya menjalankan `validate` (di runner GitHub). Workflow `Release` dipicu aplikasi atau manual. Job yang menyentuh cluster berjalan di self-hosted runner berlabel `k8s-local`, karena API server kind hanya terbuka di `127.0.0.1`. Pastikan `docker`, `kubectl`, `helm`, `terraform`, dan `kind` ada di `PATH` service runner (file `.path` di folder runner).

## Secret, variable, dan environment

Diisi di Settings → Secrets and variables → Actions. Nilainya tidak disimpan di Git.

| Nama | Jenis | Fungsi |
| --- | --- | --- |
| `GITOPS_TOKEN` | Secret | Fine-grained PAT (Contents read/write pada repo ini) untuk push commit tag dari `release-*` |
| `APP_IMAGE_NAME` | Variable | Nama image di `ghcr.io/<owner>/`. Harus sama dengan yang dibangun repositori aplikasi |
| `PROD_APPROVER` | Variable | Username GitHub penyetuju promosi ke prod |

Environment (Settings → Environments): hanya `prod-release` yang perlu dibuat, dengan required reviewers sebagai gerbang promosi. Environment `dev` dibuat otomatis oleh GitHub saat `release-dev` pertama kali jalan.

Secret aplikasi (daftar di `scripts/secret-keys.txt`) dan kredensial pull image **tidak** disimpan di GitHub. Simpan di mesin self-hosted runner, di luar repo:

```
~/.xops/dev.env
~/.xops/prod.env
```

Isi kedua file sama bentuknya (nilai boleh beda): 15 baris `KEY=value` dari `secret-keys.txt`, ditambah `REGISTRY_USER=<username>` dan `REGISTRY_PASS=<classic PAT, hanya scope read:packages>`.

File di-`source` oleh shell, jadi nilai dengan spasi atau karakter khusus perlu diberi kutip. Jalankan `chmod 600` pada keduanya.

## Registry (GHCR)

Semua image berada di satu repositori, `ghcr.io/<owner>/<APP_IMAGE_NAME>` (nama selalu lowercase, dihitung `scripts/image-repo.sh`), dengan tag `<service>-<sha8>`.

- **Push** dilakukan repositori aplikasi dengan `GITHUB_TOKEN` bawaan, tanpa kredensial yang disimpan.
- **Pull** oleh cluster memakai Secret `registry-credentials` yang dibuat dari `REGISTRY_USER` dan `REGISTRY_PASS` di file env runner. Token ini hanya boleh punya scope `read:packages`. Package dibiarkan private.
- **Mirror MongoDB dan RabbitMQ** menulis ke package yang sama dari repositori ini. Karena package dimiliki repositori aplikasi (yang membuatnya pertama), beri repositori `infra` akses **Write** sekali lewat Package settings → Manage Actions access. Sebelum itu job `mirror-images` gagal, dan itu ditoleransi.

## Menjalankan lokal

Prasyarat: Docker (misalnya Colima), `terraform`, `kubectl`, `helm`, dan `kyverno` CLI. Semua script memuat `scripts/env.sh`, yang mengarahkan `KUBECONFIG` ke `~/.kube/xops-config`.

```
./scripts/validate.sh                    # lint, validasi HPA, kubeconform, kyverno test
./scripts/cluster-up.sh                  # terraform apply, membuat cluster kind
./scripts/platform.sh                    # Traefik, metrics-server, Kyverno, Argo CD

export REGISTRY_OWNER=<owner-github> APP_IMAGE_NAME=<nama-image>
export REGISTRY_USER=<username> REGISTRY_PASS=<PAT read:packages>
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
export IMAGE_REPO="$(REGISTRY_OWNER=<owner-github> APP_IMAGE_NAME=<nama-image> ./scripts/image-repo.sh)"
./scripts/test-kyverno-admission.sh      # sembilan manifest pelanggaran harus ditolak
```
