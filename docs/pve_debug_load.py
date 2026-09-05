import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    # Reproduce with the FULL LocalAI stack, but bump verbosity: stop service,
    # run local-ai manually with the same flags and capture backend stderr live
    chan = cli.get_transport().open_session()
    chan.settimeout(None)
    cmd = '''pct exec 112 -- bash -c '
systemctl stop localai
cd /opt/localai
export MODELS_PATH=/opt/localai/models
export LOCALAI_BACKENDS_PATH=/opt/localai/backends
export LOCALAI_LOG_LEVEL=debug
# Run local-ai but only until we see the llama load attempt, then kill
timeout 180 /usr/local/bin/local-ai run --models-path /opt/localai/models --address 0.0.0.0:8080 > /tmp/la-debug.log 2>&1 &
LPID=$!
sleep 20
# fire a chat request to trigger the model load
curl -s -m 150 -X POST http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d @/tmp/q38req.json > /dev/null 2>&1
sleep 10
grep -iE "offload|KV self|CUDA0|compute buffer|rs cache|abort|llm_load" /tmp/localai-debug.log 2>/dev/null | tail -20
pkill -f "local-ai run" 2>/dev/null
echo CAPTURE_DONE
' '''
    # First launch with debug log to file
    cmd = cmd.replace('/tmp/localai-debug.log', '/tmp/la-debug.log')
    chan.exec_command(cmd)
    buf = b""
    t0 = time.time()
    while time.time() - t0 < 220:
        if chan.recv_ready():
            buf += chan.recv(65536)
        if chan.exit_status_ready() and not chan.recv_ready():
            break
        time.sleep(3)
    print(buf.decode("utf-8", "replace")[-2200:])
    chan.close()
finally:
    cli.close()
