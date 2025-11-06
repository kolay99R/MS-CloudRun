#!/usr/bin/env bash
set -euo pipefail

# ===== Logging =====
LOG_FILE="/tmp/n4_cloudrun_$(date +%s).log"
touch "$LOG_FILE"
on_err() {
  local rc=$?
  echo "" | tee -a "$LOG_FILE"
  echo "❌ ERROR: Command failed (exit $rc) at line $LINENO: ${BASH_COMMAND}" | tee -a "$LOG_FILE" >&2
  echo "📄 Log File: $LOG_FILE" >&2
  exit $rc
}
trap on_err ERR

# ===== Colors =====
RESET=$'\e[0m'; BOLD=$'\e[1m'
C_CYAN=$'\e[38;5;44m'; C_BLUE=$'\e[38;5;33m'
C_GREEN=$'\e[38;5;46m'; C_RED=$'\e[38;5;196m'; C_GREY=$'\e[38;5;245m'

hr(){ printf "${C_GREY}%s${RESET}\n" "──────────────────────────────────────────────"; }
banner(){ printf "\n${C_BLUE}${BOLD}╔══════════════════════════════════════════════════╗${RESET}\n${C_BLUE}${BOLD}║${RESET}  %-46s${C_BLUE}${BOLD}║${RESET}\n${C_BLUE}${BOLD}╚══════════════════════════════════════════════════╝${RESET}\n" "$1"; }
ok(){   printf "${C_GREEN}✔${RESET} %s\n" "$1"; }
err(){  printf "${C_RED}✘${RESET} %s\n" "$1"; }
kv(){   printf "   ${C_GREY}%s${RESET}  %s\n" "$1" "$2"; }

printf "\n${C_CYAN}${BOLD}🚀 N4 Cloud Run — Quick Deploy${RESET}\n"
hr

# ===== Spinner =====
run_with_progress() {
  local label="$1"; shift
  ( "$@" ) >>"$LOG_FILE" 2>&1 &
  local pid=$!
  local pct=5
  if [[ -t 1 ]]; then
    printf "\e[?25l"
    while kill -0 "$pid" 2>/dev/null; do
      pct=$(( pct + (RANDOM%10+1) ))
      (( pct>95 )) && pct=95
      printf "\r🌀 %s... [%s%%]" "$label" "$pct"
      sleep 0.1
    done
    wait "$pid"; local rc=$?
    printf "\r"
    (( rc==0 )) && printf "✅ %s... [100%%]\n" "$label" || printf "❌ %s failed\n" "$label"
    printf "\e[?25h"
  else
    wait "$pid"
  fi
}

# ===== Step 1: GCP Project =====
banner "🧭 Step 1 — GCP Project"
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
[[ -z "$PROJECT" ]] && err "No active project. Run: gcloud config set project <project_id>" && exit 1
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)' 2>/dev/null || true)"
PROJECT_NUMBER="${PROJECT_NUMBER:-$(gcloud projects list --filter="projectId=$PROJECT" --format='value(projectNumber)')}"
ok "Project Loaded: ${PROJECT}"

# ===== Step 2: Protocol =====
banner "🧩 Step 2 — Select Protocol"
echo "1) Trojan WS"
echo "2) VLESS WS"
echo "3) VLESS gRPC"
echo "4) VMess WS"
read -rp "Choose [1-4, default 1]: " _opt || true
case "${_opt:-1}" in
  2) PROTO="vless-ws"; IMAGE="gcr.io/cloudrun/hello" ;;
  3) PROTO="vless-grpc"; IMAGE="gcr.io/cloudrun/hello" ;;
  4) PROTO="vmess-ws"; IMAGE="gcr.io/cloudrun/hello" ;;
  *) PROTO="trojan-ws"; IMAGE="gcr.io/cloudrun/hello" ;;
esac
ok "Protocol selected: ${PROTO^^}"

# ===== Step 3: Region =====
banner "🌍 Step 3 — Region"
echo "1) 🇸🇬 Singapore (asia-southeast1)"
echo "2) 🇺🇸 US (us-central1)"
echo "3) 🇮🇩 Indonesia (asia-southeast2)"
echo "4) 🇯🇵 Japan (asia-northeast1)"
read -rp "Choose [1-4, default 2]: " _r || true
case "${_r:-2}" in
  1) REGION="asia-southeast1";;
  3) REGION="asia-southeast2";;
  4) REGION="asia-northeast1";;
  *) REGION="us-central1";;
esac
ok "Region: ${REGION}"

# ===== Step 4: Resources =====
banner "🧮 Step 4 — Resources"
read -rp "CPU [1/2/4, default 2]: " _cpu || true
CPU="${_cpu:-2}"
read -rp "Memory [512Mi/1Gi/2Gi(default)/4Gi]: " _mem || true
MEMORY="${_mem:-2Gi}"
ok "CPU/Mem: ${CPU} vCPU / ${MEMORY}"

# ===== Step 5: Service Name =====
banner "🪪 Step 5 — Service Name"
read -rp "Service name [default: freen4vpn]: " _svc || true
SERVICE="${_svc:-freen4vpn}"
ok "Service: ${SERVICE}"

# ===== Step 6: Enable APIs =====
banner "⚙️ Step 6 — Enable APIs"
run_with_progress "Enabling CloudRun & Build APIs" \
  gcloud services enable run.googleapis.com cloudbuild.googleapis.com --quiet

# ===== Step 7: Deploy =====
banner "🚀 Step 7 — Deploying"
run_with_progress "Deploying ${SERVICE}" gcloud run deploy "$SERVICE" \
  --image="$IMAGE" \
  --platform=managed \
  --region="$REGION" \
  --memory="$MEMORY" \
  --cpu="$CPU" \
  --timeout="1800" \
  --allow-unauthenticated \
  --port=8080 \
  --min-instances=1 \
  --quiet

# ===== Step 8: Result =====
CANONICAL_HOST="${SERVICE}-${PROJECT_NUMBER}.${REGION}.run.app"
URL_CANONICAL="https://${CANONICAL_HOST}"
banner "✅ Deployment Result"
ok "Service Ready"
kv "URL:" "${C_CYAN}${BOLD}${URL_CANONICAL}${RESET}"

printf "\n${C_GREEN}${BOLD}✨ Done — CloudRun Warm Instance Ready!${RESET}\n"
printf "${C_GREY}📄 Log file: ${LOG_FILE}${RESET}\n"
