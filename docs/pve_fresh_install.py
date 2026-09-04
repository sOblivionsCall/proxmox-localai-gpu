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

    def read(drain=10):
        out = b""
        t0 = time.time()
        while time.time() - t0 < drain:
            if chan.recv_ready():
                out += chan.recv(65535)
            time.sleep(0.5)
        t = out.decode("utf-8", "replace")
        return re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[()][0-9A-B]', '', t)

    # Fresh pull of the ct script (includes all pushed fixes)
    send("curl -fsSL https://raw.githubusercontent.com/sOblivionsCall/proxmox-localai-gpu/main/ct/localai.sh -o /root/proxmox-localai-gpu/ct/localai.sh && echo PULLED\n", wait=6)
    print(read(5)[-100:], flush=True)

    send("bash /root/proxmox-localai-gpu/ct/localai.sh 2>&1 | tee /root/localai-fresh.log\n", wait=12)
    t = read(12)
    if "Choose an option" in t or "Default Install" in t:
        print(">>> menu: Default Install", flush=True)
        chan.send("\r")

    milestones = []
    done = False
    for i in range(90):
        t = read(10)
        if not t.strip():
            continue
        for marker in ["NVIDIA GPU passthrough configured",
                       "LocalAI binary installed",
                       "localai.service enabled",
                       "nvidia-smi works inside",
                       "LocalAI installation complete"]:
            if marker in t and marker not in milestones:
                milestones.append(marker)
                print(f">>> MILESTONE: {marker}", flush=True)
        if "Completed successfully" in t or "LocalAI installation complete" in t:
            done = True
            print(">>> INSTALL FINISHED", flush=True)
            break
        if "Installation failed" in t or "Error:" in t[-300:]:
            print(">>> FAILURE:", flush=True)
            print(t[-400:], flush=True)
            break

    if done:
        # Extract the CT IP from the log
        ip_m = re.search(r'http://(\d+\.\d+\.\d+\.\d+):8080', t)
        ip = ip_m.group(1) if ip_m else "?"
        print(f">>> CT IP: {ip}", flush=True)
        # Persist IP for the validation phase
        send(f"echo {ip} > /root/localai-ct-ip\n", wait=2)
        read(3)
        print(">>> READY FOR VALIDATION", flush=True)
    chan.close()
finally:
    cli.close()
