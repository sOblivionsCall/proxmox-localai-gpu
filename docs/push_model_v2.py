import paramiko

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)

# Qwen3.8-27B VRAM math for 12 GB card:
# Weights: 10.9 GiB (UD-IQ3_XXS)
# KV cache: hybrid attention — only 16 of 64 layers cache, rest fixed DeltaNet state
#   per the Qwen3.8 architecture: ~0.5 GiB per 8k tokens at BF16 for the cache layers
# With q8_0 KV ≈ 0.25 GiB per 8k context
# Compute buffers + CUDA runtime: ~0.8-1.2 GiB
# Budget: 10.9 + KV + 1.0 ≤ 11.2 GiB usable → KV budget ≈ 1.0-1.2 GiB
# → context 16384 (≈ 0.5 GiB with q8_0) is safe; 8192 even safer.

yaml_content = '''name: qwen38-27b-ud-iq3xxs
backend: llama-cpp
context_size: 16384
gpu_layers: 99
cache_type_k: q8_0
cache_type_v: q8_0
parameters:
  model: Qwen3.8-27B-UD-IQ3_XXS.gguf
  batch: 512
options:
  - reasoning_format:none
'''

sftp = cli.open_sftp()
sftp.open("/tmp/qwen38-v2.yaml", "w").write(yaml_content)
sftp.close()

stdin, stdout, stderr = cli.exec_command(
    "pct push 112 /tmp/qwen38-v2.yaml /opt/localai/models/qwen38-27b-ud-iq3xxs.yaml && "
    "pct exec 112 -- systemctl restart localai && sleep 8 && pct exec 112 -- systemctl is-active localai"
)
print(stdout.read().decode())
cli.close()
