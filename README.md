# kubevirt-secureboot

A single bash script that looks at KubeVirt VMs in your cluster, tells
you which ones have Secure Boot on, and optionally flips it on or off
for you. With a stop/start cycle, because firmware is decided at
power-on and the kernel does not care about your feelings on that.

It is not my job to ask why you are doing this. If you have a reason,
good. If you do not, also fine. The script does the boring part either
way.

## Why this exists

KubeVirt has a quietly opinionated default: when `spec.template.spec.domain.firmware.bootloader.efi`
is set without an explicit `secureBoot` field, Secure Boot is **on**.
Yes, a VM whose spec contains just:

```yaml
firmware:
  bootloader:
    efi: {}
features:
  smm:
    enabled: true
```

is running with Secure Boot enforcing. You cannot tell from `oc get vm
-o yaml` alone unless you know to look for the absence of the field
and then mentally apply the default. The script normalizes this for
you and verifies the runtime state via `virsh dumpxml` inside the
virt-launcher pod, which is the only place where the truth actually
lives.

## What it does

For every VM (in scope), classify into one of three buckets:

| Bucket | Spec shape | What we do |
|---|---|---|
| **BIOS** | no `bootloader`, or `bootloader.bios` set | leave it alone (Secure Boot does not apply to BIOS) |
| **EFI no-SB** | `bootloader.efi.secureBoot: false` (explicit) | optionally flip Secure Boot ON |
| **EFI SB-on** | `bootloader.efi` set, secureBoot not explicitly false | optionally flip Secure Boot OFF |

If you run the script without an action flag, it just tells you what
each VM looks like and exits. No surprises.

## Requirements

- `oc` logged in to the cluster (the script does not care which one)
- `jq`
- `virtctl` is optional. The script uses it for stop/start if it is
  present; falls back to `oc patch` on `spec.running` otherwise. Both
  paths work; virtctl is just less typing.

## Quick start

```bash
# Take a look. No changes.
./secureboot-audit.sh

# Look at one namespace
./secureboot-audit.sh -n default

# Look at specific VMs (any namespace, with the prefix)
./secureboot-audit.sh default/rhel9-1 default/windows-2

# Same, shorter, when they all live in the same namespace
./secureboot-audit.sh -n default rhel9-1 windows-2

# Patch the VM spec to turn Secure Boot off. No restart, no impact on the
# running VMI. The change applies on the next power-cycle done by whoever.
./secureboot-audit.sh --disable-secureboot

# Same, but also stop and start each VM right now (workload-impacting,
# opt-in on purpose)
./secureboot-audit.sh --disable-secureboot --restart

# Skip the confirmation prompt (useful in scripts and pipelines)
./secureboot-audit.sh --disable-secureboot -y

# Enable Secure Boot on every EFI VM that has it off (read the warning first)
./secureboot-audit.sh --enable-secureboot --restart

# Re-check the live libvirt XML for VMs the spec calls "SB on"
./secureboot-audit.sh --verify-only
```

## On `--restart`

Stopping and starting a VM is a workload-impacting action. The script
does not do that by default. Without `--restart`, the action flags
only patch the VM CR. The running VMI keeps going untouched; the new
setting takes effect the next time someone power-cycles the VM.

Pass `--restart` when you actually want the script to stop and start
the VMs itself, with the wait-for-Running and verification cycle.

## Sample output

Read-only audit:

```
Cluster:  https://api.lab.example.com:6443
Looking at: all namespaces
Mode:     read-only. Pass --disable-secureboot or --enable-secureboot to change things.

  NAMESPACE  VM                FIRMWARE  SECURE BOOT
  default    centos-stream9-1  BIOS      n/a
  default    fedora-1          EFI       on
  default    rhel9-1           EFI       off

Total: 3 VMs (1 BIOS, 1 EFI no SB, 1 EFI SB on).

  Pass --disable-secureboot to turn Secure Boot off on the 1 VM(s) above.
  Pass --enable-secureboot to turn Secure Boot on on the 1 VM(s) above (read the warning in --help first).
```

Acting on a VM, default (patch only, no restart):

```
Working on default/fedora-1...
  patching the VM spec: set secureBoot: false
  patched. The change will apply the next time someone power-cycles this VM.

All done. No errors.
```

Acting on a VM with `--restart` (workload-impacting, opt-in):

```
Working on default/fedora-1...
  patching the VM spec: set secureBoot: false
  asking KubeVirt to stop the VM
  waiting for the running VMI to go away
  starting the VM again
  checking that libvirt now reports the expected state
  done: libvirt reports secure='no'.

All done. No errors.
```

## Disable is safe. Enable is not always safe.

**Disabling** Secure Boot on a VM that boots fine with it on is
boring. Worst case: nothing changes for the guest, except `mokutil
--sb-state` now says "disabled" and the kernel stops refusing to load
unsigned modules. Nobody cries.

**Enabling** Secure Boot on a VM that was running without it can
break boot. The guest needs:

- A signed bootloader (RHEL/Fedora/Ubuntu ship shim, Microsoft signs
  Windows)
- A signed kernel
- Signed kernel modules (or modules enrolled via MOK)

Modern stock RHEL 8/9, Fedora 35+, Ubuntu 20+, and Windows 10/11 are
fine. Custom kernels, recompiled GRUB, NVIDIA without the signed
package, and various third-party drivers are not. The VM's UEFI NVRAM
is also reset when the OVMF template changes between secboot and
non-secboot, so boot order and any MOK enrollments are lost.

If the VM does not come back Running after `--enable-secureboot`, the
script tells you. Reverting is one command:

```bash
./secureboot-audit.sh default/<that-vm> --disable-secureboot -y
```

## How the verification works

The KubeVirt VM CR is not a reliable source of truth for the runtime
firmware. KubeVirt applies its default of `secureBoot: true` only when
generating the libvirt XML, not when storing the VMI. So you can have
a VMI whose spec says `efi: {}` and a guest that is, in fact, running
with Secure Boot enforcing.

The script reads the truth from where it actually lives: inside the
virt-launcher pod, via `virsh -r dumpxml 1`. It looks for the
`<loader secure='yes|no'>` attribute and the OVMF NVRAM template
filename. Two values that cannot lie about each other.

## What it does not do

- It does not convert BIOS legacy VMs to EFI. That involves
  re-partitioning the disk inside the guest. Out of scope.
- It does not migrate VMs between clusters or hosts. KubeVirt does
  that; this script just changes a spec field.
- It does not preserve the UEFI NVRAM across template changes. The
  template swap is what KubeVirt does; the script does not have a
  workaround.
- It does not check whether the guest will actually boot with the new
  setting before applying. If you want certainty, take a snapshot
  first.
- It does not run with `no_log: true` anywhere. If something fails,
  you will see why.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Everything went as expected. |
| 1 | A precondition failed (no `oc`, no `jq`, not logged in, conflicting flags, no VMs match). |
| 1 (after acting) | One or more VMs reported errors during the patch/start/verify cycle. Scroll up. |

## License

[Apache-2.0](LICENSE). Use it, fork it, ship it in a CI pipeline,
print it and frame it. No warranty.
