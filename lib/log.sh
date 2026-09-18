#!/usr/bin/env bash
# Journal JSONL des décisions (spec §9).
# Dépend de prefilter_redact : aucune commande ne part en clair sur disque.

JEV_GUARD_LOG=${JEV_GUARD_LOG:-$HOME/.claude/logs/jev-guard.jsonl}

_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  else
    sha256sum | cut -d' ' -f1
  fi
}

log_decision() {
  local tool=$1 cmd=$2 source=$3 verdict=$4 regex_verdict=$5
  local scores=$6 confidence=$7 latency=$8
  local cause="${9:-}"

  mkdir -p "$(dirname "$JEV_GUARD_LOG")" 2>/dev/null || return 0

  local redige somme accord
  redige=$(prefilter_redact "$cmd")
  somme=$(printf '%s' "$cmd" | _sha256)
  if [ "$verdict" = "$regex_verdict" ]; then accord=true; else accord=false; fi

  jq -nc \
    --arg  ts            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg  tool          "$tool" \
    --arg  cmd_sha256    "$somme" \
    --arg  cmd_redacted  "$redige" \
    --arg  source        "$source" \
    --arg  verdict       "$verdict" \
    --arg  regex_verdict "$regex_verdict" \
    --argjson agreed     "$accord" \
    --argjson scores     "${scores:-null}" \
    --argjson confidence "${confidence:-null}" \
    --argjson latency_ms "${latency:-null}" \
    --arg  cause         "$cause" \
    '{$ts,$tool,$cmd_sha256,$cmd_redacted,$source,$verdict,
      $regex_verdict,$agreed,$scores,$confidence,$latency_ms,$cause}' \
    >> "$JEV_GUARD_LOG" 2>/dev/null || true
}
