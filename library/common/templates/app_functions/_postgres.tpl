{{/* Returns a postgres pod with init container for fixing permissions
and a pre-upgrade job to backup the database */}}
{{/* Call this template:
{{ include "ix.v1.common.app.postgres" (dict "name" "postgres" "secretName" "postgres-creds" "backupPath" "/postgres_backup" "resources" .Values.resources) }}

name (optional): Name of the postgres pod/container (default: postgres)
secretName (required): Name of the secret containing the postgres credentials
backupPath (optional): Path to store the backup, it's the container's path (default: /postgres_backup)
resources (required): Resources for the postgres container
backupChownMode (optional): Whether to chown the backup directory or
          check parent directory permissions and fix them if needed.
          (default: check) Valid values: always, check
*/}}
{{- define "ix.v1.common.app.postgres" -}}
  {{- $name := .name | default "postgres" -}}
  {{- $secretName := (required "Postgres - Secret Name is required" .secretName) -}}
  {{- $backupPath := .backupPath | default "/postgres_backup" -}}
  {{- $backupChownMode := .backupChownMode | default "check" -}}
  {{- $ixChartContext := .ixChartContext -}}
  {{- $resources := (required "Postgres - Resources are required" .resources) }}

{{ $name }}:
  enabled: true
  type: Deployment
  podSpec:
    containers:
      {{ $name }}:
        enabled: true
        primary: true
        imageSelector: postgresImage
        securityContext:
          runAsUser: 999
          runAsGroup: 999
          readOnlyRootFilesystem: false
        resources:
          limits:
            cpu: {{ $resources.limits.cpu }}
            memory: {{ $resources.limits.memory }}
        envFrom:
          - secretRef:
              name: {{ $secretName }}
        probes:
          liveness:
            enabled: true
            type: exec
            command:
              - sh
              - -c
              - "until pg_isready -U ${POSTGRES_USER} -h localhost; do sleep 2; done"
          readiness:
            enabled: true
            type: exec
            command:
              - sh
              - -c
              - "until pg_isready -U ${POSTGRES_USER} -h localhost; do sleep 2; done"
          startup:
            enabled: true
            type: exec
            command:
              - sh
              - -c
              - "until pg_isready -U ${POSTGRES_USER} -h localhost; do sleep 2; done"
    initContainers:
      {{- include "ix.v1.common.app.permissions"
        (dict
          "UID" 999
          "GID" 999
          "type" "install"
          "containerName" "permissions"
        ) | nindent 6 }}

  {{- $enableBackupJob := false -}}
  {{- if hasKey $ixChartContext "isUpgrade" -}}
    {{- if $ixChartContext.isUpgrade -}}
      {{- $enableBackupJob = true -}}
    {{- end -}}
  {{- else -}}
    {{/* If the key is not present in ixChartContext, means we
      are outside SCALE (Probably CI), let upgrade job run */}}
    {{- $enableBackupJob = true -}}
  {{- end }}

postgresbackup:
  enabled: {{ $enableBackupJob }}
  type: Job
  annotations:
    "helm.sh/hook": pre-upgrade
    "helm.sh/hook-weight": "1"
    "helm.sh/hook-delete-policy": hook-succeeded
  podSpec:
    restartPolicy: Never
    containers:
      postgresbackup:
        enabled: true
        primary: true
        imageSelector: postgresImage
        securityContext:
          runAsUser: 999
          runAsGroup: 999
          readOnlyRootFilesystem: false
        probes:
          liveness:
            enabled: false
          readiness:
            enabled: false
          startup:
            enabled: false
        resources:
          limits:
            cpu: 2000m
            memory: 2Gi
        envFrom:
          - secretRef:
              name: {{ $secretName }}
        command:
          - sh
          - -c
          - |
            until pg_isready -U ${POSTGRES_USER} -h ${POSTGRES_HOST}; do sleep 2; done
            echo "Creating backup of ${POSTGRES_DB} database"
            pg_dump --dbname=${POSTGRES_URL} --file {{ $backupPath }}/${POSTGRES_DB}_$(date +%Y-%m-%d_%H-%M-%S).sql || echo "Failed to create backup"
            echo "Backup finished"
    initContainers:
    {{- include "ix.v1.common.app.permissions"
      (dict
        "UID" 999
        "GID" 999
        "type" "init"
        "mode" $backupChownMode
        "containerName" "permissions"
      ) | nindent 6 }}
{{- end -}}

{{/* Returns a postgres-wait container for waiting for postgres to be ready */}}
{{/* Call this template:
{{ include "ix.v1.common.app.postgresWait" (dict "name" "postgres-wait" "secretName" "postgres-creds") }}

name (optional): Name of the postgres-wait container (default: postgres-wait)
secretName (required): Name of the secret containing the postgres credentials
*/}}

{{- define "ix.v1.common.app.postgresWait" -}}
  {{- $name := .name | default "postgres-wait" -}}
  {{- $secretName := (required "Postgres-Wait - Secret Name is required" .secretName) }}

{{ $name }}:
  enabled: true
  type: init
  imageSelector: postgresImage
  envFrom:
    - secretRef:
        name: {{ $secretName }}
  resources:
    limits:
      cpu: 500m
      memory: 256Mi
  command: bash
  args:
    - -c
    - |
      echo "Waiting for postgres to be ready"
      until pg_isready -h ${POSTGRES_HOST} -U ${POSTGRES_USER} -d ${POSTGRES_DB}; do
        sleep 2
      done
{{- end -}}

{{/* Returns persistence entries for postgres */}}
{{/* Call this template:
{{ include "ix.v1.common.app.postgresPersistence" (dict "pgData" .Values.storage.pgData "pgBackup" .Values.storage.pgBackup) }}

pgData (required): Data persistence configuration
pgBackup (required): Data persistence configuration for backup
*/}}

{{- define "ix.v1.common.app.postgresPersistence" -}}
  {{- $data := .pgData -}}
  {{- $backup := .pgBackup }}

  {{- if not $data -}}
    {{- fail "Postgres - Data persistence configuration is required" -}}
  {{- end -}}

  {{- if not $backup -}}
    {{- fail "Postgres - Backup persistence configuration is required" -}}
  {{- end -}}

postgresdata:
  enabled: true
  type: {{ $data.type }}
  datasetName: {{ $data.datasetName | default "" }}
  hostPath: {{ $data.hostPath | default "" }}
  targetSelector:
    postgres:
      postgres:
        mountPath: /var/lib/postgresql/data
      permissions:
        mountPath: /mnt/directories/postgres_data
postgresbackup:
  enabled: true
  type: {{ $backup.type }}
  datasetName: {{ $backup.datasetName | default "" }}
  hostPath: {{ $backup.hostPath | default "" }}
  targetSelector:
    postgresbackup:
      postgresbackup:
        mountPath: /postgres_backup
      permissions:
        mountPath: /mnt/directories/postgres_backup
{{- end -}}

{{/* Returns service entry for postgres */}}
{{/* Call this template:
{{ include "ix.v1.common.app.postgresService" . }}
*/}}
{{- define "ix.v1.common.app.postgresService" -}}
postgres:
  enabled: true
  type: ClusterIP
  targetSelector: postgres
  ports:
    postgres:
      enabled: true
      primary: true
      port: 5432
      targetPort: 5432
      targetSelector: postgres
{{- end -}}
