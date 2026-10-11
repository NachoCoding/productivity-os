#!/usr/bin/env python3
"""Read process CPU and physical footprint; never starts an app or opens a camera."""
import argparse
import ctypes
import json
import sys
import time


class Usage(ctypes.Structure):
    # Darwin rusage_info_v2, from <sys/resource.h>.
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user", "system", "package_wakes", "interrupt_wakes", "pageins", "wired",
        "rss", "footprint", "start", "exit", "child_user", "child_system",
        "child_package_wakes", "child_interrupt_wakes", "child_pageins",
        "child_elapsed", "disk_read", "disk_write")]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True, help="Already-running Health Breaks PID")
    parser.add_argument("--baseline-seconds", type=float, default=30)
    parser.add_argument("--seconds", type=float, default=120, help="Measurement time after the baseline")
    args = parser.parse_args()
    if sys.platform != "darwin" or args.pid <= 0 or min(args.seconds, args.baseline_seconds) <= 0:
        parser.error("Requires macOS, a positive PID, and positive measurement durations")
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    lib.proc_pid_rusage.restype = ctypes.c_int

    def sample():
        usage = Usage()
        if lib.proc_pid_rusage(args.pid, 2, ctypes.byref(usage)) != 0:
            raise RuntimeError(f"Cannot read PID {args.pid}; errno {ctypes.get_errno()}")
        return {"time": time.monotonic(), "cpu": usage.user + usage.system,
                "footprint": usage.footprint, "rss": usage.rss, "start": usage.start}

    first = sample()

    def collect(seconds):
        samples = [sample()]
        deadline = samples[0]["time"] + seconds
        while time.monotonic() < deadline:
            time.sleep(min(1, max(0, deadline - time.monotonic())))
            current = sample()
            if current["start"] != first["start"]:
                raise RuntimeError("The target restarted; repeat with a fresh pre-capture baseline")
            samples.append(current)
        return samples

    def summarize(samples):
        start, end = samples[0], samples[-1]
        return {"seconds": end["time"] - start["time"],
                "cpu_percent_one_core": 100 * (end["cpu"] - start["cpu"]) / 1e9 / (end["time"] - start["time"]),
                "peak_physical_footprint_mib": max(s["footprint"] for s in samples) / 1048576,
                "peak_additional_footprint_mib": max(0, max(s["footprint"] for s in samples) - first["footprint"]) / 1048576,
                "peak_rss_mib_separate_from_footprint": max(s["rss"] for s in samples) / 1048576}

    print("Baseline: keep posture coaching OFF; this script cannot enable it.", flush=True)
    baseline = summarize(collect(args.baseline_seconds))
    print("Measurement started. For camera QA only, explicitly choose Enable & Calibrate in the app now.", flush=True)
    active = summarize(collect(args.seconds))
    print(json.dumps({"pid": args.pid, "baseline": baseline, "measurement": active,
        "additional_cpu_percentage_points": active["cpu_percent_one_core"] - baseline["cpu_percent_one_core"],
        "target_additional_footprint_mib": 150, "target_cpu_percent_one_core": 5,
        "note": "Measurement does not prove the camera was active. Record the app status and coaching phase separately."}, indent=2))


if __name__ == "__main__":
    main()
