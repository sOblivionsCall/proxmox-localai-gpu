import paramiko

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)

# Write the model YAML directly into CT 112's models dir via exec heredoc
yaml_content = '''name: qwen38-27b-ud-iq3xxs
backend: llama-cpp
context_size: 8192
gpu_layers: 99
cache_type_k: q8_0
cache_type_v: q8_0
parameters:
  model: huggingface://unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-IQ3_XXS.gguf
  batch: 512
options:
  - reasoning_format:none
'''
sftp = cli.open_sftp()
import io
sftp.open("/tmp/qwen38-iq3xxs.yaml", "w").write(yaml_content)
sftp.close()

stdin, stdout, stderr = cli.exec_command(
    "pct push 112 /tmp/qwen38-iq3xxs.yaml /opt/localai/models/qwen38-27b-ud-iq3xxs.yaml && "
    "pct exec 112 -- chmod 644 /opt/localai/models/qwen38-27b-ud-iq3xxs.yaml && "
    "pct exec 112 -- cat /opt/localai/models/qwen38-27b-ud-iq3xxs.yaml | head -8"
)
print(stdout.read().decode())
print(stderr.read().decode()[:300])
cli.close()
