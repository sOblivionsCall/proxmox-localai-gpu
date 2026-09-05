import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    # Throughput probe: 300-token generation, timing it
    cmd = '''pct exec 112 -- bash -c '
cat > /tmp/bench.json <<EOF
{"model":"qwen38-27b-ud-iq3xxs","messages":[{"role":"user","content":"Write a Python function that checks if a number is prime. Be concise."}],"max_tokens":300,"temperature":0}
EOF
# warmup
curl -s -m 120 -X POST http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d @/tmp/bench.json -o /dev/null
T0=$(date +%s.%N)
RESP=$(curl -s -m 300 -X POST http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d @/tmp/bench.json)
T1=$(date +%s.%N)
echo "$RESP" > /tmp/bench-out.json
ELAPSED=$(python3 -c "print(f'{$T1-$T0:.1f}')")
python3 -c "
import json
d = json.load(open('/tmp/bench-out.json'))
u = d.get('usage', {})
ct = u.get('completion_tokens', 0)
print(f'wall={${ELAPSED}}s  ctok={ct}  tok/s={ct/${ELAPSED}:.1f}')
"
journalctl -u localai --no-pager -n 5 | grep -oE 'draft acceptance[^"]*' | tail -1
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
    print(buf.decode("utf-8", "replace")[-800:])
    chan.close()
finally:
    cli.close()
