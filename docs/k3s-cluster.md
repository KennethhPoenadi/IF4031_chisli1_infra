# Cluster K3s

Cluster demo terdiri dari dua node Linux dengan kernel terpisah, masing-masing di host fisik berbeda:

| Node | Peran | Penempatan aktual |
| --- | --- | --- |
| `chisli-control` | control-plane sekaligus worker, ingress (`ingress-ready=true`) | VM WSL2 Ubuntu 26.04 di laptop Windows (Intel Core i7-12650H, RAM 16 GB); node 8 vCPU / 10 GB, amd64, Tailscale 100.66.57.46 |
| `chisli-worker-1` | worker non-control-plane | VM Colima Ubuntu 24.04 di MacBook Air M1 2020 (RAM 8 GB, SSD 512 GB); node 3 vCPU / 4,8 GiB, arm64, Tailscale 100.109.151.22 |

Dua VM pada satu host fisik juga memenuhi syarat kernel terpisah; dua host berbeda seperti di atas memenuhi bonus host fisik berbeda.

## Prasyarat jaringan

Kedua node harus saling menjangkau pada alamat yang stabil. Cluster demo memakai **Tailscale** (WireGuard), karena node berada di
jaringan berbeda dan WSL2 berjalan dalam mode NAT: alamat Tailscale dipakai sebagai `K3S_NODE_IP` dan alamat API server.
Bila kedua node berada di satu LAN, IP LAN statis juga dapat dipakai.

- Kedua node memiliki hostname dan alamat (Tailscale atau LAN) yang unik serta stabil.
- Runner dapat mengakses Node A pada TCP `6443`.
- Antar-node mengizinkan TCP `6443`, UDP `8472` (flannel VXLAN), dan TCP `10250`.
- UDP `8472` tidak dibuka ke internet.
- Bila node berupa VM pada LAN, gunakan bridged networking atau external virtual switch.

Catatan WSL2: hostPort Traefik (80/443) tidak diteruskan ke Windows dalam mode NAT. Untuk membuka dashboard dari peramban Windows,
jalankan `kubectl -n traefik port-forward svc/traefik 8088:80` dan pakai port `:8088`.

## 1. Memasang Node A

Jalankan pada Linux Node A dari checkout repositori infra:

```bash
sudo env \
  K3S_NODE_IP=192.168.1.20 \
  K3S_NODE_NAME=chisli-control \
  ./scripts/up.sh
```

Ganti IP dengan alamat aktual Node A (Tailscale atau LAN). Script memasang K3s server, menonaktifkan komponen bawaan yang akan dipasang ulang oleh platform, dan memberi label `ingress-ready=true`.

Periksa hasil dan baca token join tanpa menyalinnya ke log:

```bash
sudo k3s kubectl get nodes -o wide
sudo cat /var/lib/rancher/k3s/server/node-token
```

## 2. Menggabungkan Node B

Jalankan pada Linux Node B:

```bash
sudo env \
  K3S_SERVER_URL=https://192.168.1.20:6443 \
  K3S_NODE_IP=192.168.1.21 \
  K3S_NODE_NAME=chisli-worker-1 \
  ./scripts/node-join.sh
```

Script meminta token secara interaktif tanpa menampilkannya. Jangan menyimpan token di repository atau menaruhnya langsung pada command history.

Verifikasi dari Node A:

```bash
sudo k3s kubectl get nodes -o wide
```

Kedua node harus berstatus `Ready` sebelum melanjutkan.

## 3. Memberikan akses kepada runner

Kubeconfig server berada di `/etc/rancher/k3s/k3s.yaml`. Pada Node A, buat salinan sementara yang hanya dapat dibaca oleh pengguna SSH:

```bash
sudo install -m 600 -o "$USER" -g "$(id -gn)" \
  /etc/rancher/k3s/k3s.yaml "$HOME/xops-config"
```

Pada runner, ambil file tersebut, ubah alamat API menjadi IP LAN Node A, lalu hapus salinan pada Node A:

```bash
mkdir -p "$HOME/.kube"
scp user@192.168.1.20:~/xops-config "$HOME/.kube/xops-config"
ssh user@192.168.1.20 'rm -f "$HOME/xops-config"'
perl -pi -e 's#https://127\.0\.0\.1:6443#https://192.168.1.20:6443#' \
  "$HOME/.kube/xops-config"
```

Ganti `user` dan IP dengan nilai aktual. Batasi permission dan uji akses:

```bash
chmod 600 "$HOME/.kube/xops-config"
KUBECONFIG="$HOME/.kube/xops-config" kubectl get nodes -o wide
```

Kubeconfig memberikan hak administratif ke cluster. Jangan commit, unggah sebagai artifact, atau tampilkan isinya di log workflow.

## 4. Mengaktifkan mode K3s di GitHub Actions

Buat repository variable pada repo infra:

```text
Settings -> Secrets and variables -> Actions -> Variables
CLUSTER_PROVIDER=k3s
```

Job `cluster` kemudian hanya memvalidasi cluster yang sudah ada. Ia tidak memasang K3s, membuat VM, atau menghapus node.

Validasi yang sama dapat dijalankan pada runner:

```bash
CLUSTER_PROVIDER=k3s ./scripts/cluster-up.sh
```

Script menolak cluster bila node kurang dari dua, ada node yang tidak `Ready`, topologi tidak mempunyai control-plane dan worker terpisah, label ingress tidak ada, atau cluster terdeteksi memakai `kind`/`k3d`.

## 5. Deploy platform

Setelah validasi cluster berhasil, pipeline melanjutkan pemasangan platform, policy, Secret, dan Argo CD. Untuk menjalankannya manual dari runner:

```bash
./scripts/platform.sh
ENV_FILE="$HOME/.xops/prod.env" ./scripts/create-secrets.sh prod
./scripts/bootstrap-argocd.sh
```

Periksa keadaan akhir:

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get applications -n argocd
kubectl get pods,hpa,ingress -n sistem-informasi-kebencanaan-bnpb
```

## Batas otomatisasi

`scripts/cluster-down.sh` hanya ditujukan untuk cluster development `kind`. Cluster K3s dihentikan atau dihapus langsung pada masing-masing VM dengan prosedur uninstall K3s, dan tidak dilakukan oleh pipeline agar node demo tidak terhapus akibat sebuah job CI.

Pemeriksaan otomatis tidak dapat membuktikan bahwa dua VM benar-benar memakai kernel atau host fisik yang berbeda. Bukti topologi tetap dikumpulkan dari konfigurasi VM/host dan output setiap node saat demo.
