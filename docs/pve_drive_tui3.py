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

    # Sync the fixed installer into the host-side local checkout
    send("curl -fsSL https://raw.githubusercontent.com/sOblivionsCall/proxmox-localai-gpu/main/install/localai-install.sh -o /root/proxmox-localai-gpu/install/localai-install.sh && grep -o 'linux-amd64' /root/proxmox-localai-gpu/install/localai-install.sh | head -1\n", wait=6)
    print("sync check:", read(5)[-80:], flush=True)

    send("bash /root/proxmox-localai-gpu/ct/localai.sh 2>&1 | tee /root/localai-run5.log\n", wait=12)
    t = read(12)
    if "Choose an option" in t or "Default Install" in t:
        print(">>> menu, selecting Default", flush=True)
        chan.send("\r")
    done = False
    for i in range(70):
        t = read(10)
        if not t.strip():
            continue
        tail = t[-300:]
        print("---tick---", flush=True)
        print(tail, flush=True)
        if "Completed successfully" in t or "LocalAI installation complete" in t:
            print(">>> INSTALL FINISHED", flush=True)
            done = True
            break
        if "Installation failed" in t:
            print(">>> FAILURE — leaving container for debug", flush=True)
            break
        if any(k in tail for k in ("Confirm", "Yes", "OK", "Default", "Select", "(Y/n)")):
            chan.send("\r")
    if done:
        # Verify GPU + service state inside the container
        send("pct exec $(pct list | grep localai | awk '{print $1}') -- bash -c 'systemctl is-active localai; nvidia-smi | head -10' 2>&1 | tail -12\n", wait=15)
        print(read(15)[-1200:], flush=True)
    chan.close()
finally:
    cli.close()
