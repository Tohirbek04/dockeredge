#!/usr/bin/env bash
# dockeredge bootstrap — idempotent, safe to re-run.
#
#   ./setup.sh                                  interactive install / update
#   ./setup.sh --email you@example.com          non-interactive
#   ./setup.sh --dashboard traefik.example.com  also expose the Traefik dashboard
#   ./setup.sh --import-acme /old/acme.json     reuse certificates from a previous Traefik
set -euo pipefail

cd "$(dirname "$0")"

red() { printf '\033[31m✖ %s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m✔ %s\033[0m\n' "$*"; }
yellow() { printf '\033[33m! %s\033[0m\n' "$*"; }
die() {
  red "$*"
  exit 1
}

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

email="${LETSENCRYPT_EMAIL:-}"
dashboard_domain=""
import_acme=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --email) email="${2:?--email needs a value}"; shift 2 ;;
    --dashboard) dashboard_domain="${2:?--dashboard needs a domain}"; shift 2 ;;
    --import-acme) import_acme="${2:?--import-acme needs a path}"; shift 2 ;;
    -h | --help) usage ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

interactive() { [[ -t 0 ]]; }

# Replace (or append) KEY=VALUE in .env without disturbing other lines.
set_env() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  grep -v -E "^#? ?${key}=" .env >"$tmp" || true
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  cat "$tmp" >.env
  rm -f "$tmp"
}

get_env() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true; }

# ── 1. Preflight ────────────────────────────────────────────────────────────
command -v docker >/dev/null || die "docker is not installed — https://docs.docker.com/engine/install/"
docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin is missing"
docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon (are you in the 'docker' group, or use sudo?)"

# A traefik/watchtower container from some other compose project (e.g. an app
# that used to bundle its own) would clash on container name and ports 80/443.
for name in traefik watchtower; do
  owner="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$name" 2>/dev/null || true)"
  if docker inspect "$name" >/dev/null 2>&1 && [[ "$owner" != "$PWD" ]]; then
    die "a container named '$name' already exists (from: ${owner:-not compose}).
  Remove it from that stack first, e.g.:  docker rm -f $name
  To keep its certificates:  ./setup.sh --import-acme <that-stack>/letsencrypt/acme.json"
  fi
done

if ! docker inspect traefik >/dev/null 2>&1; then
  for port in 80 443; do
    if command -v ss >/dev/null && ss -ltnH "sport = :$port" | grep -q .; then
      die "port $port is already in use: $(ss -ltnpH "sport = :$port" | head -1)
  Stop that service (nginx/apache/caddy…) — Traefik must own ports 80 and 443."
    fi
  done
fi

# ── 2. Shared network every app stack joins ─────────────────────────────────
if ! docker network inspect shared-network >/dev/null 2>&1; then
  docker network create shared-network >/dev/null
  green "created network shared-network"
fi

# ── 3. .env ─────────────────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
  cp .env.example .env
  green "created .env from .env.example"
fi

current="$(get_env LETSENCRYPT_EMAIL)"
if [[ -z "$email" && ( -z "$current" || "$current" == REPLACE_ME* ) ]]; then
  interactive || die "set LETSENCRYPT_EMAIL (--email you@example.com)"
  read -r -p "Email for Let's Encrypt: " email
fi
if [[ -n "$email" ]]; then
  [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "invalid email: $email"
  set_env LETSENCRYPT_EMAIL "$email"
fi

# .env now may hold a token — keep it readable by the owner only.
chmod 600 .env

# Registry logins for Watchtower live in ./registry (see registry.sh).
./registry.sh list >/dev/null # creates registry/ with an empty config.json

# GHCR: the token is entered once and kept in .env; every run re-applies it, so
# rotating the token is just editing .env and re-running setup.sh.
ghcr_token="${GHCR_TOKEN:-$(get_env GHCR_TOKEN)}"
if [[ -z "$ghcr_token" ]] && interactive && [[ -z "$(ls -A registry/auths)" ]]; then
  read -r -s -p "GitHub token for private images (classic, read:packages) — Enter to skip: " ghcr_token
  echo
fi
if [[ -n "$ghcr_token" ]]; then
  [[ "$(get_env GHCR_TOKEN)" == "$ghcr_token" ]] || set_env GHCR_TOKEN "$ghcr_token"
  GHCR_TOKEN="$ghcr_token" ./registry.sh login ghcr.io
fi

# ── 4. Optional dashboard ───────────────────────────────────────────────────
if [[ -n "$dashboard_domain" ]]; then
  user="${DASHBOARD_USER:-admin}"
  password="${DASHBOARD_PASSWORD:-}"
  if [[ -z "$password" ]]; then
    interactive || die "set DASHBOARD_PASSWORD for non-interactive --dashboard"
    read -r -s -p "Dashboard password for '$user': " password
    echo
  fi
  hash="$(docker run --rm httpd:2.4-alpine htpasswd -nbB "$user" "$password" | tr -d '\r\n')"
  set_env COMPOSE_FILE "docker-compose.yml:docker-compose.dashboard.yml"
  set_env TRAEFIK_DASHBOARD_DOMAIN "$dashboard_domain"
  set_env TRAEFIK_DASHBOARD_AUTH "'$hash'"
  green "dashboard → https://$dashboard_domain (user: $user)"
fi

# ── 5. ACME storage — Traefik refuses an acme.json that isn't mode 600 ──────
mkdir -p letsencrypt
if [[ -n "$import_acme" ]]; then
  [[ -s "$import_acme" ]] || die "no such file (or empty): $import_acme"
  cp "$import_acme" letsencrypt/acme.json
  green "imported certificates from $import_acme"
fi
touch letsencrypt/acme.json
chmod 600 letsencrypt/acme.json

# ── 6. Start ────────────────────────────────────────────────────────────────
docker compose pull --quiet
docker compose up -d --remove-orphans
docker compose ps

cat <<EOF

$(green "dockeredge is up")
Next: connect an app — see "Connect your app" in README.md, and point the
app's domain (DNS A record) at this server.
Check image access:  ./registry.sh check <image>
Logs:  docker compose logs -f traefik
EOF
