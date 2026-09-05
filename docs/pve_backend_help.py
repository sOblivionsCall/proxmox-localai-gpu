import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    # The backend binary takes model config via env/args for the GRPC server.
    # It reads the same flags as llama-server but prefixed. Check usage:
    chan = cli.get_transport().open_session()
    chan.settimeout(None)
    cmd = '''pct exec 112 -- bash -c '
cd /opt/localai/backends/cuda12-llama-cpp
export LD_LIBRARY_PATH=/opt/localai/backends/cuda12-llama-cpp/lib:/usr/lib/x86_64-linux-gnu
./llama-cpp-cpu-all --help 2>&1 | head -40
' '''
    chan.exec_command(cmd)
    buf = b""
    t0 = time.time()
    while time.time() - t0 < 40:
        if chan.recv_ready():
            buf += chan.recv(65536)
        if chan.exit_status_ready() and not chan.recv_ready():
            break
        time.sleep(2)
    print(buf.decode("utf-8", "replace")[:2500])
    chan.close()
finally:
    cli.close()
