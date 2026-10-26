{{/* Nama resource = nama release, supaya nama Service sama dengan docker-compose (aggregator, mongo, ...) */}}
{{- define "microservice.name" -}}
{{- .Release.Name -}}
{{- end -}}

{{- define "microservice.labels" -}}
app.kubernetes.io/name: {{ include "microservice.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "microservice.selectorLabels" -}}
app.kubernetes.io/name: {{ include "microservice.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Pod template bersama Deployment dan StatefulSet: aturan keamanan hanya ditulis sekali */}}
{{- define "microservice.podTemplate" -}}
metadata:
  labels:
    {{- include "microservice.selectorLabels" . | nindent 4 }}
  annotations:
    checksum/config: {{ toYaml .Values.env | sha256sum }}
spec:
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    {{- toYaml .Values.podSecurityContext | nindent 4 }}
  containers:
    - name: {{ include "microservice.name" . }}
      image: "{{ required "image.repository wajib diisi (deploy.sh dari DOCKERHUB_USERNAME)" .Values.image.repository }}:{{ required "image.tag wajib diisi (--set image.tag=<service>-<sha>)" .Values.image.tag }}"
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
      {{- with .Values.extraEnv }}
      env:
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
        {{- toYaml .Values.resources | nindent 8 }}
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
