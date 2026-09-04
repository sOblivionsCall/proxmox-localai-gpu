import paramiko, time, re

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"

cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    chan = cli.invoke_shell(width=140, height=50)
    time.sleep(2)
    chan.recv(65535)

    def send(s, wait=3):
        chan.send(s)
        time.sleep(wait)

    def read(drain=8):
        out = b""
        t0 = time.time()
        while time.time() - t0 < drain:
            if chan.recv_ready():
                out += chan.recv(65535)
            time.sleep(0.5)
        t = out.decode("utf-8", "replace")
        return re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[()][0-9A-B]', '', t)

    # Start the ct script (local checkout so engine finds install/ locally)
    send("bash /root/proxmox-localai-gpu/ct/localai.sh 2>&1 | tee /root/localai-run3.log\n", wait=12)
    t = read(12)
    # Menu: select "Default Install" (already highlighted) -> Enter
    if "Choose an option" in t or "Default Install" in t:
        print(">>> TUI menu detected, selecting Default Install", flush=True)
        chan.send("\r")
        time.sleep(8)
        t = read(10)
    print(t[-1500:], flush=True)

    # Now drive subsequent prompts generically: send Enter for confirmations
    for i in range(40):
        t = read(10)
        low = t.lower()
        if not t.strip():
            continue
        tail = t[-400:]
        print("---tick---", flush=True)
        print(tail, flush=True)
        # completion markers
        if "Completed successfully" in t or "LocalAI installation complete" in t:
            print(">>> INSTALL FINISHED", flush=True)
            break
        if "Installation failed" in t or "error" in low[-200:]:
            print(">>> FAILURE DETECTED — stopping interaction, leaving container for debug", flush=True)
            break
        # Any yes/no or confirm dialog: default to Enter
        if any(k in tail for k in ("Confirm", "Yes", "OK", "Default", "Advance", "agree", "(Y/n)", "[Y/n]", "Default Install")):
            chan.send("\r")
        # a settings OK button
        if "Select" in tail and "OK" in tail:
            chan.send("\r")

    chan.close()
finally:
    cli.close()
