#!/usr/bin/env bash
# secureboot-audit.sh
#
# Look at KubeVirt VMs across the cluster, tell which ones have Secure Boot
# turned on or off, and optionally flip the switch. Both ways.
#
# Why this exists: KubeVirt defaults secureBoot to true when bootloader.efi
# is set without the field. Yes, that means a VM with just `efi: {}` in its
# spec is actually Secure Boot on. No, you cannot tell from the spec alone.
# This script normalizes detection and the fix in one pass, so you do not
# have to remember the implicit default at 3 AM.
#
# Usage:
#   ./secureboot-audit.sh                                 # just look around (every namespace)
#   ./secureboot-audit.sh -n default                      # one namespace
#   ./secureboot-audit.sh default/rhel9                   # one specific VM
#   ./secureboot-audit.sh default/rhel9 default/fedora    # several specific VMs
#   ./secureboot-audit.sh -n default rhel9 fedora         # several VMs in a namespace
#   ./secureboot-audit.sh --disable-secureboot            # patch SB off; you power-cycle later
#   ./secureboot-audit.sh --disable-secureboot --restart  # patch AND stop/start now
#   ./secureboot-audit.sh --enable-secureboot --restart   # patch SB on AND stop/start now
#   ./secureboot-audit.sh --disable-secureboot -y         # skip the prompt
#   ./secureboot-audit.sh --verify-only                   # check runtime XML
#
# About --restart:
#   Stopping and starting a VM is a workload-impacting action, so it does not
#   happen by default. Without --restart the script only patches the VM spec
#   and leaves the running VMI alone. The change takes effect the next time
#   somebody (you, an operator, an automation, the user inside the guest)
#   power-cycles the VM. Pass --restart only when you actually want the
#   script to do the stop/start cycle itself.
#
# Note on --enable-secureboot:
#   Turning Secure Boot on is riskier than turning it off. The guest needs a
#   signed bootloader, signed kernel, and signed modules to boot. Modern
#   distros (RHEL 8/9, Fedora 35+, Ubuntu 20+, Windows 10/11) work fine.
#   Custom kernels, custom GRUB, or unsigned third-party modules do not.
#   The NVRAM is also reset when the OVMF template changes (boot order and
#   MOK enrollments are lost).

namespace=""
all_namespaces=true
disable_sb=false
enable_sb=false
assume_yes=false
restart=false
verify_only=false
target_vms=()

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace)        namespace="$2"; all_namespaces=false; shift 2 ;;
    --disable-secureboot)  disable_sb=true; shift ;;
    --enable-secureboot)   enable_sb=true; shift ;;
    -y|--yes)              assume_yes=true; shift ;;
    --restart)             restart=true; shift ;;
    --verify-only)         verify_only=true; shift ;;
    -h|--help)             sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "I do not recognize the argument '$1'. Try --help."; exit 1 ;;
    *)  target_vms+=("$1"); shift ;;
  esac
done

if $disable_sb && $enable_sb; then
  echo "Pick one: --disable-secureboot or --enable-secureboot, not both."
  exit 1
fi

for bin in oc jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "I need '$bin' on PATH and could not find it."
    exit 1
  fi
done

if ! oc whoami >/dev/null 2>&1; then
  echo "You are not logged in to a cluster. Run 'oc login' first."
  exit 1
fi

has_virtctl=false
command -v virtctl >/dev/null 2>&1 && has_virtctl=true

cluster_url=$(oc whoami --show-server 2>/dev/null)

echo "Cluster:  $cluster_url"
if [ ${#target_vms[@]} -gt 0 ]; then
  echo "Looking at: ${#target_vms[@]} specific VM(s)"
elif $all_namespaces; then
  echo "Looking at: all namespaces"
else
  echo "Looking at: namespace '$namespace'"
fi
if $verify_only; then
  echo "Mode:     verify only (compare running XML, no changes)"
elif $disable_sb; then
  if $restart; then
    echo "Mode:     will disable Secure Boot AND stop/start each affected VM now"
  else
    echo "Mode:     will patch the VM spec to disable Secure Boot. You power-cycle later."
    echo "          (pass --restart to also stop/start the VMs in this run)"
  fi
elif $enable_sb; then
  if $restart; then
    echo "Mode:     will enable Secure Boot AND stop/start each affected VM now"
  else
    echo "Mode:     will patch the VM spec to enable Secure Boot. You power-cycle later."
    echo "          (pass --restart to also stop/start the VMs in this run)"
  fi
else
  echo "Mode:     read-only. Pass --disable-secureboot or --enable-secureboot to change things."
fi
echo

# Discover and classify
if [ ${#target_vms[@]} -gt 0 ]; then
  # User asked for specific VMs. Resolve each (with or without namespace prefix)
  # and combine the JSON objects into a single .items list.
  items=()
  missing=0
  for spec in "${target_vms[@]}"; do
    case "$spec" in
      */*) one_ns="${spec%%/*}"; one_name="${spec##*/}" ;;
      *)
        if $all_namespaces; then
          echo "I need a namespace for '$spec'. Use 'namespace/$spec' or pass -n <namespace>."
          exit 1
        fi
        one_ns="$namespace"; one_name="$spec"
        ;;
    esac
    one=$(oc get vm "$one_name" -n "$one_ns" -o json 2>/dev/null)
    if [ -z "$one" ]; then
      echo "  $one_ns/$one_name does not exist (or I cannot see it). Skipping."
      missing=$((missing + 1))
      continue
    fi
    items+=("$one")
  done
  if [ ${#items[@]} -eq 0 ]; then
    echo "No matching VMs found."
    exit 1
  fi
  vm_json=$(printf '%s\n' "${items[@]}" | jq -s '{items: .}')
  [ "$missing" -gt 0 ] && echo
elif $all_namespaces; then
  vm_json=$(oc get vm -A -o json)
else
  vm_json=$(oc get vm -n "$namespace" -o json)
fi

total=$(echo "$vm_json" | jq '.items | length')
if [ "$total" -eq 0 ]; then
  echo "No VMs found. Nothing to do."
  exit 0
fi

# class is one of: bios | efi-nosb | efi-sbon
classified=$(echo "$vm_json" | jq -r '
  .items[]
  | . as $vm
  | ($vm.spec.template.spec.domain.firmware.bootloader // null) as $bl
  | (
      if $bl == null then "bios"
      elif ($bl | has("bios")) then "bios"
      elif ($bl | has("efi")) then
        (if ($bl.efi.secureBoot == false) then "efi-nosb" else "efi-sbon" end)
      else "bios"
      end
    ) as $class
  | [$class, $vm.metadata.namespace, $vm.metadata.name] | @tsv
')

# Report as a table. column -t handles the alignment so the layout adapts
# to whatever lengths your namespaces and VM names happen to be.
{
  printf 'NAMESPACE\tVM\tFIRMWARE\tSECURE BOOT\n'
  echo "$classified" | while IFS=$'\t' read -r class ns name; do
    case "$class" in
      bios)     printf '%s\t%s\tBIOS\tn/a\n' "$ns" "$name" ;;
      efi-nosb) printf '%s\t%s\tEFI\toff\n'  "$ns" "$name" ;;
      efi-sbon) printf '%s\t%s\tEFI\ton\n'   "$ns" "$name" ;;
    esac
  done
} | column -t -s "$(printf '\t')" | sed 's/^/  /'
echo

count_bios=$(echo "$classified" | awk -F'\t' '$1=="bios"'     | wc -l | tr -d ' ')
count_nosb=$(echo "$classified" | awk -F'\t' '$1=="efi-nosb"' | wc -l | tr -d ' ')
count_sbon=$(echo "$classified" | awk -F'\t' '$1=="efi-sbon"' | wc -l | tr -d ' ')

echo "Total: $total VMs ($count_bios BIOS, $count_nosb EFI no SB, $count_sbon EFI SB on)."
echo

targets_sbon=$(echo "$classified" | awk -F'\t' '$1=="efi-sbon" {print $2"/"$3}')
targets_nosb=$(echo "$classified" | awk -F'\t' '$1=="efi-nosb" {print $2"/"$3}')

# Pick which set we act on based on the chosen direction
if $disable_sb; then
  targets="$targets_sbon"
elif $enable_sb; then
  targets="$targets_nosb"
else
  targets=""
fi

# Verify-only mode
verify_one() {
  ns="$1"; name="$2"
  pod=$(oc get pods -n "$ns" -l "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$name" \
        -o name 2>/dev/null | head -1)
  if [ -z "$pod" ]; then
    echo "  $ns/$name has no running virt-launcher (VM stopped or not scheduled)."
    return
  fi
  xml=$(oc exec -n "$ns" "$pod" -- virsh -r dumpxml 1 2>/dev/null)
  secure=$(echo "$xml" | grep -oE "secure='[^']*'" | head -1)
  nvram=$(echo "$xml"  | grep -oE "OVMF_VARS\.[a-z]*\.?fd" | head -1)
  case "$secure" in
    "secure='yes'") echo "  $ns/$name: libvirt reports $secure ($nvram). Secure Boot is enforcing." ;;
    "secure='no'")  echo "  $ns/$name: libvirt reports $secure ($nvram). Secure Boot is off." ;;
    *)              echo "  $ns/$name: could not read the secure attribute from libvirt XML." ;;
  esac
}

if $verify_only; then
  if [ -z "$targets_sbon" ]; then
    echo "Nothing classified as EFI SB on. Skipping runtime verification."
    exit 0
  fi
  echo "Checking what libvirt actually loaded (runtime can differ from spec until the VM is power-cycled):"
  for entry in $targets_sbon; do
    ns="${entry%%/*}"; name="${entry##*/}"
    verify_one "$ns" "$name"
  done
  exit 0
fi

# Read-only exit
if ! $disable_sb && ! $enable_sb; then
  if [ "$count_sbon" -eq 0 ] && [ "$count_nosb" -eq 0 ]; then
    echo "Nothing to act on (no EFI VMs found, or all are BIOS legacy)."
  else
    [ "$count_sbon" -gt 0 ] && \
      echo "  Pass --disable-secureboot to turn Secure Boot off on the $count_sbon VM(s) above."
    [ "$count_nosb" -gt 0 ] && \
      echo "  Pass --enable-secureboot to turn Secure Boot on on the $count_nosb VM(s) above (read the warning in --help first)."
  fi
  exit 0
fi

# Action mode (disable or enable) from here on
if [ -z "$targets" ]; then
  if $disable_sb; then
    echo "Nothing to disable. No VMs currently have Secure Boot on."
  else
    echo "Nothing to enable. No EFI VMs with Secure Boot off were found."
  fi
  exit 0
fi

if $disable_sb; then
  echo "I am about to disable Secure Boot on:"
else
  echo "I am about to ENABLE Secure Boot on:"
fi
for entry in $targets; do echo "  $entry"; done
echo

if $enable_sb; then
  echo "Heads up: turning Secure Boot on can break boot if the guest does not"
  echo "have a signed bootloader, signed kernel, and signed modules. Modern"
  echo "RHEL/Fedora/Ubuntu/Windows are fine; custom kernels, recompiled GRUB,"
  echo "or unsigned third-party modules are not. The VM's UEFI NVRAM is also"
  echo "reset (boot order and MOK enrollments are lost)."
  echo
fi

if $restart; then
  echo "I will patch each VM, stop it, wait for it to terminate, then start it again."
else
  echo "I will only patch the spec. The change applies on the next power-on of each VM."
  echo "Pass --restart if you want me to stop/start the VMs now instead."
fi

if ! $assume_yes; then
  printf "Proceed? [y/N] "
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "OK, leaving the cluster alone."; exit 0 ;;
  esac
fi
echo

stop_vm() {
  ns="$1"; name="$2"
  if $has_virtctl; then
    virtctl stop "$name" -n "$ns" >/dev/null
  else
    oc patch vm "$name" -n "$ns" --type=merge -p '{"spec":{"running":false}}' >/dev/null
  fi
}

start_vm() {
  ns="$1"; name="$2"
  if $has_virtctl; then
    virtctl start "$name" -n "$ns" >/dev/null
  else
    oc patch vm "$name" -n "$ns" --type=merge -p '{"spec":{"running":true}}' >/dev/null
  fi
}

wait_vmi_gone() {
  oc wait vmi "$2" -n "$1" --for=delete --timeout=180s >/dev/null 2>&1
}

wait_vmi_running() {
  ns="$1"; name="$2"
  for _ in $(seq 1 60); do
    phase=$(oc get vmi "$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$phase" = "Running" ] && return 0
    sleep 3
  done
  return 1
}

# Build the JSON patch and the expected runtime state once, outside the loop.
if $disable_sb; then
  patch_desc="set secureBoot: false"
  expected_secure="secure='no'"
  patch_payload='[
    {"op":"add","path":"/spec/template/spec/domain/firmware/bootloader/efi/secureBoot","value":false}
  ]'
else
  # Enabling: set secureBoot true and ensure SMM is enabled (required for SB).
  # The 'add' op on a JSON Patch creates intermediate objects as needed in
  # most implementations; if SMM was already on, the second op is a no-op.
  patch_desc="set secureBoot: true and SMM: enabled"
  expected_secure="secure='yes'"
  patch_payload='[
    {"op":"add","path":"/spec/template/spec/domain/firmware/bootloader/efi/secureBoot","value":true},
    {"op":"add","path":"/spec/template/spec/domain/features","value":{}},
    {"op":"add","path":"/spec/template/spec/domain/features/smm","value":{"enabled":true}}
  ]'
fi

fails=0
for entry in $targets; do
  ns="${entry%%/*}"; name="${entry##*/}"
  echo "Working on $ns/$name..."

  echo "  patching the VM spec: $patch_desc"
  # First try the full patch. If features/smm already exist, the 'add' on
  # features will fail (path exists); retry with a payload that only touches
  # secureBoot in that case.
  if ! oc patch vm "$name" -n "$ns" --type=json -p="$patch_payload" >/dev/null 2>&1; then
    if $enable_sb; then
      # Fallback: just set secureBoot, assume SMM is already configured.
      if ! oc patch vm "$name" -n "$ns" --type=json -p='[
        {"op":"add","path":"/spec/template/spec/domain/firmware/bootloader/efi/secureBoot","value":true}
      ]' >/dev/null 2>&1; then
        echo "  could not patch the VM. Skipping."
        fails=$((fails + 1))
        continue
      fi
      # Also try to add smm.enabled separately (no-op if already present).
      oc patch vm "$name" -n "$ns" --type=json -p='[
        {"op":"add","path":"/spec/template/spec/domain/features/smm","value":{"enabled":true}}
      ]' >/dev/null 2>&1 || \
      oc patch vm "$name" -n "$ns" --type=json -p='[
        {"op":"replace","path":"/spec/template/spec/domain/features/smm/enabled","value":true}
      ]' >/dev/null 2>&1 || true
    else
      echo "  could not patch the VM. Skipping."
      fails=$((fails + 1))
      continue
    fi
  fi

  if ! $restart; then
    echo "  patched. The change will apply the next time someone power-cycles this VM."
    echo
    continue
  fi

  echo "  asking KubeVirt to stop the VM"
  stop_vm "$ns" "$name"

  echo "  waiting for the running VMI to go away"
  wait_vmi_gone "$ns" "$name"

  echo "  starting the VM again"
  start_vm "$ns" "$name"
  if ! wait_vmi_running "$ns" "$name"; then
    echo "  the VMI did not reach Running in time. Will not verify this one."
    if $enable_sb; then
      echo "  (this can mean the guest no longer boots with Secure Boot. Investigate"
      echo "   with: oc describe vmi $name -n $ns and the virt-launcher logs.)"
    fi
    fails=$((fails + 1))
    echo
    continue
  fi

  echo "  checking that libvirt now reports the expected state"
  pod=$(oc get pods -n "$ns" -l "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$name" \
        -o name 2>/dev/null | head -1)
  if [ -z "$pod" ]; then
    echo "  could not find the new virt-launcher pod to verify against."
    fails=$((fails + 1))
    echo
    continue
  fi
  sb=$(oc exec -n "$ns" "$pod" -- virsh -r dumpxml 1 2>/dev/null \
       | grep -oE "secure='[^']*'" | head -1)
  if [ "$sb" = "$expected_secure" ]; then
    echo "  done: libvirt reports $sb."
  else
    echo "  something is off: expected $expected_secure but got '$sb'."
    fails=$((fails + 1))
  fi
  echo
done

if [ "$fails" -eq 0 ]; then
  echo "All done. No errors."
  exit 0
else
  echo "Finished, but $fails VM(s) had problems. Scroll up for the details."
  exit 1
fi
