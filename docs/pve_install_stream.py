import paramiko, time, sys

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
LOG = "/root/localai-install-run.log"

cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    # Re-fetch the ct script (engine's internal fetch of install/localai-install.sh
    # may have raced a GitHub CDN edge) and run the whole flow, logging inline.
    cmd = f'''
rm -f {LOG}
bash -c 'curl -fsSL https://raw.githubusercontent.com/sOblivionsCall/proxmox-localai-gpu/main/ct/localai.sh -o /tmp/localai-ct.sh' && \\
bash /tmp/localai-ct.sh </dev/null 2>&1 | tee {LOG}
echo "CT_SCRIPT_EXIT=$$?" >> {LOG}
'''
    chan = cli.get_transport().open_session()
    chan.exec_command(cmd)
    # Stream until it closes, printing progress
    buf = b""
    last_print = 0
    while True:
        if chan.recv_ready():
            buf += chan.recv(4096)
        if chan.exit_status_ready() and not chan.recv_ready():
            break
        text = buf.decode("utf-8", "replace")
        if len(text) > last_print:
            new = text[last_print:]
            for line in new.splitlines():
                if line.strip():
                    print(line[:160], flush=True)
            last_print = len(text)
        time.sleep(2)
    # final flush
    text = buf.decode("utf-8", "replace")
    if len(text) > last_print:
        for line in text[last_print:].splitlines():
            if line.strip():
                print(line[:160], flush=True)
    print("=== channel closed ===")
finally:
    cli.close()
