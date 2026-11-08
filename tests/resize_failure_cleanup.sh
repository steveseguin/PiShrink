#!/bin/bash
# Run with: bash tests/resize_failure_cleanup.sh
# This executes the production shrink block with inert command mocks only.
# PISHRINK_SOURCE can select an older script to reproduce the regression.

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_file=${PISHRINK_SOURCE:-"$test_dir/../pishrink.sh"}
shrink_block=$(sed -n '/^#Shrink filesystem$/,/^#Shrink partition$/p' "$source_file")
defaults=$(sed -n '/^should_skip_autoexpand=false$/,/^while getopts/{ /^while getopts/d; p; }' "$source_file")
if [[ -z "$shrink_block" || -z "$defaults" ]]; then
  echo "Could not find the defaults or filesystem shrink block" >&2
  exit 1
fi

failures=0
cases=0

check_case() {
  local name=$1 directory=$2 mount_rc=$3 resize_rc=$4 expected_rc=$5 expected=$6
  local output status
  output=$(
    unset mountdir
    if [[ "$directory" == INHERITED ]]; then
      export mountdir=/mock/inherited
    fi
    eval "$defaults"
    if [[ "$directory" != UNSET && "$directory" != INHERITED ]]; then
      mountdir=$directory
    fi
    loopback=/mock/loop0
    minsize=1000
    info() { :; }
    error() { :; }
    resize2fs() { printf 'resize2fs|%s|%s|%s\n' "$1" "$2" "$3"; return "$resize_rc"; }
    mount() { printf 'mount|%s|%s\n' "$1" "$2"; return "$mount_rc"; }
    mv() { printf 'mv|%s|%s\n' "$1" "$2"; }
    umount() { printf 'umount|%s\n' "$1"; }
    losetup() { printf 'losetup|%s|%s\n' "$1" "$2"; }
    sleep() { :; }
    eval "$shrink_block"
  )
  status=$?
  (( cases += 1 ))
  if [[ "$status" != "$expected_rc" || "$output" != "$expected" ]]; then
    printf 'FAIL: %s (exit %s, expected %s)\n%s\n' "$name" "$status" "$expected_rc" "$output" >&2
    (( failures += 1 ))
  else
    printf 'PASS: %s\n' "$name"
  fi
}

resize='resize2fs|-p|/mock/loop0|1000'
detach='losetup|-d|/mock/loop0'

# -s and logical partitions never set mountdir. Neither should touch host /etc.
check_case 'unset mount directory' UNSET 1 1 12 "$resize"$'\n'"$detach"
check_case 'empty mount directory' '' 1 1 12 "$resize"$'\n'"$detach"
check_case 'ignore inherited mount directory' INHERITED 0 1 12 "$resize"$'\n'"$detach"

# A failed recovery mount must not restore files in the unmounted directory.
check_case 'recovery mount fails' /mock/mount 1 1 12 \
  "$resize"$'\nmount|/mock/loop0|/mock/mount\n'"$detach"

check_case 'successful recovery mount' /mock/mount 0 1 12 \
  "$resize"$'\nmount|/mock/loop0|/mock/mount\nmv|/mock/mount/etc/rc.local.bak|/mock/mount/etc/rc.local\numount|/mock/mount\n'"$detach"

check_case 'mount directory contains spaces' '/mock/mount with spaces' 0 1 12 \
  "$resize"$'\nmount|/mock/loop0|/mock/mount with spaces\nmv|/mock/mount with spaces/etc/rc.local.bak|/mock/mount with spaces/etc/rc.local\numount|/mock/mount with spaces\n'"$detach"

check_case 'successful shrink needs no recovery' UNSET 1 0 0 "$resize"

printf '%s cases, %s failures\n' "$cases" "$failures"
(( failures == 0 ))
