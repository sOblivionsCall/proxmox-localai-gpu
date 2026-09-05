import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    # Fire the request and capture the backend's own stderr during load —
    # the crash details (SIG/OOM) go to the backend subprocess, not journalctl
    chan = cli.get_transport().open_session()
    chan.settimeout(None)
    cmd = '''pct exec 112 -- bash -c '
echo "VRAM before: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader)"
free -m | head -2
T0=$(date +%s)
curl -s -m 400 -X POST http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d @/tmp/q38req.json > /tmp/q38out4.json
RC=$?
T1=$(date +%s)
echo "rc=$RC elapsed=$((T1-T0))s"
head -c 300 /tmp/q38out4.json 2>/dev/null; head -c 300 /tmp/q38out3.json
echo
echo "VRAM after: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader)"
echo "RAM after: $(free -m | awk '/Mem:/{print $3}')"
' '''
    chan.exec_command(cmd)
    buf = b""
    t0 = time.time()
    while time.time() - t0 < 420:
        if chan.recv_ready():
            buf += chan.recv(65536)
        if chan.exit_status_ready() and not chan.recv_ready():
            break
        time.sleep(3)
    print(buf.decode("utf-8", "replace")[-1000:])
    chan.close()
finally:
    cli.close()
