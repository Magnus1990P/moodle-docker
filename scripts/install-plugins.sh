#!/bin/sh
# Install the plugins listed in plugins.txt into a Moodle source tree.
# Usage: install-plugins.sh <plugins.txt> <moodle root>
set -eu

list="$1"
root="$2"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Strip CRLF (the list may be edited on Windows), comments and blank lines.
tr -d '\r' < "$list" | grep -Ev '^[[:space:]]*(#|$)' | while read -r path source _; do
    if [ -z "$source" ]; then
        echo "plugins.txt: no source for '$path'" >&2
        exit 1
    fi
    dest="$root/public/$path"
    if [ -e "$dest" ]; then
        echo "plugins.txt: public/$path already exists (core plugin or duplicate line)" >&2
        exit 1
    fi
    echo "Installing public/$path from $source"

    work="$tmp/work"
    rm -rf "$work"
    mkdir -p "$work" "$(dirname "$dest")"
    case "$source" in
        *.zip | *.zip\?*)
            curl -fsSL -o "$tmp/plugin.zip" "$source"
            unzip -q "$tmp/plugin.zip" -d "$work"
            rm -rf "$work/__MACOSX"
            # Plugin ZIPs hold a single top-level directory named after the plugin.
            set -- "$work"/*
            if [ $# -ne 1 ] || [ ! -d "$1" ]; then
                echo "$source: expected a single top-level directory in the ZIP" >&2
                exit 1
            fi
            mv "$1" "$dest"
            ;;
        *@*)
            # Fetch by ref, so tags, branches and commit SHAs all work.
            git -C "$work" init -q
            git -C "$work" fetch -q --depth 1 "${source%@*}" "${source##*@}"
            git -C "$work" checkout -q FETCH_HEAD
            rm -rf "$work/.git"
            mv "$work" "$dest"
            ;;
        *)
            echo "$path: source must be a .zip URL or <git-url>@<ref>" >&2
            exit 1
            ;;
    esac

    if [ ! -f "$dest/version.php" ]; then
        echo "$path: no version.php, so not a Moodle plugin (or the ZIP is nested differently)" >&2
        exit 1
    fi
    # FPM and NGINX run as non-root: make sure everything is world-readable.
    chmod -R u=rwX,go=rX "$dest"
done
