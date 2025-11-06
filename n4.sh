#!/usr/bin/env bash
set -euo pipefail

# ===== Ensure interactive reads =====
if [[ ! -t 0 ]] && [[ -e /dev/tty ]]; then
  exec </dev/tty
fi

# ===== Logging =====
LOG_FILE="/tmp/n4_cloudrun_$(date +%s).log"
touch "$LOG_FILE"
on_err() {
  local rc=$?
  echo "" | tee -a "$LOG_FILE"
  echo "❌ ERROR: Command failed (exit $rc) at line $LINENO: ${BASH_COMMAND}" | tee -a "$LOG_FILE" >&2
  echo "—— LOG (last 80 lines) ——" >&2
  tail -n 80 "$LOG_FILE" >&2 || true
  echo "📄 Log File: $LOG_FILE" >&2
  exit $rc
}
trap on_err ERR

# ===== Colors & UI =====
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RESET=$'\e[0m'; BOLD=$'\e[1m'; C_CYAN=$'\e[38;5;44m'
  C_BLUE=$'\e[38;5;33m'; C_GREEN=$'\e[38;5;46m'
  C_ORG=$'\e[38;5;214m'; C_GREY=$'\e[38;5;245m'; C_RED=$'\e[38;5;196m'
else
  RESET= BOLD= C_CYAN= C_BLUE= C_GREEN= C_ORG= C_GREY= C_RED=
fi

hr(){ printf "${C_GREY}%s${RESET}\n" "──────────────────────────────────────────────"; }
banner(){ printf "\n${C_BLUE}${BOLD}╔══════════════════════════════════════════════════╗${RESET}\n${C_BLUE}${BOLD}║${RESET}  %-46s${C_BLUE}${BOLD}║${RESET}\n${C_BLUE}${BOLD}╚══════════════════════════════════════════════════╝${RESET}\n" "$1"; }
ok(){   printf "${C_GREEN}✔${RESET} %s\n" "$1"; }
warn(){ printf "${C_ORG}⚠${RESET} %s\n" "$1"; }
err(){  printf "${C_RED}✘${RESET} %s\n" "$1"; }
kv(){   printf "   ${C_GREY}%s${RESET}  %s\n" "$1" "$2"; }

printf "\n${C_CYAN}${BOLD}🚀 N4 Cloud Run — One-Click Deploy${RESET} ${C_GREY}(Trojan / VLESS / VMess)${RESET}\n"
hr

# ===== Progress Spinner =====
run_with_progress() {
  local label="$1"; shift
  ( "$@" ) >>"$LOG_FILE" 2>&1 &
  local pid=$!
  local pct=5
  if [[ -t 1 ]]; then
    printf "\e[?25l"
    while kill -0 "$pid" 2>/dev/null; do
      local step=$(( (RANDOM % 9) + 2 ))
      pct=$(( pct + step ))
      (( pct > 95 )) && pct=95
      printf "\r🌀 %s... [%s%%]" "$label" "$pct"
      sleep "$(awk -v r=$RANDOM 'BEGIN{s=0.08+(r%7)/100; printf "%.2f", s }')"
    done
    wait "$pid"; local rc=$?
    printf "\r"
    if (( rc==0 )); then
      printf "✅ %s... [100%%]\n" "$label"
    else
      printf "❌ %s failed (see %s)\n" "$label" "$LOG_FILE"
      return $rc
    fi
    printf "\e[?25h"
  else
    wait "$pid"
  fi
}

# ===== Step 1: Telegram Setup =====
banner "🚀 Step 1 — Telegram Setup"
read -rp "🤖 Telegram Bot Token: " TELEGRAM_TOKEN || true
read -rp "👤 Chat ID(s) (comma-separated): " TELEGRAM_CHAT_IDS || true

# Optional button setup
BTN_LABELS=(); BTN_URLS=()
read -rp "➕ Add Telegram buttons? [y/N]: " _add || true
if [[ "${_add,,}" =~ ^(y|yes)$ ]]; then
  for i in 1 2 3; do
    read -rp "🔖 Button $i label: " lbl || true
    read -rp "🔗 Button $i URL (https://...): " url || true
    [[ -n "$lbl" && "$url" =~ ^https?:// ]] && BTN_LABELS+=("$lbl") && BTN_URLS+=("$url")
    read -rp "➕ Add another? [y/N]: " more || true
    [[ "${more,,}" =~ ^(y|yes)$ ]] || break
  done
fi

CHAT_ID_ARR=(); IFS=',' read -r -a CHAT_ID_ARR <<< "${TELEGRAM_CHAT_IDS:-}"

json_escape(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

tg_send(){
  local text="$1" RM=""
  (( ${#CHAT_ID_ARR[@]} == 0 )) && return 0
  if (( ${#BTN_LABELS[@]} > 0 )); then
    local parts=()
    for ((i=0; i<${#BTN_LABELS[@]}; i++)); do
      local L="$(json_escape "${BTN_LABELS[$i]}")"
      local U="$(json_escape "${BTN_URLS[$i]}")"
      parts+=("{\"text\":\"${L}\",\"url\":\"${U}\"}")
    done
    RM="{\"inline_keyboard\":[[${parts[*]}]]}"
    RM=$(echo "$RM" | tr -d '\n')
  fi
  for id in "${CHAT_ID_ARR[@]}"; do
    curl -s -S -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      -d "chat_id=${id}" \
      --data-urlencode "text=${text}" \
      -d "parse_mode=HTML" \
      ${RM:+--data-urlencode "reply_markup=${RM}"} >>"$LOG_FILE" 2>&1
    ok "Telegram sent → ${id}"
  done
}

# ===== Step 2: Project =====
banner "🧭 Step 2 — GCP Project"
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
[[ -z "$PROJECT" ]] && err "No active project. Run: gcloud config set project <project_id>" && exit 1
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)' 2>/dev/null || true)"
PROJECT_NUMBER="${PROJECT_NUMBER:-$(gcloud projects list --filter="projectId=$PROJECT" --format='value(projectNumber)')}"
ok "Project Loaded: ${PROJECT}"

# ===== Step 3: Protocol =====
banner "🧩 Step 3 — Select Protocol"
echo "  1️⃣ Trojan WS"
echo "  2️⃣ VLESS WS"
echo "  3️⃣ VLESS gRPC"
echo "  4️⃣ VMess WS"
read -rp "Choose [1-4, default 1]: " _opt || true
case "${_opt:-1}" in
  2) PROTO="vless-ws"   ; IMAGE="docker.io/n4pro/vl:latest" ;;
  3) PROTO="vless-grpc" ; IMAGE="docker.io/n4pro/vlessgrpc:latest" ;;
  4) PROTO="vmess-ws"   ; IMAGE="docker.io/n4pro/vmess:latest" ;;
  *) PROTO="trojan-ws"  ; IMAGE="docker.io/n4pro/tr:latest" ;;
esac
ok "Protocol selected: ${PROTO^^}"

# ===== Step 4: Region =====
banner "🌍 Step 4 — Region"
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

# ===== Step 5: Resources =====
banner "🧮 Step 5 — Resources"
read -rp "CPU [1/2/4, default 2]: " _cpu || true
CPU="${_cpu:-2}"
read -rp "Memory [512Mi/1Gi/2Gi(default)/4Gi]: " _mem || true
MEMORY="${_mem:-2Gi}"
ok "CPU/Mem: ${CPU} vCPU / ${MEMORY}"

# ===== Step 6: Service =====
banner "🪪 Step 6 — Service Name"
read -rp "Service name [default: freen4vpn]: " _svc || true
SERVICE="${_svc:-freen4vpn}"
ok "Service: ${SERVICE}"

# ===== Time Setup =====
export TZ="Asia/Yangon"
START_EPOCH="$(date +%s)"
END_EPOCH="$(( START_EPOCH + 5*3600 ))"
fmt_dt(){ date -d @"$1" "+%d.%m.%Y %I:%M %p"; }
START_LOCAL="$(fmt_dt "$START_EPOCH")"
END_LOCAL="$(fmt_dt "$END_EPOCH")"

# ===== Enable APIs =====
banner "⚙️ Step 7 — Enable APIs"
run_with_progress "Enabling CloudRun APIs" gcloud services enable run.googleapis.com cloudbuild.googleapis.com --quiet

# ===== Deploy =====
banner "🚀 Step 8 — Deploying"
run_with_progress "Deploying ${SERVICE}" gcloud run deploy "$SERVICE" \
  --image="$IMAGE" \
  --platform=managed \
  --region="$REGION" \
  --memory="$MEMORY" \
  --cpu="$CPU" \
  --timeout=1800 \
  --allow-unauthenticated \
  --port=8080 \
  --min-instances=1 \
  --quiet

# ===== Result =====
CANONICAL_HOST="${SERVICE}-${PROJECT_NUMBER}.${REGION}.run.app"
URL_CANONICAL="https://${CANONICAL_HOST}"
banner "✅ Deployment Result"
ok "Service Ready"
kv "URL:" "${C_CYAN}${BOLD}${URL_CANONICAL}${RESET}"

# ===== Protocol URLs =====
TROJAN_PASS="Trojan-2025"
VLESS_UUID="0c890000-4733-b20e-067f-fc341bd20000"
VLESS_UUID_GRPC="0c890000-4733-4a0e-9a7f-fc341bd20000"
VMESS_UUID="0c890000-4733-b20e-067f-fc341bd20000"

make_vmess_ws_uri(){
  local host="$1"
  local json=$(cat <<JSON
{"v":"2","ps":"VMess-WS","add":"vpn.googleapis.com","port":"443","id":"${VMESS_UUID}","aid":"0","scy":"zero","net":"ws","type":"none","host":"${host}","path":"/trenzych","tls":"tls","sni":"vpn.googleapis.com","alpn":"http/1.1","fp":"randomized"}
JSON
)
  base64 -w0 <<<"$json" | sed 's/^/vmess:\/\//'
}

case "$PROTO" in
  trojan-ws)  URI="trojan://${TROJAN_PASS}@vpn.googleapis.com:443?path=%2Ftrenzych&security=tls&host=${CANONICAL_HOST}&type=ws#Trojan-WS" ;;
  vless-ws)   URI="vless://${VLESS_UUID}@vpn.googleapis.com:443?path=%2Ftrenzych&security=tls&encryption=none&host=${CANONICAL_HOST}&type=ws#Vless-WS" ;;
  vless-grpc) URI="vless://${VLESS_UUID_GRPC}@vpn.googleapis.com:443?mode=gun&security=tls&encryption=none&type=grpc&serviceName=trenzych-grpc&sni=${CANONICAL_HOST}#VLESS-gRPC" ;;
  vmess-ws)   URI="$(make_vmess_ws_uri "${CANONICAL_HOST}")" ;;
esac

# ===== Telegram Notify =====
banner "📣 Step 9 — Telegram Notify"
MSG=$(cat <<EOF
✅ <b>CloudRun Deploy Success</b>
━━━━━━━━━━━━━━━━━━
<blockquote>🌍 <b>Region:</b> ${REGION}
⚙️ <b>Protocol:</b> ${PROTO^^}
🔗 <b>URL:</b> <a href="${URL_CANONICAL}">${URL_CANONICAL}</a></blockquote>
<pre><code>${URI}</code></pre>
<blockquote>🕒 Start: ${START_LOCAL}
⏳ End: ${END_LOCAL}</blockquote>
━━━━━━━━━━━━━━━━━━
EOF
)
tg_send "${MSG}"

printf "\n${C_GREEN}${BOLD}✨ Done — CloudRun Warm Instance Ready!${RESET}\n"
printf "${C_GREY}📄 Log file: ${LOG_FILE}${RESET}\n"
