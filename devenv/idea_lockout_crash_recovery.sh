#!/usr/bin/env bash
#
#   Run this script when idea crashes with complaints about a lock file. This usually
#   happens in laptop environments when power runs out and disk needs to be scanned via fsck 
#   to recover orphaned blocks.    We install idea via flatpack in our post install script. 
#

set -euo pipefail

SUMMARY_FILE="${HOME}/idea_lock_summary.txt"

# Step 1: Find all JetBrains .lock files and write them to summary
{
  find ~/.var/app -path '*JetBrains*' -name '.lock' -printf '%p\n' 2>/dev/null
  find ~/.config -path '*JetBrains*' -name '.lock' -printf '%p\n' 2>/dev/null
  find ~/.cache  -path '*JetBrains*' -name '.lock' -printf '%p\n' 2>/dev/null
  find ~/.local/share -path '*JetBrains*' -name '.lock' -printf '%p\n' 2>/dev/null
} | sort -u > "$SUMMARY_FILE"

echo "Summary of .lock files saved to $SUMMARY_FILE"
echo "Found $(wc -l < "$SUMMARY_FILE") file(s)."

# Step 2: Delete each file listed in summary
while IFS= read -r file; do
  if [ -n "$file" ] && [ -e "$file" ]; then
    echo "Deleting: $file"
    rm -f "$file"
  fi
done < "$SUMMARY_FILE"

echo "Cleanup complete."

