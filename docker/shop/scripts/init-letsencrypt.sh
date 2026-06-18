#!/usr/bin/env sh
# ============================================================
# Let's Encrypt 최초 인증서 발급 부트스트랩 (닭-달걀 해소)
# nginx 443은 인증서 파일이 있어야 기동 → 임시 self-signed로 먼저 띄우고
# certbot webroot로 실 인증서 발급 후 교체·reload.
#
# 실행(운영 호스트, docker/shop/ 에서):
#   chmod +x scripts/init-letsencrypt.sh && ./scripts/init-letsencrypt.sh
# 전제: .env 작성 완료(SHOP_DOMAIN, LETSENCRYPT_EMAIL), secrets/kek.b64 배치.
# 환경변수: STAGING=1 이면 LE 스테이징(레이트리밋 회피·테스트용).
# ============================================================
set -eu

COMPOSE="docker compose -f docker-compose.prod.yml"
ENV_FILE=".env"

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE 없음. .env.prod.example 참고해 작성하세요."; exit 1; }
# shellcheck disable=SC1090
. "./$ENV_FILE"
: "${SHOP_DOMAIN:?.env에 SHOP_DOMAIN 설정}"
: "${LETSENCRYPT_EMAIL:?.env에 LETSENCRYPT_EMAIL 설정}"

CERT_PATH="/etc/letsencrypt/live/${SHOP_DOMAIN}"

echo "### 1) 더미 인증서 생성(nginx 443 기동용) — ${SHOP_DOMAIN}"
$COMPOSE run --rm --entrypoint "sh -c \"\
  mkdir -p ${CERT_PATH} && \
  openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout ${CERT_PATH}/privkey.pem \
    -out ${CERT_PATH}/fullchain.pem \
    -subj '/CN=${SHOP_DOMAIN}'\"" shop-certbot

echo "### 2) nginx 기동(80 챌린지 + 443 더미 인증서)"
# --force-recreate: 직전 크래시 루프(인증서 부재) 컨테이너가 백오프 상태로 남아 있으면
# 단순 up -d는 재생성하지 않아 80포트가 LISTEN되지 않는다. 그 상태로 certbot을 돌리면
# ACME HTTP-01 챌린지가 Connection refused로 실패한다. 강제 재생성으로 80 서빙을 보장한다.
$COMPOSE up -d --force-recreate shop-nginx

echo "### 3) 더미 인증서 삭제 후 실 인증서 발급(webroot HTTP-01)"
$COMPOSE run --rm --entrypoint "sh -c \"rm -rf ${CERT_PATH}\"" shop-certbot

STAGING_ARG=""
[ "${STAGING:-0}" = "1" ] && STAGING_ARG="--staging" && echo "    (LE STAGING 모드)"

$COMPOSE run --rm --entrypoint "certbot certonly --webroot -w /var/www/certbot \
  ${STAGING_ARG} \
  -d ${SHOP_DOMAIN} \
  --email ${LETSENCRYPT_EMAIL} \
  --rsa-key-size 4096 \
  --agree-tos --no-eff-email --non-interactive" shop-certbot

echo "### 4) nginx reload(실 인증서 픽업)"
$COMPOSE exec shop-nginx nginx -s reload

echo "### 완료. 전체 스택 기동: $COMPOSE up -d --build"
