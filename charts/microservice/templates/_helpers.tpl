{{- define "microservice.name" -}}
{{- .Release.Name -}}
{{- end -}}
{{- define "microservice.role" -}}
{{- $roles := list "aggregator" "store" "broker" "consumer" "api" "mock" "sensor" "other" -}}
{{- $role := required "role wajib diisi (aggregator|store|broker|consumer|api|mock|sensor|other)" .Values.role -}}
{{- if not (has $role $roles) -}}
{{- fail (printf "role '%s' tidak sah, pilih salah satu: %s" $role (join ", " $roles)) -}}
{{- end -}}
{{- $role -}}
{{- end -}}
{{- define "microservice.resources" -}}
{{- $class := index .Values.resourceClasses (include "microservice.role" .) -}}
requests:
  {{- with .Values.resources.requests.cpu }}
  cpu: {{ . }}
  {{- end }}
  memory: {{ $class.requests.memory }}
limits:
  {{- with .Values.resources.limits.cpu }}
  cpu: {{ . }}
  {{- end }}
  memory: {{ $class.limits.memory }}
{{- end -}}

{{- define "microservice.labels" -}}
app.kubernetes.io/name: {{ include "microservice.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
role: {{ include "microservice.role" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "microservice.selectorLabels" -}}
app.kubernetes.io/name: {{ include "microservice.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "microservice.podTemplate" -}}
metadata:
  labels:
    {{- include "microservice.selectorLabels" . | nindent 4 }}
    role: {{ include "microservice.role" . }}
  annotations:
    checksum/config: {{ toYaml .Values.env | sha256sum }}
    {{- if .Values.telemetry.enabled }}
    prometheus.io/scrape: "true"
    prometheus.io/port: {{ .Values.telemetry.metricsPort | quote }}
    prometheus.io/path: /metrics
    {{- end }}
spec:
  {{- if or .Values.leaderElection.enabled .Values.podReader.enabled }}
  serviceAccountName: {{ include "microservice.name" . }}
  automountServiceAccountToken: true
  {{- else }}
  automountServiceAccountToken: {{ .Values.automountServiceAccountToken }}
  {{- end }}
  terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
  {{- if .Values.antiAffinity.enabled }}
  affinity:
    podAntiAffinity:
      {{- if eq .Values.antiAffinity.mode "required" }}
      requiredDuringSchedulingIgnoredDuringExecution:
        - topologyKey: {{ .Values.antiAffinity.topologyKey }}
          labelSelector:
            matchLabels:
              {{- include "microservice.selectorLabels" . | nindent 14 }}
      {{- else }}
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            topologyKey: {{ .Values.antiAffinity.topologyKey }}
            labelSelector:
              matchLabels:
                {{- include "microservice.selectorLabels" . | nindent 16 }}
      {{- end }}
  {{- end }}
  {{- if .Values.topologySpread.enabled }}
  topologySpreadConstraints:
    - maxSkew: {{ .Values.topologySpread.maxSkew }}
      topologyKey: {{ .Values.topologySpread.topologyKey }}
      whenUnsatisfiable: {{ .Values.topologySpread.whenUnsatisfiable }}
      labelSelector:
        matchLabels:
          {{- include "microservice.selectorLabels" . | nindent 10 }}
  {{- end }}
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    {{- toYaml .Values.podSecurityContext | nindent 4 }}
  containers:
    - name: {{ include "microservice.name" . }}
      image: "{{ required "image.repository wajib diisi (ApplicationSet, dari scripts/image-repo.sh)" .Values.image.repository }}:{{ required "image.tag wajib diisi (--set image.tag=<service>-<sha>)" .Values.image.tag }}"
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      {{- with .Values.args }}
      args:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      securityContext:
        {{- toYaml .Values.securityContext | nindent 8 }}
      ports:
        - name: http
          containerPort: {{ .Values.service.port }}
        {{- if .Values.telemetry.enabled }}
        - name: metrics
          containerPort: {{ .Values.telemetry.metricsPort }}
        {{- end }}
      env:
        - name: NODE_NAME
          valueFrom:
            fieldRef: { fieldPath: spec.nodeName }
        - name: POD_NAME
          valueFrom:
            fieldRef: { fieldPath: metadata.name }
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef: { fieldPath: metadata.namespace }
        {{- if .Values.telemetry.enabled }}
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: {{ .Values.telemetry.otlpEndpoint | quote }}
        - name: OTEL_TRACES_SAMPLER_ARG
          value: {{ .Values.telemetry.traceSampleRatio | quote }}
        - name: TELEMETRY_METRICS_ADDR
          value: {{ printf ":%v" .Values.telemetry.metricsPort | quote }}
        {{- end }}
        {{- with .Values.extraEnv }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- if or .Values.env .Values.secretRefs }}
      envFrom:
        {{- if .Values.env }}
        - configMapRef:
            name: {{ include "microservice.name" . }}
        {{- end }}
        {{- range .Values.secretRefs }}
        - secretRef:
            name: {{ . }}
        {{- end }}
      {{- end }}
      resources:
        {{- include "microservice.resources" . | nindent 8 }}
      {{- if gt (int .Values.preStopSleepSeconds) 0 }}
      lifecycle:
        preStop:
          sleep:
            seconds: {{ .Values.preStopSleepSeconds }}
      {{- end }}
      livenessProbe:
        {{- toYaml .Values.livenessProbe | nindent 8 }}
      readinessProbe:
        {{- toYaml .Values.readinessProbe | nindent 8 }}
      {{- if or .Values.tmpVolume .Values.extraVolumeMounts (and (eq .Values.kind "StatefulSet") .Values.persistence.enabled) }}
      volumeMounts:
        {{- if .Values.tmpVolume }}
        - name: tmp
          mountPath: /tmp
        {{- end }}
        {{- if and (eq .Values.kind "StatefulSet") .Values.persistence.enabled }}
        - name: data
          mountPath: {{ required "persistence.mountPath wajib diisi" .Values.persistence.mountPath }}
        {{- end }}
        {{- with .Values.extraVolumeMounts }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- end }}
  {{- if or .Values.tmpVolume .Values.extraVolumes }}
  volumes:
    {{- if .Values.tmpVolume }}
    - name: tmp
      emptyDir: {}
    {{- end }}
    {{- with .Values.extraVolumes }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
{{- end -}}
