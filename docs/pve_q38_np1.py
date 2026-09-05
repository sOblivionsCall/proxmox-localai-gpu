import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    # The engine hardcodes parallel="4" via LLAMACPP_PARALLEL default. Override:
    # 1) env var on the service: LLAMACPP_PARALLEL=1
    # 2) model yaml options: n_parallel:1
    yaml_content = '''name: qwen38-27b-ud-iq3xxs
backend: llama-cpp
context_size: 4096
gpu_layers: 99
cache_type_k: q8_0
cache_type_v: q8_0
parameters:
  model: Qwen3.8-27B-UD-IQ3_XXS.gguf
  batch: 512
options:
  - reasoning_format:none
  - n_parallel:1
'''
    sftp = cli.open_sftp()
    sftp.open("/tmp/qwen38-v6.yaml", "w").write(yaml_content)
    sftp.close()
    cmd = '''pct push 112 /tmp/qwen38-v6.yaml /opt/localai/models/qwen38-27b-ud-iq3xxs.yaml && \\
pct exec 112 -- bash -c 'sed -i "/Environment=MODELS_PATH/a Environment=LLAMACPP_PARALLEL=1" /etc/systemd/system/localai.service; systemctl daemon-reload; systemctl restart localai; sleep 10;
echo "VRAM before: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader)"
T0=$(date +%s)
curl -s -m 500 -X POST http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d @/tmp/q38req.json > /tmp/q38out7.json
RC=$?
T1=$(date +%s)
echo "rc=$RC elapsed=$((T1-T0))s"
head -c 450 /tmp/q38out7.json
echo
echo "VRAM after: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader)"
journalctl -u localai --no-pager --since "2 min ago" | grep "effective runtime" | tail -1
' '''
    chan = cli.get_transport().open_session()
    chan.settimeout(None)
    chan.exec_command(cmd)
    buf = b""
    t0 = time.time()
    while time.time() - t0 < 550:
        if chan.recv_ready():
            buf += chan.recv(65536)
        if chan.exit_status_ready() and not chan.recv_ready():
            break
        time.sleep(3)
    print(buf.decode("utf-8", "replace")[-1600:])
    chan.close()
finally:
    cli.close()
