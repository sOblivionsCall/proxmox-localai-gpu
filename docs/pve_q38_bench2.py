import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    cmd = '''pct exec 112 -- bash -c '
cat > /tmp/bench.json <<EOF
{"model":"qwen38-27b-ud-iq3xxs","messages":[{"role":"user","content":"Count from 1 to 50, each number on its own line."}],"max_tokens":300,"temperature":0}
EOF
curl -s -m 150 -X POST http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d @/tmp/bench.json -o /dev/null
T0=$(date +%s)
curl -s -m 300 -X POST http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d @/tmp/bench.json -o /tmp/bench-out.json
T1=$(date +%s)
ELAPSED=$((T1-T0))
echo "elapsed=${ELAPSED}s"
CT=$(python3 -c "import json; print(json.load(open('/tmp/bench-out.json'))[\"usage\"][\"completion_tokens\"])")
echo "ctok=${CT}  tok/s=$(python3 -c "print(f'{$CT/$ELAPSED:.1f}')")"
' '''
    chan = cli.get_transport().open_session()
    chan.settimeout(None)
    chan.exec_command(cmd)
    buf = b""
    t0 = time.time()
    while time.time() - t0 < 480:
        if chan.recv_ready():
            buf += chan.recv(65536)
        if chan.exit_status_ready() and not chan.recv_ready():
            break
        time.sleep(3)
    print(buf.decode("utf-8", "replace")[-500:])
    chan.close()
finally:
    cli.close()
