import paramiko

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)

yaml_content = '''name: qwen38-27b-ud-iq3xxs
backend: llama-cpp
context_size: 4096
gpu_layers: 99
cache_type_k: q8_0
cache_type_v: q8_0
parameters:
  model: Qwen3.8-27B-UD-IQ3_XXS.gguf
  batch: 512
options:
  - reasoning_format:none
  - n_parallel:1
'''

sftp = cli.open_sftp()
sftp.open("/tmp/qwen38-final.yaml", "w").write(yaml_content)
sftp.close()
stdin, stdout, stderr = cli.exec_command(
    "pct push 112 /tmp/qwen38-final.yaml /opt/localai/models/qwen38-27b-ud-iq3xxs.yaml && "
    "pct exec 112 -- chmod 644 /opt/localai/models/qwen38-27b-ud-iq3xxs.yaml && echo pushed")
print(stdout.read().decode())
cli.close()
