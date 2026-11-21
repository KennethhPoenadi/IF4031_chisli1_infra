# infra

Konfigurasi infrastruktur dan deployment untuk Sistem Informasi Kebencanaan BNPB (IF4031 Milestone 2): service Go, tiga unit
MongoDB, RabbitMQ, mock, Sensor Pantai, dan observabilitas. Repositori ini mendukung cluster `kind` untuk development dan cluster
K3s dua node untuk demo, beserta platform pendukung, chart Helm, konfigurasi dev dan prod, definisi Argo CD, policy Kyverno, dan
workflow GitHub Actions.

Kode aplikasi, pengujian P1-P5, bukti, dan dokumentasi arsitektur ada di repositori aplikasi (`IF4031_chisli1`): README-nya,
`docs/topologi-arsitektur.md`, dan `docs/bukti/`. Panduan membuat cluster ada di [docs/k3s-cluster.md](docs/k3s-cluster.md).

## Deklarasi topologi

| Node | Jenis | Host fisik | Spesifikasi host | Sumber daya node | Arsitektur |
| --- | --- | --- | --- | --- | --- |
| `chisli-control` (control plane + worker, ingress) | VM WSL2 (Ubuntu 26.04) | Laptop Windows | Intel Core i7-12650H, RAM 16 GB | 8 vCPU / 10 GB (batas WSL2) | amd64 |
| `chisli-worker-1` (worker) | VM Colima (Ubuntu 24.04) | MacBook Air M1 (2020) | Apple M1, RAM 8 GB, SSD 512 GB | 3 vCPU / 4,8 GiB (VM Colima) | arm64 |

Node terhubung lewat Tailscale. Skenario yang mematikan node hanya dikenakan pada `chisli-worker-1`. Penempatan pod dan
keterbatasan topologi: `docs/topologi-arsitektur.md` di repositori aplikasi.

## Deploy

Prasyarat: cluster K3s dua node `Ready` ([docs/k3s-cluster.md](docs/k3s-cluster.md)), self-hosted runner berlabel `k8s-local`
dengan kubeconfig cluster, dan file Secret `~/.xops/prod.env` serta `~/.xops/dev.env` di runner (lihat [Secret, variable, dan environment](#secret-variable-dan-environment)).

**Satu perintah:** jalankan workflow CI di branch `main` (push ke `main` juga memicunya):

```
gh workflow run ci.yml --ref main
```

Workflow memvalidasi cluster, memasang platform (Traefik, metrics-server, Kyverno, KEDA, Argo CD), menerapkan policy, membuat
Secret, dan menerapkan `ApplicationSet`; Argo CD kemudian men-deploy semua service ke namespace
`sistem-informasi-kebencanaan-bnpb`. Dua job terakhir memasang Tester Agent dan observabilitas; keduanya `continue-on-error`
sehingga kegagalannya terlihat di workflow tetapi tidak menggagalkan deploy aplikasi. Urutan yang sama dapat dijalankan manual
dari runner:

```
CLUSTER_PROVIDER=k3s ./scripts/cluster-up.sh           # validasi cluster
./scripts/platform.sh                                   # Traefik, metrics-server, Kyverno, KEDA, Argo CD, namespace
# policy: lihat job `policies` di .github/workflows/ci.yml
ENV_FILE="$HOME/.xops/prod.env" ./scripts/create-secrets.sh prod
./scripts/bootstrap-argocd.sh                           # ApplicationSet; Argo CD mulai sinkronisasi
```

```
./scripts/install-tester-agent.sh                       # Tester Agent dari manifest yang di-pin (menolak digest lain)
./scripts/observability.sh                              # Prometheus, Loki, Tempo, Alloy, Grafana
```

Memeriksa hasil:

```
kubectl get nodes -o wide
kubectl get applications -n argocd
kubectl get pods,hpa,ingress -n sistem-informasi-kebencanaan-bnpb
kubectl get pods -n observability
```

## Struktur

| Path | Isi |
| --- | --- |
| `terraform/` | Cluster kind sebagai resource Terraform: node, label ingress, pemetaan port 80/443, kubeconfig |
| `docs/k3s-cluster.md` | Pembuatan cluster K3s dua node dan koneksi self-hosted runner |
| `platform/` | Values dan versi chart Traefik, metrics-server, Kyverno, dan Argo CD (`versions.env`) |
| `platform/observability/` | Values Prometheus, Loki, Tempo, Alloy, Grafana, dan dashboard sebagai kode (`dashboards/*.json`, dihasilkan `scripts/gen-dashboards.py`) |
| `charts/microservice/` | Satu chart generik: Deployment atau StatefulSet, Service, Ingress, HPA, ConfigMap, NetworkPolicy, PodDisruptionBudget |
| `envs/dev`, `envs/prod` | Values per service dan per environment |
| `envs/<env>/tags/` | Tag image per service. `envs/prod/tags/` ditulis oleh job `release-prod` dan dibaca Argo CD |
| `argocd/` | `ApplicationSet` yang menghasilkan 12 Application (12 workload, hanya environment `prod`) |
| `policies/kyverno/` | Sebelas ClusterPolicy dan satu ClusterRole untuk membaca HPA |
| `policies/tests/` | Tes Kyverno CLI dan manifest pelanggaran untuk uji penolakan di cluster |
| `scripts/` | Script yang dipanggil pipeline, dan dapat dijalankan lokal |
| `tests/k6/` | Skrip uji beban untuk HPA |
| `hpa-evidence/` | Data mentah uji autoscaling |
| `evidence/tester-agent-compat/` | Bukti kompatibilitas Tester Agent (dry-run manifest, skenario, pod per node) dari `scripts/tester-agent-compat.sh` |

## Desain singkat

- **GitOps, pull.** Argo CD di dalam cluster menarik konfigurasi dari repositori ini (`main`) dan menerapkannya dengan `prune` dan `selfHeal`. Self-hosted runner tetap memerlukan akses API untuk bootstrap platform, policy, Secret, dan pengujian M2; sinkronisasi workload berikutnya dilakukan Argo CD.
- **Rilis adalah commit tag.** Workflow aplikasi mengirim `repository_dispatch` berisi `image_tag` ke repo ini (nama event `deploy-dev` masih diterima, begitu juga `deploy-prod`). Job `release-prod` menulis `envs/prod/tags/<service>.yaml` lewat `scripts/set-tags.sh`, lalu commit `[skip ci]`. Tidak ada tahap dev dan tidak ada persetujuan manual. Rilis manual: workflow `Release` dengan input `image_tag`.
- **Satu chart untuk semua workload.** Perbedaan antar service dan environment hanya ada di `envs/`.
- **Hanya `prod` yang di-deploy.** `prod` memakai namespace kontrak M2, `sistem-informasi-kebencanaan-bnpb` (dipetakan oleh `ns_for` di `scripts/env.sh` dan oleh `argocd/applicationset.yaml`). Environment `dev` (namespace `dev`) dinonaktifkan di `ApplicationSet` karena node tidak muat menampung dev dan prod sekaligus. Values `envs/dev/` tetap ada, dan dev dapat diaktifkan lagi dengan menghapus tanda komentar di `argocd/applicationset.yaml`. Namespace `dev` dan Secret-nya tetap dibuat oleh `platform.sh` dan job `secrets`.
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
| `require-role-label` | Label `role` dengan nilai dari daftar kontrak M2 |
| `enforce-resource-class` | Memori requests dan limits sesuai kelas role (Lampiran B) |
| `store-local-storage` | Volume `role=store` di disk lokal node |
| `forbid-privileged` | Pod aplikasi tidak privileged dan tidak memakai jaringan atau PID host |
| `restrict-image-repositories` | Image hanya dari repositori image kelompok di `ghcr.io` |
| `disallow-latest-tag` | Tag harus versi, bukan `latest` atau `<service>-latest` |
| `require-container-security` | `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false` |
| `require-resource-limits` | Limit CPU dan memory pada setiap container |
| `require-health-probes` | Liveness dan readiness probe |
| `require-minimum-replicas` | Replika Deployment, StatefulSet, dan `minReplicas` HPA minimal 1 |
| `require-hpa` | Setiap Deployment harus ditarget oleh sebuah HPA (StatefulSet tidak termasuk) |

`require-hpa` membaca daftar HPA lewat `apiCall`, sehingga Kyverno memerlukan ClusterRole `allow-hpa-read.yaml`. HPA diberi `sync-wave: "-1"` agar Argo CD membuatnya sebelum Deployment. Keberadaan HPA juga dicek di CI oleh `scripts/validate-hpa-coverage.sh`.

## Workflow

Didefinisikan di `.github/workflows/ci.yml` (validate dan platform), `.github/workflows/release.yml` (rilis prod), dan
`.github/workflows/m2-ops.yml` (pengujian M2, lihat [Pengujian M2](#pengujian-m2-workflow-m2-ops)).

| Stage | Job | Fungsi |
| --- | --- | --- |
| `validate` | `validate` | Sintaks script, `terraform validate`, `helm lint`, cakupan HPA, `kubeconform`, `kyverno test` |
| `mirror` | `mirror-images` | Menyalin MongoDB dan RabbitMQ ke repositori image kelompok di `ghcr.io` |
| `cluster` | `cluster` | Membuat cluster `kind` untuk development atau memvalidasi cluster K3s demo |
| `platform` | `platform` | Traefik, metrics-server, Kyverno, KEDA, Argo CD, dan namespace `dev` dan `sistem-informasi-kebencanaan-bnpb` |
| `policies` | `policies` | Menerapkan policy, menunggu Ready, lalu menguji penolakan manifest pelanggaran di cluster |
| `secrets` | `secrets` (matriks `dev`, `prod`) | Secret `registry-credentials` (pull image), `app-secrets`, `rabbitmq-keda`, dan `llm-credentials` (bila `LLM_*` lengkap) per namespace. Gagal bila `~/.xops/<env>.env` tidak ada |
| `bootstrap` | `bootstrap-argocd` | Menerapkan `ApplicationSet` |
| `tester-agent` | `tester-agent` | Memasang Tester Agent dari manifest yang di-pin. `continue-on-error` |
| `observability` | `observability` | Prometheus, Loki, Tempo, Alloy, dan Grafana di namespace `observability`. `continue-on-error`, tidak memblokir deploy |
| `release` | `release-prod` | Menulis tag prod langsung, dipicu oleh workflow aplikasi atau manual |

Push ke `main` menjalankan `validate` sampai `observability`; pull request hanya menjalankan `validate` (di runner GitHub). Workflow `Release` dipicu aplikasi atau manual.

### Pengujian M2 (workflow `m2-ops`)

Job berjalan di self-hosted runner dan menyimpan hasilnya sebagai artifact workflow (30 hari).

| Job | Pemicu | Isi |
| --- | --- | --- |
| `tester-agent-compat` | Push ke `main` yang mengubah `envs/`, `charts/`, `policies/`, atau skrip Tester Agent; atau manual | `scripts/tester-agent-compat.sh`: manifest Tester Agent dapat dipasang tanpa diubah, setiap pod aplikasi berlabel `role` yang sah, tidak ada NetworkPolicy/ResourceQuota/LimitRange yang menghalangi Tester Agent, dan daftar skenario dapat dibaca. Input `practice` ikut menjalankan satu skenario latihan. Hasil di `evidence/tester-agent-compat/` |
| `game-day` | Manual | `scripts/game-day.sh`: menjalankan skenario Tester Agent berurutan (bawaan `kill-store wipe-node clock-skew partition kill-leader schema`) dengan jendela pemulihan per skenario (bawaan 180 detik) tanpa intervensi, opsional sambil menjalankan k6, lalu mengumpulkan bukti P5 kriteria 6-8: checksum Audit API antar skenario (count yang turun berarti ada HazardEvent hilang) dan SLO jalur peringatan dari Prometheus |
| `load-test` | Manual | `scripts/load-test.sh`: k6 dari repositori aplikasi (bawaan `tests/k6/p2-sustained.js`, 10.000 VU, 150 detik) sambil mengubah replika Aggregator menurut `scale_plan` (bawaan `0:3 50:5 100:2`) |
| `p5-priority` | Manual | Job `load-test` dengan skrip tetap `tests/k6/p5-priority.js` selama 45 detik, tanpa perubahan replika |

```
gh workflow run m2-ops.yml -f job=tester-agent-compat -f practice=<nama-skenario>
gh workflow run m2-ops.yml -f job=game-day -f recovery_seconds=180
gh workflow run m2-ops.yml -f job=load-test -f vus=10000 -f duration=150s -f scale_plan="0:3 50:5 100:2"
gh workflow run m2-ops.yml -f job=p5-priority
```

`game-day` dan `load-test` memuat `~/.xops/prod.env` di runner (token Audit dan kredensial client) dan mengambil skrip k6 dari
repositori aplikasi pada ref `app_ref` (bawaan `main`). Skrip yang sama dapat dijalankan langsung dari runner dengan variabel
lingkungan yang sama (`RUN_PRACTICE`, `SCENARIOS`, `RECOVERY_SECONDS`, `K6_SCRIPT`, `VUS`, `DURATION`, `SCALE_PLAN`,
`MAX_ERROR_RATE`, `BASE_URL`, `AUTH_BASE_URL`, `AUDIT_URL`, `AUDIT_TOKEN`, `PROM_URL`, `OUT_DIR`); daftar lengkapnya di komentar
awal tiap skrip. Job yang menyentuh cluster berjalan di self-hosted runner berlabel `k8s-local`. Untuk development, pastikan `docker`, `kubectl`, `helm`, `terraform`, dan `kind` ada di `PATH`. Untuk demo K3s, runner memerlukan `kubectl`, `helm`, akses jaringan ke API Node A, dan kubeconfig yang valid.

## Observabilitas

Stack Grafana: **Prometheus** (metrik), **Tempo** (trace), **Loki** (log), **Alloy** (pengumpul, satu pod per node), dan
**Grafana** (tampilan). Semuanya di namespace `observability`, dipasang oleh job `observability` di workflow CI (atau manual dengan
`scripts/observability.sh`) dengan versi chart yang di-pin di `platform/versions.env`. Skrip aman dijalankan ulang (`helm upgrade --install`).
Aplikasi memakai modul bersama `services/telemetry` (OpenTelemetry).

Penempatan: Prometheus dan Grafana di node ingress (`ingress-ready=true`, yaitu `chisli-control`) agar dashboard tetap hidup saat
node worker dimatikan; Loki dan Tempo di `chisli-worker-1` untuk membagi memori. Penyesuaian untuk node WSL2: node-exporter tanpa
mount root host (`/` di WSL2 bukan mount shared), dan Alloy diberi limit 1 CPU / 512Mi karena node control menjalankan pod paling
banyak.

| Kebutuhan | Di mana melihatnya |
| --- | --- |
| Metrik per service (latensi p50/p95/p99, error rate, throughput) | Grafana → dashboard **BNPB / Service (RED)** |
| Alur data dan jalur peringatan (latensi notifikasi terhadap 5 detik, ingest, penyimpanan tersebar) | **BNPB / Alur data dan jalur peringatan** |
| Kesehatan node dan sebaran pod (dipakai saat game day) | **BNPB / Cluster dan node** |
| Jejak satu permintaan lintas service dengan durasi tiap langkah | Grafana → Explore → **Tempo** |
| Log terstruktur ber-correlation ID | Grafana → Explore → **Loki** |

Membuka Grafana: `http://grafana.localtest.me`, pengguna `admin`. Dari peramban Windows (node control berupa WSL2), hostPort
Traefik tidak diteruskan ke Windows: jalankan `kubectl -n traefik port-forward svc/traefik 8088:80` lalu buka
`http://grafana.localtest.me:8088`. Kata sandi dibuat acak saat pemasangan pertama dan disimpan di
Secret `grafana-admin` (bukan di Git):

```
kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
```

Mengikuti satu permintaan:
- **Dari correlation ID:** Explore → Tempo → TraceQL `{ span.correlation.id = "<id>" }`, atau Explore → Loki `{app="aggregator"} | correlation_id = "<id>"`.
- **Dari log ke trace:** log aplikasi memuat `trace_id`; Loki menampilkan tautan **Buka trace**.
- **Dari trace ke log:** buka sebuah span lalu pilih **Logs for this span**.
- Di jalur data, trace berlanjut lewat RabbitMQ: span `publish` di aggregator tersambung ke span `process` di notifier dan dashboard-updater.

Cara kerjanya di sisi service: setiap pod aplikasi mengekspos `/metrics` di port 9102 (terpisah dari port API, jadi tidak terkena
autentikasi dan NetworkPolicy milik API) dan mengirim trace OTLP ke Alloy. Chart menambahkan anotasi `prometheus.io/*`, variabel
`OTEL_*`, dan aturan NetworkPolicy yang diperlukan (Prometheus masuk, OTLP keluar). Konfigurasinya di blok `telemetry` pada
`charts/microservice/values.yaml`. Saat load test besar, turunkan sampling trace agar kolektor tidak kewalahan:
`telemetry.traceSampleRatio: "0.1"`.

Aturan Prometheus (`prometheus-values.yaml`) mencakup SLO jalur peringatan (`slo:alert_path_within_5s:ratio_rate5m`; label bucket
dicocokkan dengan `le=~"5(\.0)?"` karena Prometheus 3 menormalisasinya menjadi `5.0`) dan peringatan
untuk p95 latensi > 5 detik, unit penyimpanan mati, error rate > 1%, dan target metrik tidak merespons.

Mengubah dashboard: ubah `scripts/gen-dashboards.py`, jalankan `python3 scripts/gen-dashboards.py`, lalu commit JSON hasilnya.
`validate.sh` gagal bila JSON tidak sesuai dengan skripnya.

Batasan yang disadari:
- **MongoDB dan RabbitMQ tidak punya metrik.** Keduanya image pihak ketiga tanpa modul telemetry, jadi tidak diekspor. Status unit penyimpanan
  tetap terlihat lewat metrik aggregator (`store_unit_up`). Menambah exporter pihak ketiga adalah langkah terpisah.
- **Data tidak persisten.** Prometheus, Loki, dan Tempo memakai penyimpanan sementara dan menyimpan 24 jam; data hilang bila pod dipindah.
- **Alertmanager dimatikan.** Aturan tetap dievaluasi dan terlihat, tetapi tidak ada notifikasi keluar.
- **Anggaran memori sekitar 1,1 GiB (requests) dan 3,1 GiB (limits)** di luar aplikasi, ditambah Alloy dan node-exporter di setiap node.

## Secret, variable, dan environment

Diisi di Settings → Secrets and variables → Actions. Nilainya tidak disimpan di Git.

| Nama | Jenis | Fungsi |
| --- | --- | --- |
| `GITOPS_TOKEN` | Secret | Fine-grained PAT (Contents read/write pada repo ini) untuk push commit tag dari `release-prod` |
| `APP_IMAGE_NAME` | Variable | Nama image di `ghcr.io/<owner>/`. Harus sama dengan yang dibangun repositori aplikasi |
| `APP_REPOSITORY` | Variable | Repositori aplikasi (`owner/repo`), sumber skrip k6 untuk `m2-ops` |
| `APP_READ_TOKEN` | Secret (opsional) | PAT baca repositori aplikasi bila repositori itu private. Kosong berarti memakai `github.token` |
| `LOAD_TEST_BASE_URL`, `LOAD_TEST_AUTH_URL` | Variable | Alamat API client dan auth-service yang dituju k6 (`load-test`) |
| `AUDIT_URL`, `PROM_URL` | Variable | Alamat Audit API dan Prometheus yang diperiksa `game-day` |

Tidak ada GitHub Environment yang perlu dibuat: rilis ke prod berjalan tanpa gerbang persetujuan.

Secret aplikasi (daftar di `scripts/secret-keys.txt`) dan kredensial pull image **tidak** disimpan di GitHub. Simpan di mesin self-hosted runner, di luar repo:

```
~/.xops/dev.env
~/.xops/prod.env
```

Kedua file wajib ada karena job `secrets` berjalan untuk `dev` dan `prod`, meskipun hanya `prod` yang di-deploy. Isinya sama bentuknya
(nilai boleh beda): satu baris `KEY=value` untuk setiap kunci di `secret-keys.txt` (19 kunci), ditambah `REGISTRY_USER=<username>` dan
`REGISTRY_PASS=<classic PAT, hanya scope read:packages>`. Opsional: `LLM_BASE_URL`, `LLM_MODEL`, `LLM_API_KEY` untuk
situation-analyst.

Kunci bertanda `?` di `secret-keys.txt` boleh kosong tanpa menggagalkan `create-secrets.sh`, tetapi wajib diisi di `prod.env` untuk
demo: `AUDIT_TOKEN` dan `DASHBOARD_TOKEN` (Audit API dan dashboard analitik) serta `SATELLITE_TOKEN` (token kelompok Feed Satelit;
tanpa token ini `satellite-ingestor` gagal start). Isi `SATELLITE_TOKEN` hanya di `prod.env`: Feed Satelit menutup koneksi lain
yang memakai token yang sama (`429 too_many_connections`). Setelah mengubah file ini, jalankan ulang job `secrets` (atau
`create-secrets.sh prod`) lalu `kubectl rollout restart deploy/<service> -n sistem-informasi-kebencanaan-bnpb`, karena Secret
dibaca saat pod start.

File di-`source` oleh shell, jadi nilai dengan spasi atau karakter khusus perlu diberi kutip. Jalankan `chmod 600` pada keduanya.

## Registry (GHCR)

Semua image berada di satu repositori, `ghcr.io/<owner>/<APP_IMAGE_NAME>` (nama selalu lowercase, dihitung `scripts/image-repo.sh`), dengan tag `<service>-<sha8>`.

- **Push** dilakukan repositori aplikasi dengan `GITHUB_TOKEN` bawaan, tanpa kredensial yang disimpan.
- **Pull** oleh cluster memakai Secret `registry-credentials` yang dibuat dari `REGISTRY_USER` dan `REGISTRY_PASS` di file env runner. Token ini hanya boleh punya scope `read:packages`. Package dibiarkan private.
- **Mirror MongoDB dan RabbitMQ** menulis ke package yang sama dari repositori ini. Karena package dimiliki repositori aplikasi (yang membuatnya pertama), beri repositori `infra` akses **Write** sekali lewat Package settings → Manage Actions access. Sebelum itu job `mirror-images` gagal, dan itu ditoleransi.

## Menjalankan lokal

Prasyarat development: Docker (misalnya Colima), `terraform`, `kubectl`, `helm`, dan `kyverno` CLI. Semua script memuat `scripts/env.sh`. `KUBECONFIG` dapat diberikan dari environment dan memakai `~/.kube/xops-config` bila tidak ditentukan.

```
./scripts/validate.sh                    # lint, validasi HPA, kubeconform, kyverno test
CLUSTER_PROVIDER=kind ./scripts/cluster-up.sh  # terraform apply, membuat cluster kind
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

Untuk cluster demo multi-node, ikuti [panduan K3s](docs/k3s-cluster.md). Setelah kubeconfig tersedia pada runner, validasi dengan:

```
CLUSTER_PROVIDER=k3s ./scripts/cluster-up.sh
```

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
