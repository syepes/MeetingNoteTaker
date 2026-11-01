# Replace a verified directory while retaining the previous version on failure.
replace_directory() {
  local incoming="$1" destination="$2" backup
  mkdir -p "$(dirname "$destination")" || return 1
  backup="$(mktemp -d "$(dirname "$destination")/.previous.XXXXXX")" || return 1
  if [ -e "$destination" ]; then
    if ! mv "$destination" "$backup/original"; then rmdir "$backup"; return 1; fi
  fi
  if mv "$incoming" "$destination"; then
    rm -rf "$backup"
  else
    if [ -e "$backup/original" ]; then
      if ! mv "$backup/original" "$destination"; then
        echo "Replacement failed; previous output is preserved at $backup/original" >&2
        return 1
      fi
    fi
    rmdir "$backup"
    return 1
  fi
}
