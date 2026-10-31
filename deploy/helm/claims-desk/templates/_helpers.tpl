{{- define "claims-desk.name" -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{- define "claims-desk.labels" -}}
app.kubernetes.io/name: claims-desk
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "claims-desk.selector" -}}
app.kubernetes.io/name: claims-desk
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: api
{{- end -}}

{{- define "claims-desk.chatSelector" -}}
app.kubernetes.io/name: claims-desk
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: chat
{{- end -}}

{{- define "claims-desk.downward" -}}
- name: POD_NAMESPACE
  valueFrom: {fieldRef: {fieldPath: metadata.namespace}}
- name: NODE_NAME
  valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
- name: NODE_IP
  valueFrom: {fieldRef: {fieldPath: status.hostIP}}
- name: POD_IP
  valueFrom: {fieldRef: {fieldPath: status.podIP}}
{{- end -}}

{{/* PV nfs fields are immutable. A new export gets a new PV and PVC name. */}}
{{- define "claims-desk.docsVolume" -}}
{{- $id := printf "%s:%s" .Values.nfs.server .Values.nfs.path | sha256sum | trunc 8 -}}
{{- printf "%s-docs-%s" (include "claims-desk.name" .) $id -}}
{{- end -}}
