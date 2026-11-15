#!/bin/bash
# 同步引擎本机回归：拿 Python 参考实现的 MiniWebDAV 当服务端，跑两台虚拟设备。
set -euo pipefail
cd "$(dirname "$0")"

PROTO="../../../../clip-sync-prototype/output/prototype"
ROOT=$(mktemp -d)

python3 - "$PROTO" "$ROOT" <<'PY' &
import sys, time
sys.path.insert(0, sys.argv[1])
from dav_server import MiniDavServer
srv = MiniDavServer(sys.argv[2], user="u", password="p", port=18081)
print("DAV:", srv.start(), flush=True)
try:
    while True: time.sleep(1)
except KeyboardInterrupt:
    srv.stop()
PY
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 2

swiftc -swift-version 5 -O ../../Shared/ClipModel.swift ../../Shared/TextMatch.swift \
    ../../PocApp/WebDAVClient.swift ../../PocApp/SyncEngine.swift shim.swift main.swift -o /tmp/synctest
/tmp/synctest
