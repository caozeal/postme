#!/bin/bash
# Synthetic-only smoke tests. Needs permission to bind localhost and Unix sockets.
set -euo pipefail
cd "$(dirname "$0")/../.."
TMP="$(mktemp -d /tmp/postme-context-smoke.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
SDK="${SDK:-macosx26.5}"
xcrun --sdk "$SDK" swiftc -parse-as-library Sources/Postme/Services/AgentContextBridge.swift scripts/context-smoke/BridgeHarness.swift -o "$TMP/bridge"
"$TMP/bridge"
python3 - "$TMP" <<'PY'
import sys
from pathlib import Path
s=Path('Sources/Postme/PostmeApp.swift').read_text()
start=s.index('@main\nenum PostmeEntryPoint'); end=s.index('/// 应用委托。', start)
Path(sys.argv[1], 'PostmeAppWithoutMain.swift').write_text(s[:start]+s[end:])
PY
xcrun --sdk "$SDK" swiftc -parse-as-library -swift-version 5 $(find Sources/Postme -name '*.swift' ! -name 'PostmeApp.swift') "$TMP/PostmeAppWithoutMain.swift" scripts/context-smoke/AppHarness.swift -o "$TMP/app-harness"
POSTME_HARNESS="$TMP/app-harness" python3 scripts/context-smoke/server.py
