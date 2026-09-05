import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    cmd = '''pct exec 112 -- bash -c '
T0=$(date +%s)
curl -s -m 300 -X POST http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d @/tmp/bench.json -o /tmp/bench-out2.json
T1=$(date +%s)
echo "elapsed=$((T1-T0))s"
CT=$(python3 -c "import json; print(json.load(open('/tmp/bench-out2.json'))['usage']['completion_tokens'])")
echo "completion_tokens=$CT tok/s=$(python3 -c "print(round($CT/($T1-$T0),1))")"
' '''
    stdin, stdout, stderr = cli.exec_command(cmd, timeout=340)
    print(stdout.read().decode())
finally:
    cli.close()
