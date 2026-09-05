import paramiko, time

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)

# Qwen3.8-27B on 12 GB: full offload doesn't fit (rs-cache single 4.2 GiB
# tensor + weights 10.9 GiB > 12 GB usable). Partial offload it is.
# 48 DeltaNet layers carry ~72 MiB fixed state; 16 attention layers cache.
# Strategy: gpu_layers 48 (of ~64), context 8192, q8_0 KV.
yaml_content = '''name: qwen38-27b-ud-iq3xxs
backend: llama-cpp
context_size: 8192
gpu_layers: 48
cache_type_k: q8_0
cache_type_v: q8_0
parameters:
  model: Qwen3.8-27B-UD-IQ3_XXS.gguf
  batch: 512
options:
  - reasoning_format:none
'''

sftp = cli.open_sftp()
sftp.open("/tmp/qwen38-v3.yaml", "w").write(yaml_content)
sftp.close()

stdin, stdout, stderr = cli.exec_command(
    "pct push 112 /tmp/qwen38-v2.yaml /tmp/check.yaml && "
    "pct push 112 /tmp/qwen38-v2.yaml /opt/localai/models/qwen38-27b-ud-iq3xxs.yaml 2>/dev/null; "
    "pct exec 112 -- bash -c 'cat > /opt/localai/models/qwen38-27b-ud-iq3xxs.yaml <<EOF2\n"
+ yaml_content.replace('"', '\\"') + "EOF2\ncat /opt/localai/models/qwen38-27b-ud-iq3xxs.yaml | head -4'"
)
print(stdout.read().decode())
print(stderr.read().decode()[:300])
cli.close()
