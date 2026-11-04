#!/usr/bin/env bash
# LP変更時だけ動かすデプロイ検証スクリプト（トークン消費ゼロ / モデル呼び出しなし）
#
#   bash work/lp/deploy.sh              # 検証のみ（公開ページがローカルと一致するか + 内容チェック）
#   bash work/lp/deploy.sh --push "msg" # 変更をcommit&pushしてから、デプロイ完了を待って検証
#   bash work/lp/deploy.sh --wait 300   # 待ち時間の上限秒（既定240）
#
# 判定: 公開 index.html / tokusho.html / privacy.html の sha256 がローカルのHEADと一致すること。
set -uo pipefail
cd "$(dirname "$0")" || exit 2

BASE_URL="https://basediscipline.github.io/basediscipline/"
WAIT_MAX=240
FORCE_PUSH=0
MSG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --push) FORCE_PUSH=1; shift; [ $# -gt 0 ] && { MSG="$1"; shift; } ;;
    --wait) WAIT_MAX="${2:-240}"; shift 2 ;;
    *) MSG="$1"; shift ;;
  esac
done

say() { printf '%s\n' "$*"; }

# 二重起動よけ（hook と手動実行が重なっても1本だけ動かす）
exec 9>"$PWD/.deploy.lock"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || { say "== 検証は実行中。スキップ"; exit 0; }
fi
say "== $(date -u '+%Y-%m-%dT%H:%M:%SZ') deploy check"

if [ "$FORCE_PUSH" = "1" ]; then
  if [ -n "$(git status --porcelain)" ]; then
    git add -A || exit 2
    git commit -m "${MSG:-chore(lp): update}" || exit 2
  fi
  say "== push"
  TOKF=/home/node/.openclaw/workspace/work/secrets/github_token.txt
  if [ -s "$TOKF" ]; then
    TOK=$(tr -d '\r\n' < "$TOKF")
    git push "https://x:${TOK}@github.com/basediscipline/basediscipline.git" HEAD:main || { say "!! push 失敗（認証トークン切れの可能性）"; exit 3; }
  elif ! git push origin main; then
    say "!! push 失敗（認証トークン未設定: $TOKF）"
    exit 3
  fi
fi

want_index=$(sha256sum index.html | cut -d' ' -f1)
say "== 公開反映を待機（最大 ${WAIT_MAX}s）"
say "   local index.html = ${want_index:0:12}"

elapsed=0
ok=0
while [ "$elapsed" -lt "$WAIT_MAX" ]; do
  got=$(curl -s -m 20 -A "lp-check/1.0" "${BASE_URL}" | sha256sum | cut -d' ' -f1)
  if [ "$got" = "$want_index" ]; then ok=1; break; fi
  sleep 10
  elapsed=$((elapsed + 10))
done

if [ "$ok" != "1" ]; then
  say "!!  ${WAIT_MAX}s 待っても公開ページが更新されない（デプロイ未完了 or ビルド失敗）"
  say "    live=${got:0:12} / local=${want_index:0:12}"
  exit 4
fi
say "== 反映OK（${elapsed}s）"

mismatch=0
for p in tokusho.html privacy.html; do
  a=$(sha256sum "$p" | cut -d' ' -f1)
  b=$(curl -s -m 20 -A "lp-check/1.0" "${BASE_URL}${p}" | sha256sum | cut -d' ' -f1)
  if [ "$a" != "$b" ]; then say "!!  ${p} がローカルと不一致"; mismatch=1; fi
done
[ "$mismatch" = "1" ] && exit 5
say "== 3ページとも一致"

say "== 内容チェック"
if python3 ../lp_check.py --force; then
  say "== PASS"
  exit 0
else
  say "== FAIL（上記の異常を修正）"
  exit 1
fi
