---
title: Distributed Tracing (Tempo)
permalink: /docs/tracing/
description: How to deploy a distributed tracing solution based on Grafana Tempo.
last_modified_at: "01-04-2026"
---


Distributed tracing solution for Kubernetes cluster is based on [Grafana Tempo](https://grafana.com/oss/tempo/).

![tracing-architecture](/assets/img/tracing-architecture.png)


Grafana Tempo is used as traces backend and Grafana as front-end. Tempo, integrates a [Open Telemetry collector](https://opentelemetry.io/docs/collector/) enabling the ingestion of traces generated with common open source tracing protocols like Jaeger, Zipkin, and OpenTelemetry.

Tempo requires only object storage backend to operate, and is integrated with Grafana, Prometheus, and Loki. Minio S3 Object Store will be used as Tempo backend.

Instead of using embedded Tempo's collector, Pi Cluster uses the same OpenTelemetry Collector deployed in the cluster for receiving and processing telemetry from applications and platform components. That allows to centralize telemetry processing and exporting in a single component, while supporting multiple backends (Prometheus for metrics, Elasticsearch for logs, Tempo for traces) and multiple collection paths (OTLP for instrumented workloads, Prometheus scraping and Fluent Bit collection for non-instrumented workloads).

See details in [Observability solution documentation](/docs/observability/) and instructions on how to configure OpenTelemetry Collector for Tempo in [OpenTelemetry Collector documentation](/docs/opentelemetry-collector/#configure-opentelemetry-collector-for-tempo).



## Tempo architecture

Tempo architecture is displayed in the following picture (source: [Grafana documentation](https://grafana.com/docs/tempo/latest/operations/architecture/)):

![Tempo-Architecture](/assets/img/tempo_arch.png)

Tempo architecture is quite similar to Loki's.

- Distributor: responsible for collect traces in different formats (Jaeger, Zipkin, OpenTelemetry)
- Ingester: responsible for batching trace into blocks and storing them in S3 backend
- Query Frontend: responsible for sharding the search space for an incoming query and distributed the sharded query to querier component
- Querier: responsible for finding the requested trace id in either the ingesters or the backend storage
- Compactor: responsible for compacting trace blocks in the backend.

All Tempo components are included within a single binary (docker image) that  supports two different deployments modes (helm installation) where the above components can be started in different PODs:

- Monolithic mode

  In this mode, all Tempo components are running in a single process (container).

- Microservices mode

  In microservices mode, components are deployed in distinct processes. Scaling and HA is specified by microservice.


Further details in Tempo architecture documentation: [Tempo Architecture](https://grafana.com/docs/tempo/latest/operations/architecture/) and [Tempo deployment](https://grafana.com/docs/tempo/latest/setup/deployment/)

Tempo will be installed using microservices mode configuring S3 Object Storage Server (Minio) as backend.

## Configure S3 Minio Server

Minio Storage server is used as Tempo long-term data storage.

Grafana Tempo needs to store two different types of data: chunks and indexes. Both of them can be stored in S3 server.

{{site.data.alerts.note}}

Tempo helm chart is able to install this Minio service as a subchart, but its installation will be disabled and Minio Storage Service already deployed in the cluster will be used as Tempo's backend.

As part of Minio Storage Service installation, Tempo's S3 bucket, policy and user is already configured.
See documentation: [Minio S3 Object Storage Service](/docs/minio/).

{{site.data.alerts.end}}

### Create Minio user and bucket

Use Minio's `mc` command to create Tempo bucket and user

```shell
mc mb <minio_alias>/k3s-tempo
mc admin user add <minio_alias> tempo <user_password>
```
{{site.data.alerts.note}}

As the [Tempo's documentation states](https://grafana.com/docs/tempo/latest/configuration/s3/#amazon-s3-permissions), when using S3 as object storage, the following permissions are needed:

- s3:ListBucket
- s3:PutObject
- s3:GetObject
- s3:DeleteObject
- s3:GetObjectTagging
- s3:PutObjectTagging

Over the resources: arn:aws:s3:::<bucket_name>, arn:aws:s3:::<bucket_name>/*

{{site.data.alerts.end}}

Apply policy to user `tempo` so it has the proper persmissions on `k3s-tempo` bucket.

```shell
  mc admin policy add <minio_alias> tempo user_policy.json
```

Where `user_policy.json`, contains the following AWS access policies definition:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "TempoPermissions",
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:ListBucket",
                "s3:DeleteObject",
                "s3:GetObjectTagging",
                "s3:PutObjectTagging"
            ],
            "Resource": [
                "arn:aws:s3:::k3s-tempo/*",
                "arn:aws:s3:::k3s-tempo"
            ]
        }
    ]
}
```

## Tempo Installation

- Step 1: Add the Grafana repository:
  ```shell
  helm repo add grafana https://grafana.github.io/helm-charts
  ```
- Step2: Fetch the latest charts from the repository:
  ```shell
  helm repo update
  ```
- Step 3: Create namespace
  ```shell
  kubectl create namespace tempo
  ```
- Step 4: Create file `tempo-values.yml`

  ```yml
  streamOverHTTPEnabled: true

  # Enable trace ingestion
  traces:
    otlp:
      grpc:
        enabled: true
      http:
        enabled: true
    zipkin:
      enabled: true
    jaeger:
      thriftCompact:
        enabled: true
      thriftHttp:
        enabled: true
    opencensus:
      enabled: true

  # Configure S3 backend
  storage:
    trace:
      backend: s3
      s3:
        bucket: k3s-tempo
        endpoint: <minio_endpoint>:<minio_port>
        region: eu-west-1
        access_key: <minio_tempo_user>
        secret_key: <minio_tempo_key>
        insecure: false

  # Configure distributor
  distributor:
    config:
      log_received_spans:
        enabled: true

  # Enable metrics-generator so TraceQL metrics queries such as rate() work
  metricsGenerator:
    enabled: true
    config:
      processor:
        local_blocks:
          filter_server_spans: false
          flush_to_storage: true

  # Disable Minio server installation
  minio:
    enabled: false
  ```

  This configuration:

  - Enable S3 as storage backend, providing Minio credentials and bucket.

  - Enable traces ingestion of different protocols.

  - Enable Tempo search streaming for Grafana (`streamOverHTTPEnabled: true`).

  - Enable the metrics-generator so TraceQL metrics queries can use a live ring.

  - Disable minio server installation (`minio.enabled`)

- Step 3: Install Tempo in `tempo` namespace
  ```shell
  helm install tempo grafana/tempo-distributed -f tempo-values.yml --namespace tempo
  ```
- Step 4: Check status of Loki pods
  ```shell
  kubectl get pods -l app.kubernetes.io/name=tempo -n tempo
  ```

### GitOps installation

As an alternative, for GitOps deployments, instead of hardcoding minio credentials within Helm chart values, a external secret can be configured leveraging [Tempo's capability of using environment variables in config file](https://grafana.com/docs/tempo/latest/configuration/#use-environment-variables-in-the-configuration).

The following secret need to be created:
```yml
apiVersion: v1
kind: Secret
metadata:
  name: tempo-minio-secret
  namespace: tempo
type: Opaque
data:
  MINIO_ACCESS_KEY_ID: < minio_tempo_user | b64encode >
  MINIO_SECRET_ACCESS_KEY: < minio_tempo_key | b64encode >
```

And the following Helm values has to be provided:

```yml
streamOverHTTPEnabled: true

# Enable trace ingestion
traces:
  otlp:
    grpc:
      enabled: true
    http:
      enabled: true
  zipkin:
    enabled: true
  jaeger:
    thriftCompact:
      enabled: true
    thriftHttp:
      enabled: true
  opencensus:
    enabled: true

# Configure S3 backend
storage:
  trace:
    backend: s3
    s3:
      bucket: k3s-tempo
      endpoint: "${S3_SERVER}:9091"
      region: eu-west-1
      access_key: ${MINIO_ACCESS_KEY_ID}
      secret_key: ${MINIO_SECRET_ACCESS_KEY}
      insecure: false

# Configure distributor
distributor:
  config:
    log_received_spans:
      enabled: true
  # Enable environment variables in config file
  # https://grafana.com/docs/tempo/latest/configuration/#use-environment-variables-in-the-configuration
  extraArgs:
    - '-config.expand-env=true'
  extraEnv:
    - name: MINIO_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: tempo-minio-secret
          key: MINIO_ACCESS_KEY_ID
    - name: MINIO_SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: tempo-minio-secret
          key: MINIO_SECRET_ACCESS_KEY
# Configure ingester
ingester:
  # Enable environment variables in config file
  # https://grafana.com/docs/tempo/latest/configuration/#use-environment-variables-in-the-configuration
  extraArgs:
    - '-config.expand-env=true'
  extraEnv:
    - name: MINIO_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: tempo-minio-secret
          key: MINIO_ACCESS_KEY_ID
    - name: MINIO_SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: tempo-minio-secret
          key: MINIO_SECRET_ACCESS_KEY
# Configure compactor
compactor:
  # Enable environment variables in config file
  # https://grafana.com/docs/tempo/latest/configuration/#use-environment-variables-in-the-configuration
  extraArgs:
    - '-config.expand-env=true'
  extraEnv:
    - name: MINIO_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: tempo-minio-secret
          key: MINIO_ACCESS_KEY_ID
    - name: MINIO_SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: tempo-minio-secret
          key: MINIO_SECRET_ACCESS_KEY
# Configure querier
querier:
  # Enable environment variables in config file
  # https://grafana.com/docs/tempo/latest/configuration/#use-environment-variables-in-the-configuration
  extraArgs:
    - '-config.expand-env=true'
  extraEnv:
    - name: MINIO_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: tempo-minio-secret
          key: MINIO_ACCESS_KEY_ID
    - name: MINIO_SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: tempo-minio-secret
          key: MINIO_SECRET_ACCESS_KEY
# Configure query-frontend
queryFrontend:
  # Enable environment variables in config file
  # https://grafana.com/docs/tempo/latest/configuration/#use-environment-variables-in-the-configuration
  extraArgs:
    - '-config.expand-env=true'
  extraEnv:
    - name: MINIO_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: tempo-minio-secret
          key: MINIO_ACCESS_KEY_ID
    - name: MINIO_SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: tempo-minio-secret
          key: MINIO_SECRET_ACCESS_KEY

# Enable metrics-generator so TraceQL metrics queries such as rate() work
metricsGenerator:
  enabled: true
  config:
    processor:
      local_blocks:
        filter_server_spans: false
        flush_to_storage: true
  # Enable environment variables in config file
  # https://grafana.com/docs/tempo/latest/configuration/#use-environment-variables-in-the-configuration
  extraArgs:
    - '-config.expand-env=true'
  extraEnv:
    - name: MINIO_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: tempo-minio-secret
          key: MINIO_ACCESS_KEY_ID
    - name: MINIO_SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: tempo-minio-secret
          key: MINIO_SECRET_ACCESS_KEY

# Disable Minio server installation
minio:
  enabled: false
```

As tempo is running in distributed mode, extra arguments for each of the services that will be connecting to S3 storage service has to be configured. This means that we have to apply the configuration to the following services:
-   distributor
-   compactor
-   ingester
-   metrics-generator
-   querier
-   query-frontend


## Tempo Configuration


## Traefik traces integration

The ingress is a key component for distributed tracing solution because it is reposible for creating the root span of each trace and for deciding if that trace should be sampled or not.

Distributed tracing systems all rely on propagate the trace context throuhg the chain of involved services. This trace contex is encoding in HTTP request headers. Of the available propagation protocols, B3 is the only one supported by Linkerd, and so this is the one to be used in the whole system.

Traefik uses OpenTrace to export traces to different backends.

To activate tracing using B3 propagation protocol, the following options need to be provided

```
--tracing.zipkin=true
--tracing.zipkin.httpEndpoint=http://tempo-distributor.tracing.svc.cluster.local:9411/api/v2/spans
--tracing.zipkin.sameSpan=true
--tracing.zipkin.id128Bit=true
--tracing.zipkin.sampleRate=1
```

For more details see [Traefik tracing documentation](https://doc.traefik.io/traefik/observability/tracing/overview/)

In order to be able to correlate logs with traces in Grafana, Traefik access log should be configured so, trace ID is also present as a field in the logs. Trace ID comes as a header field (`X-B3-Traceid`), that need to be included in the logs.

By default no header is included in Traefik's access log. Additional parameters need to be added to include the traceID.

```
--accesslog.fields.headers.defaultmode=drop
--accesslog.fields.headers.names.X-B3-Traceid=keep
```

See more details in [Traefik access log documentation](https://doc.traefik.io/traefik/observability/access-logs/#limiting-the-fieldsincluding-headers).

When installing Traefik with Helm the following values.yml file achieve the above configuration

```yml
# Enable access log
logs:
  access:
    enabled: true
    format: json
    fields:
      general:
        defaultmode: keep
      headers:
        defaultmode: drop
        names:
          X-B3-Traceid: keep
# Enabling tracing
tracing:
  zipkin:
    httpEndpoint: http://tempo-distributor.tracing.svc.cluster.local:9411/api/v2/spans
    sameSpan: true
    id128Bit: true
    sampleRate: 1.0
```

In Traefik's access logs, a new field appear `request_X-B3-Traceid` containing trace id that can be used to extrac Tempo traces information.


## Ingress NGINX traces integration

Ingress Contoller is a key component for distributed tracing solution because it is reposible for creating the root span of each trace and for deciding if that trace should be sampled or not.

Distributed tracing systems all rely on propagate the trace context throuhg the chain of involved services. This trace contex is encoding in HTTP request headers. There is two key protocols used to propagate tracing context: W3C, used by OpenTelemetry, and B3, used by OpenTracing.

Since release 1.10, Ingress Nginx has deprecated OpenTracing and Zipkin modules, being OpenTelemtry the only supported. See [Ingress Nginx 1.10 release notes](https://github.com/kubernetes/ingress-nginx/releases/tag/controller-v1.10.0)

Ingress Nginx's OpenTelemetry module only supports W3C context propagation. B3 context propagation is not supported. See [nginx ingress open issue #10324](https://github.com/kubernetes/ingress-nginx/issues/10324).

By the other hand, linkerd included support to W3C tracing propagation since release v2.13. See [linkerd issue #5416](https://github.com/linkerd/linkerd2/issues/5416). When multiple headers are present: proxy will use w3c by default, if that's not present, it will fallback to b3.

To activate tracing using W3C propagation protocol, the following options need to be provided following to helm values.yml:

```yml
controller:
  config:
    # Open Telemetry
    enable-opentelemetry: "true"
    otlp-collector-host: tracing-tempo-distributor.tracing.svc.cluster.local
    otlp-service-name: nginx-internal
    # Print access log to file instead of stdout
    # Separating acces logs from the rest
    access-log-path: "/data/access.log"
    log-format-escape-json: "true"
    log-format-upstream: '{"source": "nginx", "time": $msec, "resp_body_size": $body_bytes_sent, "request_host": "$http_host", "request_address": "$remote_addr", "request_length": $request_length, "request_method": "$request_method", "uri": "$request_uri", "status": $status,  "user_agent": "$http_user_agent", "resp_time": $request_time, "upstream_addr": "$upstream_addr", "trace_id": "$opentelemetry_trace_id", "span_id": "$opentelemetry_span_id"}'
```

With this configuratin, embedded Tempo OTEL collector (distributor) is used as destination. Access logs format is also changed to include W3C context: `$opentelemetry_trace_id` and `$opentelemetry_span_id` appears as field in the logs: `trace_id` and `span_id`

For more details, see [Ingress NGINX Open Telemetry documentation](https://kubernetes.github.io/ingress-nginx/user-guide/third-party-addons/opentelemetry/).


{{site.data.alerts.note}}

Before NGINX Ingress 1.10, openTracing and B3 propagation protocol were configured using the following helm chart values.

```yml
controller:
  config:
    # Open Tracing
    enable-opentracing: "true"
    zipkin-collector-host: tracing-tempo-distributor.tracing.svc.cluster.local
    zipkin-service-name: nginx-internal
    log-format-escape-json: "true"
    log-format-upstream: '{"source": "nginx", "time": $msec, "resp_body_size": $body_bytes_sent, "request_host": "$http_host", "request_address": "$remote_addr", "request_length": $request_length, "method": "$request_method", "uri": "$request_uri", "status": $status,  "user_agent": "$http_user_agent", "resp_time": $request_time, "upstream_addr": "$upstream_addr", "trace_id": "$opentracing_context_x_b3_traceid", "span_id": "$opentracing_context_x_b3_spanid"}'
```

In this case Zipkin tempo embedded collector, ditributor, was used as destination. Access logs format was also configured to include B3 context. Opentrace context (x_b3_traceid and x_b3_spanId) appears as field in the logs: `trace_id` and `span_id`

NGINX configuration using OpenTracing protocol is not working since Ingress NGINX 1.10. See [issue #329](https://github.com/ricsanfre/pi-cluster/issues/329).


{{site.data.alerts.end}}

## Grafana Configuration

See [Grafana Operator - Provisioning Data Sources](/docs/grafana-operator/#provisioning-data-sources) for the general `GrafanaDatasource` provisioning pattern used by Grafana Operator.

Tempo need to be added to Grafana as DataSource. In Tempo distributed mode, the endpoint to be used is the `query-frontend` service.

Tempo search streaming requires the Tempo Helm chart to enable `streamOverHTTPEnabled: true`, which maps to Tempo's `stream_over_http_enabled: true` setting. The full request path between Grafana and Tempo must still preserve HTTP/2 correctly. Otherwise Grafana can emit gRPC preface errors when opening traces from Loki links.

In this repository, the Tempo Helm values should include:

```yml
streamOverHTTPEnabled: true
```

This can be done automatically when installing kube-prometheus-stack providing the following additional helm chart configuration:

```yml
grafana:
  # Additional data source
  additionalDataSources:
  - name: Tempo
    type: tempo
    uid: tempo
    access: proxy
    url: http://tempo-query-frontend.tempo.svc.cluster.local:3200
    jsonData:
      streamingEnabled:
        search: true
```

If Grafana is deployed with Grafana Operator, the same configuration is defined through a `GrafanaDatasource` resource instead of Helm values:

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: tempo
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  datasource:
    name: Tempo
    uid: tempo
    type: tempo
    access: proxy
    url: http://tempo-query-frontend.tempo.svc.cluster.local:3200
    basicAuth: false
    jsonData:
      streamingEnabled:
        search: true
```

#### Loki and Tempo integration

##### Logs to Traces correlation

Grafana's Loki data source can be configured to detect traceID automatically and providing a link in grafana to automatically opening the corresponding trace information from Tempo.

See [Loki data source - derived Fields](https://grafana.com/docs/grafana/latest/datasources/loki/#derived-fields).

Loki Data source configuration needs to be updated to include Tempo as a derived field datasource, and the regex pattern to detect traceID in log messages.

![loki-derived-fields](/assets/img/loki-derivedfields.png)


This can be done automatically when installing kube-prometheus-stack providing the following helm chart configuration:

```yml
grafana
  additionalDataSources:
  - name: Loki
    type: loki
    uid: loki
    access: proxy
    url: http://loki-read-headless.loki.svc.cluster.local
    jsonData:
      derivedFields:
        - datasourceUid: tempo
          matcherRegex: trace_id
          matcherType: label
          name: TraceID
          url: "$S{__value.raw}"
  - name: Tempo
    uid: tempo
    type: tempo
    access: proxy
    url: http://tempo-query-frontend.tempo.svc.cluster.local:3200
    jsonData:
      streamingEnabled:
        search: true
```

{{site.data.alerts.note}}
`$` character need to be escaped as `$$` in Grafana datasource configuration. Otherwise, Grafana will try to resolve it as a template variable and the query will not work as expected.
{{site.data.alerts.end}}

A derived field `TraceID` is added to logs whose message containing label `trace_id`. Envoy-Gateway access logs contains this label as part of the log record generated by OpenTelemetry.

When clicking on the `TraceID` link, Grafana will automatically search for that trace ID in Tempo and display the corresponding trace information.

If Grafana is deployed with Grafana Operator, the Loki and Tempo integration can be configured declaratively with `GrafanaDatasource` resources:

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: loki
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  datasource:
    name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://loki-read-headless.loki.svc.cluster.local:3100
    jsonData:
      derivedFields:
        - datasourceUid: tempo
          matcherRegex: trace_id
          matcherType: label
          name: TraceID
          url: $${__value.raw}
```


### Traces to Logs correlation

Grafana Tempo can be configured to include links to Loki Explore when displaying trace information. This allows users to easily navigate from a trace to the corresponding logs in Loki.

Tempo datasource need to be updated to include the following custom query configuration

![tempo-traces-to-log](/assets/img/tempo-traces-to-log.png)

This can be done automatically when installing kube-prometheus-stack providing the following helm chart configuration:

```yml
grafana:
  additionalDataSources:
  - name: Tempo
    uid: tempo
    type: tempo
    access: proxy
    url: http://tempo-query-frontend.tempo.svc.cluster.local:3200
    jsonData:
      streamingEnabled:
        search: true
      tracesToLogsV2:
        datasourceUid: 'loki'
        spanStartTimeShift: '-1h'
        spanEndTimeShift: '1h'
        filterByTraceID: false
        filterBySpanID: false
        customQuery: true
        query: '{$${__tags}} | trace_id="$${__span.traceId}"'
```

With Grafana Operator, the same correlation is configured in `GrafanaDatasource.spec.datasource.jsonData.tracesToLogsV2`, as shown in the combined Loki and Tempo example above.

Grafana Tempo's `tracesToLogsV2` configuration allows to specify a custom query that will be used to search for logs in Loki when clicking on the "Logs" link from a trace. In the above configuration, the query is set to search for logs that have a label `trace_id` matching the trace ID of the selected span.

{{site.data.alerts.note}}
`$` character need to be escaped as `$$` in Grafana datasource configuration. Otherwise, Grafana will try to resolve it as a template variable and the query will not work as expected.
{{site.data.alerts.end}}

If Grafana is deployed with Grafana Operator, the Loki and Tempo integration can be configured declaratively with `GrafanaDatasource` resources:


```yaml
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: tempo
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  datasource:
    name: Tempo
    uid: tempo
    type: tempo
    access: proxy
    url: http://tempo-query-frontend.tempo.svc.cluster.local:3200
    basicAuth: false
    jsonData:
      tracesToLogsV2:
        datasourceUid: loki
        spanStartTimeShift: -1h
        spanEndTimeShift: 1h
        filterByTraceID: false
        filterBySpanID: false
        customQuery: true
        query: '{$${__tags}} | trace_id="$${__span.traceId}"'
      serviceMap:
        datasourceUid: prometheus
      nodeGraph:
        enabled: true
      search:
        hide: false
      traceQuery:
        timeShiftEnabled: true
        spanStartTimeShift: -1h
        spanEndTimeShift: 1h
      spanBar:
        type: Tag
        tag: http.path
      streamingEnabled:
        search: true
```
