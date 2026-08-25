#!/bin/sh
set -eu

version="${1:-0.1.0}"
output_dir="${2:-dist}"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
package_name="simutex-$version"
stage_dir=$(mktemp -d)

cleanup() {
    rm -rf "$stage_dir"
}
trap cleanup EXIT INT TERM

mkdir -p "$stage_dir/$package_name" "$project_dir/$output_dir"
cp "$project_dir/build.zig" "$project_dir/build.zig.zon" "$stage_dir/$package_name/"
cp "$project_dir/README.md" "$project_dir/LICENSE" "$stage_dir/$package_name/"
cp -R "$project_dir/src" "$stage_dir/$package_name/"

archive="$project_dir/$output_dir/$package_name.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$archive" -C "$stage_dir" "$package_name"

printf '%s  %s\n' "$(shasum -a 256 "$archive" | awk '{print $1}')" "$archive"
