import sys
import paramiko

HOST = "192.168.1.135"
USER = "root"
PASS = "1Starshine!"

def run(cmd, timeout=60):
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
    try:
        stdin, stdout, stderr = cli.exec_command(cmd, timeout=timeout)
        out = stdout.read().decode("utf-8", "replace")
        err = stderr.read().decode("utf-8", "replace")
        code = stdout.channel.recv_exit_status()
        return out, err, code
    finally:
        cli.close()

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "hostname"
    timeout = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    out, err, code = run(cmd, timeout)
    print(out)
    if err.strip():
        print("STDERR:", err[:2000])
    print(f"exit={code}")
