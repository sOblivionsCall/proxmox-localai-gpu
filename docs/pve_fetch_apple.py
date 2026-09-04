import paramiko

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
# pull image out of CT 114 to host, then SFTP it local
stdin, stdout, stderr = cli.exec_command("pct pull 114 /tmp/apple.png /root/apple-114.png && ls -la /root/apple-114.png")
print(stdout.read().decode(), stderr.read().decode()[:200])
sftp = cli.open_sftp()
sftp.get("/root/apple-114.png", r"C:/Users/Spencer/proxmox-localai-gpu/docs/apple-114.png")
sftp.close()
cli.close()
print("fetched to local docs/apple-114.png")
