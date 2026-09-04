import paramiko, time, re, json

HOST, USER, PASS = "192.168.1.135", "root", "1Starshine!"

cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
try:
    def run(cmd, timeout=120):
        stdin, stdout, stderr = cli.exec_command(cmd, timeout=timeout)
        out = stdout.read().decode("utf-8", "replace")
        code = stdout.channel.recv_exit_status()
        return out, code

    # find the fresh CT
    out, _ = run("pct list | grep localai | awk '{print $1}' | head -1")
    CTID = out.strip()
    IP = out2 = run(f"pct config {CTID} | grep -oP 'ip=dhcp' >/dev/null; pct exec {CTID} -- hostname -I | awk '{{print $1}}'")[0].strip()
    print(f"CT {CTID} @ {IP}", flush=True)

    results = {}

    # 1) service + readyz
    out, _ = run(f"pct exec {CTID} -- bash -c 'systemctl is-active localai; curl -s -m 20 http://localhost:8080/readyz -o /dev/null -w \"%{{http_code}}\"'")
    results["service+readyz"] = out.strip().replace("\r", " ")
    print("1) service+readyz:", results["service+readyz"], flush=True)

    # 2) chat completion + GPU offload
    out, _ = run(f'''pct exec {CTID} -- bash -c '
nvidia-smi --query-gpu=memory.used --format=csv,noheader
curl -s -m 280 -X POST http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d '{{"model":"qwen2.5-3b-chat","messages":[{{"role":"user","content":"What is 6 times 7? Answer with just the number."}}],"max_tokens":30}}' | head -c 300
echo
nvidia-smi --query-gpu=memory.used --format=csv,noheader' ''', 320)
    results["chat+gpu"] = out.strip().replace("\r", " ")
    print("2) chat+gpu:", results["chat+gpu"][:400], flush=True)

    # 3) banner renders (update-motd)
    out, _ = run(f"pct exec {CTID} -- /etc/update-motd.d/99-localai 2>&1 | head -8")
    results["banner"] = out.strip().replace("\r", " ")[:200]
    print("3) banner head:", results["banner"], flush=True)

    # 4) UPDATE FLOW: run the in-container updater (re-downloads binary)
    out, _ = run(f"pct exec {CTID} -- bash /opt/localai/update.sh 2>&1 | tail -6", 300)
    results["update"] = out.strip().replace("\r", " ")
    print("4) update:", results["update"], flush=True)

    # 5) service healthy after update + API still serving
    out, _ = run(f"pct exec {CTID} -- bash -c 'systemctl is-active localai; curl -s -m 30 http://localhost:8080/readyz -o /dev/null -w \"readyz:%{{http_code}}\"'")
    results["post-update-health"] = out.strip().replace("\r", " ")
    print("5) post-update:", results["post-update-health"], flush=True)

    # host-side update_script() path test (community-scripts convention)
    out, _ = run(f"pct exec {CTID} -- bash -c 'local-ai --version 2>/dev/null | head -1' ")
    print("version:", out.strip(), flush=True)

    print("\n=== VALIDATION SUMMARY ===", flush=True)
    for k, v in results.items():
        print(f"{k}: {v[:150]}", flush=True)
finally:
    cli.close()
