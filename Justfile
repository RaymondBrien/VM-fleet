set shell := ["bash", "-ceu"]

# ---- Files ----

compose_file := "docker-compose.yml"
fleet_key_dir := "./keys"
fleet_priv_key := fleet_key_dir + "/fleet_ed25519"
fleet_pub_key := fleet_key_dir + "/fleet_ed25519.pub"
authorized_keys_fleet := "./authorized_keys_fleet"
dockerfile := "./Dockerfile"
ssh_target_port := "22"  # passed to jq --argjson, coerced to a JSON number there

# ---- Commands ----
compose_services_cmd := "docker compose -f " + compose_file + " config --services"

# ---- FULL-FAT MAIN ENTRYPOINT ----
go: install-deps validate run list-fleet-services 
  # ping-fleet  # TODO: need to debug further as still locked out despite not using password ssh auth


# ---- Setup ----
validate-justfile:
  just --dump

# NOTE: shebang to avoid indentation issues at runtime due to Just mushing into one big script under the hood
install-deps:
  #!/usr/bin/env bash
  set -euo pipefail

  ensure_cmd() {
    local bin="$1"
    local pkg="$2"

    if command -v "$bin" >/dev/null 2>&1; then
      return 0
    fi

    case "$(uname -s)" in
      Darwin)
        brew install "$pkg"
        ;;
      Linux)
        if [ -f /etc/alpine-release ]; then
          apk add --no-cache "$pkg"
        elif [ -f /etc/debian_version ]; then
          sudo apt-get update
          sudo apt-get install -y "$pkg"
        else
          echo "Unsupported Linux distro: $(cat /etc/os-release 2>/dev/null || true)"
          exit 1
        fi
        ;;
      MINGW*|MSYS*|CYGWIN*)
        # Windows Git Bash/MSYS
        # Assumes you have choco or winget set up; otherwise do manual install.
        if command -v choco >/dev/null 2>&1; then
          choco install -y "$pkg"
        elif command -v winget >/dev/null 2>&1; then
          winget install --silent "$pkg"
        else
          echo "On Windows, install '$pkg' manually (need choco or winget)."
          exit 1
        fi
        ;;
      *)
        echo "Unsupported OS: $(uname -s)"
        exit 1
        ;;
    esac
  }

  # jq
  ensure_cmd jq jq

  # docker
  case "$(uname -s)" in
    Darwin)
      ensure_cmd docker docker
      ;;
    Linux)
      if [ -f /etc/alpine-release ]; then
        ensure_cmd docker docker-cli
      else
        ensure_cmd docker docker.io
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      echo "On Windows: install Docker Desktop/CLI manually (this recipe doesn't know your package name)."
      ;;
    *)
      :
      ;;
  esac

# Check ports for each node unique and mapped correctly
validate:
  #!/usr/bin/env bash
  set -euo pipefail

  [ -f "{{compose_file}}" ] || { echo "Missing {{compose_file}}"; exit 1; }

  command -v docker >/dev/null || { echo "docker not found"; exit 1; }
  command -v jq >/dev/null || { echo "jq not found (install jq to use validate)"; exit 1; }

  # Render config -> JSON
  cfg="$(docker compose -f "{{compose_file}}" config --format json)"

  # Extract service names from the rendered JSON
  services="$(echo "$cfg" | jq -r '.services | keys[]')"

  echo "Validating SSH port mappings (container port = {{ssh_target_port}}) for:"
  echo "$services"

  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT

  for svc in $services; do
    hosts="$(
      echo "$cfg" | jq -r --arg svc "$svc" --argjson tgt "{{ssh_target_port}}" '
        .services[$svc].ports? // []
        | map(
            select(.target == $tgt)
            | .published
          )
        | .[]
      '
    )"

    if [ -z "${hosts:-}" ]; then
      echo "ERROR: service '$svc' does not publish container port {{ssh_target_port}}"
      exit 1
    fi

    for hp in $hosts; do
      echo "$hp $svc" >> "$tmp"
    done
  done

  # Uniqueness check of host ports
  dups="$(awk '{print $1}' "$tmp" | sort | uniq -d)"

  if [ -n "${dups:-}" ]; then
    echo "ERROR: duplicate published host SSH ports detected:"
    echo "$(
      awk '{
        port=$1; svc=$2; ports[port]=ports[port] " " svc
      } END {
        for (p in ports) if (length(ports[p])>0) print p ports[p]
      }' "$tmp"
    )" | grep -E "^($(echo "$dups" | tr '\n' '|' | sed 's/|$//')) "
    echo "Collisions involve at least one of these host ports:"
    echo "$dups"
    exit 1
  fi

  echo "OK: All services publish container port {{ssh_target_port}}, and host ports are unique."


# TODO: validate for all OS's
setup-keys:
  #!/usr/bin/env bash
  set -euo pipefail

  [ -f "{{compose_file}}" ] || { echo "Missing {{compose_file}}"; exit 1; }
  [ -f "{{dockerfile}}" ] || { echo "Missing {{dockerfile}} (recommended SSH best-practice approach)"; exit 1; }
  [ -d "{{fleet_key_dir}}" ] || { echo "Missing {{fleet_key_dir}} directory"; exit 1; }
  [ -f "{{fleet_priv_key}}" ] || { echo "Missing private key: {{fleet_priv_key}}"; exit 1; }
  [ -f "{{fleet_pub_key}}" ] || { echo "Missing public key: {{fleet_pub_key}}"; exit 1; }

  if [ ! -f "{{authorized_keys_fleet}}" ]; then
    echo "Generating {{authorized_keys_fleet}} from {{fleet_pub_key}}..."
    cp "{{fleet_pub_key}}" "{{authorized_keys_fleet}}"
  fi
  [ -s "{{authorized_keys_fleet}}" ] || { echo "Missing or empty: {{authorized_keys_fleet}}"; exit 1; }

  chmod 600 "{{fleet_priv_key}}" || true
  chmod 644 "{{fleet_pub_key}}" || true
  chmod 600 "{{authorized_keys_fleet}}" || true


# ---- Main actions ----
run:
  echo "Starting fleet containers via docker compose..."
  docker compose -f "{{compose_file}}" up -d $({{compose_services_cmd}})

list-fleet-services:
  {{compose_services_cmd}}

stop:
  docker compose -f "{{compose_file}}" stop $({{compose_services_cmd}})

# ---- Testing ----

# check ssh is reachable on all nodes
# This uses a backoff approach so that 'just go' allows time for all nodes to start
# check ssh is reachable on all nodes
ping-fleet:
  #!/usr/bin/env bash
  set -euo pipefail

  cfg="$(docker compose -f "{{compose_file}}" config --format json)"

  for svc in $({{compose_services_cmd}}); do
    port="$(
      echo "$cfg" | jq -r --arg svc "$svc" --argjson tgt "{{ssh_target_port}}" '
        .services[$svc].ports? // []
        | map(select(.target == $tgt) | .published)
        | .[0] // empty
      '
    )"

    if [ -z "${port:-}" ]; then
      echo "No published host port found for ${svc}:22 in compose config"
      exit 1
    fi

    echo "Pinging SSH on ${svc} (localhost:${port})..."
    ok=""
    for i in $(seq 1 15); do
      if ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
             user@localhost -p "$port" exit 2>/dev/null; then
        ok=1
        break
      fi
      sleep 1
    done

    if [ -z "$ok" ]; then
      echo "${svc}: SSH not reachable on localhost:${port} after retries"
      exit 1
    fi

    echo "${svc}: OK"
  done

# Usage:
#   run-in-fleet 'whoami'
#   run-in-fleet 'hostname && uname -a'
# TODO: validate command first
# TODO: may want to handle command more specifically with better quoting strategy to handle pipes, spaces etc
run-in-fleet command:
  #!/usr/bin/env bash
  set -euo pipefail

  for svc in $({{compose_services_cmd}}); do
    port=$(
      docker compose -f "{{compose_file}}" port "$svc" 22 \
      | awk 'NR==1{print $2}'
    )

    if [ -z "${port:-}" ]; then
      echo "Could not determine published port for ${svc}:22"
      exit 1
    fi

    echo "Running in ${svc} via ssh user@localhost:${port}: {{command}}"
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        user@localhost -p "$port" '{{command}}'
  done


# ---- Key config ----

# Two options for rotating keys:
# 1) generate a new keypair
# 2) update keys/authorized_keys_fleet from the new public key
# 3) restart containers so they see the updated mounted authorized_keys

rotate-keys-auto:
  mkdir -p "{{fleet_key_dir}}"

  echo "Generating new fleet SSH keypair..."
  ssh-keygen -t ed25519 -f "{{fleet_priv_key}}.new" -C "fleet-ssh" -N "" 1>/dev/null

  mv -f "{{fleet_priv_key}}.new" "{{fleet_priv_key}}"
  mv -f "{{fleet_pub_key}}.new" "{{fleet_pub_key}}"

  cp "{{fleet_pub_key}}" "{{authorized_keys_fleet}}"

  chmod 600 "{{fleet_priv_key}}"
  chmod 644 "{{fleet_pub_key}}"
  chmod 600 "{{authorized_keys_fleet}}"

  echo "Restarting fleet containers so authorized_keys updates..."
  docker compose -f "{{compose_file}}" restart $({{compose_services_cmd}})

# Rotate using an already-generated keypair you provide
# Usage:
#   just rotate-keys-from path/to/new_priv path/to/new_pub
rotate-keys-from new_priv new_pub:
  [ -f "{{new_priv}}" ] || { echo "Missing private key: {{new_priv}}"; exit 1; }
  [ -f "{{new_pub}}" ] || { echo "Missing public key: {{new_pub}}"; exit 1; }

  mkdir -p "{{fleet_key_dir}}"

  echo "Installing provided new fleet SSH keypair..."
  cp -f "{{new_priv}}" "{{fleet_priv_key}}"
  cp -f "{{new_pub}}" "{{fleet_pub_key}}"

  cp "{{fleet_pub_key}}" "{{authorized_keys_fleet}}"

  chmod 600 "{{fleet_priv_key}}"
  chmod 644 "{{fleet_pub_key}}"
  chmod 600 "{{authorized_keys_fleet}}"

  echo "Restarting fleet containers so authorized_keys updates..."
  docker compose -f "{{compose_file}}" restart $({{compose_services_cmd}})


logs node:
  docker compose logs -f "{{node}}"
