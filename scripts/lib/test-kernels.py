"""Runs inside a JupyDo image with /opt/python4Jup/bin/python3: starts every kernel
of the image (its Pythons and Rs), executes a computation and checks the result.
Prints one line per kernel and "KERNELS python=N r=M"; exit code 1 if one fails."""
import sys
from jupyter_client.kernelspec import KernelSpecManager
from jupyter_client.manager import start_new_kernel

CODE = {"python": "print(6 * 7)", "r": "cat(6 * 7)"}
failed = False
counts = {"python": 0, "r": 0}
# the image's kernels only (JupyDo's own Python is not one: no native kernel added)
for name, spec in sorted(KernelSpecManager(ensure_native_kernel=False).get_all_specs().items()):
    language = spec["spec"]["language"].lower()
    if language not in CODE:
        continue
    try:
        km, kc = start_new_kernel(kernel_name=name, startup_timeout=300)
        try:
            output = []
            msg_id = kc.execute(CODE[language])
            while True:
                msg = kc.get_iopub_msg(timeout=300)
                if msg["parent_header"].get("msg_id") != msg_id:
                    continue
                kind, content = msg["msg_type"], msg["content"]
                if kind == "stream":
                    output.append(content["text"])
                elif kind == "execute_result":
                    output.append(content["data"].get("text/plain", ""))
                elif kind == "error":
                    output.append("ERROR " + content.get("ename", ""))
                elif kind == "status" and content["execution_state"] == "idle":
                    break
        finally:
            km.shutdown_kernel(now=True)
        result = "".join(output).strip()
        ok = "42" in result
    except Exception as e:  # kernel did not start
        ok, result = False, "{}: {}".format(type(e).__name__, e)
    print("{} kernel {} ({}): {}".format("OK  " if ok else "FAIL", name, language, result[-120:]))
    failed = failed or not ok
    if ok and language in counts:
        counts[language] += 1
print("KERNELS python={python} r={r}".format(**counts))
sys.exit(1 if failed else 0)
