#!/bin/bash
# Boot a diskimage-builder appliance in QEMU and collect its output.
#
# The appliance is a kernel plus an initramfs that performs a diskimage-builder
# build (for example an ironic-python-agent ramdisk or a qcow2 image). It is
# deliberately offline and has no implicit hardware, so a build that needs an
# asset which is not on the input disk fails instead of downloading it.
# Running the build on a real kernel also gives diskimage-builder working loop
# devices, mount namespaces and a writable /boot.
#
# Contract with the appliance:
#   * /dev/vda is a read-only ext4 filesystem labelled $VM_DATA_LABEL, created
#     from the contents of $DATA_DIR.
#   * /dev/vdb is a writable ext4 filesystem labelled $VM_OUT_LABEL, where the
#     appliance writes:
#       $VM_STATUS_PATH     the build exit status (0 on success)
#     and the files named by $VM_ARTIFACTS, relative to that filesystem root.
#   * The appliance powers itself off when it is done.
#
# Nothing here is specific to a particular image: $VM_ARTIFACTS names the
# files the appliance publishes, and they are copied into $OUTPUT_DIR, so the
# caller decides what the build produces.
#
# No privileges are required. QEMU uses TCG unless /dev/kvm is available, and
# the disks are created and read with e2fsprogs (mke2fs -d, debugfs), which
# needs no loop devices or mount privilege.

set -euo pipefail

BUILD_DIR=${BUILD_DIR:-/build}
DATA_DIR=${DATA_DIR:-/vmdata}
OUTPUT_DIR=${OUTPUT_DIR:-${BUILD_DIR}}
VM_KERNEL=${VM_KERNEL:-${BUILD_DIR}/vm.kernel}
VM_INITRAMFS=${VM_INITRAMFS:-${BUILD_DIR}/vm.initramfs}
VM_DATA_LABEL=${VM_DATA_LABEL:-dib-data}
VM_OUT_LABEL=${VM_OUT_LABEL:-dib-out}
VM_STATUS_PATH=${VM_STATUS_PATH:-/status}
VM_ARTIFACTS=${VM_ARTIFACTS:-}
VM_DATA_IMG=${VM_DATA_IMG:-${BUILD_DIR}/vm-data.img}
VM_OUT_IMG=${VM_OUT_IMG:-${BUILD_DIR}/vm-out.img}
VM_OUT_KB=${VM_OUT_KB:-}
EXTRACT_DIR=${EXTRACT_DIR:-${BUILD_DIR}/vm-extract}
CONSOLE_LOG=${CONSOLE_LOG:-${BUILD_DIR}/vm.console.log}
VM_CPUS=${VM_CPUS:-4}
VM_MEMORY=${VM_MEMORY:-4096}
VM_TIMEOUT=${VM_TIMEOUT:-5400}
VM_MACHINE=${VM_MACHINE:-q35}
QEMU_BIN=${QEMU_BIN:-}

log() { echo "=== $* ==="; }

dump_console() {
    if [[ -f ${CONSOLE_LOG} ]]; then
        echo "--- last 500 lines of the guest console (${CONSOLE_LOG}) ---" >&2
        tail -n 500 "${CONSOLE_LOG}" >&2
    fi
}

# EL packages install the system emulator as /usr/libexec/qemu-kvm, Fedora
# style packages provide qemu-system-x86_64 on PATH. Accept either.
if [[ -z ${QEMU_BIN} ]]; then
    for candidate in qemu-system-x86_64 /usr/libexec/qemu-kvm qemu-kvm; do
        if [[ ${candidate} == /* ]]; then
            if [[ -x ${candidate} ]]; then
                QEMU_BIN=${candidate}
                break
            fi
        elif command -v "${candidate}" >/dev/null 2>&1; then
            QEMU_BIN=${candidate}
            break
        fi
    done
fi
if [[ -z ${QEMU_BIN} ]]; then
    echo "ERROR: no QEMU system emulator found (is qemu-kvm installed?)" >&2
    ls -l /usr/libexec/qemu-kvm /usr/bin/qemu-kvm /usr/bin/qemu-system-x86_64 2>&1 >&2 || true
    rpm -qa 'qemu*' >&2 || true
    exit 1
fi

# Size the disks from the input contents. The output disk has to hold the
# build tree as well as the published artifacts, so allow extra room; callers
# building larger images can override VM_OUT_KB.
data_kb=$(du -sk "${DATA_DIR}" | cut -f1)
data_img_kb=$(( data_kb * 12 / 10 + 262144 ))
out_img_kb=${VM_OUT_KB:-$(( data_kb + 4194304 ))}

log "Creating VM input disk (${data_img_kb}K)"
truncate -s "${data_img_kb}K" "${VM_DATA_IMG}"
mke2fs -t ext4 -F -q -L "${VM_DATA_LABEL}" -d "${DATA_DIR}" "${VM_DATA_IMG}"

log "Creating VM output disk (${out_img_kb}K)"
truncate -s "${out_img_kb}K" "${VM_OUT_IMG}"
mke2fs -t ext4 -F -q -L "${VM_OUT_LABEL}" "${VM_OUT_IMG}"

if [[ -w /dev/kvm ]]; then
    accel=kvm
    cpu=host
else
    accel=tcg,thread=multi
    cpu=max
fi

log "Booting diskimage-builder appliance (${VM_CPUS} vCPU, ${VM_MEMORY}MB, ${accel}, ${QEMU_BIN})"
# Stream the guest serial console into the image build log as it happens and
# keep a copy for the failure diagnostics below. -serial stdio requires that
# no other character device (such as a graphical display) uses the stdio.
#
# The guest is deliberately offline and has no implicit hardware: -nodefaults
# drops QEMU's default devices and -nic none guarantees there is no network
# interface, so the build fails if any asset is expected from the network.
set +e
timeout "${VM_TIMEOUT}" "${QEMU_BIN}" \
    -M "${VM_MACHINE}" \
    -nodefaults \
    -accel "${accel}" \
    -cpu "${cpu}" \
    -smp "${VM_CPUS}" \
    -m "${VM_MEMORY}" \
    -display none \
    -no-reboot \
    -nic none \
    -device virtio-rng-pci \
    -kernel "${VM_KERNEL}" \
    -initrd "${VM_INITRAMFS}" \
    -append "console=ttyS0 selinux=0 rdinit=/init panic=1" \
    -serial stdio \
    -drive "file=${VM_DATA_IMG},if=virtio,format=raw,readonly=on" \
    -drive "file=${VM_OUT_IMG},if=virtio,format=raw,cache=unsafe" \
    2>&1 </dev/null | tee "${CONSOLE_LOG}"
rc=${PIPESTATUS[0]}
set -e

if [[ ${rc} -ne 0 ]]; then
    echo "ERROR: QEMU exited with status ${rc} (console log: ${CONSOLE_LOG})" >&2
    dump_console
    exit 1
fi

# Replay the journal in case the guest did not unmount cleanly; debugfs does
# not do journal recovery itself.
e2fsck -fy "${VM_OUT_IMG}" >/dev/null 2>&1 || true

# Extract one file from the output image. debugfs exits 0 even when its
# command fails, so verify the destination instead of the exit status; fall
# back to streaming the file to stdout if "dump" did not produce it.
extract_file() {
    local src="$1"
    local dest="$2"

    rm -f "${dest}"
    debugfs -R "dump ${src} ${dest}" "${VM_OUT_IMG}" >/dev/null 2>&1 || true
    if [[ -s ${dest} ]]; then
        return 0
    fi
    debugfs -R "cat ${src}" "${VM_OUT_IMG}" 2>/dev/null >"${dest}" || true
    [[ -s ${dest} ]]
}

dump_out_dir() {
    echo "--- / in ${VM_OUT_IMG} ---" >&2
    debugfs -R "ls -l /" "${VM_OUT_IMG}" 1>&2 || true
}

rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}" "${OUTPUT_DIR}"

if ! extract_file "${VM_STATUS_PATH}" "${EXTRACT_DIR}/status"; then
    echo "ERROR: could not read the build status from ${VM_OUT_IMG}" >&2
    dump_out_dir
    dump_console
    exit 1
fi

status=$(cat "${EXTRACT_DIR}/status")
if [[ "${status}" != "0" ]]; then
    echo "ERROR: in-VM build failed (status: ${status})" >&2
    dump_console
    exit 1
fi

if [[ -z ${VM_ARTIFACTS} ]]; then
    echo "ERROR: VM_ARTIFACTS must list the files the appliance publishes" >&2
    dump_out_dir
    exit 1
fi

read -r -a artifacts <<<"${VM_ARTIFACTS}"
for name in "${artifacts[@]}"; do
    case "${name}" in
        /* | *..*)
            echo "ERROR: invalid artifact path '${name}'" >&2
            exit 1
            ;;
    esac
    dest="${OUTPUT_DIR}/${name}"
    mkdir -p "$(dirname "${dest}")"
    if ! extract_file "/${name}" "${dest}"; then
        echo "ERROR: the appliance did not produce ${name}" >&2
        dump_out_dir
        dump_console
        exit 1
    fi
done

# The disks are large and only needed during this build step.
rm -rf "${EXTRACT_DIR}"
rm -f "${VM_DATA_IMG}" "${VM_OUT_IMG}"

log "Build artifacts written to ${OUTPUT_DIR}: ${VM_ARTIFACTS}"
