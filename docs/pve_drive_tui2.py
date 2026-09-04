import paramiko, time, re

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"

cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    # Sync fixed installer into the local checkout the engine will fetch from
    for f in ["install/localai-install.sh", "install/localai-update.sh"]:
        cli.exec_command(f"pct exec 112 -- mkdir -p /tmp/none 2>/dev/null; true")
    time.sleep(1)

    chan = cli.invoke_shell(width=140, height=50)
    time.sleep(2)
    chan.recv(65535)

    def send(s, wait=3):
        chan.send(s)
        time.sleep(wait)

    def read(drain=10):
        out = b""
        t0 = time.time()
        while time.time() - t0 < drain:
            if chan.recv_ready():
                out += chan.recv(65535)
            time.sleep(0.5)
        t = out.decode("utf-8", "replace")
        return re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[()][0-9A-B]', '', t)

    # Pull the fixed installer into the CT's own checkout? No — the engine
    # fetches from COMMUNITY_SCRIPTS_URL (GitHub). We just pushed, but CDN
    # may lag. Bypass: push the fixed installer directly into CT 112 at the
    # path the engine's local-checkout would use, and re-run the ct script.
    send("curl -fsSL https://raw.githubusercontent.com/sOblivionsCall/proxmox-localai-gpu/main/install/localai-install.sh -o /root/proxmox-localai-gpu/install/localai-install.sh && grep -c 'local-ai-' /root/proxmox-localai-gpu/install/localai-install.sh\n", wait=6)
    print(read(5)[-200:], flush=True)

    send("bash /root/proxmox-localai-gpu/ct/localai.sh 2>&1 | tee /root/localai-run4.log\n", wait=12)
    t = read(12)
    if "Choose an option" in t or "Default Install" in t:
        print(">>> menu, selecting Default", flush=True)
        chan.send("\r")
    for i in range(60):
        t = read(10)
        if not t.strip():
            continue
        tail = t[-350:]
        print("---tick---", flush=True)
        print(tail, flush=True)
        if "Completed successfully" in t or "LocalAI installation complete" in t:
            print(">>> INSTALL FINISHED", flush=True)
            break
        if "Installation failed" in t:
            print(">>> FAILURE — leaving container for debug", flush=True)
            break
        if any(k in tail for k in ("Confirm", "Yes", "OK", "Default", "Select", "(Y/n)")):
            chan.send("\r")
    chan.close()
finally:
    cli.close()
