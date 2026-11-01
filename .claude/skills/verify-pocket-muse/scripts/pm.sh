#!/bin/bash
# Pocket Muse verification helper. Run from anywhere.
#   pm.sh doctor              read-only: iPhone paired, app installed, bundle exported, packs built
#   pm.sh build               export packs + build + install (needs the CudaBuild plugin trusted)
#   pm.sh selftest [RUN]      launch the app with -selftest, stream SELFTEST lines, pull Documents/selftest.json
#   pm.sh launch              launch the app normally (for a human to drive by voice)
#   pm.sh stop                terminate the app instance this helper launched
#   pm.sh mac [RUN]           Mac-side check: eval.py --scenarios (same questions, same pass rule, no speech)
# Evidence goes to artifacts/verify/<RUN>/ (gitignored, survives `stop`). RUN defaults to a timestamp.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
BUNDLE_ID=com.baobabtr33.pocketmuse
cmd="${1:-doctor}"
RUN="${2:-$(date +%Y%m%d-%H%M%S)}"
OUT="$ROOT/artifacts/verify/$RUN"

device() {
  xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && (/available/ || /connected/) {print $3; exit}'
}

app_pid() {
  xcrun devicectl device info processes --device "$1" 2>/dev/null | awk '/PocketMuse.app\/PocketMuse/ {print $1; exit}'
}

case "$cmd" in
doctor)
  ok=1
  dev=$(device)
  if [[ -n "$dev" ]]; then echo "ok   iPhone paired: $dev"; else echo "FAIL no paired iPhone (connect USB, unlock)"; ok=0; fi
  if [[ -n "$dev" ]]; then
    if xcrun devicectl device info apps --device "$dev" --bundle-id "$BUNDLE_ID" 2>/dev/null | grep -q "$BUNDLE_ID"; then
      echo "ok   app installed ($BUNDLE_ID)"
    else
      echo "FAIL app not installed: run pm.sh build"; ok=0
    fi
    pid=$(app_pid "$dev"); [[ -n "$pid" ]] && echo "info app running, pid $pid" || echo "info app not running"
  fi
  if [[ -f "$ROOT/ios/Bundle/index.json" ]]; then
    echo "ok   ios/Bundle exported: $(python3 -c "import json;print(', '.join(p['id'] for p in json.load(open('$ROOT/ios/Bundle/index.json'))))")"
  else
    echo "FAIL ios/Bundle not exported: uv run python export_ios.py"; ok=0
  fi
  python3 - "$ROOT" <<'EOF'
import json, sys, pathlib
root = pathlib.Path(sys.argv[1])
want = [s["id"] for s in json.loads((root / "data/scenarios.json").read_text())["scenarios"]]
have = {json.loads(p.read_text()).get("scenario") for p in (root / "artifacts/packs").glob("*/pack.json")
        if (p.parent / "adapters/adapters.safetensors").exists()}
for s in want:
    print(("ok   " if s in have else "WARN ") + f"pack built for scenario {s}" + ("" if s in have else ": uv run python pack.py --scenario " + s))
EOF
  newest_src=$(find "$ROOT/ios/PocketMuse" -name "*.swift" -newer "$ROOT/ios/build/Build/Products/Release-iphoneos/PocketMuse.app/PocketMuse" 2>/dev/null | head -1)
  [[ -n "$newest_src" ]] && echo "WARN source newer than last build ($(basename "$newest_src")): the phone runs old code until pm.sh build"
  [[ $ok == 1 ]] && echo "doctor: worth driving" || { echo "doctor: NOT ready"; exit 1; }
  ;;
build)
  "$ROOT/ios/run.sh" --export
  ;;
selftest)
  dev=$(device); [[ -z "$dev" ]] && { echo "no paired iPhone"; exit 1; }
  mkdir -p "$OUT"
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "Self-test on $dev, evidence in $OUT (takes ~3 min: 25 spoken questions at real-time pace)"
  xcrun devicectl device process launch --console --terminate-existing --device "$dev" -- "$BUNDLE_ID" -selftest \
    2>&1 | tee "$OUT/console.log" | grep --line-buffered -E "SELFTEST|POCKETMUSE"
  xcrun devicectl device copy from --device "$dev" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" --source Documents/selftest.json --destination "$OUT/selftest.json" >/dev/null 2>&1 \
    && python3 -c "import json,sys;r=json.load(open('$OUT/selftest.json'));print(f\"report: {r['passed']}/{r['total']} passed, finished {r['finished']}\");sys.exit(r['finished']<'$started')" \
    || echo "FAIL no fresh Documents/selftest.json: the run did not finish (stale report from an earlier run, or app crashed)"
  grep -q "SELFTEST DONE" "$OUT/console.log" || { echo "FAIL no SELFTEST DONE line: see $OUT/console.log"; exit 1; }
  ;;
launch)
  dev=$(device); [[ -z "$dev" ]] && { echo "no paired iPhone"; exit 1; }
  xcrun devicectl device process launch --terminate-existing --device "$dev" "$BUNDLE_ID" | tail -1
  ;;
stop)
  dev=$(device); [[ -z "$dev" ]] && exit 0
  pid=$(app_pid "$dev")
  [[ -n "$pid" ]] && xcrun devicectl device process terminate --device "$dev" --pid "$pid" >/dev/null && echo "stopped pid $pid" || echo "not running"
  ;;
mac)
  mkdir -p "$OUT"
  (cd "$ROOT" && TOKENIZERS_PARALLELISM=false uv run python eval.py --scenarios 2>&1 | grep -v Warning | tee "$OUT/mac-scenarios.log")
  ;;
*)
  sed -n 2,9p "$0"; exit 1
  ;;
esac
