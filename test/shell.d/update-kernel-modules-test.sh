#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/root/usr/lib/omarchy" "$work/root/usr/lib/modules/7.2.3-arch1-3/updates/dkms"
export TEST_ROOT="$work/root" PACMAN_LOG="$work/pacman.log"
cat > "$work/bin/pacman" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$PACMAN_LOG"
[[ ${BROKEN_DATABASE:-0} != 1 ]] || exit 1
if [[ $* == *-Qq ]]; then
  [[ ${NO_STOCK_KERNEL:-0} == 1 ]] || echo linux
  exit 0
fi
printf '%s/usr/lib/modules/7.2.3-arch1-3/modules.order\n' "$TEST_ROOT"
STUB
# Use executable providers with the same stdin/argument interface as the
# package-owned verifiers. Reject a stock module in place of the DKMS override.
for pair in 'verify-snd-hda-macbookpro snd-hda-codec-cs8409' 'verify-facetimehd facetimehd'; do
  read -r name module <<< "$pair"
  cat > "$work/root/usr/lib/omarchy/$name" <<STUB
#!/bin/bash
[[ \$1 == --modules-root && \$2 == "\$TEST_ROOT/usr/lib/modules" ]] || exit 2
read -r target
[[ \$target == usr/lib/modules/7.2.3-arch1-3/modules.order ]] || exit 2
[[ -s \$2/7.2.3-arch1-3/updates/dkms/$module.ko.zst ]] || {
  echo 'Missing $module' >&2
  exit 1
}
STUB
  chmod +x "$work/root/usr/lib/omarchy/$name"
done
chmod +x "$work/bin/pacman"
export PATH="$work/bin:$PATH"

run_check() {
  bash "$ROOT/bin/omarchy-update-verify-kernel-modules" --root "$work/root" > "$work/out" 2>&1
}

if run_check; then fail "missing drivers pass hardware verification"; fi
for module in snd-hda-codec-cs8409 facetimehd; do
  grep -q "Missing $module" "$work/out" || fail "verification did not report $module"
done
grep -q 'do not reboot' "$work/out" || fail "failure omits reboot guidance"
pass "both missing drivers are reported before an update can finish"

printf 'module\n' > "$work/root/usr/lib/modules/7.2.3-arch1-3/updates/dkms/snd-hda-codec-cs8409.ko.zst"
if run_check; then fail "one working driver hides another missing driver"; fi
printf 'module\n' > "$work/root/usr/lib/modules/7.2.3-arch1-3/updates/dkms/facetimehd.ko.zst"
# A preserved kernel directory must not require a driver for the next boot.
mkdir -p "$work/root/usr/lib/modules/7.1.9-arch1-2"
run_check || fail "present modules are rejected"
pass "the installed stock kernel is checked without checking preserved kernel directories"

NO_STOCK_KERNEL=1 run_check || fail "alternative-kernel installation is rejected"
if BROKEN_DATABASE=1 run_check; then fail "an unreadable package database bypasses verification"; fi
pass "package database errors cannot bypass verification"
rm "$work/root/usr/lib/omarchy/verify-snd-hda-macbookpro" "$work/root/usr/lib/omarchy/verify-facetimehd"
: > "$PACMAN_LOG"
run_check || fail "a machine without compatibility packages is rejected"
[[ ! -s $PACMAN_LOG ]] || fail "a machine without compatibility packages queries pacman"
pass "machines without the optional packages or stock kernel can still update"

# Calling update restart directly must also stop before any reboot prompt.
cat > "$work/bin/omarchy-update-verify-kernel-modules" <<'STUB'
#!/bin/bash
exit 1
STUB
cat > "$work/bin/gum" <<'STUB'
#!/bin/bash
printf 'prompted\n' > "$PACMAN_LOG"
exit 0
STUB
chmod +x "$work/bin/omarchy-update-verify-kernel-modules" "$work/bin/gum"
: > "$PACMAN_LOG"
if bash "$ROOT/bin/omarchy-update-restart" > "$work/out" 2>&1; then
  fail "direct restart proceeds after failed hardware verification"
fi
[[ ! -s $PACMAN_LOG ]] || fail "direct restart offers a reboot with missing drivers"
pass "direct update restart also refuses to recommend an unsafe reboot"
