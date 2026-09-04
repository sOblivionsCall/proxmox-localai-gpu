import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"

cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    cmd = '''mkdir -p /root/proxmox-localai-gpu/ct /root/proxmox-localai-gpu/install /root/proxmox-localai-gpu/core
curl -fsSL https://raw.githubusercontent.com/sOblivionsCall/proxmox-localai-gpu/main/ct/localai.sh -o /root/proxmox-localai-gpu/ct/localai.sh
curl -fsSL https://raw.githubusercontent.com/sOblivionsCall/proxmox-localai-gpu/main/install/localai-install.sh -o /root/proxmox-localai-gpu/install/localai-install.sh
curl -fsSL https://raw.githubusercontent.com/sOblivionsCall/proxmox-localai-gpu/main/install/localai-update.sh -o /root/proxmox-localai-gpu/install/localai-update.sh
curl -fsSL https://raw.githubusercontent.com/sOblivionsCall/proxmox-localai-gpu/main/core/minimal-build.func -o /root/proxmox-localai-gpu/core/minimal-build.func
ls -la /root/proxmox-localai-gpu/ct /root/proxmox-localai-gpu/install
rm -f /root/localai-install-run.log
nohup bash /root/proxmox-localai-gpu/ct/localai.sh </dev/null > /root/localai-install-run.log 2>&1 &
echo "bg install started, pid=$!"
'''
    stdin, stdout, stderr = cli.exec_command(cmd, timeout=60)
    print(stdout.read().decode())
    print(stderr.read().decode()[:500])
finally:
    cli.close()
