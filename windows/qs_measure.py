"""Memory of N idle Quicksand sandboxes (QEMU on Windows, Alpine, 256 MB each)."""
import asyncio
import sys
import time
from contextlib import AsyncExitStack

import psutil
from quicksand import Sandbox


def qemu_procs():
    out = []
    for p in psutil.process_iter(["name", "memory_info"]):
        if "qemu" in (p.info["name"] or "").lower() and p.info["memory_info"]:
            out.append(p)
    return out


async def run(n: int) -> None:
    before_free = psutil.virtual_memory().available / 1048576
    t0 = time.time()
    async with AsyncExitStack() as stack:
        boxes = []
        for _ in range(n):
            box = await asyncio.wait_for(stack.enter_async_context(Sandbox(image="alpine", memory="256M")), 240)
            boxes.append(box)
        boot = time.time() - t0
        for box in boxes:
            await asyncio.wait_for(box.execute("echo ok"), 60)
        await asyncio.sleep(20)
        procs = qemu_procs()
        ws = sum(p.info["memory_info"].rss for p in procs) / 1048576
        after_free = psutil.virtual_memory().available / 1048576
        print(
            f"RESULT quicksand N={n} qemu_procs={len(procs)} qemu_working_set_total_mb={ws:.0f} "
            f"per_guest_mb={ws / n:.0f} total_boot_s={boot:.1f} available_ram_drop_mb={before_free - after_free:.0f}",
            flush=True,
        )


asyncio.run(run(int(sys.argv[1])))
