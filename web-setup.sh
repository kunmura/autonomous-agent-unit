#!/bin/bash
# Launch the AAU Web Setup Wizard
AAU_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$AAU_ROOT/web/server.py"
