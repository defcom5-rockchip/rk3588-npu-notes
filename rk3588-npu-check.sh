#!/bin/sh
# rk3588-npu-check — are you running a PHANTOM OVERCLOCK?
#
# On RK3588 the NPU/GPU/big-CPU clocks are SCMI clocks owned by ARM Trusted
# Firmware (BL31). A device-tree OPP is a *request*, not a command: if you add an
# operating point that ATF has no validated rate for, the firmware can clamp to a
# rate BELOW the native bin — while devfreq happily reports the value you asked
# for. Measured result on an Orange Pi 5B: local-LLM throughput HALVED
# (8.68 -> 4.05 tok/s) with every readout reporting success.
#
# This script is READ-ONLY. It changes nothing. It tells you whether you are
# affected and how to undo it.
#
#   Background : https://github.com/defcom5-rockchip/pi-studio/blob/main/OVERCLOCKING.md
#   Discussion : https://github.com/defcom5-rockchip/pi-studio/issues/3
#
# defcom5-rockchip — GPL-3.0. Run as root for the full clock cross-check.

STOCK_NPU_HZ=1000000000     # RK3588/RK3588S native NPU bin
STOCK_GPU_HZ=1000000000
VERDICT=ok
say() { printf '%s\n' "$*"; }
hr()  { printf -- '----------------------------------------------------------\n'; }

say "rk3588-npu-check — phantom overclock detector (read-only)"
hr

# ---------- 1. is this even an RK3588? ----------
COMPAT=$(tr -d '\0' < /proc/device-tree/compatible 2>/dev/null)
MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
case "$COMPAT" in
  *rk3588*) : ;;
  *) say "Not an RK3588/RK3588S (compatible: ${COMPAT:-unknown})."
     say "This check only applies to RK3588-family SoCs. Nothing to do."
     exit 0 ;;
esac
say "Board   : ${MODEL:-unknown}"
say "Kernel  : $(uname -r)"

# ---------- 2. locate the NPU/GPU devfreq nodes ----------
find_devfreq() {  # $1 = name fragment to match in the device path
    for d in /sys/class/devfreq/*/; do
        [ -e "$d/available_frequencies" ] || continue
        case "$(basename "$d")" in *"$1"*) printf '%s' "$d"; return 0;; esac
    done
    return 1
}
NPU=$(find_devfreq npu) || NPU=""
GPU=$(find_devfreq gpu) || GPU=""

# ---------- 3. the actual test: any OPP above the native bin? ----------
check_engine() {  # $1=label $2=devfreq dir $3=stock Hz
    label=$1; dir=$2; stock=$3
    [ -n "$dir" ] || { say "$label     : no devfreq node found (skipped)"; return; }
    avail=$(cat "$dir/available_frequencies" 2>/dev/null)
    cur=$(cat "$dir/cur_freq" 2>/dev/null)
    max=0
    for f in $avail; do [ "$f" -gt "$max" ] 2>/dev/null && max=$f; done
    printf '%s     : cur %s MHz | max OPP %s MHz | governor %s\n' \
        "$label" "$((cur/1000000))" "$((max/1000000))" "$(cat "$dir/governor" 2>/dev/null)"
    if [ "$max" -gt "$stock" ] 2>/dev/null; then
        say ""
        say "  *** WARNING: $label has an OPP above the native $((stock/1000000)) MHz bin."
        say "      Added operating point(s):"
        for f in $avail; do
            [ "$f" -gt "$stock" ] 2>/dev/null && say "        $((f/1000000)) MHz"
        done
        say "      This does NOT overclock the $label. ATF may clamp it BELOW stock."
        VERDICT=affected
        say ""
    fi
}
hr
check_engine "NPU" "$NPU" "$STOCK_NPU_HZ"
check_engine "GPU" "$GPU" "$STOCK_GPU_HZ"

# ---------- 4. cross-check the gauges (needs root + debugfs) ----------
hr
if [ -r /sys/kernel/debug/clk/clk_summary ]; then
    SCMI=$(awk '/scmi_clk_npu|npu.*scmi/ {print $1" "$5; exit}' /sys/kernel/debug/clk/clk_summary 2>/dev/null)
    if [ -n "$SCMI" ]; then
        say "Clock cross-check (devfreq vs the clock framework):"
        say "  devfreq cur_freq : $( [ -n "$NPU" ] && echo "$(( $(cat "$NPU/cur_freq")/1000000 )) MHz" || echo n/a )"
        say "  clk_summary      : $SCMI  (name rate-Hz)"
        say "  NOTE: these disagreeing is the fingerprint. On our affected board:"
        say "        devfreq said 1100 MHz, clk_summary said 200 MHz, and the"
        say "        workload implied ~470 MHz. Only the workload told the truth."
    fi
else
    say "Clock cross-check skipped (run as root; needs debugfs mounted)."
fi

# ---------- 5. verdict ----------
hr
if [ "$VERDICT" = affected ]; then
    say "VERDICT: *** you have a non-stock NPU/GPU OPP — you are likely AFFECTED. ***"
    say ""
    say "It is a bad configuration, NOT damaged silicon. Fully reversible:"
    say "  1. BENCHMARK, don't trust the readout. Run a real NPU workload and"
    say "     compare tokens/sec (or inference time) against stock. SLOWER than"
    say "     stock = confirmed."
    say "  2. Undo it, any one of:"
    say "       - restore your DTB backup and reboot"
    say "       - sudo apt install --reinstall linux-image-\$(uname -r)"
    say "       - re-flash the image"
    say "     A board that will not boot is recoverable via maskrom + rkdeveloptool."
    say "  3. Re-benchmark to confirm the recovery."
    exit 2
else
    say "VERDICT: stock operating points — no phantom overclock detected."
    say ""
    say "Tip: on RK3588 the win isn't a bigger number, it's SUSTAINING the rated"
    say "clocks under load. Good cooling stops the chip de-clocking itself; a"
    say "device-tree 'overclock' does not raise the ceiling."
    exit 0
fi
