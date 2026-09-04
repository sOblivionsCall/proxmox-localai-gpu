# Proxmox LocalAI GPU Node

One-command Proxmox VE LXC installer for [LocalAI](https://github.com/mudler/LocalAI) with **automatic GPU passthrough** (NVIDIA / AMD / Intel) **and full CPU-only support**. Serves OpenAI-compatible APIs for **chat LLMs, image generation, embeddings, TTS, and STT** on your own hardware.

Unlike [yenksid/proxmox-local-ai](https://github.com/yenksid/proxmox-local-ai) (CPU-only, single hardcoded GGUF, no GPU support), this installer detects your hardware and wires the whole chain: host driver check → LXC device mounts → userspace runtime inside the container → LocalAI with CUDA/ROCm/Level Zero — or a clean CPU-only container if no GPU exists.

## Requirements

| Component | GPU mode | CPU-only mode |
|---|---|---|
| Proxmox VE | 8.x / 9.x | 8.x / 9.x |
| Host driver | NVIDIA: `nvidia-smi` works on **host**; AMD: `/dev/kfd` present | none needed |
| Container | Ubuntu 24.04 (auto-downloaded) | Ubuntu 24.04 |
| Resources | 4 cores · 8 GB RAM · 40 GB disk | 2-4 cores · 4 GB RAM · 20 GB disk |
| GPU VRAM | 8 GB+ recommended | n/a |

The installer auto-detects hardware and picks the mode; you can also force it (see below).

## Quick install (one-liner, Proxmox host shell)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/sOblivionsCall/proxmox-localai-gpu/main/ct/localai.sh)"
```

Or clone first:

```bash
git clone https://github.com/sOblivionsCall/proxmox-localai-gpu.git
cd proxmox-localai-gpu
bash ct/localai.sh
```

## Hardware modes

| Mode | Detection | Container | Inside the LXC |
|---|---|---|---|
| **NVIDIA** | `lspci` shows NVIDIA | privileged, device mounts for `/dev/nvidia*` | CUDA userspace + `nvidia-container-toolkit` |
| **AMD** | `lspci` + `/dev/kfd` present | device mounts for `/dev/kfd`, `/dev/dri` | ROCm userspace |
| **CPU-only** | no GPU found, or `GPU=no` | **unprivileged** (more secure) | plain LocalAI, no GPU libs |

Force a mode with env: `GPU=no bash ct/localai.sh` (CPU-only) or `GPU=yes` (fail if no GPU found instead of falling back).

### CPU-only notes

- Everything works: chat, image gen, embeddings — just slower (a 3B chat model ≈ 15-30 tok/s on a modern CPU; SD1.5 image ≈ 2-5 min).
- The container is **unprivileged** — more secure, since GPU device mounts are the only reason this installer used privileged mode.
- Model configs ship with `gpu_layers: 99`, which llama.cpp treats as "offload what fits" — on a CPU-only container it simply runs everything on CPU. No config change needed.

## What the installer does

1. **Host-side** (`ct/localai.sh`):
   - Detects GPU (or honors `GPU=no`/`GPU=yes`), warns loudly if NVIDIA is present without a host driver
   - Creates the LXC — privileged + device mounts for GPU, unprivileged for CPU-only
   - GPU mounts: NVIDIA `/dev/nvidia*` + cgroup `195:*`/`234:*`; AMD `/dev/kfd`, `/dev/dri` + cgroup `226:*`
   - Adds host crontab `@reboot nvidia-modprobe -u -c=0` (NVIDIA only) so UVM devices exist at boot
2. **Container-side** (`install/localai-install.sh`):
   - Re-detects GPU vendor inside the container
   - NVIDIA: `libnvidia-container` + `nvidia-container-toolkit` + CUDA runtime libs
   - AMD: ROCm userspace; Intel: Level Zero; CPU: skipped
   - Downloads the latest LocalAI release binary from GitHub
   - Writes starter model configs to `/opt/localai/models`: chat LLM (Qwen2.5-3B), image gen (SD1.5 via `stablediffusion-ggml`), embeddings (granite)
   - Creates and enables `localai.service` (systemd, auto-restart)
   - Verifies the service is running and reports the hardware mode

## Using it

```bash
# API endpoint (OpenAI-compatible)
curl http://<container-ip>:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-3b-chat","messages":[{"role":"user","content":"Hello"}]}'

# Image generation
curl http://<container-ip>:8080/v1/images/generations \
  -H "Content-Type: application/json" \
  -d '{"model":"stablediffusion","prompt":"a red apple on a wooden table","size":"512x512"}'
```

Models are configured by **dropping YAML files** into `/opt/localai/models` — LocalAI hot-loads them, no restart needed. See [LocalAI model configuration docs](https://localai.io/docs/advanced/model-configuration/).

## Repo layout

```
ct/localai.sh               # Host-side LXC creator (community-scripts ct/*.sh style)
install/localai-install.sh  # In-container installer (community-scripts install/*.sh style)
core/minimal-build.func     # Self-contained build.func fallback (no external dep)
docs/                       # Script metadata example + design notes
```

## Design notes

- **community-scripts compatible**: if [community-scripts/core](https://github.com/community-scripts/core) is available (`COMMUNITY_SCRIPTS_CORE_DIR` or auto-download), its full-featured `build.func` is used — var_gpu handling, TUI, update checks. Otherwise a minimal built-in `core/minimal-build.func` provides the same interface so this repo has **zero hard dependencies**.
- **Privileged only when needed** — GPU device bind-mounts want privileged mode; CPU-only containers default to unprivileged (more secure).
- **Userspace-only GPU libs in the container** — the kernel driver stays on the host. Never install a kernel driver inside the LXC.
- Inspired by the structure of [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE) (MIT). Differences from that project's Ollama installer: this targets LocalAI (multi-modal: chat + images + audio), auto-detects NVIDIA/AMD/Intel with a clean CPU-only fallback, and ships starter model YAMLs.

## Roadmap

- [ ] Frontend JSON metadata (community-scripts website listing format)
- [ ] `update` command (pulls latest LocalAI release)
- [ ] Model pre-download prompt (LLM / SD / both / none)
- [ ] Docker-in-LXC variant using nvidia-container-toolkit CDI
- [ ] VM variant (full PCIe passthrough) for users who prefer it

## License

MIT — see [LICENSE](LICENSE).
