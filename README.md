# ios-topaz

**Apple's iOS 16 running on a Redmi Note 12 4G.**

This is a port of [dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet) (Apple's open-source XNU kernel, xnu-8796, on a Redmi Note 10 Pro) to the Xiaomi **Redmi Note 12 4G** (`topaz` / `tapas`, Qualcomm **SM6225 "khaje"** / Snapdragon 685). On top of it runs the **unmodified iOS 16.7.16 (20H392) userland of the iPhone X**: launchd, the system daemons, backboardd and SpringBoard.

As of **2026-10-18** the phone boots to the **iOS lock screen** in about 3 minutes, on the four Cortex-A73 cores. Rendering runs entirely on the CPU; there is no GPU driver. Touch is being brought up (see the roadmap); without it the lock screen cannot be unlocked yet.

> Experimental bring-up, not a usable phone OS. Many things are missing or stubbed, and Apple's security model is mostly switched off. It installs into the `userdata` partition and so **erases Android's user data**. Nothing is flashed to the boot partitions; the kernel is started from RAM with `fastboot boot`.

## What works

| Area | State |
| --- | --- |
| Boot | Stock Xiaomi ABL → `fastboot boot` of our shim (boot image v4) → XNU. Boot slots and other OSes on the phone are not touched |
| CPU | The four Cortex-A73 ("Gold", MPIDR `0x100`–`0x103`) cores, 16K pages, GICv3, timers. The Silver cores are parked (see below) |
| Memory | The upper DDR bank, `0x1_40000000` + 4 GiB |
| Storage | UFS host driver (UFS 3.0 at `0x4804000`); the iOS root is a journaled HFS+ volume in `userdata`, read/write |
| iOS userland | Real iPhone X 16.7.16 root filesystem and shared cache; launchd and the system daemons run |
| Display | Kernel IOSurface + IOMobileFramebuffer (`AppleCLCD`); CoreAnimation renders in software into ABL's framebuffer at `0x5c000000` (1080×2400). Presented to iOS as an iPhone X panel |
| GUI | backboardd, SpringBoard, boot Apple logo, lock screen |
| Device identity | iPhone X (`iPhone10,3` / `D22AP`): no Home button, gesture UI |

## What does not work (yet)

- **Touch and buttons.** The FocalTech FT5452 driver (patch 0083) is written but not yet confirmed on the phone; power/volume keys are not ported.
- **No Wi-Fi, Bluetooth, cellular, audio, camera, sensors, GPS, SEP.** `bluetoothd` and `fairplayd.H2` relaunch constantly because the hardware is missing.
- **No GPU**, low frame rate (the CPU copies frames to the panel, `sweetfb_hz`).
- **No real-time clock**: the date starts at 31 December.
- **Only 4 of 8 cores** (see "Why only the Gold cores").
- **Security is off**: permissive AMFI and sandbox, stub AppleKeyStore, no data protection.

## How topaz differs from sweet

These are the walls hit during the port; each one stops the boot silently if missed.

| Problem | Fix |
| --- | --- |
| Xiaomi's topaz ABL ignores boot image v1/v2 and drops the boot v4 ramdisk (it only passes vendor_boot's) | The shim is packed as boot v4 and the XNU payload is appended to the shim's kernel Image after `_end` (`shim/build.sh`, `shim/loader.c`) |
| ABL starts on a Kryo 260 **Silver** core (Cortex-A53 class, MIDR `0x51AF8014`), which has **no 16K translation granule** (`ID_AA64MMFR0.TGran16 = 0`) | The shim wakes Gold CPU `0x100` with PSCI `CPU_ON`, the Silver core parks in `wfi`, and XNU only ever runs on Gold. The ADT lists the four Gold cores (`tools/mkadt.py`, patch 0082) |
| The cores are **ARMv8.0**: no LSE atomics, no RCpc (`ldapr`), no PAN. Apple clang keeps its `apple-m1` CPU default under `-arch arm64` even with `-march` | Kernel and `libfirehose_kernel` are built with `-mcpu=cortex-a53`, PAN is off, the commpage PFZ `casa` became an LDAXR/STXR loop (patch 0081, `xnu.yml`) |
| The iPhone X userland still contains LSE atomics and `ldapr` | They are emulated atomically in `handle_uncategorized` (LDAXR/STLXR on the user address, copyio recovery) (patch 0081) |
| XNU hangs after `initCPU` on Gold (no SGI / timer interrupt) | The shim prepares the GIC for all Gold cores before the jump: GICD groups, redistributor wake, SGIs/PPIs in Group 1 (`test_gic()` / `gold_gicr_prepare()` in `shim/shim.c`) |
| Different MMIO map | GIC `0xf200000`/`0xf300000`, UFS `0x4804000`, splash framebuffer `0x5c000000`, PS_HOLD `0x440b000`, IMEM restart reason `0xc12565c`, TLMM tiles WEST `0x500000` / SOUTH `0x900000` / EAST `0xd00000` |

### Why only the Gold cores

XNU for iOS uses 16K pages for the kernel and the userland on every CPU, and the Silver cores cannot translate 16K pages. Using all eight cores needs a 4K-page XNU, which is on the roadmap as an experiment.

## How it boots

```
ABL (stock Xiaomi bootloader, unlocked)
  -> fastboot boot shim-boot.img        (boot image v4, RAM only)
     -> shim on Silver CPU0: prints MMFR0/MIDR, wakes Gold CPU 0x100, parks
        -> shim on Gold: GIC setup, speed probe, finds the payload behind _end
           -> XNU Mach-O + Apple Device Tree (ADT) + boot-args
              -> XNU -> UFS driver -> HFS+ root in userdata
                 -> dyld + shared cache -> launchd -> backboardd + SpringBoard
```

There is no serial console. The kernel draws its console into ABL's framebuffer; with `sweetfb_noconsole=1` it stops after the first iOS frame (panics are still drawn). The kernel also keeps sweet's persistent log ring at the end of `userdata` and its user stack sampler (`SMP name tN pc .. bt ..`).

## How to do it yourself

You need a Redmi Note 12 4G (`topaz`/`tapas`, SM6225) with an **unlocked bootloader**, a Linux PC with `fastboot`, and a GitHub account for the kernel build. **Everything on `userdata` is lost.** Boot, vendor_boot, firmware and other partitions are never written.

### 1. Build the kernel

The kernel builds on GitHub's macOS runners (macos-14, Xcode 15) with [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build); newer Xcode's `iig` does not match the xnu-8796 IORPC ABI. Fork the repo and run, on the `topaz` branch:

```sh
gh workflow run xnu.yml -R YOU/ios-topaz --ref topaz
gh run download RUN_ID -R YOU/ios-topaz -n xnu-kernel -D xnu/out
```

A build takes about 8 minutes. If the artifact upload times out on GitHub's side, rerun the job. Check that the kernel has no LSE left (`llvm-objdump -d --mattr=+v8.5a ... | grep -P '\t(cas|ldadd|ldset|ldclr|swp|ldapr)'`; the only hit should be the `K256` SHA table).

### 2. Build the iOS root image

Download the iPhone X (iPhone10,3) iOS 16.7.16 (20H392) IPSW from Apple. On Linux, with `apfs-fuse` (build it from [sgan81/apfs-fuse](https://github.com/sgan81/apfs-fuse) if your distribution has no package), `hfsprogs` and sudo:

```sh
# OS, SystemOS and AppOS disk images (see BuildManifest.plist, D22AP Erase identity)
sudo bash tools/mkiosroot.sh OS.dmg SystemOS.dmg AppOS.dmg ios16-root.img 16G
sudo mount -t hfsplus -o loop,force ios16-root.img /mnt/iosroot
sudo python3 tools/sweet-root-tweaks.py /mnt/iosroot
sudo umount /mnt/iosroot
img2simg ios16-root.img ios16-root.simg
```

The device tree builder copies `/product` from the real iPhone X device tree. Take `Firmware/all_flash/DeviceTree.d22ap.im4p` from the IPSW, decompress its LZFSE payload (`ipsw img4 im4p extract`) and save it as `research/ipsw-x/d22ap.adt`.

### 3. Build the boot image

Needs `aarch64-linux-gnu-gcc` and AOSP `mkbootimg.py` (set `MKBOOTIMG` if it is not at the default path in `shim/build.sh`).

```sh
python3 tools/mkadt.py shim/out/topaz.adt --highmem
python3 tools/mkpayload.py xnu/out/kernel.development.sweet shim/out/topaz.adt shim/out/payload.bin \
    --cmdline 'debug=0xc serial=3 cpus=4 keepsyms=1 -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30'
shim/build.sh ../shim/out/payload.bin      # -> shim/out/shim-boot.img
```

| Boot-arg | Effect |
| --- | --- |
| `rd=ufsroot0 ufsrw=1 rootrw=1` | Root on `userdata`, writable |
| `cpus=4` | All four Gold cores; `cpus=1` is the safe fallback |
| `sweetfb_noconsole=1` | Stop drawing kernel text over the GUI after the first iOS frame. Leave it out to debug (much slower: every console line is drawn and scrolled by the CPU) |
| `sweetfb_hz=30` | Panel refresh rate of the CPU frame copy |
| `sweettouch=0` | Disable the touch driver |
| `sweethw=1` | Also start sweet's SM7150 key and USB drivers (**unsafe on topaz**, not ported) |
| `launchd_unsecure_cache=1`, `wdt=-1 wdt_test=no_user_checkin` | launchd without AMFI; no hardware watchdog |

### 4. Flash the root and boot

```sh
fastboot -S 512M flash userdata ios16-root.simg   # ~5 minutes; do not unplug
fastboot boot shim/out/shim-boot.img
```

The shim screen (red) shows `MMFR0`, the Gold hand-off and `SPEED silver=… gold=…` for 8 seconds, then XNU starts. The first boot spends a while on the Apple logo (SpringBoard waits for LaunchServices to build its database); the lock screen follows after about 3 minutes. To get back to fastboot, hold Power + Volume down.

### Debugging tips

- Stack samples (`SMP name[pid] slide S mh M` then `SMP name tN pc .. bt ..`): symbolicate shared-cache addresses with `ipsw dyld a2s dyld_shared_cache_arm64 <addr - S>`.
- `SWEET TOUCH: ...` lines show each touch bring-up step (clocks, SE2 firmware check, chip id `54:52`).

## Roadmap

1. **Touch** (FT5452 at I²C `0x38` on QUP0 SE2 `0x4a88000`, IRQ GPIO80, reset GPIO86, AVDD GPIO36): patch 0083, needs confirmation on the phone.
2. **Buttons**: power and volume down on the PM6125 PON block, volume up on PM6125 GPIO5.
3. **Smoother display**: higher `sweetfb_hz`; check whether the Gold cores run at a low clock without cpufreq (the shim's speed probe) and raise it if so.
4. **Narrow the GIC fix** to the register that actually matters, then move it into XNU.
5. **Real-time clock** from the PMIC RTC or passed in by the shim.
6. **All 8 cores (experiment, later):** build XNU with 4K pages (drop `__ARM_16K_PG__` from `SWEET.h`, as XNU's own `BCM2837` Raspberry Pi 3 config does on Cortex-A53) and describe two clusters, Gold as `P` and Silver as `E`, so the AMP scheduler uses both. Risk: the iOS 16 userland was only ever run on 16K pages (hard-coded 16K in malloc, JIT guard pages, IOSurface, commpage layout), and the 16K assumptions in the shim and sweet's patches have to be checked too. The 16K Gold-only kernel stays as the fallback.
7. **Silver cores as a coprocessor** (idea): run bare-metal shim code on them for the panel frame copy instead of XNU.
8. **6 GB model** (requested): the RAM layout is hard-coded for the 4 GB phone (`mkadt.py --highmem`, 4 GiB at `0x1_40000000`). Have the shim read the DDR ranges from the `/memory` node of the DTB that ABL passes and write them into the ADT and boot args, so one image boots both the 4 GB and the 6 GB versions. Everything else (SoC, panel, touch, battery) is the same hardware.
**GPU plan (2026-10-19):** a kernel Adreno 610 driver (topaz-woa `TopazGpuW` sequences) with an msm DRM style user client for Mesa freedreno, so QuartzCore's OpenGL ES renderer draws the UI on the GPU; Metal for apps after that.

9. **Wi-Fi** (port from [MakrSas/topaz-woa](https://github.com/MakrSas/topaz-woa) `TopazWifi`, which has scan, WPA2 and working internet on Windows): bring up the modem/WLAN firmware through TrustZone, SMEM/QMI and the WCN3988 WLAN commands exactly as `TopazWifi` does, in an XNU driver. Expose it to iOS first as a network interface (IONetworkingFamily, network set by config), then emulate the IO80211 interface that `wifid` talks to, so Settings → Wi-Fi shows the scan list and joins networks.
10. **Speaker** (port from topaz-woa `TopazAudio` (ADSP / AudioReach) + `TopazSpeaker`, see its `docs/P9_audio.md`): ADSP firmware through TrustZone, AudioReach graph to the speaker, and an XNU audio driver that CoreAudio can output to.
11. **Also ready in topaz-woa to port**: brightness (display adapter), USB host/OTG (`TopazOtgDxe` + XHCI), RPM requests (`TopazRpm`: rails, clocks, GPU CX level), SIM/LTE registration (`docs/P9_sim.md`). The GPU work follows `TopazGpuW`.

## Repository layout

| Path | What |
| --- | --- |
| `shim/` | Bare-metal boot shim (C + asm), boot image v4, Gold hand-off, GIC setup, payload loader |
| `xnu/patches/` | XNU patch series (applied in order by CI): sweet's 0001–0079, topaz's 0080+ |
| `.github/workflows/xnu.yml` | Kernel CI build |
| `tools/mkadt.py` | Apple Device Tree for topaz (Gold cores, memory map, MMIO) and the iPhone X identity |
| `tools/mkpayload.py` | Packs kernel + ADT + boot-args into the shim payload |
| `tools/mkiosroot.sh`, `tools/sweet-root-tweaks.py` | Build and adjust the HFS+ iOS root |
| `tools/sweet-crash.py`, `sweet-log.py` | Symbolicate crash reports, read the persistent log |
| `NOTES.md` | sweet's engineering log (history of the original port) |

Not in git: partition backups, live device trees, Apple firmware and root images, build trees.

## topaz kernel patches

| # | What |
| --- | --- |
| 0080 | CPU topology for SM6225; sweet's SM7150 key/touch/USB drivers gated behind `sweethw=1` |
| 0081 | ARMv8.0: `-mcpu=cortex-a53`, no PAN, PFZ without CASA, userland LSE/LDAPR emulation |
| 0082 | Boot CPU is Gold MPIDR `0x100` |
| 0083 | Touch: FocalTech FT5452 on QUP0 SE2 (values from [topaz-woa](https://github.com/MakrSas/topaz-woa) TopazTouch) |
| 0084 | Touch diagnostics: `sweettouchdiag=1` panics with the touch probe values on failure |
| 0085 | `sweetfb_stayon=1` ignores display-off requests |
| 0086 | Touch parser as in TopazTouch (event 3 = empty slot); `sweettouchdiag=2` statistics |
| 0087 | Touch RCG offset fix (0x1f3a8), 400 kHz, IRQ-gated polling; topaz keys |
| 0088 | LUN0 GPT watchdog and write fence (see RECOVERY.md) |
| 0089 | Touch: FT5452 firmware/mode at probe, raw bytes of rejected frames |
| 0090 | Touch: a TD_STATUS 0xff frame (no-touch) releases all contacts |
| 0091 | Battery: SM5602 gauge + charger status over QUP0 SE1 (read-only) |
| 0092 | Direct MDP scanout of full-screen surfaces (no CPU frame copy) |
| 0093 | Scanout from contiguous RAM; `mkadt.py --native` canvas |
| 0094 | Gold cluster at max cpufreq |
| 0095 | Write-combined console framebuffer |
| 0096 | Smooth display-off fade (cached buffer, whole-frame flips) |
| 0097 | Unified console scanout (cached shadow + MDP); panics use the same path |
| 0098 | INTF1 refresh-rate diagnostics (read-only) |
| 0099 | On-screen IOSurfaces held in use; console cache flush batched per vsync |
| 0100 | Double-buffered kernel frames: flip at vsync, never draw into the scanned buffer |
| 0101 | Real `flush_dcache`/`clean_dcache` (they were coherent-IO no-ops) |
| 0102 | Tear-free frames: console copy under the putc lock, iOS surfaces copied to the back buffer then flipped |
| 0103 | Multi-layer frames (dims, apps) composed in the back buffer and flipped |
| 0104 | Panel brightness via DSI DCS 0x51 from `IOMFBBrightnessLevel` |
| 0105 | AppleARMBacklight service so CoreBrightness drives the panel |
| 0106 | DCS 0x28/0x29 display off/on with RequestPowerChange |
| 0107 | Display-only real dcache clean; asynchronous panel brightness (backboardd no longer stalls on DSI waits) |
| 0110 | AppleARMBacklight only with `sweetbl=1` (CoreBrightness digital dimming killed CPU rendering) |
| 0111 | Real cache maintenance (`dc cvac`/`dc civac`) for display buffers (this kernel config makes `clean_dcache` a no-op) |
| 0112 | Console log filter: boot-arg `sweetlog=WORD,WORD` draws only matching lines |

Patch numbers 0108 and 0109 were never used.

## Key hardware facts (topaz)

- SoC SM6225 "khaje": 4× Kryo 260 Silver (A53 class, MPIDR `0x0`–`0x3`) + 4× Kryo 260 Gold (A73 class, `0x100`–`0x103`). Only Gold has the 16K granule.
- DDR banks `0x40000000`+`0x3bb00000`, `0x80000000`+3 GiB, `0x1_40000000`+4 GiB; all fixed carve-outs are below `0x63900000`.
- GICv3 at `0xf200000` (redistributors `0xf300000`, stride `0x20000`), virtual timer INTID 19, 19.2 MHz.
- Panel: 1080×2400 DSI video mode with DSC, continuous splash at `0x5c000000`.
- Touch: FocalTech FT5452 at `0x38` on QUP0 SE2, raw range 1350×3000 (1.25× the panel).
- More hardware notes for this phone: [MakrSas/topaz-woa](https://github.com/MakrSas/topaz-woa) (`docs/AGENT_BRIEF_drivers.md`).

## Credits

Based on [dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet), which did the hard part: XNU on a Qualcomm phone with the iPhone X userland. Built on Apple's open-source releases (xnu, IOHIDFamily, libpthread, hfs), [BearSSL](https://bearssl.org), [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build), [ipsw](https://github.com/blacktop/ipsw), Qualcomm/Xiaomi's published Linux kernel sources, and the topaz hardware work in [MakrSas/topaz-woa](https://github.com/MakrSas/topaz-woa). iOS itself is Apple's and is not distributed here.
