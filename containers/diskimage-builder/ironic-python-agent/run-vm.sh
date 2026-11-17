#!/bin/bash
# Run ironic-python-agent-builder inside a QEMU guest during the image build.
#
# Building in a VM gives diskimage-builder a real kernel, loop devices and
# writable pseudo-filesystems, which removes the container workarounds that
# were previously needed (placeholder /boot/initramfs, DIB_BIND_MOUNTS,
# DIB_NO_TMPFS). No privileges are required: QEMU uses TCG unless /dev/kvm
# is available.
#
# Inputs are packed into a read-only ext4 disk (ipa-data) so that the
# appliance initramfs stays small enough to fit in guest RAM. The build
# output is written to a second ext4 disk (ipa-out) and extracted with
# debugfs, which needs no loop devices or mount privileges.

set -euo pipefail

BUILD_DIR=${BUILD_DIR:-/build}
DATA_DIR=${DATA_DIR:-/vmdata}
IMAGE_NAME=${IMAGE_NAME:-ironic-python-agent}
KERNEL=${KERNEL:-${BUILD_DIR}/ipa-builder.kernel}
INITRAMFS=${INITRAMFS:-${BUILD_DIR}/ipa-builder.initramfs}
CONSOLE_LOG=${CONSOLE_LOG:-${BUILD_DIR}/ipa-builder.console.log}
DATA_IMG=${DATA_IMG:-${BUILD_DIR}/ipa-data.img}
OUT_IMG=${OUT_IMG:-${BUILD_DIR}/ipa-out.img}
OUT_DIR=${OUT_DIR:-${BUILD_DIR}/vm-out}
VM_CPUS=${VM_CPUS:-4}
VM_MEMORY=${VM_MEMORY:-4096}
VM_TIMEOUT=${VM_TIMEOUT:-5400}
QEMU_BIN=${QEMU_BIN:-}

log() { echo "=== $* ==="; }

dump_console() {
    if [[ -f ${CONSOLE_LOG} ]]; then
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

# Size the disks from their contents: DIB extracts the os_source tarball and
# copies the wheels into the chroot, then writes the initramfs and kernel.
data_kb=$(du -sk "${DATA_DIR}" | cut -f1)
data_kb=$(( data_kb * 12 / 10 + 262144 ))
tar_kb=$(du -sk "${DATA_DIR}/os_source.tar" | cut -f1)
wheels_kb=$(du -sk "${DATA_DIR}/wheels" | cut -f1)
out_kb=$(( tar_kb + wheels_kb + 2097152 ))

log "Creating VM input disk (${data_kb}K)"
truncate -s "${data_kb}K" "${DATA_IMG}"
mke2fs -t ext4 -F -q -L ipa-data -d "${DATA_DIR}" "${DATA_IMG}"

log "Creating VM output disk (${out_kb}K)"
truncate -s "${out_kb}K" "${OUT_IMG}"
mke2fs -t ext4 -F -q -L ipa-out "${OUT_IMG}"

if [[ -w /dev/kvm ]]; then
    accel=kvm
    cpu=host
else
    accel=tcg,thread=multi
    cpu=max
fi

log "Booting build appliance (${VM_CPUS} vCPU, ${VM_MEMORY}MB, ${accel}, ${QEMU_BIN})"
set +e
timeout "${VM_TIMEOUT}" "${QEMU_BIN}" \
    -M q35 \
    -accel "${accel}" \
    -cpu "${cpu}" \
    -smp "${VM_CPUS}" \
    -m "${VM_MEMORY}" \
    -display none \
    -no-reboot \
    -device virtio-rng-pci \
    -kernel "${KERNEL}" \
    -initrd "${INITRAMFS}" \
    -append "console=ttyS0 selinux=0 rdinit=/init panic=1" \
    -serial "file:${CONSOLE_LOG}" \
    -drive "file=${DATA_IMG},if=virtio,format=raw,readonly=on" \
    -drive "file=${OUT_IMG},if=virtio,format=raw,cache=unsafe"
rc=$?
set -e

if [[ ${rc} -ne 0 ]]; then
    echo "ERROR: QEMU exited with status ${rc} (console log: ${CONSOLE_LOG})" >&2
    dump_console
    exit 1
fi

# Replay the journal in case the guest did not unmount cleanly; debugfs does
# not do journal recovery itself.
e2fsck -fy "${OUT_IMG}" >/dev/null 2>&1 || true

# Extract one file from /out in the image. debugfs exits 0 even when its
# command fails, so verify the destination instead of the exit status; fall
# back to streaming the file to stdout if "dump" did not produce it.
extract_file() {
    local name="$1"
    local dest="$2"

    rm -f "${dest}"
    debugfs -R "dump /out/${name} ${dest}" "${OUT_IMG}" >/dev/null 2>&1 || true
    if [[ -s ${dest} ]]; then
        return 0
    fi
    debugfs -R "cat /out/${name}" "${OUT_IMG}" 2>/dev/null >"${dest}" || true
    [[ -s ${dest} ]]
}

dump_out_dir() {
    echo "--- /out in ${OUT_IMG} ---" >&2
    debugfs -R "ls -l /out" "${OUT_IMG}" 1>&2 || true
}

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
if ! extract_file status "${OUT_DIR}/status"; then
    echo "ERROR: could not read the build status from ${OUT_IMG}" >&2
    dump_out_dir
    dump_console
    exit 1
fi

status=$(cat "${OUT_DIR}/status")
if [[ "${status}" != "0" ]]; then
    echo "ERROR: in-VM build failed (status: ${status})" >&2
    dump_console
    exit 1
fi

for suffix in initramfs kernel; do
    src="${OUT_DIR}/ironic-python-agent.${suffix}"
    if ! extract_file "ironic-python-agent.${suffix}" "${src}"; then
        echo "ERROR: ironic-python-agent.${suffix} was not produced by the in-VM build" >&2
        dump_out_dir
        dump_console
        exit 1
    fi
    mv "${src}" "${BUILD_DIR}/${IMAGE_NAME}.${suffix}"
done

# The disks are large and only needed during this build step.
rm -f "${DATA_IMG}" "${OUT_IMG}"
rm -rf "${OUT_DIR}" "${DATA_DIR}"

log "Build artifacts written to ${BUILD_DIR}/${IMAGE_NAME}.{initramfs,kernel}"
