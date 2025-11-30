#!/bin/bash
# companion script for doing mass compose actions
# Usage:
# bash dc.sh up
# OR allow script execution: `chmod +x dc.sh`
# ./dc.sh up

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 {up|down|pull}"
    exit 1
fi

cmd="$1"

case "$cmd" in
    up|down|pull)
        ;;
    *)
        echo "Invalid command: $cmd"
        echo "Usage: $0 {up|down|pull}"
        exit 1
        ;;
esac

for d in */; do
    cd $d || continue
	
	if [[ ! -f '.skip' ]]; then
		echo "=== Processing: $d ==="
		if [[ "$cmd" == "up" ]]; then
			docker compose up -d
		elif [[ "$cmd" == "down" ]]; then
			docker compose down
		elif [[ "$cmd" == "pull" ]]; then
			docker compose pull
		fi
	else
		echo "=== Skipping: $d ==="
	fi
    cd ..
done
