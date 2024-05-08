#!/bin/bash

# Setup ADOT Collector
rpm -ivh https://aws-otel-collector.s3.amazonaws.com/amazon_linux/amd64/latest/aws-otel-collector.rpm

# Setup Jaeger
wget https://github.com/jaegertracing/jaeger/releases/download/v1.28.0/jaeger-1.28.0-linux-amd64.tar.gz
tar xf jaeger-1.28.0-linux-amd64.tar.gz
cd jaeger-1.28.0-linux-amd64
cp jaeger-all-in-one  /usr/local/bin

cat <<EOF > /etc/systemd/system/jaeger.service
[Unit]
Description=Jaeger All-in-One
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/jaeger-all-in-one
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable and start Jaeger service
systemctl daemon-reload
systemctl enable jaeger
systemctl start jaeger

# ADOT Collector Config
cat <<EOF > /opt/aws/aws-otel-collector/etc/config.yaml
extensions:
  sigv4auth:
    service: "aps"
    region: "us-east-2"

receivers:
  otlp:
    protocols:
      grpc: {}
      http: {}
  prometheus:
    config:
      scrape_configs:
        - job_name: 'adot_collector'
          scrape_interval: 10s
          static_configs:
            - targets: ['localhost:8888']

        - job_name: 'node_exporter'
          scrape_interval: 10s
          static_configs:
            - targets: ['localhost:9100']
            
        - job_name: 'prometheus'
          scrape_interval: 10s
          static_configs:
            - targets: ['localhost:9090']
  filelog:
    include: [ /var/log/* ]
    operators:
      - type: json_parser
        timestamp:
          parse_from: attributes.time
          layout: '%Y-%m-%d %H:%M:%S'
        severity:
          parse_from: attributes.sev

  awsxray:
    endpoint: 0.0.0.0:2000
    transport: udp
    proxy_server:
      endpoint: 0.0.0.0:2000
      proxy_address: ""
      tls:
        insecure: false
        server_name_override: ""
      region: "us-east-2"
      role_arn: ""
      aws_endpoint: ""
      local_mode: false

exporters:
  awsxray:
    region: "us-east-2"
  awsemf:
    region: "us-east-2"
    namespace: AWSOTel/Application/CPU
    resource_to_telemetry_conversion:
      enabled: true
    dimension_rollup_option: "NoDimensionRollup"
    metric_declarations:
      - dimensions:
          - ["host.id"]

  prometheusremotewrite:
    endpoint: "https://aps-workspaces.us-east-2.amazonaws.com/workspaces/ws-69975d73-029b-4613-90f1-210cbf242bfb/api/v1/remote_write"
    auth:
      authenticator: sigv4auth
    resource_to_telemetry_conversion:
      enabled: true

  logging:
    loglevel: debug

  awscloudwatchlogs:
    log_group_name: "filelogs"
    log_stream_name: "filelog-streams"
    raw_log: true
    region: "us-east-2"
    endpoint: "logs.us-east-2.amazonaws.com"
    log_retention: 1
    tags: { 'generator': 'adotlogs'}

processors:
  resourcedetection/ec2:
    detectors: ["ec2"]

  batch:
    send_batch_size: 10000
    timeout: 10s

  batch/traces:
    timeout: 10s
    send_batch_size: 50

  batch/metrics:
    timeout: 60s

service:
  extensions: [sigv4auth]
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [awsxray]

    metrics:
      receivers: [prometheus]
      processors: [resourcedetection/ec2]
      exporters: [awsemf, logging]

    metrics/2:
      receivers: [prometheus]
      processors: [resourcedetection/ec2]
      exporters: [prometheusremotewrite, logging]

    logs:
      receivers: [filelog]
      exporters: [awscloudwatchlogs]
EOF

# ADOT Collector service
sudo systemctl enable aws-otel-collector
sudo systemctl start aws-otel-collector

# Setup Node Exporter
wget https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
tar xvfz node_exporter-1.7.0.linux-amd64.tar.gz
cp node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin

# Node Exporter Service
cat <<EOF > /etc/systemd/system/node_exporter.service
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the Node Exporter service
systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter

# Setup Prometheus
wget https://github.com/prometheus/prometheus/releases/download/v2.51.2/prometheus-2.51.2.linux-amd64.tar.gz
tar xvfz prometheus-2.51.2.linux-amd64.tar.gz
cp prometheus-2.51.2.linux-amd64/prometheus /usr/local/bin
cp prometheus-2.51.2.linux-amd64/promtool /usr/local/bin
mkdir /etc/prometheus
mkdir /var/lib/prometheus
cp -r prometheus-*/consoles /etc/prometheus
cp -r prometheus-*/console_libraries /etc/prometheus

# Prometheus Config
cat <<EOF > /etc/prometheus/prometheus.yml
global:
  scrape_interval:     15s
  evaluation_interval: 15s
scrape_configs:
  - job_name: 'node_exporter'
    static_configs:
      - targets: ['localhost:9100']
  - job_name: 'loki'
    static_configs:
      - targets: ['localhost:3100']
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
  - job_name: 'blackbox'
    metrics_path: /probe
    params:
      module: [http_2xx]  
    static_configs:
      - targets:
        - https://www.google.com
        - https://www.facebook.com
        - https://www.amazon.com
        - https://www.wikipedia.org
        - https://www.reddit.com
        - https://www.youtube.com
        - https://www.twitter.com
        - https://www.linkedin.com
        - https://www.instagram.com
        - https://www.netflix.com
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9115  
EOF

chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

# Prometheus Service
cat <<EOF > /etc/systemd/system/prometheus.service
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
--config.file=/etc/prometheus/prometheus.yml \
--storage.tsdb.path=/var/lib/prometheus/ \
--web.console.templates=/etc/prometheus/consoles \
--web.console.libraries=/etc/prometheus/console_libraries

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the Prometheus service
systemctl daemon-reload
systemctl enable prometheus
systemctl start prometheus

# Install and configure Thanos
wget https://github.com/thanos-io/thanos/releases/download/v0.23.1/thanos-0.23.1.linux-amd64.tar.gz
tar -xzf thanos-0.23.1.linux-amd64.tar.gz
cp thanos-0.23.1.linux-amd64/thanos /usr/local/bin

# Thanos Sidecar Service
cat <<EOF > /etc/systemd/system/thanos-sidecar.service
[Unit]
Description=Thanos Sidecar
Wants=network-online.target
After=network-online.target prometheus.service

[Service]
Type=simple
ExecStart=/usr/local/bin/thanos sidecar \
  --tsdb.path /var/lib/prometheus/ \
  --prometheus.url http://localhost:9090 \
  --objstore.config-file=/path/to/bucket_config.yaml \
  --http-address 0.0.0.0:19190 \
  --grpc-address 0.0.0.0:19090

[Install]
WantedBy=multi-user.target
EOF

# Create S3 bucket config file
cat <<EOF > /path/to/bucket_config.yaml
type: S3
config:
  bucket: "your-s3-bucket-name"
  endpoint: "s3.amazonaws.com"
  access_key: "your-access-key"
  secret_key: "your-secret-key"
  insecure: false
  signature_version2: false
  encrypt_sse: false
  put_user_metadata: {}
  http_config:
    idle_conn_timeout: 90s
    response_header_timeout: 2m
    insecure_skip_verify: false
  trace:
    enable: false
  part_size: 134217728
EOF

# Enable and start Thanos Sidecar service
systemctl daemon-reload
systemctl enable thanos-sidecar
systemctl start thanos-sidecar

# Ensure all services are started
systemctl start aws-otel-collector
systemctl start jaeger
systemctl start node_exporter
systemctl start prometheus
systemctl start thanos-sidecar
