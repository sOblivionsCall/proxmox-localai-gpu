import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    # 3 timed runs entirely from the host side, timing each
    for i in [1, 2, 3]:
        t0 = time.time()
        stdin, stdout, stderr = cli.exec_command(
            "pct exec 112 -- curl -s -m 200 -X POST http://localhost:8080/v1/chat/completions "
            "-H 'Content-Type: application/json' -d @/tmp/bench.json -o /tmp/bench-o.json", timeout=220)
        stdout.read()
        wall = time.time() - t0
        # read usage
        stdin, stdout, stderr = cli.exec_command(
            "pct exec 112 -- python3 -c \"import json; print(json.load(open('/tmp/bench-o.json'))['usage']['completion_tokens'])\"", timeout=30)
        ct_raw = stdout.read().decode().strip()
        try:
            ct = int(ct_raw)
            print(f"run {i}: {wall:.1f}s wall  {ct} ctok  {ct/wall:.1f} tok/s")
        except Exception:
            print(f"run {i}: wall={wall:.1f}s ct_raw={ct_raw!r}")
finally:
    cli.close()
