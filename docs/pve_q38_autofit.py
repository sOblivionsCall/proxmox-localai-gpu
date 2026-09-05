import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    # Full-offload attempt with minimal context: 4096, q8 KV, and let
    # llama.cpp auto-fit (omit gpu_layers entirely so common_fit_params runs)
    chan = cli.get_transport().open_session()
    chan.settimeout(None)
    yaml_content = '''name: qwen38-27b-ud-iq3xxs
backend: llama-cpp
context_size: 4096
cache_type_k: q8_0
cache_type_v: q8_0
parameters:
  model: Qwen3.8-27B-UD-IQ3_XXS.gguf
  batch: 512
options:
  - reasoning_format:none
'''
    sftp = cli.open_sftp()
    sftp.open("/tmp/qwen38-v4.yaml", "w").write(yaml_content)
    sftp.close()
    cmd = '''pct push 112 /tmp/qwen38-v4.yaml /opt/localai/models/qwen38-27b-ud-iq3xxs.yaml && \\
pct exec 112 -- bash -c '
systemctl restart localai
sleep 8
echo "VRAM before: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader)"
T0=$(date +%s)
curl -s -m 500 -X POST http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d @/tmp/q38req.json > /tmp/q38out5.json
RC=$?
T1=$(date +%s)
echo "rc=$RC elapsed=$((T1-T0))s"
head -c 500 /tmp/q38out5.json
echo
echo "VRAM after: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader)"
journalctl -u localai --no-pager --since "3 min ago" | grep -iE "offload|KV self|n_ctx|fit" | tail -4
' '''
    chan.exec_command(cmd)
    buf = b""
    t0 = time.time()
    while time.time() - t0 < 550:
        if chan.recv_ready():
            buf += chan.recv(65536)
        if chan.exit_status_ready() and not chan.recv_ready():
            break
        time.sleep(3)
    print(buf.decode("utf-8", "replace")[-2000:])
    chan.close()
finally:
    cli.close()
