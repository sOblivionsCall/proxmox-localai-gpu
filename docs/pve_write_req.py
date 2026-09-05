import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    # Write the request JSON as a file first (avoids quoting hell)
    setup = '''pct exec 112 -- bash -c 'cat > /tmp/q38req.json <<EOF
{"model":"qwen38-27b-ud-iq3xxs","messages":[{"role":"user","content":"What is 6 times 7? Answer with just the number."}],"max_tokens":200}
EOF
echo written; cat /tmp/q38req.json'
'''
    stdin, stdout, stderr = cli.exec_command(setup, timeout=30)
    print(stdout.read().decode())
    cli.close()
finally:
    pass
