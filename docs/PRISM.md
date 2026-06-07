# Prism Kernel for ASUS X01BD/X01BDA

Device: ASUS Zenfone Max Pro M2, Qualcomm Snapdragon 660/SDM660.
Kernel name: Prism.
Builder: @BukanSuhuTelegram.
Base branch: `lineage-23.2` from `joyccn/android_kernel_asus_sdm660-4.19`.
Build host: `Prism-Project`.

## Research Notes, 2026-06-07

- Current X01BD work is community maintained. The practical modern base is a 4.19 SDM660 tree, because Android 13/14/15 ROM ports for this device family rely on backported Android kernel interfaces rather than a mainline SDM660 stack.
- Public X01BD references still point to ASUS SDM660 family kernels, RyuujiX/KnightWalker 4.19 work, older Lineage-era X01BD trees, rsuntk AnyKernel/KernelSU ecosystem work, and Telegram ROM releases for Android 15/LineageOS 22.1 X01BD. Most old Android 10/11 XDA threads are useful only for compatibility hints, not as current patch sources.
- The selected base already includes Android compatibility pieces that matter for newer ROMs: binderfs, incremental fs, EROFS, exFAT, WireGuard, Simple LMK, F2FS, fs-verity, inline crypto hooks, BPF JIT, uclamp, LRU_GEN, and modernized scheduler/cpufreq changes.
- Daily-driver ROM compatibility priority is Android 13/14/15 AOSP/Lineage-style trees for X01BD/X01BDA. Prism avoids unsafe charging-current changes, panel/touch hacks, and aggressive thermal bypasses because this phone is used for work, navigation, mobile data, and messaging throughout the day.

## Enabled Features

- Branding changed to `-Prism`.
- Build identity defaults to `BukanSuhuTelegram@Prism-Project`.
- Full Clang LTO enabled with `CONFIG_LTO_CLANG=y` and ThinLTO disabled.
- LLVM Polly enabled after confirming the server Clang accepts `-mllvm -polly`.
- Linker dead-code/data elimination remains enabled.
- Existing Clang optimization path is retained: armv8-a crc/crypto tuning, Cortex-A53 codegen where supported, hot/cold splitting, and MLGO register allocation advisor flags when supported by the toolchain.
- BBR is selected as the default TCP congestion controller.
- FQ and fq_codel queue disciplines are enabled for lower latency and BBR pacing.
- Workqueue power-efficient mode is enabled by default to reduce idle drain.
- Stock charging safety and thermal limit infrastructure are preserved.

## Optimizations Deliberately Not Forced

- PGO is not enabled as a release optimization yet. Kernel PGO needs representative device-side profile data from real X01BD workloads, then a second optimized build. Server-only profile generation would bias the binary toward build-host behavior and is not valid for phone runtime performance.
- BOLT is installed on the build host and available through `./build-prism.sh bolt-check`, but it should not be applied to the release image without a valid device runtime profile and a verified AArch64 vmlinux flow. An unprofiled or wrongly profiled BOLT pass is more likely to regress boot stability than help.
- Unsafe charging current changes, thermal-disabling configs, and benchmark-first GPU hacks are intentionally excluded.

## Expected Impact

Performance:
- Full LTO and existing Clang tuning can reduce call overhead and improve global optimization across the kernel.
- Scheduler/cpufreq changes already present in the base are preserved for UI and app launch responsiveness.
- FQ/BBR should help network latency and stability on mobile data where pacing works.

Battery:
- Workqueue power-efficient default may improve idle behavior and reduce background wake pressure.
- No thermal bypasses or voltage/current changes are included, so daily-driver thermal safety remains closer to stock behavior.

Gaming:
- The release favors sustained stability over peak benchmark behavior. It keeps KGSL, devfreq boost, memory latency governor, and schedutil behavior from the base tree.
- PUBG Mobile testing must be done on device with sustained sessions and thermal logs.

## Validation Workflow

Phase 1, server validation:
1. `git switch prism`
2. `./build-prism.sh distclean`
3. `./build-prism.sh all`
4. Confirm `out-prism/arch/arm64/boot/Image.gz-dtb` exists and is non-empty.
5. Confirm AnyKernel3 zip and SHA256 are generated in `/root/kernel-work/releases`.

Phase 2, device validation:
1. Flash the generated AnyKernel3 zip from recovery.
2. Boot Android and let the device settle for at least 5 minutes.
3. Collect logs:
   - `adb shell uname -a`
   - `adb shell dmesg > prism-dmesg.txt`
   - `adb logcat -d > prism-logcat.txt`
   - `adb shell cat /sys/fs/pstore/console-ramoops-0` if a panic occurs.
4. Check deep sleep, idle drain, thermals, touch, camera, Wi-Fi, mobile data, GPS, Maps navigation, Maxim/Gojek, messaging, and one sustained PUBG Mobile session.

## Flashing Instructions

1. Backup boot/vendor_boot and keep a known-good kernel zip available.
2. Reboot to recovery.
3. Flash `Prism-X01BD-*-AnyKernel3.zip`.
4. Wipe Dalvik/ART cache only if the ROM/recovery workflow normally requires it.
5. Reboot system.
6. If bootloop occurs, restore the previous boot image or flash the known-good kernel.

## Known Limitations

- Server validation cannot prove boot, modem, thermal, GPS, or battery behavior.
- PGO/BOLT require real runtime profile data from the device before they can be treated as safe release optimizations.
- Android 15 ROM compatibility depends on each ROM's vendor/device tree expectations. Prism is built for the current X01BD 4.19 ecosystem, not for a generic GKI flow.
