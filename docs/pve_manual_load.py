import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    # Reproduce the load manually via the backend's grpc binary with the exact
    # failed config, capturing full llama.cpp stderr (the part journalctl drops)
    chan = cli.get_transport().open_session()
    chan.settimeout(None)
    cmd = '''pct exec 112 -- bash -c '
cd /opt/localai/backends/cuda12-llama-cpp
export LD_LIBRARY_PATH=/opt/localai/backends/cuda12-llama-cpp/lib:/usr/lib/x86_64-linux-gnu
timeout 120 ./llama-cpp-grpc --help >/dev/null 2>&1 && echo grpc-works
# Run with explicit split: 48 of ~64 layers on GPU
./llama-cpp-cpu-all --addr 127.0.0.1:39999 --model /opt/localai/models/Qwen3.8-27B-UD-IQ3_XXS.gguf --ctx-size 8192 --n-gpu-layers 48 --batch-size 512 --flash-attn auto 2>&1 | grep -iE "offload|KV self|CUDA0 model|compute buffer|error|abort" | head -15
' '''
    chan.exec_command(cmd)
    buf = b""
    t0 = time.time()
    while time.time() - t0 < 150:
        if chan.recv_ready():
            buf += chan.recv(65536)
        if chan.exit_status_ready() and not chan.recv_ready():
            break
        time.sleep(3)
    print(buf.decode("utf-8", "replace")[:2500])
    chan.close()
finally:
    cli.close()
