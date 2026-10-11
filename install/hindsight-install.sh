#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: rayone
# License: MIT | https://github.com/community-scripts/DevScripts/raw/main/LICENSE
# Source: https://github.com/vectorize-io/hindsight

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

var_llm_provider="${var_llm_provider:-none}"
var_llm_api_key="${var_llm_api_key:-}"
var_llm_model="${var_llm_model:-}"
var_llm_base_url="${var_llm_base_url:-}"

msg_info "Installing Dependencies"
$STD apt install -y build-essential
msg_ok "Installed Dependencies"

PG_VERSION="17" PG_MODULES="pgvector" setup_postgresql
PG_DB_NAME="hindsight" PG_DB_USER="hindsight" PG_DB_EXTENSIONS="vector,pg_trgm,btree_gin" setup_postgresql_db
fetch_and_deploy_gh_release "hindsight" "vectorize-io/hindsight" "tarball"
PYTHON_VERSION="3.11" UV_PROJECT_DIR="/opt/hindsight" setup_uv

msg_info "Setting up Hindsight API"
cd /opt/hindsight
$STD uv sync --locked --no-dev --package hindsight-api-slim --extra local-ml
msg_ok "Set up Hindsight API"

NODE_VERSION="24" setup_nodejs
fetch_and_deploy_gh_release "hindsight-ui" "vectorize-io/hindsight" "prebuild" "v$(<~/.hindsight)" "/opt/hindsight-ui" \
  "vectorize-io-hindsight-control-plane-*.tgz"

msg_info "Configuring Hindsight"
mkdir -p /opt/hindsight_data/huggingface
cat <<EOF >/opt/hindsight.env
HINDSIGHT_API_HOST=0.0.0.0
HINDSIGHT_API_PORT=8888
HINDSIGHT_API_LOG_LEVEL=info
HINDSIGHT_API_DATABASE_URL=postgresql://hindsight:${PG_DB_PASS}@127.0.0.1:5432/hindsight
HINDSIGHT_API_LLM_PROVIDER=${var_llm_provider}
${var_llm_api_key:+HINDSIGHT_API_LLM_API_KEY=${var_llm_api_key}}
${var_llm_model:+HINDSIGHT_API_LLM_MODEL=${var_llm_model}}
${var_llm_base_url:+HINDSIGHT_API_LLM_BASE_URL=${var_llm_base_url}}
HINDSIGHT_API_EMBEDDINGS_LOCAL_FORCE_CPU=true
HINDSIGHT_API_RERANKER_LOCAL_FORCE_CPU=true
HF_HOME=/opt/hindsight_data/huggingface
HF_HUB_DOWNLOAD_TIMEOUT=600
TOKENIZERS_PARALLELISM=false
PYTHONUNBUFFERED=1
EOF
chmod 600 /opt/hindsight.env
msg_ok "Configured Hindsight"

msg_info "Creating Services"
cat <<EOF >/etc/systemd/system/hindsight-api.service
[Unit]
Description=Hindsight API
Wants=network-online.target
After=network-online.target postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/hindsight
EnvironmentFile=/opt/hindsight.env
ExecStart=/opt/hindsight/.venv/bin/hindsight-api
Restart=on-failure
RestartSec=10
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF
cat <<EOF >/etc/systemd/system/hindsight-ui.service
[Unit]
Description=Hindsight Control Plane
After=network-online.target hindsight-api.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/hindsight-ui
Environment=NODE_ENV=production
ExecStart=/usr/bin/node /opt/hindsight-ui/bin/cli.js -p 8000 -H 0.0.0.0 -a http://127.0.0.1:8888
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now hindsight-api hindsight-ui
msg_ok "Created Services"

msg_info "Waiting for Hindsight API"
for _ in {1..60}; do
  curl -fsS http://127.0.0.1:8888/health >/dev/null 2>&1 && break
  sleep 5
done
curl -fsS http://127.0.0.1:8888/health >/dev/null || {
  msg_error "Hindsight API did not become healthy, see journalctl -u hindsight-api"
  exit 1
}
msg_ok "Hindsight API is healthy"

motd_ssh
customize
cleanup_lxc
