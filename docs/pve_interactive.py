import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"

cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    # Run interactively via invoke_shell so the TUI (whiptail-style prompts)
    # works and we can see the real failure point.
    chan = cli.invoke_shell(width=120, height=40)
    time.sleep(2)
    out = chan.recv(65535).decode("utf-8", "replace")
    print(out[-800:])
    chan.send("bash /root/proxmox-localai-gpu/ct/localai.sh 2>&1 | tee /root/localai-install-run2.log\n")
    time.sleep(30)
    out = b""
    t0 = time.time()
    while time.time() - t0 < 60:
        if chan.recv_ready():
            out += chan.recv(65535)
        time.sleep(2)
        if len(out) > 4000:
            break
    text = out.decode("utf-8", "replace")
    # strip ANSI
    import re
    text = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', text)
    print(text[-3000:])
    chan.close()
finally:
    cli.close()
