# rk3588-npu-notes

Hardware findings for the Rockchip RK3588 / RK3588S NPU. Measurements, methods, and a
detection script. No product here — just what we measured and how, so it can be checked,
reproduced, or contradicted.

## The main finding: the "phantom overclock"

On RK3588, the NPU/GPU/big-CPU clocks are **SCMI clocks owned by ARM Trusted Firmware
(BL31)** — not by the Linux clock driver. A device-tree OPP is therefore a **request, not a
command**. Adding an operating point above the native bin does not raise the clock; ATF can
clamp it to a rate *below* stock, while `devfreq` continues to report the value you asked for.

Measured on an Orange Pi 5B (RK3588S), vendor BSP 6.1 kernel, Qwen3-1.7B (w8a8) on the NPU:

| Configuration | `devfreq cur_freq` | throughput | SoC temp |
|---|---|---|---|
| stock | 1000 MHz | **8.68 tok/s** | 42 °C |
| +1100 MHz OPP (iso-voltage) | 1100 MHz | **4.05 tok/s** | 37 °C |
| reverted to stock | 1000 MHz | **8.52 tok/s** | 43 °C |

Three instruments disagreed under identical load — `devfreq` said 1100 MHz, `clk_summary`
said 200 MHz, throughput implied ~470 MHz, and `vdd_npu` held 850 mV throughout. **Only the
workload told the truth.** Output stayed correct in every configuration; this is a bad
configuration, not damaged silicon, and it is fully reversible.

## Correction (2026-08-15): the stock baseline was measurement-bound

The 8.68 tok/s stock figure above was limited by the measurement environment, not the NPU.
Re-measured clean on the same board and model (Qwen3-1.7B w8a8, decode tok/s straight from the
RKLLM `PerfStat` counter, warm-up + 3 scored runs per condition):

| condition | decode tok/s | vs recorded 8.68 |
|---|---|---|
| recorded stock | 8.68 | — |
| clean: `performance` governor + quiesced desktop (default IRQ) | **10.6** | **+22%** |
| + NPU IRQ (`37/38/39`) pinned to an A76 core | **11.2** | **+29%** |

The dominant lever is the CPU governor plus quiescing the desktop (+22%); NPU interrupt
affinity adds roughly another 5% — smaller here than on mainline, because this NPU runs at
1 GHz rather than 200 MHz, so the fixed per-token interrupt cost is a smaller fraction of each
token. **The phantom-overclock result is unaffected:** the +1100 MHz request was measured
slower than stock under *identical* conditions, so the relative clamp stands; only the absolute
stock ceiling was understated.

A refinement to the gauge-disagreement note above: at a **valid in-table bin** (e.g. stock
1000 MHz) `devfreq` and the workload *agree*. The three-way disagreement is specific to the
**out-of-table request** (the +1100 MHz phantom-OC), where `devfreq` reports 1100 while ATF
clamps the real rate below 1000. `available_frequencies` tops out at 1000 MHz, and that ceiling
is the ATF-validated table refusing the out-of-range request.

This independently reproduces, from the **BSP + LLM** side, the methodology in Igor Paunović's
mainline `accel/rocket` DVFS RFC (linux-rockchip, Aug 2026): interrupt placement, CPU governor,
and a busy SoC dominate NPU-throughput measurements, and `clk_summary` is unreliable for the
SCMI-owned NPU clock — only the workload is honest. Two drivers (vendor `rknpu` vs mainline
`rocket`), two workloads (LLM vs vision), same silicon truth.

## Are you affected?

```sh
sudo ./rk3588-npu-check.sh
```

Read-only. It detects non-stock NPU/GPU operating points, cross-checks the clock gauges, and
prints revert instructions if you're affected. Exit 0 = stock, exit 2 = affected.

Then **benchmark** — that is the only gauge that has been reliable here. If a real NPU
workload is *slower* than stock, the OPP is the cause.

## Contents

- **[OVERCLOCKING.md](OVERCLOCKING.md)** — the full field guide: what's already at its
  ceiling (everything, at max rail voltage), the DDR 2112 MHz training-blob wall, the
  phantom-OC experiment, the SCMI/PMIC mechanism, a risks table, the maskrom +
  `rkdeveloptool` recovery net, and the real ATF/BL31 avenue.
- **[rk3588-npu-check.sh](rk3588-npu-check.sh)** — the detector above.

## Scope, and what we did *not* establish

One board, one SoC bin, one out-of-table value (1100 MHz), one workload, on the **vendor BSP
6.1 kernel with the vendor `rknpu` driver** — *not* mainline. The SCMI/ATF clock ownership is
architectural and should apply to any RK3588/RK3588S board (Rock 5B, Orange Pi 5/5 Plus,
Radxa, Khadas, NanoPi) and to mainline, but we have not verified either. We did not
characterise the fallback behaviour for other frequencies or engines.

**We would like this checked on other hardware.** If you have an RK3588 board and an NPU
workload, a confirming *or* contradicting result is equally useful — please open an issue
with your numbers. Older non-SCMI Rockchip parts (RK3399, RK356x) manage OPPs in the kernel
and are not affected.

## The practical takeaway

There is no free headroom on RK3588 — every engine already runs at its rated ceiling at
maximum rail voltage. The win available to you is not a bigger number, it is **sustaining**
the rated clocks under sustained load. Good cooling stops the chip de-clocking itself; a
device-tree "overclock" does not raise the ceiling.

---
Measured by **defcom5-rockchip**. GPL-3.0. Raw logs and the exact DTS delta available on request.
