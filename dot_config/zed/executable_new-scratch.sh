#!/bin/sh
# Bare extension ("go") becomes scratch-<stamp>.go; a full name is kept as is.
set -eu

printf 'name or extension (empty for none): '
read -r name || name=

stamp="scratch-$(date +%Y%m%d-%H%M%S)"
case "$name" in
  "") file="$stamp" ;;
  *.*) file="$name" ;;
  *) file="$stamp.$name" ;;
esac

dir="${ZED_WORKTREE_ROOT:-$PWD}/.notes"
mkdir -p "$dir"
[ -e "$dir/$file" ] || : >"$dir/$file"
# -e overrides cli_default_open_behavior=new_window from settings.json.
exec zed --existing "$dir/$file"
