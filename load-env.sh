#!/usr/bin/env bash
#
# load-env.sh
# AWS SSM 파라미터 스토어에서 값을 읽어 .env 파일을 생성합니다.
# docker compose up 전에 실행하세요.
#
#   사용법:  ./load-env.sh && docker compose up -d
#
# 매핑 (docker-compose 변수  <-  SSM 경로):
#   GRAFANA_ADMIN_USER      <- /pocat/prod/GRAFANA_USER
#   GRAFANA_ADMIN_PASSWORD  <- /pocat/prod/GRAFANA_PASSWORD
#   GRAFANA_DOMAIN          <- /pocat/prod/GRAFANA_DOMAIN
#   N8N_BASIC_AUTH_USER     <- /pocat/prod/N8N_AUTH_USER
#   N8N_BASIC_AUTH_PASSWORD <- /pocat/prod/N8N_AUTH_PASSWORD
#   N8N_DOMAIN              <- /pocat/prod/N8N_DOMAIN
#   MYSQL_EXPORTER_DSN      <- /pocat/prod/MYSQL_EXPORTER_DSN
#
# 사전 준비:
#   1) 위 경로로 SSM 에 값 등록
#   2) 실행 주체(EC2 인스턴스 Role 등)에 ssm:GetParameter + kms:Decrypt 권한
#   3) aws cli 설치
#
set -euo pipefail

# ===== 설정 (환경변수로 덮어쓸 수 있음) =====
SSM_PREFIX="${SSM_PREFIX:-/pocat/prod}"
REGION="${AWS_REGION:-ap-northeast-2}"
ENV_FILE="${ENV_FILE:-.env}"

# "환경변수명|SSM 경로(프리픽스 뒤)"  형식의 명시적 매핑
MAPPINGS=(
  "GRAFANA_ADMIN_USER|GRAFANA_USER"
  "GRAFANA_ADMIN_PASSWORD|GRAFANA_PASSWORD"
  "GRAFANA_DOMAIN|GRAFANA_DOMAIN"
  "N8N_BASIC_AUTH_USER|N8N_AUTH_USER"
  "N8N_BASIC_AUTH_PASSWORD|N8N_AUTH_PASSWORD"
  "N8N_DOMAIN|N8N_DOMAIN"
  "MYSQL_EXPORTER_DSN|MYSQL_EXPORTER_DSN"
  "REDIS_PASSWORD|REDIS_PASSWORD"
)

echo "🔐 SSM(${SSM_PREFIX}) 에서 환경변수 불러오는 중..."

# 안전하게 임시 파일에 먼저 쓰고, 성공하면 교체
TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

{
  echo "# 이 파일은 load-env.sh 가 SSM 에서 자동 생성합니다. 직접 수정하지 마세요."
  echo "# generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
} > "$TMP_FILE"

missing=()
for pair in "${MAPPINGS[@]}"; do
  var="${pair%%|*}"
  name="${SSM_PREFIX}/${pair#*|}"
  if value="$(aws ssm get-parameter \
                --name "$name" \
                --with-decryption \
                --region "$REGION" \
                --query "Parameter.Value" \
                --output text 2>/dev/null)"; then
    printf '%s=%s\n' "$var" "$value" >> "$TMP_FILE"
  else
    missing+=("${var}  (${name})")
  fi
done

# 못 찾은 게 있으면 어떤 건지 알려주고 중단 (.env 는 건드리지 않음)
if [ "${#missing[@]}" -gt 0 ]; then
  echo "❌ SSM 에서 못 찾은 파라미터:"
  for m in "${missing[@]}"; do echo "   - $m"; done
  exit 1
fi

# 성공 → 실제 파일로 교체하고 권한 잠그기 (소유자만 읽기/쓰기)
mv "$TMP_FILE" "$ENV_FILE"
trap - EXIT
chmod 600 "$ENV_FILE"

echo "✅ ${ENV_FILE} 생성 완료! (변수 ${#MAPPINGS[@]}개)"
