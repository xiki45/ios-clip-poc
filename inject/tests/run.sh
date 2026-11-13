#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
clang -fobjc-arc -framework Foundation -framework CoreFoundation \
      -I. WTClipEngine.m tests/main.m -o /tmp/wtclip_test
/tmp/wtclip_test
