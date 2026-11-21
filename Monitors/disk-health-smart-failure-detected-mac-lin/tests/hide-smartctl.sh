#!/bin/bash
# Leave no smartctl the monitor could reach: the shim goes, and any real one
# on the root PATH is renamed aside (the runner is thrown away afterwards).
# The monitor finds smartctl only through PATH (command -v), so this hides it.
IFS=: read -r -a dirs <<<"$PATH"
for d in "${dirs[@]}"; do
    if [ -e "$d/smartctl" ] || [ -L "$d/smartctl" ]; then
        mv -f "$d/smartctl" "$d/smartctl.tc-hidden" || exit 1
    fi
done
if command -v smartctl >/dev/null 2>&1; then
    echo "smartctl still reachable: $(command -v smartctl)"; exit 1
fi
echo "no smartctl on the root PATH"
