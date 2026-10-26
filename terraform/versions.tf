terraform {
  required_version = ">= 1.5.0"

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = ">= 0.6.0, < 1.0.0"
    }
  }

  # Lokasi state diisi saat init (-backend-config="path=..."), lihat scripts/cluster-up.sh.
  # State disimpan di mesin host runner agar tidak hilang antar job CI.
  backend "local" {}
}
