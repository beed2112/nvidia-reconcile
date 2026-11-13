#!/usr/bin/env bash
# Reconcile the *loaded* NVIDIA kernel module with the *installed* userspace
# driver after an unattended update.
#
# On Fedora/RHEL boxes using the RPM Fusion akmod-nvidia driver, an unattended
# update (e.g. `dnf automatic`) can install a new kernel plus a new NVIDIA driver.
# On the next boot the nvidia modules may load from a stale build BEFORE
# akmods.service finishes rebuilding the matching module for the new kernel. The
# result: nvidia-smi fails with "Driver/library version mismatch" and every CUDA/
# nvidia-smi consumer is broken until the modules are reloaded or the box is
# rebooted again.
#
# Run this at boot, ordered After=akmods.service. If nvidia-smi is healthy it does
# nothing. If it sees that specific mismatch AND a freshly-built on-disk module
# that differs from the loaded one, it reloads the nvidia module stack. If any
# module is in use (e.g. a running CUDA job), it refuses to force a reload and logs
# instead, so it never yanks the driver out from under a live workload.
#
# Safe to reload live only when nothing is actively using the GPUs — which is the
# normal situation this early in boot. If your display is driven by an NVIDIA GPU,
# reloading will also blank/reset that output briefly.
set -u

log(){ logger -t nvidia-reconcile "$*"; echo "nvidia-reconcile: $*"; }

# Nothing loaded? Nothing to reconcile.
[ -e /proc/driver/nvidia/version ] || { log "no nvidia module loaded; skipping"; exit 0; }

# Already healthy -> done (the common case on a normal boot).
if nvidia-smi -L >/dev/null 2>&1; then
    log "nvidia-smi healthy; no action needed"
    exit 0
fi

# Only handle the specific version-mismatch failure. Leave other failures alone.
err="$(nvidia-smi -L 2>&1 || true)"
case "$err" in
    *"Driver/library version mismatch"*) : ;;
    *) log "nvidia-smi failing, but not a version mismatch -- leaving modules alone: $err"; exit 0 ;;
esac

# Wait (up to ~150s) for akmods to produce an on-disk module that DIFFERS from
# the loaded one -- only then will a reload actually help. If they already match,
# the on-disk module is still stale (akmods not finished) and reloading is futile.
loaded_v=""; ondisk_v=""
for i in $(seq 1 30); do
    loaded_v="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' /proc/driver/nvidia/version 2>/dev/null | head -1)"
    ondisk_v="$(modinfo -F version nvidia 2>/dev/null)"
    [ -n "$ondisk_v" ] && [ "$ondisk_v" != "$loaded_v" ] && break
    sleep 5
done

if [ -z "$ondisk_v" ] || [ "$ondisk_v" = "$loaded_v" ]; then
    log "on-disk module ($ondisk_v) does not yet differ from loaded ($loaded_v); akmods may be incomplete -- not reloading"
    exit 1
fi
log "mismatch: loaded=$loaded_v on-disk=$ondisk_v; reloading nvidia modules"

persist_was_active=no
systemctl is-active --quiet nvidia-persistenced && persist_was_active=yes
systemctl stop nvidia-persistenced 2>/dev/null || true

if ! modprobe -r nvidia_drm nvidia_uvm nvidia_modeset nvidia 2>/tmp/nvidia-reconcile.err; then
    log "could not unload nvidia modules (in use?): $(cat /tmp/nvidia-reconcile.err 2>/dev/null)"
    rm -f /tmp/nvidia-reconcile.err
    [ "$persist_was_active" = yes ] && systemctl start nvidia-persistenced 2>/dev/null || true
    exit 1
fi
rm -f /tmp/nvidia-reconcile.err

modprobe nvidia && modprobe nvidia_modeset && modprobe nvidia_drm modeset=1
[ "$persist_was_active" = yes ] && systemctl start nvidia-persistenced 2>/dev/null || true

if nvidia-smi -L >/dev/null 2>&1; then
    n="$(nvidia-smi -L 2>/dev/null | wc -l)"
    log "reload succeeded; nvidia-smi now healthy ($n GPU(s))"
    exit 0
fi
log "reload did NOT resolve the mismatch: $(nvidia-smi -L 2>&1)"
exit 1
