#!/usr/bin/env python3
"""Memeriksa manifest hasil render terhadap kontrak Milestone 2.

Tabel kelas sumber daya dan daftar role di bawah ini sengaja ditulis ulang di sini (bukan dibaca dari
chart), agar perubahan tak sengaja pada chart tidak lolos diam-diam.

Pemakaian: scripts/contract-check.py   (dipanggil oleh scripts/validate.sh)
Butuh: helm dan PyYAML.
"""
import glob
import os
import subprocess
import sys

try:
    import yaml
except ImportError:
    sys.exit("ERROR: PyYAML tidak terpasang (pip install pyyaml)")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_NAMESPACE = "sistem-informasi-kebencanaan-bnpb"
TESTER_NAMESPACE = "tester-agent"
ROLES = {"aggregator", "store", "broker", "consumer", "api", "mock", "sensor", "other"}
# role -> (memory requests, memory limits), Lampiran B
CLASSES = {
    "aggregator": ("256Mi", "512Mi"),
    "store": ("512Mi", "1Gi"),
    "broker": ("512Mi", "1Gi"),
    "consumer": ("128Mi", "256Mi"),
    "api": ("128Mi", "256Mi"),
    "mock": ("64Mi", "128Mi"),
    "sensor": ("128Mi", "256Mi"),
    "other": ("128Mi", "256Mi"),
}
LOCAL_STORAGE_CLASSES = {"", "local-path", "standard"}
NETWORK_VOLUME_KEYS = {"nfs", "csi", "cephfs", "glusterfs", "iscsi", "rbd", "awsElasticBlockStore",
                       "azureDisk", "azureFile", "gcePersistentDisk"}

errors = []
checked = 0


def fail(where, msg):
    errors.append(f"{where}: {msg}")


def render(env, svc):
    cmd = ["helm", "template", svc, "charts/microservice", "-f", f"envs/{env}/{svc}.yaml"]
    tags = f"envs/{env}/tags/{svc}.yaml"
    if os.path.exists(os.path.join(ROOT, tags)):
        cmd += ["-f", tags]
    cmd += ["--set", "image.repository=validate/app", "--set", f"image.tag={svc}-validate"]
    out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if out.returncode != 0:
        fail(f"{env}/{svc}", f"helm template gagal: {out.stderr.strip().splitlines()[-1]}")
        return []
    return [d for d in yaml.safe_load_all(out.stdout) if d]


def check_workload(env, svc, docs):
    where = f"{env}/{svc}"
    workloads = [d for d in docs if d["kind"] in ("Deployment", "StatefulSet")]
    if len(workloads) != 1:
        fail(where, f"harus tepat satu Deployment atau StatefulSet, ditemukan {len(workloads)}")
        return
    w = workloads[0]
    tpl = w["spec"]["template"]
    pod_labels = tpl["metadata"].get("labels", {})
    role = pod_labels.get("role")

    if role not in ROLES:
        fail(where, f"label role pod '{role}' tidak sah")
        return
    if w["metadata"].get("labels", {}).get("role") != role:
        fail(where, "label role pada workload berbeda dengan label role pada pod")

    # Lampiran B
    for c in tpl["spec"]["containers"]:
        res = c.get("resources", {})
        want_req, want_lim = CLASSES[role]
        got_req = res.get("requests", {}).get("memory")
        got_lim = res.get("limits", {}).get("memory")
        if (got_req, got_lim) != (want_req, want_lim):
            fail(where, f"role={role} butuh memori {want_req}/{want_lim}, dapat {got_req}/{got_lim}")

    for c in tpl["spec"]["containers"]:
        image = c["image"]
        if image.endswith(":latest") or ":" not in image.rsplit("/", 1)[-1]:
            fail(where, f"image '{image}' tidak bertag versi")

    spec = tpl["spec"]
    if role == "aggregator":
        hpas = [d for d in docs if d["kind"] == "HorizontalPodAutoscaler"]
        replicas = hpas[0]["spec"]["minReplicas"] if hpas else w["spec"].get("replicas", 1)
        if replicas < 3:
            fail(where, f"aggregator wajib minimal 3 instance, dapat {replicas}")
        spread = spec.get("topologySpreadConstraints") or []
        hard_spread = any(t.get("whenUnsatisfiable") == "DoNotSchedule" and
                          t.get("topologyKey") == "kubernetes.io/hostname" for t in spread)
        hard_affinity = "requiredDuringSchedulingIgnoredDuringExecution" in \
            (spec.get("affinity", {}).get("podAntiAffinity", {}))
        if not (hard_spread or hard_affinity):
            fail(where, "aggregator wajib tersebar di node berbeda (DoNotSchedule atau anti-affinity required)")

    if role == "store":
        for v in spec.get("volumes") or []:
            bad = NETWORK_VOLUME_KEYS & set(v)
            if bad:
                fail(where, f"role=store memakai volume jaringan {sorted(bad)}")
        for claim in w["spec"].get("volumeClaimTemplates") or []:
            sc = claim["spec"].get("storageClassName", "")
            if sc not in LOCAL_STORAGE_CLASSES:
                fail(where, f"role=store memakai StorageClass '{sc}', harus disk lokal node")
        if w["kind"] != "StatefulSet":
            fail(where, "role=store harus StatefulSet")

    if role == "mock":
        allowed = False
        for np in (d for d in docs if d["kind"] == "NetworkPolicy"):
            for rule in np["spec"].get("ingress", []) or []:
                for src in rule.get("from", []) or []:
                    labels = (src.get("namespaceSelector") or {}).get("matchLabels", {})
                    if labels.get("kubernetes.io/metadata.name") == TESTER_NAMESPACE:
                        allowed = True
        if not allowed:
            fail(where, f"NetworkPolicy mock harus menerima trafik dari namespace {TESTER_NAMESPACE}")

    global checked
    checked += 1


def check_applicationset():
    path = os.path.join(ROOT, "argocd/applicationset.yaml")
    with open(path) as f:
        text = f.read()
    if f"namespace: {APP_NAMESPACE}" not in text:
        fail("argocd/applicationset.yaml", f"environment prod harus memakai namespace {APP_NAMESPACE}")
    if "namespace: '{{.namespace}}'" not in text:
        fail("argocd/applicationset.yaml", "destination.namespace harus memakai elemen namespace")


def check_policies():
    for path in glob.glob(os.path.join(ROOT, "policies/kyverno/*.yaml")):
        with open(path) as f:
            if TESTER_NAMESPACE in f.read():
                fail(os.path.relpath(path, ROOT),
                     f"policy tidak boleh mencakup namespace {TESTER_NAMESPACE} (Tester Agent tidak boleh dihalangi)")
        if os.path.basename(path) == "allow-hpa-read.yaml":
            continue
        with open(path) as f:
            doc = yaml.safe_load(f)
        for rule in doc["spec"]["rules"]:
            for entry in (rule.get("match", {}).get("any") or []):
                nss = entry.get("resources", {}).get("namespaces") or []
                if "prod" in nss:
                    fail(os.path.relpath(path, ROOT), "masih menyebut namespace 'prod', seharusnya " + APP_NAMESPACE)


def main():
    for env in ("dev", "prod"):
        for values in sorted(glob.glob(os.path.join(ROOT, f"envs/{env}/*.yaml"))):
            svc = os.path.basename(values)[:-5]
            docs = render(env, svc)
            if docs:
                check_workload(env, svc, docs)
    check_applicationset()
    check_policies()

    if errors:
        print(f"Kontrak M2 dilanggar ({len(errors)} temuan):", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)
    print(f"Kontrak M2 terpenuhi: {checked} workload diperiksa.")


if __name__ == "__main__":
    main()
