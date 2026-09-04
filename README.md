# Proxmox LocalAI GPU Node

One-command Proxmox VE LXC installer for [LocalAI](https://github.com/mudler/LocalAI) with **automatic GPU passthrough** (NVIDIA / AMD / Intel) **and full CPU-only support**. Serves OpenAI-compatible APIs for **chat LLMs, embeddings, and reranking** on your own hardware.

Unlike [yenksid/proxmox-local-ai](https://github.com/yenksid/proxmox-local-ai) (CPU-only, single hardcoded GGUF, no GPU support), this installer detects your hardware and wires the whole chain: host driver check → LXC device passthrough (via the community-scripts engine) → LocalAI binary with GPU offload — or a clean unprivileged CPU-only container.

## Philosophy

**The installer provides the working platform. Configuring LocalAI is up to you.**

What it does automatically: OS setup, GPU device passthrough, the LocalAI binary, starter model configs, and a systemd service.

What it leaves to you: model selection and tuning — drop YAML files into `/opt/localai/models` and they hot-load. [LocalAI model configuration docs](https://localai.io/docs/advanced/model-configuration/).

## Binary-mode limitation (important)

LocalAI's release binary does **not** ship Python-based backends or `stablediffusion-cpp` (upstream docs: [Binaries](https://localai.io/reference/binaries/)). Concretely:

| Capability | Binary mode (this installer) | Docker image |
|---|---|---|
| Chat LLMs (llama-cpp) | ✅ | ✅ |
| Embeddings / reranking | ✅ | ✅ |
| GPU offload | ✅ (when device visible) | ✅ |
| **Image generation** (diffusers, SD) | ❌ | ✅ |
| TTS / STT | ❌ | ✅ |

If you need image generation or TTS, run LocalAI via Docker instead — inside this container after install (`docker run -p 8080:8080 --gpus all -v /opt/localai/models:/models localai/localai:latest-aio-gpu-nvidia-cuda-13`) or elsewhere. The installer prints this reminder at install time.

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

- **In-container:** `bash /opt/localai/update.sh` — re-downloads the latest LocalAI release binary, swaps it in atomically, restarts the service. Model configs untouched.
- **Host side:** re-run the ct script — it detects the existing installation and runs the update path (community-scripts `update_script()` convention, so the post-install helper's "Update" option works too).

## Using it

```bash
# Chat
curl http://<container-ip>:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-3b-chat","messages":[{"role":"user","content":"Hello"}]}'

# Embeddings
curl http://<container-ip>:8080/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model":"text-embedding-ada-002","input":"hello world"}'
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
- **Why binary, not Docker?** Simpler platform story (no Docker-in-LXC, no toolkit layers), one process to manage. The trade-off — no Python backends — is stated honestly above; users needing image-gen/TTS can run the Docker image inside this container or elsewhere.
- Inspired by the structure of [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE) (MIT).

## Roadmap

- [ ] Frontend JSON metadata (community-scripts website listing format)
- [ ] Optional Docker-image deployment variant (opt-in flag) for image-gen/TTS
- [ ] Model pre-download prompt at install time

## License

MIT — see [LICENSE](LICENSE).
