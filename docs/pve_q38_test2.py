import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    chan = cli.get_transport().open_session()
    chan.settimeout(None)
    cmd = '''pct exec 112 -- bash -c '
echo "VRAM before: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader)"
T0=$(date +%s)
curl -s -m 540 -X POST http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d @/tmp/q38req.json > /tmp/q38out.json
RC=$?
T1=$(date +%s)
echo "rc=$RC elapsed=$((T1-T0))s"
head -c 700 /tmp/q38out.json
echo
echo "VRAM after: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader)"
' '''
    chan.exec_command(cmd)
    buf = b""
    t0 = time.time()
    while time.time() - t0 < 560:
        if chan.recv_ready():
            buf += chan.recv(65536)
        if chan.exit_status_ready() and not chan.recv_ready():
            break
        time.sleep(3)
    print(buf.decode("utf-8", "replace")[-1400:])
    chan.close()
finally:
    cli.close()
