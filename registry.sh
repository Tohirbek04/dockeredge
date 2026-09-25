#!/usr/bin/env bash
# Registry credentials Watchtower uses to pull private images.
# Stored in ./registry (git-ignored), separate from ~/.docker, so a later
# `docker login` by someone else on the server can't replace them.
#
#   ./registry.sh login [REGISTRY]    log in (default ghcr.io)
#   ./registry.sh logout REGISTRY     remove a stored login
#   ./registry.sh check IMAGE...      verify the stored logins can pull each image
#   ./registry.sh list                registries currently logged in
#
# GHCR needs only a token: put GHCR_TOKEN=<classic PAT, read:packages> in .env
# (or export it) and the username is looked up from the token. One token reads
# every package your account can see: your own, your organizations', and packages
# other accounts shared with you (or whose repos you collaborate on).
# Other registries: REGISTRY_USER=… REGISTRY_TOKEN=… ./registry.sh login docker.io
set -euo pipefail

cd "$(dirname "$0")"

dir=registry
auths="$dir/auths" # one file per registry host holding base64(user:token)
mkdir -p "$auths"
chmod 700 "$dir" "$auths"

die() {
  printf '\033[31m✖ %s\033[0m\n' "$*" >&2
  exit 1
}
ok() { printf '\033[32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }

get_env() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true; }

# GitHub username behind a token, plus a scope sanity check. Classic PATs report
# their scopes in X-OAuth-Scopes; fine-grained ones report none and can't read
# packages owned by other accounts.
github_user() {
  local token="$1" headers body scopes login
  command -v curl >/dev/null || die "curl is required to look up the GitHub user (or set GHCR_USER)"
  headers="$(mktemp)"
  if ! body="$(curl -fsS -D "$headers" -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" https://api.github.com/user)"; then
    rm -f "$headers"
    die "GitHub rejected the token (expired, revoked, or mistyped)"
  fi
  scopes="$(grep -i '^x-oauth-scopes:' "$headers" | cut -d: -f2- | tr -d '\r' || true)"
  rm -f "$headers"
  if [[ -z "${scopes// /}" ]]; then
    warn "not a classic token (or it has no scopes). It may fail on packages owned by other accounts"
  elif [[ "$scopes" != *packages* ]]; then
    die "token has no read:packages scope (it has:${scopes})"
  fi
  login="$(printf '%s' "$body" | grep -o '"login": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  [[ -n "$login" ]] || die "could not read the username from GitHub's response"
  printf '%s' "$login"
}

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# Docker Hub's credentials live under a legacy key, not its hostname.
config_key() {
  case "$1" in
    docker.io | index.docker.io | registry-1.docker.io) echo "https://index.docker.io/v1/" ;;
    *) echo "$1" ;;
  esac
}

# Rebuild config.json from auths/. Credentials are written inline on purpose:
# `docker login` may hand them to a host credential helper (osxkeychain, pass,
# secretservice) that doesn't exist inside the Watchtower container.
render_config() {
  local tmp file first=1
  tmp="$(mktemp "$dir/.config.XXXXXX")"
  {
    printf '{\n  "auths": {'
    for file in "$auths"/*; do
      [[ -f "$file" ]] || continue
      [[ $first -eq 1 ]] || printf ','
      first=0
      printf '\n    "%s": { "auth": "%s" }' "$(config_key "$(basename "$file")")" "$(cat "$file")"
    done
    printf '\n  }\n}\n'
  } >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$dir/config.json"
}

restart_watchtower() {
  # Watchtower re-reads the file on every poll; restart so it applies right away.
  if docker inspect watchtower >/dev/null 2>&1; then
    docker restart watchtower >/dev/null
    ok "watchtower restarted"
  fi
}

cmd_login() {
  local registry="${1:-ghcr.io}" user="${REGISTRY_USER:-}" token="${REGISTRY_TOKEN:-}" probe
  if [[ "$registry" == ghcr.io ]]; then
    token="${token:-${GHCR_TOKEN:-$(get_env GHCR_TOKEN)}}"
    user="${user:-${GHCR_USER:-$(get_env GHCR_USER)}}"
    if [[ -z "$token" ]]; then
      [[ -t 0 ]] || die "set GHCR_TOKEN in .env (classic PAT with read:packages)"
      read -r -s -p "GitHub token (classic, read:packages): " token
      echo
    fi
    [[ -n "$user" ]] || user="$(github_user "$token")"
  elif [[ -z "$user" || -z "$token" ]]; then
    [[ -t 0 ]] || die "set REGISTRY_USER and REGISTRY_TOKEN for non-interactive login"
    [[ -n "$user" ]] || read -r -p "$registry username: " user
    [[ -n "$token" ]] || { read -r -s -p "$registry token: " token; echo; }
  fi

  # Validate against the registry in a throwaway config, then log out so nothing
  # lingers in a host credential helper.
  probe="$(mktemp -d)"
  if ! printf '%s' "$token" | docker --config "$probe" login "$registry" -u "$user" --password-stdin >/dev/null 2>"$probe/err"; then
    cat "$probe/err" >&2
    rm -rf "$probe"
    die "login to $registry failed — check the username and token"
  fi
  docker --config "$probe" logout "$registry" >/dev/null 2>&1 || true
  rm -rf "$probe"

  printf '%s:%s' "$user" "$token" | base64 | tr -d '\n' >"$auths/$registry"
  chmod 600 "$auths/$registry"
  render_config
  ok "logged in to $registry as $user"
  restart_watchtower
}

cmd_logout() {
  local registry="${1:?usage: ./registry.sh logout REGISTRY}"
  [[ -f "$auths/$registry" ]] || die "not logged in to $registry"
  rm -f "$auths/$registry"
  render_config
  ok "logged out of $registry"
  restart_watchtower
}

cmd_check() {
  [[ $# -gt 0 ]] || die "usage: ./registry.sh check IMAGE..."
  local image failed=0
  for image in "$@"; do
    if docker --config "$dir" manifest inspect "$image" >/dev/null 2>&1; then
      ok "$image"
    else
      printf '\033[31m✖ %s — no access (not logged in, token lacks read:packages, or not shared with you)\033[0m\n' "$image"
      failed=1
    fi
  done
  return "$failed"
}

cmd_list() {
  local hosts
  hosts="$(ls -1 "$auths")"
  echo "${hosts:-(none)}"
}

[[ -f "$dir/config.json" ]] || render_config

case "${1:-}" in
  login) shift; cmd_login "$@" ;;
  logout) shift; cmd_logout "$@" ;;
  check) shift; cmd_check "$@" ;;
  list) cmd_list ;;
  -h | --help | "") usage ;;
  *) usage 1 ;;
esac
