# Proxmox LocalAI GPU Node

One-command Proxmox VE LXC installer for [LocalAI](https://github.com/mudler/LocalAI) with **automatic GPU passthrough** (NVIDIA / AMD / Intel) **and full CPU-only support**. Serves OpenAI-compatible APIs for **chat LLMs, image generation, embeddings, TTS, and STT** on your own hardware.

Unlike [yenksid/proxmox-local-ai](https://github.com/yenksid/proxmox-local-ai) (CPU-only, single hardcoded GGUF, no GPU support), this installer detects your hardware and wires the whole chain: host driver check → LXC device passthrough (via the community-scripts engine) → LocalAI binary with GPU offload — or a clean unprivileged CPU-only container.

## Philosophy

**The installer provides the working platform. Configuring LocalAI is up to you.**

What it does automatically: OS setup, GPU device passthrough, the LocalAI binary, starter model configs, and a systemd service.

What it leaves to you: model selection and tuning — drop YAML files into `/opt/localai/models` and they hot-load. [LocalAI model configuration docs](https://localai.io/docs/advanced/model-configuration/).

## How backends work (no Docker required)

Since LocalAI v3.2, **all backends ship outside the binary** as OCI images that LocalAI itself downloads, extracts, and runs — daemonless, no Docker involved. This includes `diffusers` (image generation), `whisper` (STT), `piper` (TTS), and 60+ others.

Practical consequences:

- **Chat, image gen, embeddings, TTS/STT all work in binary mode.** The starter configs include an image-gen model (`stablediffusion`, via the `diffusers` backend).
- **First use pulls the backend** — the first request against a `backend: diffusers` model downloads a multi-GB OCI image before generating. Be patient, and give the container disk headroom.
- **Backends persist** in `/opt/localai/backends` (installer sets `LOCALAI_BACKENDS_PATH` so they survive restarts and don't fill `/tmp`).
- **Pre-install instead of lazily** if you prefer: `local-ai backends install diffusers` (or via the web UI's Backends page).
- **Updates**: `bash /opt/localai/update.sh` re-downloads the LocalAI binary; backends persist across binary updates.

## Requirements

| Component | GPU mode | CPU-only mode |
|---|---|---|
| Proxmox VE | 8.x / 9.x | 8.x / 9.x |
| Host driver | NVIDIA: `nvidia-smi` works on **host**; AMD: `/dev/kfd` present | none needed |
| Container | Ubuntu 24.04 (auto-downloaded) | Ubuntu 24.04 |
| Resources | 4 cores · 8 GB RAM · 40 GB disk | 2-4 cores · 4 GB RAM · 20 GB disk |

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

| Mode | Detection | Container | Notes |
|---|---|---|---|
| **NVIDIA** | `lspci` shows NVIDIA | privileged, engine-managed device mounts | `nvidia-smi` must work on the host first |
| **AMD** | `lspci` + `/dev/kfd` present | engine-managed mounts | |
| **CPU-only** | no GPU found, or `GPU=no` | **unprivileged** (more secure) | slower for large models |

Force a mode with env: `GPU=no bash ct/localai.sh` (CPU-only) or `GPU=yes` (fail if no GPU found instead of falling back).

## Updates

Two supported paths:

- **In-container:** `bash /opt/localai/update.sh` — re-downloads the latest LocalAI release binary, swaps it in atomically, restarts the service. Model configs and installed backends untouched.
- **Host side:** re-run the ct script — it detects the existing installation and runs the update path (community-scripts `update_script()` convention, so the post-install helper's "Update" option works too).

## Using it

```bash
# Chat
curl http://<container-ip>:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-3b-chat","messages":[{"role":"user","content":"Hello"}]}'

# Image generation (first call pulls the diffusers backend — multi-GB, one time)
curl http://<container-ip>:8080/v1/images/generations \
  -H "Content-Type: application/json" \
  -d '{"model":"stablediffusion","prompt":"a red apple on a wooden table","size":"512x512"}'
```

## Repo layout

```
ct/localai.sh               # Host-side LXC creator (community-scripts ct/*.sh style)
install/localai-install.sh  # In-container installer (binary deployment)
install/localai-update.sh   # In-container updater
core/minimal-build.func     # Self-contained build.func fallback (no external dep)
docs/                       # Script metadata example + design notes
```

## Design notes

- **community-scripts compatible**: if [community-scripts/core](https://github.com/community-scripts/core) is available (`COMMUNITY_SCRIPTS_CORE_DIR` or auto-download), its full-featured `build.func` is used — including its own GPU passthrough machinery (`detect_gpu_devices` / `configure_gpu_passthrough` / `fix_gpu_gids`), which this installer deliberately does not duplicate. Otherwise a minimal built-in `core/minimal-build.func` provides the same interface.
- **GPU passthrough is the engine's job** — earlier versions hand-appended device mounts, which raced with the engine's config writes and caused "GPU not visible" failures. The installer now only sets `var_gpu=yes/no` and verifies visibility after the fact.
- **Host driver stays on the host** — the container only gets device nodes + userspace libs. Never install a kernel driver inside the LXC.
- **Why the binary, not the Docker image?** Simpler platform story (no Docker-in-LXC, no toolkit layers, one process to manage) and backends are now fetched by LocalAI itself anyway, so the Docker image's main advantage (pre-bundled backends) is gone. Trade-off: backend OCI pulls happen over the network on first use rather than being pre-baked — see [How backends work](#how-backends-work-no-docker-required).
- Inspired by the structure of [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE) (MIT).

## Roadmap

- [ ] Frontend JSON metadata (community-scripts website listing format)
- [ ] Optional backend pre-install prompt at install time (diffusers / piper / whisper)
- [ ] Model pre-download prompt at install time

## License

MIT — see [LICENSE](LICENSE).
