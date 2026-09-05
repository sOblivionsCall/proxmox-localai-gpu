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
timeout 100 ./llama-cpp-cpu-all -m /opt/localai/models/Qwen3.8-27B-UD-IQ3_XXS.gguf -c 8192 -ngl 48 -b 512 -ub 512 -fa on 2>&1 > /tmp/manual-load.log
echo "exit=$?"
wc -l /tmp/manual-load.log 2>/dev/null
tail -30 /tmp/manual-load.log 2>/dev/null || true
' '''
    # Actually capture BOTH: run with output to file inside CT, then read tail
    cmd2 = '''pct exec 112 -- bash -c '
cd /opt/localai/backends/cuda12-llama-cpp
export LD_LIBRARY_PATH=/opt/localai/backends/cuda12-llama-cpp/lib:/usr/lib/x86_64-linux-gnu
timeout 100 ./llama-cpp-cpu-all -m /opt/localai/models/Qwen3.8-27B-UD-IQ3_XXS.gguf -c 8192 -ngl 48 -b 512 -ub 512 -fa on > /tmp/manual-load.log 2>&1
echo "EXIT=$?"
grep -iE "offload|KV self|buffer|error|abort|CUDA0|n_ctx|n_layer" /tmp/manual-load.log | tail -20
echo TAIL
tail -8 /tmp/manual-load.log
' '''
    chan.exec_command(cmd2)
    buf = b""
    t0 = time.time()
    while time.time() - t0 < 140:
        if chan.recv_ready():
            buf += chan.recv(65536)
        if chan.exit_status_ready() and not chan.recv_ready():
            break
        time.sleep(3)
    print(buf.decode("utf-8", "replace")[-3000:])
    chan.close()
finally:
    cli.close()
