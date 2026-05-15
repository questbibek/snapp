#!/usr/bin/env bash
# Server deploy for Snapp with multi-domain (vrit.click, link.skillshikshya.com, link.vrittechnologies.com).
# Idempotent: safe to re-run. Run as root from anywhere; it cd's to /opt/snapp itself.

set -euo pipefail

PRIMARY_DOMAIN="vrit.click"
EXTRA_DOMAINS=("link.skillshikshya.com" "link.vrittechnologies.com")
ADMIN_EMAIL="bibek@vrittechnologies.com"
ADMIN_USERNAME="bibek"
INSTALL_DIR="/opt/snapp"
APP_PORT=3000

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

step() { echo; echo "==> $*"; }

step "Removing Kutt if present"
if [ -d /opt/kutt ]; then
  ( cd /opt/kutt && docker compose down -v || true )
  docker volume ls -q --filter name=kutt | xargs -r docker volume rm || true
  rm -rf /opt/kutt
fi
rm -f /etc/nginx/sites-enabled/kutt /etc/nginx/sites-available/kutt

step "Stopping any stale Snapp containers and volumes"
docker ps -a --filter "name=snapp" -q | xargs -r docker rm -f
docker volume ls -q --filter "name=snapp" | xargs -r docker volume rm 2>/dev/null || true

step "Ensuring /opt/snapp is on the latest beta-version-1"
[ -d "$INSTALL_DIR" ] || { echo "$INSTALL_DIR missing — clone the fork first." >&2; exit 1; }
cd "$INSTALL_DIR"
git fetch origin
git reset --hard origin/beta-version-1

step "Writing config/settings.yaml (all 4 disable.* fields required)"
mkdir -p config maxmind
cat > config/settings.yaml <<EOF
appname: Snapp
admin:
  - email: ${ADMIN_EMAIL}
    username: ${ADMIN_USERNAME}
hosts:
  - options:
      customRedirect: /dashboard
      disable: { homepage: false, limits: false, signup: false, twoFactor: true }
    origin: https://${PRIMARY_DOMAIN}
EOF
for d in "${EXTRA_DOMAINS[@]}"; do
  cat >> config/settings.yaml <<EOF
  - options:
      customRedirect: /dashboard
      disable: { homepage: false, limits: false, signup: false, twoFactor: true }
    origin: https://${d}
EOF
done
cat >> config/settings.yaml <<EOF
smtp:
  enabled: false
EOF

# oauth.json must be a JSON array — genericOAuth plugin calls .map() on it.
# An empty object ({}) crashes the auth init.
if [ ! -f config/oauth.json ] || ! head -c1 config/oauth.json | grep -q '\['; then
  echo '[]' > config/oauth.json
fi

step "Writing .env (no ORIGIN — let SvelteKit derive per request)"
if [ ! -f .env ] || ! grep -q '^BETTER_AUTH_SECRET=' .env; then
  BETTER_AUTH_SECRET="$(openssl rand -hex 32)"
else
  BETTER_AUTH_SECRET="$(grep '^BETTER_AUTH_SECRET=' .env | cut -d= -f2-)"
fi
cat > .env <<EOF
DATABASE_URL=postgres://root:mysecretpassword@snapp-db:5432/local
BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
PORT=${APP_PORT}
SNAPP_DEBUG=false
EOF
chmod 600 .env

step "Writing docker-compose.yml"
cat > docker-compose.yml <<EOF
services:
  snapp-db:
    image: postgres:16-alpine
    container_name: snapp-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: root
      POSTGRES_PASSWORD: mysecretpassword
      POSTGRES_DB: local
    volumes:
      - snapp-db-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U root -d local"]
      interval: 5s
      timeout: 5s
      retries: 20

  snapp:
    build: .
    container_name: snapp
    restart: unless-stopped
    env_file: .env
    ports:
      - "127.0.0.1:${APP_PORT}:${APP_PORT}"
    volumes:
      - ./config:/app/config
      - ./maxmind:/app/maxmind
    depends_on:
      snapp-db:
        condition: service_healthy

volumes:
  snapp-db-data:
EOF

step "Writing nginx site (reusing existing Let's Encrypt certs)"
ALL_DOMAINS=("${PRIMARY_DOMAIN}" "${EXTRA_DOMAINS[@]}")
SERVER_NAMES_80="${PRIMARY_DOMAIN} www.${PRIMARY_DOMAIN} ${EXTRA_DOMAINS[*]}"

find_cert_dir() {
  local target="$1"
  local dir
  for dir in /etc/letsencrypt/live/*/; do
    [ -f "${dir}fullchain.pem" ] || continue
    if openssl x509 -in "${dir}fullchain.pem" -noout -ext subjectAltName 2>/dev/null \
        | grep -qiE "DNS:${target}(,|$)"; then
      echo "${dir%/}"
      return 0
    fi
  done
  return 1
}

for d in "${ALL_DOMAINS[@]}"; do
  if ! find_cert_dir "${d}" >/dev/null; then
    echo "==> Obtaining Let's Encrypt cert for ${d}"
    certbot certonly --nginx \
      -d "${d}" \
      --email "${ADMIN_EMAIL}" \
      --agree-tos --non-interactive --keep-until-expiring \
      || echo "WARNING: certbot failed for ${d}. Check DNS A record points to this server." >&2
  fi
done

{
  cat <<EOF
server {
    listen 80;
    server_name ${SERVER_NAMES_80};
    return 301 https://\$host\$request_uri;
}
EOF
  for d in "${ALL_DOMAINS[@]}"; do
    cert_dir="$(find_cert_dir "${d}" || true)"
    if [ -z "${cert_dir}" ]; then
      echo "WARNING: no cert covers ${d}; skipping its 443 server block. Run: certbot --nginx -d ${d}" >&2
      continue
    fi
    extra_name=""
    if [ "${d}" = "${PRIMARY_DOMAIN}" ]; then
      # Only add www if the same cert also covers it
      if openssl x509 -in "${cert_dir}/fullchain.pem" -noout -ext subjectAltName 2>/dev/null \
          | grep -qiE "DNS:www\.${PRIMARY_DOMAIN}(,|$)"; then
        extra_name="www.${PRIMARY_DOMAIN}"
      fi
    fi
    cat <<EOF
server {
    listen 443 ssl http2;
    server_name ${d} ${extra_name};
    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/privkey.pem;
    client_max_body_size 25m;
    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
  done
} > /etc/nginx/sites-available/snapp

ln -sf /etc/nginx/sites-available/snapp /etc/nginx/sites-enabled/snapp
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

step "Building and starting Snapp (this takes a few minutes)"
# Explicit -f because the repo also ships a dev-only compose.yaml.
docker compose -f docker-compose.yml up -d --build

step "Done. Tailing logs — capture the admin password line."
echo
echo "Look for:  [auth] generated admin ${ADMIN_USERNAME}"
echo "           Password: <save this>"
echo
echo "Three [init] created organization lines should appear, one per host."
echo
docker logs -f snapp
