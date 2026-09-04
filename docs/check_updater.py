import paramiko

cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect('192.168.1.135', username='root', password='1Starshine!', timeout=15, look_for_keys=False, allow_agent=False)
# Fix the root cause of the missing updater: the installer ships it, but the
# engine deletes /tmp between install and our push step. Instead, have the
# INSTALLER keep a copy at a stable path and the ct script copy from there.
# Simpler: ct script writes the updater via the repo checkout it already has.
# Verify what happened: did installer's copy of update.sh land?
stdin, stdout, stderr = cli.exec_command("pct exec 112 -- ls -la /opt/localai/ | grep -E 'update|deploy'")
print(stdout.read().decode())
cli.close()
