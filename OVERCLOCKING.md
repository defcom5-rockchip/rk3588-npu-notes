# Overclocking the Orange Pi 5B (RK3588S) — a defcom5-rockchip field note

*A builder's honest look at where the headroom actually is on the RK3588S, measured on a
Pi Studio image with an ice-tower cooler. Short version: the chip is already tuned harder
than most people think, and the cooler's job is to **hold** the rated clocks, not raise them.*

> 🛑 **STOP — the one thing to know before you overclock *anything* on this chip.** On RK3588 the
> NPU / GPU / CPU clocks are owned by **firmware, not Linux.** Adding a device-tree "OPP" to
> overclock them — the trick generic guides hand you — **does not make them faster. It can
> silently leave your NPU running at roughly HALF speed while every tool cheerfully reports the
> higher number.** No crash, no error, no warning — you would never know. It is **not damage**
> (fully reversible — see **"Already tried it?"** below), but it's a trap a "cool, let's
> overclock!" skim walks you straight into. Read the result section before you touch the device tree.
>
> ⚠️ Everything past **"The runtime tune"** edits the device tree and reboots. A bad DTB = no boot
> (recoverable via maskrom — see the recovery section). Done on a disposable board. If you value
> the machine, read the whole thing — especially the longevity note — before touching a voltage.

---

## TL;DR

- **CPU, GPU, and NPU already run at their rated top clocks at the max rail voltage** the
  vendor set. There is **no free "unused high bin"** sitting above them — the top bin *is*
  the voltage ceiling.
- **RAM is not a soft knob.** It's already pinned to its ceiling (2112 MHz) whenever there's
  load, by the governor. Going higher is **firmware-gated** (the DDR training blob), not a
  device-tree edit — don't.
- **You cannot overclock the CPU/GPU/NPU by editing the device tree alone.** On RK3588 these
  clocks are owned by **ARM Trusted Firmware over SCMI** — the kernel/DTB OPP is a *request*,
  not a command. We added a 1100 MHz NPU OPP; ATF didn't honor it, and local-LLM throughput
  **dropped from 8.7 to 4.05 tok/s** (a phantom clock that ran *slower*, while `devfreq`
  cheerfully reported "1100 MHz"). **Measured, not theorized.**
- Real core overclocking on RK3588 means patching **the firmware blobs** (ATF/BL31 for
  CPU/GPU/NPU via SCMI; the DDR init blob for RAM) — the *same* wall as the RAM. The device
  tree can only *select among* firmware-blessed rates, never invent higher ones.
- The **ice tower's true value**: it lets the board sit at its rated ceilings **24/7 with zero
  throttle**, where a passively-cooled 5B throttles. That's the longevity-smart win — full
  rated performance, stock voltage, cool. **That, not a higher number, is the real "tune."**

---

## What the chip already does (measured, `performance`/on-demand governors)

| Engine | Cores | Rated top clock | Governor as shipped | Voltage at top bin |
|---|---|---|---|---|
| A55 (little) | cpu0–3 (`policy0`) | **1800 MHz** | performance | — |
| A76 (big) | cpu4–5 (`policy4`) | **2304 MHz** | performance | ~1.00 V (cap) |
| A76 (big) | cpu6–7 (`policy6`) | **2352 MHz** | performance | ~1.00 V (cap) |
| Mali-G610 GPU | `fb000000.gpu` | **1000 MHz** | performance | **0.85 V (cap)** |
| NPU (3-core) | `fdab0000.npu` | **1000 MHz** | rknpu_ondemand | **0.85 V (cap)** |
| DDR (dmc) | LPDDR4x | **2112 MHz** | dmc_ondemand | (blob-trained) |

Rail-voltage caps decoded from the DTB OPP tables (hex µV): `0xcf850` = **0.85 V** (GPU/NPU
ceiling), `0xf4240` = **1.00 V** (CPU ceiling). The **top frequency bin of every engine already
sits at its cap.** That single fact is the whole story.

---

## The RAM question: "can we overclock the memory?"

Short answer: **it's already maxed whenever it matters, and you can't safely push past it.**

- The DDR OPP table exposes `528 / 1068 / 1560 / 2112 MHz`. Idle it drops low; the moment a
  real workload hits, `dmc_ondemand` slams it to **2112 MHz** and holds it there. We proved
  this by sampling the live DDR frequency *during* an NPU inference run — it sat pegged at 2112
  the entire time. Pinning the governor to `performance` changes **nothing** for sustained
  load (it only removes the idle→load ramp latency for bursty light work).
- **Above 2112 is firmware-gated, not device-tree-gated.** DDR speeds are trained at power-on
  by a **binary DDR init blob** inside u-boot's TPL stage (from Rockchip's closed `rkbin`) —
  not a text config you can edit. Each speed needs a validated PHY-timing table baked into that
  blob. This board is **LPDDR4x**, and 2112 MHz is its rated ceiling; there is no validated
  higher-speed table for it. Forcing it = silent memory corruption or no-boot. **Don't.**

> "Is the firmware a `.config` file?" No — three different things get called "firmware":
> the **DDR blob** (binary, in u-boot, *not* editable as text → why RAM is locked), the
> **device tree** (`.dtb`, compiled from editable `.dts` → *this* is the clock/voltage config
> you edit to overclock cores), and the **kernel `.config`** (text, but a different layer — it
> builds the kernel, not the clocks).

---

## The runtime tune (safe, reversible, no reboot — do this)

Everything ships on `performance` already except the NPU. The only genuinely useful runtime
move is to keep the on-demand engines from ramping — but as shown above, **it buys nothing for
sustained load.** For a 24/7 box the shipped config is already optimal: rated clocks, stock
voltage, and — with a real cooler — no throttling. **That is the recommended daily-driver state.**

If you want deterministic max-clock behavior for bursty workloads:
```bash
# pins DDR + NPU to their top bin continuously (still stock voltage — safe)
echo performance | sudo tee /sys/class/devfreq/dmc/governor
echo performance | sudo tee /sys/class/devfreq/fdab0000.npu/governor
```
Reverts on reboot, or set them back to `dmc_ondemand` / `rknpu_ondemand`.

---

## The one free-lunch experiment: NPU 1000 → 1100 MHz at **unchanged** voltage

The NPU governs token-generation speed for on-device LLMs (the weights stream from DDR, the
math runs on the NPU). Its top bin is 1000 MHz **already at the 0.85 V cap**, so this is a pure
gamble: *does this silicon do 1100 MHz at the same 0.85 V?* If yes, it's a real gain at **zero
overvolt** — the only kind of overclock that respects a longevity-first build.

**Procedure** (device-tree OPP edit — the editable "clock config"):
```bash
BOARD=/lib/firmware/$(uname -r)/device-tree/rockchip/rk3588s-orangepi-5b.dtb
sudo cp -n "$BOARD" "$BOARD.stock-bak"          # ALWAYS back up first
dtc -I dtb -O dts "$BOARD" > board.dts          # decompile
# add a new OPP node inside npu-opp-table, copying the 1000 MHz entry's voltage:
#   opp-1100000000 {
#       opp-supported-hw = <0xf9 0xffff>;
#       opp-hz = <0x00 1100000000>;
#       opp-microvolt = <0xcf850 0xcf850 0xcf850 0xcf850 0xcf850 0xcf850>;  # 0.85 V, UNCHANGED
#   };
dtc -I dts -O dtb -o board-oc.dtb board.dts     # recompile
dtc -I dtb -O dts board-oc.dtb >/dev/null && echo "valid"   # round-trip check BEFORE installing
sudo cp board-oc.dtb "$BOARD"
sudo reboot
```
After reboot, confirm `cat /sys/class/devfreq/fdab0000.npu/available_frequencies` lists
`1100000000`, then benchmark.

### Result — the free lunch was a trap 🪤

| Config | NPU clock | **Tokens/sec** | SoC temp | Compute |
|---|---|---|---|---|
| Stock | 1000 MHz | **8.68** | 42 °C | valid |
| "Overclocked" | **1100 MHz** *(as reported by `devfreq`)* | **4.05** — *half* | **37 °C** | valid |
| Reverted to stock | 1000 MHz | **8.52** (restored) | 43 °C | valid |

The 1100 MHz OPP made local-LLM inference **~2× slower** — while running **cooler** and still
producing correct code. Reverting the DTB restored the baseline exactly. So the OPP edit
*caused* the regression, and it was **never actually running at 1100 MHz.**

**Why: the RK3588 NPU clock is owned by firmware (SCMI/ATF), not the kernel.**
`clk_summary` shows the NPU rate as `scmi_clk_npu` — an **SCMI clock**, meaning the real
frequency is programmed by **ARM Trusted Firmware (BL31)**, not the Linux clock driver. The
device-tree OPP is only a *request* passed to ATF. ATF has its **own** table of validated NPU
operating points; **1100 MHz isn't in it**, so ATF clamped/rounded to a rate *below* the native
1000 MHz bin and ran there. `devfreq` reported the OPP we asked for (1100) — a number the
kernel *requested* but has no way to verify, because SCMI is opaque to it. The lower temperature
is the tell: less heat = less silicon work = a lower **real** clock. A **phantom overclock.**

**The lesson:** on RK3588 you cannot overclock the NPU (or GPU, or the big CPUs — all SCMI
clocks) by editing device-tree OPP tables. You'd have to patch **ATF/BL31's SCMI clock table**
(a `rkbin` blob) and rebuild u-boot — the *same* firmware-blob wall that gates the DDR. The DTB
is a menu, not a dial: it can pick among firmware-blessed rates, never mint new ones. Try to,
and you can end up **slower than stock.**

---

## Already tried it? — detect it, undo it

Followed a generic "add an OPP" guide and rebooted? Your board may be in the phantom-overclock
state **right now** — reporting the higher clock, running slower. **It's a bad config, not broken
silicon. Fully reversible. You are not out a board.**

**How to tell (don't trust the readout — benchmark):**
- `cur_freq` shows the number you *requested*; that proves nothing. Run a real NPU workload and
  compare tokens/sec (or inference time) against a known-good baseline. **Slower than stock = you're in it.**
- Spot the culprit: `cat /sys/class/devfreq/fdab0000.npu/available_frequencies` — anything above
  `1000000000` that a guide had you add is it.

**How to undo (any one):**
- Kept a DTB backup: `sudo cp <dtb>.stock-bak <dtb> && sudo reboot`.
- Didn't: reinstall the stock DTB — `sudo apt install --reinstall linux-image-$(uname -r)` — or
  re-flash the board image. **Maskrom + `rkdeveloptool` recovers even a board that won't boot.**
- After reboot, confirm `available_frequencies` tops out at `1000000000` again and re-benchmark;
  throughput returns to baseline. No harm done.

---

## Thermals & the ice tower

Idle **29–31 °C**; under a full NPU load only **41–43 °C**. SoC passive-throttle trips at
**85 °C**, critical at **115 °C** — we never came within 40 °C of trouble. This is the point:
a bare/passive 5B *throttles* under sustained load, silently losing the clocks it's rated for.
**A serious cooler doesn't overclock the chip — it stops the chip from de-clocking itself.**
For a 24/7 machine that's the highest-value cooling win there is.

---

## For the daring: the risks, and the *real* avenue

The DTB-OPP route above is a dead end for going *faster* — the phantom-overclock result proves it.
If you're determined to push RK3588 clocks past the rated bins anyway, do it with eyes open and on
the right layer. **People spend money bricking boards because they flail at the wrong layer (the
DTB) and don't know the recovery path. Both are avoidable.**

### 1. The risks — read before you spend a dollar

| Risk | Severity | Reality |
|---|---|---|
| **Soft-brick** (bad u-boot/blob → won't boot) | **Recoverable** | RK3588's boot ROM has **maskrom mode** — you can almost always reflash over USB-C. See §2. *Do not buy a new board for this.* |
| **Silicon damage** (sustained overvolt → electromigration) | **NOT recoverable** | This is the real, permanent cost. Higher voltage shortens silicon life — the one thing maskrom can't undo. On a 24/7 longevity build it's a bad trade. |
| **Memory corruption** (custom DDR blob) | Data loss / instability | Untrained/aggressive DDR timings corrupt silently. Test brutally; don't run it on data you love. |
| **Small payoff** | — | Realistic gains: A76 ~2.4 GHz, GPU ~1.05–1.1 GHz, NPU ~1.1 GHz. **Low single-digit %.** Weigh it against the above. |

The honest summary: a *soft*-brick costs you an hour, not a board. The thing that actually costs
money is **overvolting your way to a shorter-lived chip** — so if you go, go on **disposable
hardware**, keep voltages conservative, and let cooling (not volts) do the work.

### 2. The recovery net that saves your money: maskrom + `rkdeveloptool`

Before you touch firmware, learn this — it's why a botched flash is a hiccup, not a funeral:

- RK3588's on-chip **boot ROM** enters **maskrom mode** when boot media is empty/invalid, or when
  you hold the board's **MASKROM button** (or short the flash CLK pin) at power-on.
- In maskrom, the SoC accepts a loader + firmware over **USB-C** via **`rkdeveloptool`** (Linux) or
  the Rockchip tool — reflashing u-boot, the boot blobs, or a full image onto a board that won't
  otherwise boot.
- **Keep a known-good image and a USB-C data cable on the bench.** With those, a "brick" is a
  reflash. Practice the maskrom + `rkdeveloptool db/wl` cycle *once* on a healthy board so it's
  muscle memory before you need it.

### 3. The actual avenue (where the clocks really live)

Because CPU/GPU/NPU are **SCMI clocks**, the authoritative frequency **and** voltage tables live in
**ARM Trusted Firmware (BL31)**, shipped as a binary blob in Rockchip's **`rkbin`**. A genuine core
overclock is firmware work, not a config edit:

1. **Accept that the DTB alone is inert** for these clocks (we measured it — 2× *slower*). Don't
   waste boards proving it again.
2. **CPU / GPU / NPU:** modify **BL31's SCMI clock+voltage tables** — rebuild ATF/BL31 from
   Rockchip's source (or patch the `rkbin` blob), then **rebuild u-boot** with that BL31 and
   **re-flash the bootloader sectors**. Only *then* does a matching DTB OPP take effect.
3. **RAM (> 2112 MHz):** requires a **custom DDR init blob** (`rkbin` `rk3588_ddr_*.bin`) trained
   for the higher rate — highly DRAM- and board-specific, highest corruption risk of the lot.
4. **Tools & sources:** Rockchip `rkbin` + ATF trees, the u-boot build for your board, and
   `rkdeveloptool` for flashing/recovery. Cross-check the Armbian and Collabora RK3588 work and the
   community overclock threads before inventing your own tables.

**Bottom line for the daring:** the door isn't locked because it's forbidden — it's locked because
it's *firmware*, and firmware is the one layer where a mistake doesn't boot. Go in with a maskrom
cable, conservative voltages, a disposable board, and the understanding that you're trading silicon
life for low single digits. If that math still works for you, it's your board. Just don't buy a
second one because the first "bricked" — it almost certainly didn't.

**Revert anything here:**
```bash
BOARD=/lib/firmware/$(uname -r)/device-tree/rockchip/rk3588s-orangepi-5b.dtb
sudo cp "$BOARD.stock-bak" "$BOARD" && sudo reboot
```

---

## Methodology

Token throughput measured with the on-device LLM (Qwen3-1.7B w8a8, rkllm runtime) via a fixed
prompt, 1 warm-up + 5 scored generations, reporting tokens ÷ generate-time (length-normalized).
A background thread sampled DDR and NPU frequencies every ~20 ms to capture what the governors
actually did *during* inference (not just at idle), and the generated output was checked for
validity to catch NPU compute errors from an unstable overclock.

*— defcom5-rockchip. Overclock honestly; cool for longevity; never claim a gain you didn't measure.*
