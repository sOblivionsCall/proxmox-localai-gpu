import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    # Capture the backend process's raw stderr during load: run the backend
    # load manually with the same flags LocalAI would use, on the host side
    # of the container, logging to a file we can read.
    chan = cli.get_transport().open_session()
    chan.settimeout(None)
    cmd = '''pct exec 112 -- bash -c '
export LOCALAI_BACKENDS_PATH=/opt/localai/backends
ls /opt/localai/backends/llama-cpp/ 2>/dev/null
cat /opt/localai/backends/llama-cpp/run.sh 2>/dev/null | head -20
' '''
    chan.exec_command(cmd)
    buf = b""
    t0 = time.time()
    while time.time() - t0 < 30:
        if chan.recv_ready():
            buf += chan.recv(65536)
        if chan.exit_status_ready() and not chan.recv_ready():
            break
        time.sleep(2)
    print(buf.decode("utf-8", "replace")[:2000])
    chan.close()
finally:
    cli.close()
