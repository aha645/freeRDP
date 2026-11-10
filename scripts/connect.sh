#!/usr/bin/env bash
# 빌드한 sdl-freerdp로 원격 데스크톱에 접속합니다.
#   사용법: bash scripts/connect.sh <사용자ID> [서버주소:포트]
#   예:     bash scripts/connect.sh aha
#           bash scripts/connect.sh aha 127.0.0.1:13389
# 서버 기본값은 SSH 터널 주소 127.0.0.1:13389 입니다. 비밀번호는 실행 중 입력합니다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
USER_ID="${1:-}"
SERVER="${2:-127.0.0.1:13389}"

[[ -n "$USER_ID" ]] || { echo "사용법: bash scripts/connect.sh <사용자ID> [서버주소:포트]" >&2; exit 1; }

EXE="$ROOT/dist/macos-$(uname -m)/sdl-freerdp"
[[ -x "$EXE" ]] || { echo "실행 파일이 없습니다: $EXE  (먼저 bash scripts/build.sh macos-$(uname -m))" >&2; exit 1; }

# 서버 포트가 열려 있는지 먼저 확인 (SSH 터널이 꺼져 있으면 바로 알림)
HOST="${SERVER%:*}" PORT="${SERVER##*:}"
if ! nc -z -w 3 "$HOST" "$PORT" 2>/dev/null; then
  cat >&2 <<EOF
$SERVER 에 연결할 수 없습니다.
다른 터미널에서 아래 명령을 입력하여 터널링을 준비해주세요.

  ssh -N -i key_ed25519 -L $HOST:$PORT:127.0.0.1:3389 <서버사용자>@<서버주소>

터널이 열린 상태에서 다시 실행하세요.
EOF
  exit 1
fi

# /cert:ignore: SSH 터널(127.0.0.1)로 암호화된 연결에서 인증서 확인 질문으로 멈추는 것을 방지
exec "$EXE" /v:"$SERVER" /u:"$USER_ID" /dynamic-resolution /cert:ignore
