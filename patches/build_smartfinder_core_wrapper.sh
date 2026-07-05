#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

core_dir="$repo_root/App_Template/Contents/Frameworks/SmartFinderCore.framework/Versions/A"
main_bin="$repo_root/App_Template/Contents/MacOS/HandShaker"
core_bin="$core_dir/SmartFinderCore"
original_bin="$core_dir/SmartFinderCoreOriginal"
patch_bin="$core_dir/CorePatch"
patch_src="$script_dir/PhotoLibraryAsyncPatch.m"
tmp_bin="$core_dir/CorePatch.tmp"
core_install_name="@rpath/SmartFinderCore.framework/Versions/A/SmartFinderCore"
patch_install_name="@rpath/SmartFinderCore.framework/Versions/A/CorePatch"

fail() {
  printf '%s\n' "FAIL: $1" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

need_file() {
  [ -f "$1" ] || fail "missing required file: $1"
}

need_cmd clang
need_cmd codesign
need_cmd perl
need_file "$main_bin"
need_file "$core_bin"
need_file "$patch_src"

if [ -f "$original_bin" ]; then
  cp -p "$original_bin" "$core_bin"
  rm -f "$original_bin"
fi

rm -f "$tmp_bin"

clang \
  -dynamiclib \
  -arch x86_64 \
  -mmacosx-version-min=10.11 \
  -fobjc-arc \
  "$patch_src" \
  -o "$tmp_bin" \
  -install_name "$patch_install_name" \
  -current_version 1.0 \
  -compatibility_version 1.0 \
  -Wl,-reexport_library,"$core_bin" \
  -framework AppKit \
  -framework Foundation

mv "$tmp_bin" "$patch_bin"
chmod 755 "$patch_bin"

if otool -L "$main_bin" | grep -q "$core_install_name"; then
  codesign --remove-signature "$main_bin" >/dev/null 2>&1 || true
  OLD_DYLIB_PATH="$core_install_name" \
  NEW_DYLIB_PATH="$patch_install_name" \
  perl -0pi -e '
    BEGIN {
      $old = $ENV{"OLD_DYLIB_PATH"};
      $new = $ENV{"NEW_DYLIB_PATH"};
      $pad = length($old) - length($new);
      die "replacement dylib path is longer than original\n" if $pad < 0;
      $replacement = $new . ("\0" x ($pad + 1));
    }
    $count += s/\Q$old\E\0/$replacement/g;
    END {
      die "original dylib path not found\n" unless $count;
    }
  ' "$main_bin"
fi

printf '%s\n' "SmartFinderCore runtime patch updated: $patch_bin"
