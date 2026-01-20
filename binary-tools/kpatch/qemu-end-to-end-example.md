# kpatch: End-to-End QEMU-Based Example

**Topic:** Easy, hands-on kpatch testing using QEMU
**Date:** 2025-01-20
**Level:** Beginner to Intermediate
**Based on:** kpatch source code and Linux kernel samples/livepatch

---

## Overview

This guide provides a complete, tested example for learning and experimenting with kpatch (kernel live patching) using QEMU virtualization. You'll build a kernel, create a live patch, and apply it without rebooting - all in a safe VM environment.

---

## Table of Contents

- [Prerequisites](#prerequisites)
  - [Host System Requirements](#host-system-requirements)
  - [System Resources](#system-resources)
- [Quick Start: 20-Minute Tutorial](#quick-start-20-minute-tutorial)
  - [Step 1: Clone and Setup kpatch](#step-1-clone-and-setup-kpatch)
  - [Step 2: Create a Simple Test Patch](#step-2-create-a-simple-test-patch)
- [Method 1: Using Your Current Kernel (Easiest)](#method-1-using-your-current-kernel-easiest)
  - [Step 3: Build the Patch Module](#step-3-build-the-patch-module)
  - [Step 4: Load and Test the Patch](#step-4-load-and-test-the-patch)
- [Method 2: Complete QEMU-Based Setup (Recommended for Learning)](#method-2-complete-qemu-based-setup-recommended-for-learning)
  - [Step 3: Obtain Kernel Source](#step-3-obtain-kernel-source)
  - [Step 4: Configure Kernel for Livepatch](#step-4-configure-kernel-for-livepatch)
  - [Step 5: Build Kernel](#step-5-build-kernel)
  - [Step 6: Create Root Filesystem for QEMU](#step-6-create-root-filesystem-for-qemu)
  - [Step 7: Boot VM with Custom Kernel](#step-7-boot-vm-with-custom-kernel)
  - [Step 8: Inside VM - Install kpatch Dependencies](#step-8-inside-vm---install-kpatch-dependencies)
  - [Step 9: Transfer and Build kpatch Inside VM](#step-9-transfer-and-build-kpatch-inside-vm)
  - [Step 10: Create, Build, and Load Patch Inside VM](#step-10-create-build-and-load-patch-inside-vm)
- [Method 3: Using Kernel Samples (Simplest Code Example)](#method-3-using-kernel-samples-simplest-code-example)
  - [Step 1: Build Sample Modules](#step-1-build-sample-modules)
  - [Step 2: Examine the Sample Code](#step-2-examine-the-sample-code)
  - [Step 3: Load and Test Sample](#step-3-load-and-test-sample)
- [Understanding What Happens Under the Hood](#understanding-what-happens-under-the-hood)
  - [kpatch-build Process](#kpatch-build-process)
  - [Runtime: How ftrace Hooks Functions](#runtime-how-ftrace-hooks-functions)
  - [Verify Patch Status](#verify-patch-status)
- [Troubleshooting](#troubleshooting)
  - [Issue: "CONFIG_LIVEPATCH not enabled"](#issue-config_livepatch-not-enabled)
  - [Issue: "kpatch-build fails with compiler version mismatch"](#issue-kpatch-build-fails-with-compiler-version-mismatch)
  - [Issue: "kpatch load fails"](#issue-kpatch-load-fails)
  - [Issue: "QEMU VM doesn't boot"](#issue-qemu-vm-doesnt-boot)
- [Advanced: Creating Your Own Patch](#advanced-creating-your-own-patch)
  - [Example: Adding a printk Statement](#example-adding-a-printk-statement)
- [Safety Best Practices](#safety-best-practices)
  - [DO: Safe Changes](#do-safe-changes)
  - [DON'T: Unsafe Changes](#dont-unsafe-changes)
  - [Always Test Before Production](#always-test-before-production)
- [Quick Reference: Essential Commands](#quick-reference-essential-commands)
- [References and Resources](#references-and-resources)
  - [Source Code Locations](#source-code-locations)
  - [Documentation](#documentation)
  - [Testing](#testing)
  - [Key Files for Understanding](#key-files-for-understanding)
- [Next Steps](#next-steps)
- [Summary: Complete Workflow](#summary-complete-workflow)

---

## Prerequisites

### Host System Requirements

```bash
# Required packages on Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    bridge-utils \
    virtinst \
    virt-manager \
    cpu-checker \
    git \
    build-essential \
    libelf-dev \
    elfutils \
    bison \
    flex \
    openssl \
    bc \
    kmod \
    ccache

# Verify KVM support
kvm-ok
# Should output: KVM acceleration can be used
```

### System Resources

- **Disk Space:** 30GB+ free (15GB for kernel build cache, 15GB for VM)
- **RAM:** 8GB+ recommended (4GB for host, 4GB for VM)
- **CPU:** Hardware virtualization support (VT-x/AMD-V)

---

## Quick Start: 20-Minute Tutorial

### Step 1: Clone and Setup kpatch

```bash
# Navigate to kpatch directory (assuming you have it)
cd /home/egg/source/linux/kpatch

# OR clone fresh
git clone https://github.com/dynup/kpatch.git
cd kpatch

# Install build dependencies (requests root)
make dependencies

# Build kpatch tools
make
sudo make install
```

### Step 2: Create a Simple Test Patch

Create `/tmp/meminfo-test.patch`:

```diff
Index: src/fs/proc/meminfo.c
===================================================================
--- src.orig/fs/proc/meminfo.c
+++ src/fs/proc/meminfo.c
@@ -95,7 +95,7 @@ static int meminfo_proc_show(struct seq_
 		"Committed_AS:   %8lu kB\n"
 		"VmallocTotal:   %8lu kB\n"
 		"VmallocUsed:    %8lu kB\n"
-		"VmallocChunk:   %8lu kB\n"
+		"VMALLOCCHUNK:   %8lu kB\n"  /* CHANGED: ALL CAPS for visibility */
 #ifdef CONFIG_MEMORY_FAILURE
 		"HardwareCorrupted: %5lu kB\n"
 #endif
```

**What this patch does:**
- Changes "VmallocChunk" to "VMALLOCCHUNK" in /proc/meminfo
- Safe for learning: only changes a string, no logic changes
- Easy to verify: visible in `/proc/meminfo`

---

## Method 1: Using Your Current Kernel (Easiest)

If your host kernel already has `CONFIG_LIVEPATCH` enabled (check with `zcat /proc/config.gz | grep LIVEPATCH` or `cat /boot/config-$(uname -r) | grep LIVEPATCH`), you can test directly:

### Step 3: Build the Patch Module

```bash
cd /home/egg/source/linux/kpatch

# Build patch module
./kpatch-build/kpatch-build /tmp/meminfo-test.patch

# Expected output:
# Using cache at /home/user/.kpatch/6.x.x/src
# Testing patch file
# checking file fs/proc/meminfo.c
# Building original kernel
# Building patched kernel
# Detecting changed objects
# Rebuilding changed objects
# Extracting new and modified ELF sections
# meminfo.o: changed function: meminfo_proc_show
# Building patch module: livepatch-meminfo-test.ko
# SUCCESS

# The output module is created
ls -lh livepatch-meminfo-test.ko
```

### Step 4: Load and Test the Patch

```bash
# Load the patch module
sudo ./kpatch/kpatch load livepatch-meminfo-test.ko

# Verify the patch is loaded
cat /sys/kernel/livepatch/livepatch_meminfo_test/enabled
# Output: 1

# Check the change
grep Vmalloc /proc/meminfo
# Output: VMALLOCCHUNK:   34359337092 kB  ← Changed!

# View patch info in sysfs
ls /sys/kernel/livepatch/livepatch_meminfo_test/
# enabled: 1
# transition: 0

# Unload the patch
sudo ./kpatch/kpatch unload livepatch-meminfo-test
grep Vmalloc /proc/meminfo
# Output: VmallocChunk:   34359337092 kB  ← Back to original!
```

---

## Method 2: Complete QEMU-Based Setup (Recommended for Learning)

This method builds a custom kernel with livepatch support and runs it in QEMU.

### Step 3: Obtain Kernel Source

```bash
# Use your existing kernel tree
cd /home/egg/source/linux

# OR download fresh kernel
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.1.tar.xz
tar -xf linux-6.6.1.tar.xz
cd linux-6.6.1
```

### Step 4: Configure Kernel for Livepatch

```bash
# Copy current config as base
cp /boot/config-$(uname -r) .config

# Enable livepatch options
./scripts/config --set-val CONFIG_LIVEPATCH y
./scripts/config --set-val CONFIG_DEBUG_INFO y
./scripts/config --set-val CONFIG_DEBUG_INFO_REDUCED y
./scripts/config --set-val CONFIG_FTRACE y
./scripts/config --set-val CONFIG_FUNCTION_TRACER y

# Or use make menuconfig for interactive config
make menuconfig
# Navigate to:
#   Processor type and features  --->
#     [*] Enable livepatching support

# Build configuration
make olddefconfig

# Verify config
grep CONFIG_LIVEPATCH .config
# Should show: CONFIG_LIVEPATCH=y
```

### Step 5: Build Kernel

```bash
# Build with parallel jobs (adjust -j based on CPU cores)
make -j$(nproc) bzImage modules

# This will take 15-60 minutes depending on your system
# Output: arch/x86/boot/bzImage
```

### Step 6: Create Root Filesystem for QEMU

```bash
# Download Fedora cloud image (fast and easy)
cd /tmp
wget https://download.fedoraproject.org/pub/fedora/linux/releases/39/Cloud/x86_64/images/Fedora-Cloud-Base-39-1.5.x86_64.qcow2

# OR create Debian cloud image
wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2

# Create working copy
qemu-img create -f qcow2 -F qcow2 -b Fedora-Cloud-Base-39-1.5.x86_64.qcow2 test-vm.qcow2 20G

# Resize image if needed
qemu-img resize test-vm.qcow2 +20G
```

### Step 7: Boot VM with Custom Kernel

```bash
# Create QEMU boot script
cat > /tmp/run-kpatch-vm.sh << 'EOF'
#!/bin/bash
KERNEL=/home/egg/source/linux/arch/x86/boot/bzImage
ROOTFS=/tmp/test-vm.qcow2

qemu-system-x86_64 \
    -m 4G \
    -smp 2 \
    -kernel $KERNEL \
    -drive file=$ROOTFS,if=virtio,format=qcow2 \
    -net user,hostfwd=tcp::2222-:22 \
    -net nic,model=virtio \
    -nographic \
    -append "root=/dev/vda1 ro console=ttyS0 loglevel=7" \
    -enable-kvm \
    -cpu host \
    $@
EOF

chmod +x /tmp/run-kpatch-vm.sh

# Boot the VM
/tmp/run-kpatch-vm.sh
```

**Login to VM:**
- Fedora cloud image default: `fedora` / `fedora`
- Or via SSH: `ssh -p 2222 fedora@localhost`

### Step 8: Inside VM - Install kpatch Dependencies

```bash
# Inside the VM
sudo dnf install -y \
    gcc \
    make \
    elfutils \
    elfutils-devel \
    git \
    rpm-build \
    wget \
    patchutils \
    bison \
    flex \
    openssl-devel \
    elfutils-libelf-devel

# Install kernel build dependencies
sudo dnf builddep -y kernel

# Install kernel debuginfo (for your running kernel)
KVER=$(uname -r)
sudo dnf install -y kernel-debuginfo-$KVER kernel-devel-$KVER

# Setup ccache (highly recommended)
sudo dnf install -y ccache
ccache --max-size 5G
```

### Step 9: Transfer and Build kpatch Inside VM

```bash
# From host, copy kpatch to VM
scp -P 2222 -r /home/egg/source/linux/kpatch fedora@localhost:/home/fedora/

# Inside VM, build and install kpatch
cd /home/fedora/kpatch
make
sudo make install
```

### Step 10: Create, Build, and Load Patch Inside VM

```bash
# Inside VM, create test patch
cat > /tmp/meminfo-test.patch << 'PATCH'
Index: src/fs/proc/meminfo.c
===================================================================
--- src.orig/fs/proc/meminfo.c
+++ src/fs/proc/meminfo.c
@@ -95,7 +95,7 @@ static int meminfo_proc_show(struct seq_
 		"Committed_AS:   %8lu kB\n"
 		"VmallocTotal:   %8lu kB\n"
 		"VmallocUsed:    %8lu kB\n"
-		"VmallocChunk:   %8lu kB\n"
+		"VMALLOCCHUNK:   %8lu kB\n"
 #ifdef CONFIG_MEMORY_FAILURE
 		"HardwareCorrupted: %5lu kB\n"
 #endif
PATCH

# Build patch module
kpatch-build /tmp/meminfo-test.patch

# Load the patch
sudo kpatch load livepatch-meminfo-test.ko

# Verify
grep -i chunk /proc/meminfo
# Output: VMALLOCCHUNK:   34359337092 kB

# Success! Kernel patched without reboot!
```

---

## Method 3: Using Kernel Samples (Simplest Code Example)

The Linux kernel has built-in livepatch examples. This is the simplest way to understand the code structure.

### Step 1: Build Sample Modules

```bash
# In your kernel source tree
cd /home/egg/source/linux

# Build the livepatch samples
make M=samples/livepatch

# This creates:
# - samples/livepatch/livepatch-sample.ko
# - samples/livepatch/livepatch-callbacks-demo.ko
# - samples/livepatch/livepatch-callbacks-mod.ko
# - etc.
```

### Step 2: Examine the Sample Code

```bash
# View the simplest example
cat samples/livepatch/livepatch-sample.c

# Key parts:
# 1. KLPCODE macros define the patch
# 2. klp_func structs declare what to replace
# 3. module_init/exit load/unload the patch
```

```c
// Simplified view from livepatch-sample.c
#include <linux/livepatch.h>

/* Replacement function: changes command line output */
static int livepatch_cmdline_proc_show(struct seq_file *m, void *v)
{
    seq_printf(m, "%s\n", "this has been live patched");
    return 0;
}

/* Map old function to new function */
static struct klp_func funcs[] = {
    {
        .old_name = "cmdline_proc_show",  // Function to replace
        .new_func = livepatch_cmdline_proc_show,  // Replacement
    }, { }
};

/* Define the patch */
static struct klp_object objs[] = {
    {
        .funcs = funcs,
    }, { }
};

static struct klp_patch patch = {
    .mod = THIS_MODULE,
    .objs = objs,
};

/* Load and unload functions */
static int livepatch_init(void)
{
    return klp_enable_patch(&patch);
}

static void livepatch_exit(void)
{
    /* Automatic cleanup */
}
module_init(livepatch_init);
module_exit(livepatch_exit);
```

### Step 3: Load and Test Sample

```bash
# Check original /proc/cmdline
cat /proc/cmdline
# Output: BOOT_IMAGE=/vmlinuz-6.x.x ...

# Load the sample patch
sudo insmod samples/livepatch/livepatch-sample.ko

# Check again - it's changed!
cat /proc/cmdline
# Output: this has been live patched

# Unload to restore
sudo rmmod livepatch_sample

# Back to original
cat /proc/cmdline
# Output: BOOT_IMAGE=/vmlinuz-6.x.x ...
```

---

## Understanding What Happens Under the Hood

### kpatch-build Process

```
1. Build original kernel
   ├── Compiles without your patch
   ├── Creates orig/version.o files

2. Apply patch & rebuild
   ├── Applies your .patch file
   ├── Recompiles only changed files
   ├── Creates patched/version.o files

3. Compare objects
   ├── create-diff-object compares orig/*.o vs patched/*.o
   ├── Uses -ffunction-sections for granular comparison
   ├── Identifies changed functions and dependencies

4. Create patch module
   ├── Extracts changed functions
   ├── Adds metadata (.kpatch.funcs, .kpatch.dynrelas)
   ├── Creates livepatch-*.ko module
```

### Runtime: How ftrace Hooks Functions

```
Original function:
  push rbp
  mov rbp, rsp
  call fentry  ← ftrace hook point
  ... function code ...
  pop rbp
  ret

After patch is loaded:
  fentry handler checks if livepatch is active
  → If yes: redirect to new function
  → If no: execute original function
```

### Verify Patch Status

```bash
# Check if patch is loaded
ls /sys/kernel/livepatch/
# Output: livepatch_meminfo_test

# Check patch details
cat /sys/kernel/livepatch/livepatch_meminfo_test/enabled
# Output: 1 (patch is active)

# Check for taint flag (kernel knows it was patched)
cat /proc/sys/kernel/tainted
# Output may include: 32768 (TAINT_LIVEPATCH)
```

---

## Troubleshooting

### Issue: "CONFIG_LIVEPATCH not enabled"

```bash
# Check kernel config
zcat /proc/config.gz | grep CONFIG_LIVEPATCH
# OR
cat /boot/config-$(uname -r) | grep CONFIG_LIVEPATCH

# Should be: CONFIG_LIVEPATCH=y

# If not set, rebuild kernel with it enabled
./scripts/config --set-val CONFIG_LIVEPATCH y
make olddefconfig
make -j$(nproc)
sudo make modules_install install
sudo reboot
```

### Issue: "kpatch-build fails with compiler version mismatch"

```bash
# kpatch-build requires matching compiler versions
# Check what compiler built your kernel
readelf -p .comment /lib/modules/$(uname -r)/vmlinux | grep GCC

# Install matching GCC version
# On Fedora/RHEL:
sudo dnf install gcc-$(uname -r | cut -d. -f1,2)

# Use with kpatch-build
CC=gcc-$(uname -r | cut -d. -f1,2) kpatch-build patch.patch
```

### Issue: "kpatch load fails"

```bash
# Check dmesg for errors
dmesg | tail -20

# Common causes:
# 1. Kernel doesn't support livepatch
#    → Check CONFIG_LIVEPATCH=y
# 2. Patch module built for wrong kernel version
#    → Rebuild with correct kernel source
# 3. Security restrictions (Secure Boot)
#    → Disable Secure Boot or sign the module
```

### Issue: "QEMU VM doesn't boot"

```bash
# 1. Check kernel path
ls -lh /home/egg/source/linux/arch/x86/boot/bzImage

# 2. Verify KVM support
kvm-ok

# 3. Check root filesystem path
ls -lh /tmp/test-vm.qcow2

# 4. Try with graphic console instead of -nographic
# Remove -nographic from QEMU command
```

---

## Advanced: Creating Your Own Patch

### Example: Adding a printk Statement

```diff
Index: src/kernel/sched/core.c
===================================================================
--- src.orig/kernel/sched/core.c
+++ src/kernel/sched/core.c
@@ -4545,6 +4545,9 @@ asmlinkage __visible void __sched schedu
 {
     struct task_struct *tsk = current;

+    /* KPATCH: Add debugging output */
+    printk(KERN_INFO "kpatch: Schedule called on %s (pid=%d)\n", tsk->comm, tsk->pid);
+
     sched_submit_work(tsk);
 }
```

**Build and test:**
```bash
kpatch-build sched-debug.patch
sudo kpatch load livepatch-sched-debug.ko

# Watch dmesg
dmesg -w
# You'll see kpatch messages as tasks are scheduled!

# Unload when done
sudo kpatch unload livepatch-sched-debug
```

---

## Safety Best Practices

### DO: Safe Changes
- ✅ Change string literals
- ✅ Add printk/pr_debug statements
- ✅ Modify function logic (with care)
- ✅ Use callbacks for complex changes
- ✅ Test thoroughly in VM first

### DON'T: Unsafe Changes
- ❌ Change `__init` functions
- ❌ Modify static data structures
- ❌ Change function signatures
- ❌ Alter data layout
- ❌ Patch without understanding dependencies

### Always Test Before Production

```bash
# Test in QEMU VM first!
# 1. Build and load patch in VM
# 2. Run your workload
# 3. Check dmesg for errors
# 4. Verify patch works correctly
# 5. Unload and verify restore
# 6. Only then consider production use
```

---

## Quick Reference: Essential Commands

```bash
# Build patch module
kpatch-build your-patch.patch

# Load patch
sudo kpatch load livepatch-patch.ko

# List loaded patches
sudo kpatch list

# Unload patch
sudo kpatch unload livepatch-patch

# Check livepatch sysfs
cat /sys/kernel/livepatch/*/enabled
ls /sys/kernel/livepatch/

# View kernel taint
cat /proc/sys/kernel/tainted

# Check dmesg for livepatch messages
dmesg | grep -i livepatch
dmesg | grep -i kpatch
```

---

## References and Resources

### Source Code Locations
- **kpatch:** `/home/egg/source/linux/kpatch/`
- **kpatch-build script:** `kpatch/kpatch-build/kpatch-build`
- **create-diff-object:** `kpatch/kpatch-build/create-diff-object.c`
- **Sample patches:** `kpatch/test/integration/fedora-27/*.patch`
- **Kernel samples:** `/home/egg/source/linux/samples/livepatch/`

### Documentation
- **kpatch README:** `kpatch/README.md`
- **Installation guide:** `kpatch/doc/INSTALL.md`
- **Patch author guide:** `kpatch/doc/patch-author-guide.md`
- **Kernel livepatch docs:** `Documentation/livepatch/`

### Testing
- **Integration tests:** `kpatch/test/integration/`
- **kpatch-test script:** `kpatch/test/integration/kpatch-test`
- **Test framework:** `kpatch/test/integration/lib.sh`

### Key Files for Understanding
1. `create-diff-object.c` - Binary differencing engine
2. `kpatch-build` - Main build script
3. `livepatch-sample.c` - Simplest example
4. `new-function.patch` - Example of adding functions

---

## Next Steps

1. **Practice** with the meminfo patch example
2. **Experiment** with kernel samples/livepatch modules
3. **Study** the `create-diff-object.c` source code
4. **Read** `patch-author-guide.md` for advanced techniques
5. **Contribute** test cases or improvements to kpatch

---

## Summary: Complete Workflow

```bash
# 1. Create your source patch
cat > my-fix.patch << 'PATCH'
(Your diff here)
PATCH

# 2. Build patch module
kpatch-build my-fix.patch
# Output: livepatch-my-fix.ko

# 3. Load the patch
sudo kpatch load livepatch-my-fix.ko

# 4. Verify it works
# Check your fix is applied

# 5. Unload when done
sudo kpatch unload livepatch-my-fix
```

**That's it!** You've just patched a running kernel without rebooting. 🎉

---

<!-- Source: linux kernel git repository at tag v6.19-rc5 -->
<!-- Based on kpatch source at /home/egg/source/linux/kpatch -->
