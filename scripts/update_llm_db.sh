#!/usr/bin/env bash
# Update the llm_db model catalog with latest data from upstream sources.
#
# - Clones/updates llm_db from GitHub into ~/.cache/llm_db
# - Checks which API credentials are available
# - Pulls only from sources with valid credentials (+ public sources)
# - Builds the snapshot via ETL pipeline
# - Validates the manifest
# - Copies updated provider data back to quoracle's deps/llm_db
#
# Usage:
#   ./scripts/update_llm_db.sh
#   ./scripts/update_llm_db.sh --dry-run   # Check credentials only, don't pull

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="${HOME}/.cache/llm_db"
REPO_URL="https://github.com/agentjido/llm_db.git"
DEPS_LLMDB="${PROJECT_DIR}/deps/llm_db"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
  esac
done

# --- Output helpers ---
info() { echo -e "\033[0;34m[INFO]\033[0m $*"; }
ok()   { echo -e "\033[0;32m  ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m  ⚠\033[0m $*"; }
fail() { echo -e "\033[0;31m  ✗\033[0m $*"; }
step() { echo -e "\n\033[1;37m── $* ──\033[0m"; }

# ==========================================================================
# Step 1: Load environment
# ==========================================================================
step "Loading environment"

# Source .env files if they exist (quoracle's, then llm_db cache's)
for envfile in "${PROJECT_DIR}/.env" "${HOME}/.env"; do
  if [[ -f "$envfile" ]]; then
    info "Sourcing $envfile"
    set -a
    # shellcheck disable=SC1090
    source "$envfile"
    set +a
  fi
done

# ==========================================================================
# Step 2: Check credentials
# ==========================================================================
step "Checking API credentials"

declare -A SOURCE_KEYS
SOURCE_KEYS=(
  [openai]="OPENAI_API_KEY"
  [anthropic]="ANTHROPIC_API_KEY"
  [google]="GOOGLE_API_KEY GEMINI_API_KEY"
  [xai]="XAI_API_KEY"
  [zenmux]="ZENMUX_API_KEY"
)

# Public sources (no key needed)
PULL_SOURCES=("models_dev")
ok "models_dev — public API, no key needed"

# Check each keyed source
for source in openai anthropic google xai zenmux; do
  found=false
  found_var=""
  for var in ${SOURCE_KEYS[$source]}; do
    val="${!var:-}"
    if [[ -n "$val" ]]; then
      found=true
      found_var="$var"
      break
    fi
  done

  if $found; then
    ok "$source — credential found (\$$found_var)"
    PULL_SOURCES+=("$source")
  else
    warn "$source — no credential, skipping (set \$${SOURCE_KEYS[$source]%% *})"
  fi
done

echo ""
info "Will pull from: ${PULL_SOURCES[*]}"

if $DRY_RUN; then
  info "Dry run — exiting before pull."
  exit 0
fi

# ==========================================================================
# Step 3: Clone or update llm_db
# ==========================================================================
step "Preparing llm_db workspace"

if [[ -d "${CACHE_DIR}/.git" ]]; then
  info "Updating existing clone at $CACHE_DIR"
  git -C "$CACHE_DIR" fetch origin
  git -C "$CACHE_DIR" reset --hard origin/main
else
  info "Cloning $REPO_URL → $CACHE_DIR"
  mkdir -p "$(dirname "$CACHE_DIR")"
  git clone --depth 1 "$REPO_URL" "$CACHE_DIR"
fi

# ==========================================================================
# Step 4: Install deps (MIX_ENV=prod to skip git_hooks)
# ==========================================================================
step "Installing dependencies (MIX_ENV=prod — no git_hooks)"

cd "$CACHE_DIR"

# CRITICAL: Use prod env so git_hooks (only: :dev) is never compiled or
# installed. This prevents any interaction with git hooks or
# creation of git_hooks.db files.
MIX_ENV=prod mix deps.get --quiet 2>/dev/null
MIX_ENV=prod mix compile --quiet 2>/dev/null

ok "Dependencies ready"

# ==========================================================================
# Step 5: Pull from each source individually
# ==========================================================================
step "Pulling model data from upstream sources"

pull_ok=0
pull_fail=0

for source in "${PULL_SOURCES[@]}"; do
  info "Pulling from $source..."
  if MIX_ENV=prod mix llm_db.pull --source "$source" 2>&1; then
    pull_ok=$((pull_ok + 1))
  else
    fail "$source pull failed"
    pull_fail=$((pull_fail + 1))
  fi
  echo ""
done

info "Pull complete: $pull_ok succeeded, $pull_fail failed"

if [[ $pull_ok -eq 0 ]]; then
  fail "No sources pulled successfully. Aborting build."
  exit 1
fi

# ==========================================================================
# Step 6: Build snapshot
# ==========================================================================
step "Building snapshot"

MIX_ENV=prod mix llm_db.build

# ==========================================================================
# Step 7: Validate manifest
# ==========================================================================
step "Validating manifest"

MANIFEST="${CACHE_DIR}/priv/llm_db/manifest.json"
PROVIDERS_DIR="${CACHE_DIR}/priv/llm_db/providers"

# Check manifest exists and is valid JSON
if [[ ! -f "$MANIFEST" ]]; then
  fail "Manifest not found at $MANIFEST"
  exit 1
fi

# Validate JSON structure using Elixir (available in the project)
validation=$(MIX_ENV=prod mix run -e '
  manifest = File.read!("priv/llm_db/manifest.json") |> Jason.decode!()

  # Check required fields
  unless Map.has_key?(manifest, "version"), do: raise "Missing version"
  unless Map.has_key?(manifest, "providers"), do: raise "Missing providers"
  unless is_list(manifest["providers"]), do: raise "providers is not a list"

  providers = manifest["providers"]
  providers_dir = "priv/llm_db/providers"

  # Check each listed provider has a JSON file
  missing =
    Enum.filter(providers, fn p ->
      not File.exists?(Path.join(providers_dir, "#{p}.json"))
    end)

  if missing != [] do
    raise "Missing provider files: #{Enum.join(missing, ", ")}"
  end

  # Check no orphaned provider files
  on_disk =
    providers_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.map(&String.replace_suffix(&1, ".json", ""))
    |> Enum.sort()

  orphaned = on_disk -- providers

  if orphaned != [] do
    IO.puts("NOTE: #{length(orphaned)} stale provider files in cache (will not be copied)")
  end

  IO.puts("OK: manifest v#{manifest["version"]}, #{length(providers)} providers, #{length(on_disk)} files on disk")
' 2>&1)

echo "$validation"

if [[ "$validation" == *"OK:"* ]]; then
  ok "Manifest is valid"
else
  fail "Manifest validation failed"
  exit 1
fi

# ==========================================================================
# Step 8: Copy results back to quoracle deps
# ==========================================================================
step "Copying updated data to quoracle"

if [[ ! -d "$DEPS_LLMDB" ]]; then
  fail "deps/llm_db not found at $DEPS_LLMDB — run 'mix deps.get' in quoracle first"
  exit 1
fi

TARGET_PRIV="${DEPS_LLMDB}/priv/llm_db"
TARGET_GENERATED="${DEPS_LLMDB}/lib/llm_db/generated"
SOURCE_GENERATED="${CACHE_DIR}/lib/llm_db/generated/valid_providers.ex"

# Extract provider list from manifest (plain JSON parse, no mix needed)
provider_list=$(python3 -c "
import json, sys
with open('${MANIFEST}') as f:
    m = json.load(f)
for p in m['providers']:
    print(p)
")

# Wipe target providers dir and replace with exactly what the build produced.
# This prevents stale files from the git clone (or previous builds) from
# persisting and breaking the integrity check.
rm -f "${TARGET_PRIV}/providers/"*.json
cp "${MANIFEST}" "${TARGET_PRIV}/manifest.json"

provider_count=0
while IFS= read -r provider_id; do
  src="${PROVIDERS_DIR}/${provider_id}.json"
  if [[ -f "$src" ]]; then
    cp "$src" "${TARGET_PRIV}/providers/"
    provider_count=$((provider_count + 1))
  else
    warn "Provider '$provider_id' in manifest but missing from build output"
  fi
done <<< "$provider_list"

# Copy regenerated valid_providers.ex (build may have added new provider atoms)
if [[ -f "$SOURCE_GENERATED" ]]; then
  mkdir -p "$TARGET_GENERATED"
  cp "$SOURCE_GENERATED" "${TARGET_GENERATED}/valid_providers.ex"
  ok "Copied valid_providers.ex"
else
  warn "valid_providers.ex not found in build output"
fi

ok "Copied manifest + ${provider_count} provider files to ${TARGET_PRIV}"

# ==========================================================================
# Step 9: Recompile quoracle to pick up new data
# ==========================================================================
step "Recompiling quoracle"

cd "$PROJECT_DIR"
for env in dev test prod; do
  MIX_ENV=$env mix deps.compile llm_db --force
done

ok "llm_db recompiled with updated data (dev + test + prod)"

# ==========================================================================
# Step 10: Hot-reload llm_db on running server (if reachable)
# ==========================================================================
step "Hot-reloading llm_db on running server"

if cd "$PROJECT_DIR" && mix llm_db.hot_reload 2>&1; then
  ok "Running server updated — new models are live"
else
  warn "Server not reachable — will take effect on next server restart"
fi

# ==========================================================================
# Done
# ==========================================================================
step "Update complete"
