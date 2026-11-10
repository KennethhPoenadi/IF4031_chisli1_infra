#!/usr/bin/env python3
"""Menghasilkan dashboard Grafana (JSON) ke platform/observability/dashboards/.

Dashboard disimpan sebagai kode: ubah skrip ini, jalankan ulang, lalu commit JSON-nya. scripts/observability.sh
memasangnya sebagai ConfigMap berlabel grafana_dashboard, yang diambil otomatis oleh sidecar Grafana.

Nama metrik berasal dari modul telemetry aplikasi (OpenTelemetry yang diekspos sebagai Prometheus) dan dari
kube-state-metrics, node-exporter, serta cAdvisor.
"""
import json
import os
import sys

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "platform/observability/dashboards")
if len(sys.argv) > 1:
    OUT = sys.argv[1]  # folder keluaran lain, dipakai validate.sh untuk membandingkan tanpa menimpa
NS = "sistem-informasi-kebencanaan-bnpb"
DS = {"type": "prometheus", "uid": "prometheus"}
APP = "app_kubernetes_io_name"  # label nama aplikasi dari label pod, dibawa oleh scrape Prometheus
LAT = "http_server_request_duration_seconds"

_next_id = [0]


def _id():
    _next_id[0] += 1
    return _next_id[0]


def target(expr, legend="", ref="A", instant=False):
    t = {"datasource": DS, "expr": expr, "legendFormat": legend, "refId": ref}
    if instant:
        t["instant"] = True
    return t


def row(title, y):
    return {"id": _id(), "type": "row", "title": title, "collapsed": False,
            "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []}


def timeseries(title, exprs, x, y, w=12, h=8, unit="short", desc="", thresholds=None, stack=False, minimum=None, maximum=None):
    """exprs: daftar (expr, legend). thresholds: garis ambang, mis. [(5, 'red')]."""
    custom = {"lineWidth": 2, "fillOpacity": 10 if stack else 0, "showPoints": "never", "spanNulls": False}
    if stack:
        custom["stacking"] = {"mode": "normal", "group": "A"}
    defaults = {"unit": unit, "custom": custom}
    if minimum is not None:
        defaults["min"] = minimum
    if maximum is not None:
        defaults["max"] = maximum
    if thresholds:
        defaults["thresholds"] = {"mode": "absolute", "steps": [{"color": "green", "value": None}] +
                                  [{"color": c, "value": v} for v, c in thresholds]}
        custom["thresholdsStyle"] = {"mode": "line"}
    return {
        "id": _id(), "type": "timeseries", "title": title, "description": desc, "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {"legend": {"displayMode": "table", "placement": "bottom", "calcs": ["lastNotNull", "max"]},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
        "targets": [target(e, l, chr(65 + i)) for i, (e, l) in enumerate(exprs)],
    }


def stat(title, expr, x, y, w=6, h=4, unit="short", desc="", steps=None, mappings=None, decimals=None):
    defaults = {"unit": unit,
                "thresholds": {"mode": "absolute", "steps": steps or [{"color": "blue", "value": None}]}}
    if mappings:
        defaults["mappings"] = mappings
    if decimals is not None:
        defaults["decimals"] = decimals
    return {
        "id": _id(), "type": "stat", "title": title, "description": desc, "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "colorMode": "background", "graphMode": "none", "textMode": "value_and_name", "justifyMode": "center"},
        "targets": [target(expr, "{{unit}}", instant=True)],
    }


def dashboard(uid, title, panels, variables=None, description=""):
    return {
        "uid": uid, "title": title, "description": description, "tags": ["bnpb", "m2"], "schemaVersion": 39,
        "version": 1, "editable": True, "timezone": "browser", "refresh": "10s", "time": {"from": "now-30m", "to": "now"},
        "graphTooltip": 1, "panels": panels,
        "templating": {"list": variables or []},
        "annotations": {"list": []},
    }


def var_app():
    return {"name": "app", "label": "Service", "type": "query", "datasource": DS, "multi": True, "includeAll": True,
            "allValue": ".+", "current": {"selected": True, "text": "All", "value": "$__all"}, "refresh": 2,
            "query": {"query": f"label_values({LAT}_count, {APP})", "refId": "app"}, "sort": 1}


def write(name, d):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name), "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
        f.write("\n")


# ---------------------------------------------------------------------------------------------------------------
# 1. RED per service
# ---------------------------------------------------------------------------------------------------------------
def services():
    sel = f'{APP}=~"$app"'
    q = lambda p: (f'histogram_quantile({p}, sum by (le, {APP}) (rate({LAT}_bucket{{{sel}}}[2m])))', f"{{{{{APP}}}}}")
    panels = [
        row("Throughput dan error", 0),
        timeseries("Throughput (permintaan/detik)", [(f"sum by ({APP}) (rate({LAT}_count{{{sel}}}[1m]))", f"{{{{{APP}}}}}")],
                   0, 1, unit="reqps", desc="Permintaan per detik yang diterima tiap service."),
        timeseries("Error rate (5xx)", [(
            f'sum by ({APP}) (rate({LAT}_count{{{sel},http_response_status_code=~"5.."}}[1m])) / '
            f'sum by ({APP}) (rate({LAT}_count{{{sel}}}[1m]))', f"{{{{{APP}}}}}")],
            12, 1, unit="percentunit", minimum=0,
            desc="Rasio respons 5xx. Penolakan terkontrol (429) sengaja tidak dihitung sebagai error.",
            thresholds=[(0.01, "red")]),
        timeseries("Penolakan terkontrol (429)", [(
            f'sum by ({APP}) (rate({LAT}_count{{{sel},http_response_status_code="429"}}[1m]))', f"{{{{{APP}}}}}")],
            0, 9, unit="reqps", minimum=0,
            desc="Permintaan yang ditolak pembatas beban (mis. Media saat overload), bukan kegagalan."),
        timeseries("Respons per kode status", [(
            f'sum by (http_response_status_code) (rate({LAT}_count{{{sel}}}[1m]))', "{{http_response_status_code}}")],
            12, 9, unit="reqps", stack=True),
        row("Latensi", 17),
        timeseries("Latensi p50", [q(0.50)], 0, 18, w=8, unit="s", minimum=0),
        timeseries("Latensi p95", [q(0.95)], 8, 18, w=8, unit="s", minimum=0),
        timeseries("Latensi p99", [q(0.99)], 16, 18, w=8, unit="s", minimum=0),
        row("Sumber daya", 26),
        timeseries("Replika siap per service", [(
            f'count by ({APP}) (up{{job="kubernetes-pods",{sel}}} == 1)', f"{{{{{APP}}}}}")],
            0, 27, unit="short", minimum=0, desc="Jumlah pod yang metriknya berhasil diambil."),
        timeseries("Memori pod (working set)", [(
            f'sum by (pod) (container_memory_working_set_bytes{{namespace="{NS}",container!="",container!="POD"}})', "{{pod}}")],
            12, 27, unit="bytes", minimum=0),
    ]
    write("services.json", dashboard(
        "bnpb-services", "BNPB / Service (RED)", panels, [var_app()],
        "Throughput, error rate, dan latensi p50/p95/p99 per service, dari metrik OpenTelemetry modul telemetry."))


# ---------------------------------------------------------------------------------------------------------------
# 2. Alur data dan jalur peringatan
# ---------------------------------------------------------------------------------------------------------------
def pipeline():
    panels = [
        row("Jalur peringatan (SLO)", 0),
        stat("p95 latensi notifikasi", 'histogram_quantile(0.95, sum by (le) (rate(notification_latency_seconds_bucket[5m])))',
             0, 1, w=6, unit="s", decimals=2, desc="Detik dari event disimpan aggregator sampai notifier memprosesnya. Target: ≤ 5 detik.",
             steps=[{"color": "green", "value": None}, {"color": "orange", "value": 3}, {"color": "red", "value": 5}]),
        stat("Pesan diproses ≤ 5 detik", "slo:alert_path_within_5s:ratio_rate5m", 6, 1, w=6, unit="percentunit", decimals=2,
             desc="SLO jalur peringatan: persentase pesan diproses dalam 5 detik (aturan rekaman, jendela 5 menit).",
             steps=[{"color": "red", "value": None}, {"color": "orange", "value": 0.95}, {"color": "green", "value": 0.99}]),
        stat("Event masuk (per menit)", "sum(rate(hazard_events_ingested_total[5m])) * 60", 12, 1, w=6, unit="short", decimals=1),
        stat("Event gagal (per menit)", "sum(rate(hazard_events_failed_total[5m])) * 60", 18, 1, w=6, unit="short", decimals=1,
             steps=[{"color": "green", "value": None}, {"color": "red", "value": 0.01}]),
        timeseries("Latensi notifikasi p50 / p95 / p99", [
            ("histogram_quantile(0.50, sum by (le) (rate(notification_latency_seconds_bucket[2m])))", "p50"),
            ("histogram_quantile(0.95, sum by (le) (rate(notification_latency_seconds_bucket[2m])))", "p95"),
            ("histogram_quantile(0.99, sum by (le) (rate(notification_latency_seconds_bucket[2m])))", "p99")],
            0, 5, unit="s", minimum=0, thresholds=[(5, "red")], desc="Garis merah adalah batas 5 detik."),
        timeseries("Hasil pemrosesan notifier", [(
            "sum by (outcome) (rate(notifier_messages_total[1m]))", "{{outcome}}")], 12, 5, unit="ops", stack=True,
            desc="alert, below_threshold, duplicate, dropped, cancelled."),
        row("Pengambilan dan penyimpanan data", 13),
        timeseries("Event masuk per sumber dan jenis", [(
            "sum by (source, type) (rate(hazard_events_ingested_total[1m]))", "{{source}} / {{type}}")],
            0, 14, unit="ops", stack=True),
        timeseries("Event gagal per tahap", [(
            "sum by (stage) (rate(hazard_events_failed_total[1m]))", "{{stage}}")], 12, 14, unit="ops", minimum=0,
            desc="store: gagal menyimpan. publish: gagal mengirim ke RabbitMQ."),
        timeseries("Latensi pembaruan dashboard p95", [(
            "histogram_quantile(0.95, sum by (le) (rate(dashboard_update_latency_seconds_bucket[2m])))", "p95")],
            0, 22, unit="s", minimum=0),
        timeseries("Pesan dashboard-updater", [(
            "sum by (outcome) (rate(dashboard_updater_messages_total[1m]))", "{{outcome}}")], 12, 22, unit="ops", stack=True),
        row("Penyimpanan tersebar (P1)", 30),
        stat("Unit penyimpanan", "store_unit_up", 0, 31, w=12, h=5, unit="short",
             desc="1 = terjangkau, 0 = tidak terjangkau. Satu kotak per unit.",
             steps=[{"color": "red", "value": None}, {"color": "green", "value": 1}],
             mappings=[{"type": "value", "options": {"0": {"text": "MATI", "color": "red"}, "1": {"text": "HIDUP", "color": "green"}}}]),
        stat("Rebalancing", "max(store_rebalancing)", 12, 31, w=6, h=5, unit="short",
             desc="1 = penempatan data sedang disamakan, angka bisa sedikit kurang.",
             steps=[{"color": "green", "value": None}, {"color": "orange", "value": 1}],
             mappings=[{"type": "value", "options": {"0": {"text": "NORMAL"}, "1": {"text": "BERLANGSUNG"}}}]),
        stat("Jumlah salinan (RF)", "max(store_replication_factor)", 18, 31, w=6, h=5, unit="short"),
        timeseries("Penulisan tidak lengkap", [(
            "sum(rate(store_writes_degraded_total[1m]))", "kurang dari RF")], 0, 36, unit="ops", minimum=0,
            desc="Penulisan yang tersimpan kurang dari jumlah salinan (ada unit mati). Perbaikan melengkapinya."),
        timeseries("Perbaikan penempatan data", [
            ("sum(increase(store_repair_replicated_total[5m]))", "salinan dibuat (5 menit)"),
            ("sum(increase(store_repair_removed_total[5m]))", "salinan usang dihapus (5 menit)")],
            12, 36, unit="short", minimum=0, desc="Aktivitas pemulihan setelah node hilang atau ditambah."),
    ]
    write("pipeline.json", dashboard(
        "bnpb-pipeline", "BNPB / Alur data dan jalur peringatan", panels,
        description="Latensi jalur peringatan terhadap target 5 detik, ingest, dan kesehatan penyimpanan tersebar."))


# ---------------------------------------------------------------------------------------------------------------
# 3. Cluster dan node
# ---------------------------------------------------------------------------------------------------------------
def cluster():
    panels = [
        row("Node", 0),
        stat("Node siap", 'kube_node_status_condition{condition="Ready",status="true"}', 0, 1, w=24, h=5, unit="short",
             desc="Satu kotak per node. Saat Tester Agent mematikan node, kotaknya menjadi merah.",
             steps=[{"color": "red", "value": None}, {"color": "green", "value": 1}],
             mappings=[{"type": "value", "options": {"0": {"text": "TIDAK SIAP", "color": "red"}, "1": {"text": "SIAP", "color": "green"}}}]),
        timeseries("CPU node", [(
            '1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[2m]))', "{{instance}}")],
            0, 6, unit="percentunit", minimum=0, maximum=1),
        timeseries("Memori node terpakai", [(
            '1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)', "{{instance}}")],
            12, 6, unit="percentunit", minimum=0, maximum=1),
        row("Pod aplikasi", 14),
        timeseries("Pod per node", [(
            f'count by (node) (kube_pod_info{{namespace="{NS}"}})', "{{node}}")], 0, 15, unit="short", minimum=0,
            desc="Sebaran pod antar node. Setelah satu node mati, pod berpindah ke node lain."),
        timeseries("Pod per role", [(
            f'count by (label_role) (kube_pod_labels{{namespace="{NS}"}})', "{{label_role}}")], 12, 15, unit="short", minimum=0,
            desc="Label role yang dipakai Tester Agent: aggregator, store, broker, consumer, api, mock, sensor, other."),
        timeseries("Pod menurut fase", [(
            f'sum by (phase) (kube_pod_status_phase{{namespace="{NS}"}})', "{{phase}}")], 0, 23, unit="short", minimum=0, stack=True),
        timeseries("Restart container (10 menit terakhir)", [(
            f'sum by (pod) (increase(kube_pod_container_status_restarts_total{{namespace="{NS}"}}[10m]))', "{{pod}}")],
            12, 23, unit="short", minimum=0, desc="Pod yang terus restart menandakan crash atau pembunuhan oleh Tester Agent."),
    ]
    write("cluster.json", dashboard(
        "bnpb-cluster", "BNPB / Cluster dan node", panels,
        description="Kesehatan node, sebaran pod, dan restart. Dipakai saat game day untuk menjelaskan kegagalan."))


if __name__ == "__main__":
    services()
    pipeline()
    cluster()
    print("dashboard ditulis ke", OUT)
