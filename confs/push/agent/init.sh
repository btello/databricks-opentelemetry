#!/bin/bash

set -euxo pipefail

initialize_env() {
	apt install -y gettext
	export SPARK_NODE_IP=$(hostname -I | awk '{print $1}')
}

# Function to generate config based on node type
generate_config() {
	local is_driver=$1
	local config_path="/databricks/otelcol/config.yaml"
	local receiver_config="    - job_name: \"spark_metrics\"
          scrape_interval: 10s
          metrics_path: \"/metrics/prometheus\"
          static_configs:
            - targets: [\"${SPARK_NODE_IP}:40001\"]"

	if [[ "$is_driver" == "TRUE" ]]; then
		receiver_config+="\n        - job_name: \"spark_exec_agg_metrics\"
          scrape_interval: 10s
          metrics_path: \"/metrics/executors/prometheus\"
          static_configs:
            - targets: [\"${SPARK_NODE_IP}:40001\"]"
	fi

	cat <<EOF >$config_path
extensions:
  bearertokenauth:
    scheme: "Bearer"
    token: "\${DB_API_TOKEN}"

receivers:
  hostmetrics:
    collection_interval: 10s
    scrapers:
      cpu:
      memory:
      disk:
      load:
        cpu_average: true
      filesystem:
      network:
      process:
      paging:
      processes:

  prometheus:
    config:
      scrape_configs:
$receiver_config

exporters:
  otlphttp:
    endpoint: "\${OTLP_HTTP_ENDPOINT}"
    auth:
      authenticator: bearertokenauth
  debug:

processors:
  attributes:
    actions:
      - key: databricks_cluster_id
        value: \${DB_CLUSTER_ID}
        action: insert
      - key: databricks_cluster_name
        value: \${DB_CLUSTER_NAME}
        action: insert
      - key: databricks_is_driver
        value: \${DB_IS_DRIVER}
        action: insert

service:
  extensions: [bearertokenauth]
  pipelines:
    metrics:
      receivers: [hostmetrics, prometheus]
      processors: [attributes]
      exporters: [debug, otlphttp]
EOF
}

setup_otelcol() {
	mkdir -p /databricks/otelcol/
	cp /dbfs/databricks-otelcol/databricks-otelcol /databricks/otelcol/

	cat <<'EOT' | sudo tee /etc/systemd/system/databricks-otelcol.service
[Unit]
Description=Databricks OpenTelemetry Collector Service
After=network.target

[Service]
Type=simple
WorkingDirectory=/databricks/otelcol
ExecStart=/databricks/otelcol/databricks-otelcol --config /databricks/otelcol/config.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOT

	sudo systemctl daemon-reload
	sudo systemctl enable databricks-otelcol.service
	sudo systemctl start databricks-otelcol.service
}

# Function to initialize Spark Prometheus Servlet
init_spark_prometheus_servelet() {
	cat <<EOF >/databricks/spark/conf/metrics.properties
*.source.jvm.class=org.apache.spark.metrics.source.JvmSource
*.sink.prometheusServlet.class=org.apache.spark.metrics.sink.PrometheusServlet
*.sink.prometheusServlet.path=/metrics/prometheus
master.sink.prometheusServlet.path=/metrics/master/prometheus
applications.sink.prometheusServlet.path=/metrics/applications/prometheus
EOF
}

# Function to set Spark configurations
set_spark_confs() {
	local SPARK_DEFAULTS_CONF_PATH="/databricks/driver/conf/00-databricks-otel.conf"

	cat <<EOF >>$SPARK_DEFAULTS_CONF_PATH
"spark.executor.processTreeMetrics.enabled" = "true"
"spark.metrics.appStatusSource.enabled" = "true"
"spark.metrics.namespace" = ""
"spark.sql.streaming.metricsEnabled" = "true"
"spark.ui.prometheus.enabled" = "true"
EOF
}

initialize_env
generate_config "$DB_IS_DRIVER"
set_spark_confs
init_spark_prometheus_servelet
setup_otelcol