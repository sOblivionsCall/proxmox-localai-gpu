import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    chan = cli.get_transport().open_session()
    chan.settimeout(None)
    cmd = '''pct exec 112 -- bash -c '
cd /opt/localai/backends/cuda12-llama-cpp
export LD_LIBRARY_PATH=/opt/localai/backends/cuda12-llama-cpp/lib:/usr/lib/x86_64-linux-gnu
timeout 100 ./llama-cpp-cpu-all -m /opt/localai/models/Qwen3.8-27B-UD-IQ3_XXS.gguf -c 8192 -ngl 48 -b 512 -ub 512 --flash-attn auto -fa on 2>&1 | tail -25
echo MANUAL_LOAD_DONE
' '''
    chan.exec_command(cmd)
    buf = b""
    t0 = time.time()
    while time.time() - t0 < 140:
        if chan.recv_ready():
            buf += chan.recv(65536)
        if chan.exit_status_ready() and not chan.recv_ready():
            break
        time.sleep(3)
    out = buf.decode("utf-8", "replace")
    # Filter to the interesting lines
    keep = [l for l in out.splitlines() if any(k in l.lower() for k in ["offload", "kv", "buffer", "error", "abort", "load", "cuda0", "n_ctx"]) or "MANUAL_LOAD_DONE" in l]
    print("\n".join(keep[-25:]))
    chan.close()
finally:
    cli.close()
