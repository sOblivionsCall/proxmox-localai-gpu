import paramiko

cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect('192.168.1.135', username='root', password='1Starshine!', timeout=15, look_for_keys=False, allow_agent=False)
sftp = cli.open_sftp()
sftp.put(r'C:/Users/Spencer/proxmox-localai-gpu/install/localai-banner.sh', '/tmp/localai-banner.sh')
sftp.close()
cli.close()
print('banner pushed to pve2 /tmp')
