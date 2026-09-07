#!/usr/bin/env python3
"""只读采集指定 macOS 进程的常驻资源指标，不读取剪贴板或应用内容。"""

import argparse
import ctypes
import datetime
import json
import math
from pathlib import Path
import sys
import time


class ResourceUsage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64)
        for name in (
            "user_ticks", "system_ticks", "idle_wakeups", "interrupt_wakeups",
            "pageins", "wired_bytes", "resident_bytes", "footprint_bytes",
            "start_abstime", "exit_abstime", "child_user_ticks", "child_system_ticks",
            "child_idle_wakeups", "child_interrupt_wakeups", "child_pageins",
            "child_elapsed_abstime", "disk_read_bytes", "disk_write_bytes",
        )
    ]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--seconds", type=float, default=900)
    parser.add_argument("--interval", type=float, default=10)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if (sys.platform != "darwin" or not 0 < args.pid < 2**31
            or not math.isfinite(args.seconds) or args.seconds <= 0
            or not math.isfinite(args.interval) or args.interval <= 0):
        parser.error("需要 macOS、有效 PID，以及大于零的时长和间隔")
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    library.proc_pid_rusage.restype = ctypes.c_int
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    system.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
    system.mach_timebase_info.restype = ctypes.c_int
    timebase = Timebase()
    if system.mach_timebase_info(ctypes.byref(timebase)) != 0 or timebase.denom == 0:
        raise SystemExit("无法读取系统计时单位")
    seconds_per_tick = timebase.numer / timebase.denom / 1e9
    args.output.parent.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    previous = None
    identity = None
    count = 0
    # 独占创建，避免长时采样误覆盖已有证据。
    with args.output.open("x") as output:
        try:
            while True:
                usage = ResourceUsage()
                if library.proc_pid_rusage(args.pid, 2, ctypes.byref(usage)) != 0:
                    raise OSError(ctypes.get_errno(), "无法读取目标进程；可能已退出或缺少权限")
                current_identity = (usage.start_abstime, bytes(usage.uuid))
                if identity is not None and identity != current_identity:
                    raise RuntimeError("PID 已被另一进程使用，停止采样")
                identity = current_identity
                now = time.monotonic()
                row = {name: getattr(usage, name) for name, _ in usage._fields_ if name != "uuid"}
                row.update(pid=args.pid, timestamp=datetime.datetime.now().astimezone().isoformat(), elapsed_seconds=now - start)
                row["cpu_seconds"] = (usage.user_ticks + usage.system_ticks) * seconds_per_tick
                if previous is not None:
                    elapsed = now - previous["monotonic"]
                    row["cpu_percent"] = (row["cpu_seconds"] - previous["cpu_seconds"]) / elapsed * 100
                    row["idle_wakeups_per_second"] = (usage.idle_wakeups - previous["idle_wakeups"]) / elapsed
                    row["interrupt_wakeups_per_second"] = (usage.interrupt_wakeups - previous["interrupt_wakeups"]) / elapsed
                previous = dict(monotonic=now, cpu_seconds=row["cpu_seconds"],
                                idle_wakeups=usage.idle_wakeups, interrupt_wakeups=usage.interrupt_wakeups)
                output.write(json.dumps(row) + "\n")
                output.flush()
                count += 1
                remaining = args.seconds - (time.monotonic() - start)
                if remaining <= 0:
                    break
                time.sleep(min(args.interval, remaining))
        except (OSError, RuntimeError, KeyboardInterrupt) as error:
            output.write(json.dumps({"stopped": str(error), "samples": count}) + "\n")
            output.flush()
            raise SystemExit(f"采样已停止，保留 {count} 条记录：{error}") from error
    print(f"已采集 {count} 条进程资源记录：{args.output}")


if __name__ == "__main__":
    main()
