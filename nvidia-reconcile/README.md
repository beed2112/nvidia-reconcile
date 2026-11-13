# nvidia-reconcile

Self-heal the NVIDIA driver after an unattended update on Fedora/RHEL boxes using
the RPM Fusion **akmod-nvidia** driver.

## The problem

Unattended updates (`dnf automatic`) can install a new kernel *and* a new NVIDIA
driver in one shot. On the next boot, the nvidia kernel modules sometimes load
from a **stale build before `akmods.service` finishes rebuilding** the module for
the new kernel. You end up with a loaded kernel module whose version doesn't match
the installed userspace libraries, and everything that touches the GPU breaks:

```
$ nvidia-smi
Failed to initialize NVML: Driver/library version mismatch
NVML library version: 620.70
```

A plain reboot doesn't reliably fix it (the same race can recur); the real fix is
to reload the nvidia modules *after* akmods has produced the matching build.

## What this does

A oneshot systemd service (`nvidia-reconcile.service`) runs at every boot, ordered
`After=akmods.service`:

1. If `nvidia-smi` is healthy → does nothing.
2. Only on the exact **"Driver/library version mismatch"** error, it waits until
   the on-disk module (`modinfo -F version nvidia`) differs from the loaded one —
   i.e. akmods has produced a newer build that a reload will actually pick up.
3. Then it reloads the nvidia module stack (`nvidia_drm`, `nvidia_uvm`,
   `nvidia_modeset`, `nvidia`) and verifies `nvidia-smi` recovers.
4. If any module is **in use** (e.g. a running CUDA job), it refuses to force a
   reload and logs instead — it never yanks the driver out from under a workload.

Every decision is logged to `journalctl -t nvidia-reconcile`.

## Install (on the target machine, as root)

```bash
sudo ./install.sh
```

Installs `/usr/local/sbin/nvidia-reconcile.sh` and enables the service for
`multi-user.target`.

## Files
```
install.sh                        runs the below
nvidia-reconcile.sh               -> /usr/local/sbin/nvidia-reconcile.sh
systemd/nvidia-reconcile.service  -> /etc/systemd/system/
```

## Use / verify
```bash
sudo /usr/local/sbin/nvidia-reconcile.sh   # reconcile right now
journalctl -t nvidia-reconcile             # history
systemctl status nvidia-reconcile.service
```

## Caveats
- Targets the **RPM Fusion akmod-nvidia** layout (akmods + `kmod-nvidia`). It does
  not apply to the `.run` installer or distro-specific DKMS setups unmodified.
- The live reload is safe only when nothing is actively using the GPUs — which is
  the normal state this early in boot. **If your display is driven by an NVIDIA
  GPU**, a reload briefly resets that output.
- Does not stop the mismatch from happening; it reconciles it on the next boot. If
  you'd rather prevent it, exclude the driver/kernel from `dnf automatic`
  (`/etc/dnf/automatic.conf`) and update them deliberately instead.
