import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    # grab the FULL llama.cpp load log from the backend (it goes to grpc stderr)
    chan = cli.get_transport().open_session()
    chan.settimeout(None)
    cmd = '''pct exec 112 -- bash -c '
curl -s -m 30 -X POST http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d @/tmp/q38req.json > /dev/null 2>&1 &
sleep 2
for i in $(seq 1 20); do
  journalctl -u localai --no-pager --since "5 sec ago" 2>/dev/null | grep -iE "llm_load|print_info|KV |buffer|offload|CUDA" | tail -20
  sleep 2
done
wait
' '''
    chan.exec_command(cmd)
    buf = b""
    t0 = time.time()
    while time.time() - t0 < 100:
        if chan.recv_ready():
            buf += chan.recv(65536)
        if chan.exit_status_ready() and not chan.recv_ready():
            break
        time.sleep(2)
    out = buf.decode("utf-8", "replace")
    # LocalAI gRPC backend logs often swallowed; also check the backend log file
    print(out[-2500:] if out.strip() else "(no llama load lines in journal)")
    chan.close()
finally:
    cli.close()
