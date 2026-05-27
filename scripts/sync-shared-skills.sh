#!/usr/bin/env bash
  # sync-shared-skills.sh
  # Fetch one or more SKILL.md files from a shared-skills GitHub repository
  # and place them under .local/skills/<name>/SKILL.md for the Replit Agent
  # to pick up automatically.
  #
  # Required env:
  #   SHARED_SKILLS_REPO          e.g. "locabo-data/ecforce-api_skills"
  #
  # Optional env:
  #   SHARED_SKILLS_REF           Branch / tag / SHA (default: main)
  #   SHARED_SKILLS_NAME          Space-separated skill names (default: ecforce)
  #   SHARED_SKILLS_GITHUB_TOKEN  GitHub PAT (only needed for private repos)
  #
  # Idempotent. Safe to run repeatedly. Overwrites existing SKILL.md files.

  set -euo pipefail

  : "${SHARED_SKILLS_REPO:?SHARED_SKILLS_REPO is required, e.g. locabo-data/ecforce-api_skills}"
  REF="${SHARED_SKILLS_REF:-main}"
  NAMES="${SHARED_SKILLS_NAME:-ecforce}"
  TOKEN="${SHARED_SKILLS_GITHUB_TOKEN:-}"

  API_BASE="https://api.github.com/repos/${SHARED_SKILLS_REPO}/contents"

  auth_args=()
  if [[ -n "${TOKEN}" ]]; then
    auth_args+=(-H "Authorization: Bearer ${TOKEN}")
  fi

  fetch_skill() {
    local name="$1"
    local dest_dir=".local/skills/${name}"
    local dest_file="${dest_dir}/SKILL.md"
    local url="${API_BASE}/${name}/SKILL.md?ref=${REF}"

    echo "[sync-shared-skills] ${name}: GET ${url}"
    mkdir -p "${dest_dir}"

    local http_code
    http_code=$(curl -sS -o "${dest_file}.tmp" -w "%{http_code}" \
      -H "Accept: application/vnd.github.raw" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${auth_args[@]}" \
      "${url}")

    if [[ "${http_code}" != "200" ]]; then
      echo "[sync-shared-skills] ERROR ${name}: HTTP ${http_code}" >&2
      cat "${dest_file}.tmp" >&2 || true
      rm -f "${dest_file}.tmp"
      return 1
    fi

    mv "${dest_file}.tmp" "${dest_file}"
    local size lines
    size=$(wc -c < "${dest_file}" | tr -d ' ')
    lines=$(wc -l < "${dest_file}" | tr -d ' ')
    echo "[sync-shared-skills] OK   ${name}: ${dest_file} (${size} bytes, ${lines} lines)"
  }

  failed=0
  for n in ${NAMES}; do
    fetch_skill "${n}" || failed=$((failed + 1))
  done

  if [[ "${failed}" -gt 0 ]]; then
    echo "[sync-shared-skills] ${failed} skill(s) failed" >&2
    exit 1
  fi

  echo "[sync-shared-skills] done"
  