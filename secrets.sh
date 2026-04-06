#!/bin/bash
# Encrypt all secret.yaml files using SOPS + age.
# Prerequisites: sops, age
#
# First-time setup:
#   1. Install:  brew install sops age
#   2. Generate: age-keygen -o keys.txt
#   3. Put the PUBLIC key in .sops.yaml (age1...)
#   4. Backup keys.txt (private key) in Vaultwarden or another safe place
#
# Usage:
#   ./secrets.sh encrypt   — encrypt all secret.yaml files
#   ./secrets.sh decrypt   — decrypt all secret.yaml files
#   ./secrets.sh status    — show which files are encrypted/decrypted
set -euo pipefail
cd "$(dirname "$0")"

# Auto-detect age key file location
if [ -n "${SOPS_AGE_KEY_FILE:-}" ]; then
  : # already set
elif [ -f "keys.txt" ]; then
  export SOPS_AGE_KEY_FILE="./keys.txt"
elif [ -f "${HOME}/.config/sops/age/keys.txt" ]; then
  export SOPS_AGE_KEY_FILE="${HOME}/.config/sops/age/keys.txt"
else
  echo "No age key file found. Set SOPS_AGE_KEY_FILE or place keys.txt in repo root."
  echo "Generate one with: age-keygen -o keys.txt"
  exit 1
fi

SECRET_FILES=$(find . -name 'secret.yaml' -type f -not -path './.git/*')

is_encrypted() {
  grep -q "sops:" "$1" 2>/dev/null && grep -q "age:" "$1" 2>/dev/null
}

case "${1:-help}" in
  encrypt)
    echo "Encrypting secrets..."
    for f in $SECRET_FILES; do
      if is_encrypted "$f"; then
        echo "  skip (already encrypted): $f"
      else
        sops -e -i "$f"
        echo "  encrypted: $f"
      fi
    done
    echo "Done. Safe to commit."
    ;;

  decrypt)
    echo "Decrypting secrets..."
    for f in $SECRET_FILES; do
      if is_encrypted "$f"; then
        sops -d -i "$f"
        echo "  decrypted: $f"
      else
        echo "  skip (already decrypted): $f"
      fi
    done
    echo "Done. Do NOT commit decrypted files."
    ;;

  status)
    echo "Secret file status:"
    for f in $SECRET_FILES; do
      if is_encrypted "$f"; then
        echo "  🔒 $f"
      else
        echo "  🔓 $f (UNENCRYPTED)"
      fi
    done
    ;;

  *)
    echo "Usage: $0 {encrypt|decrypt|status}"
    exit 1
    ;;
esac
