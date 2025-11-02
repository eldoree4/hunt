```markdown
# HUNT v2 - Production Guidance (Author: JFlow)

Ringkasan:
- Versi produksi (hunt_v2_production.sh) dibuat dengan safer defaults, non-interactive mode, container-friendly, and helper scripts.
- Tools tambahan yang disertakan: tools/node_render.js (Puppeteer), tools/multi_login.py (Python).

Kewajiban sebelum menjalankan:
1. Pastikan Anda memiliki izin tertulis untuk semua target.
2. Jalankan hanya di lingkungan lab atau VM terisolasi.
3. Jangan jalankan modul intrusif (SSRF/XXE/LFI/WAF bypass) kecuali telah mendapat otorisasi tertulis.

Installasi dependensi minimal (Ubuntu/Debian):
- System:
  sudo apt update && sudo apt install -y python3 python3-pip nodejs npm curl jq wget git nmap
- Python:
  pip3 install requests beautifulsoup4
- Node (Puppeteer):
  cd tools
  npm init -y
  npm install puppeteer
- Optional:
  - Install sqlmap: git clone https://github.com/sqlmapproject/sqlmap.git tools/sqlmap
  - Install ffuf: download binary or build via Go
  - Install hxselect/pup for better HTML parsing

Docker:
- A Dockerfile is provided to build an isolated container with node + python + curl.
- Build: docker build -t huntv2:prod .
- Run example interactive (bind reports): docker run --rm -it -v $(pwd)/reports:/app/reports huntv2:prod /app/hunt_v2_production.sh -u https://example.com

Operational checklist before scan:
1. Set LEGAL_CONSENT=yes in config or confirm interactively.
2. Set appropriate RATE_LIMIT_REQUESTS, THREADS, and DELAY in the config file.
3. Populate wordlists under wordlists/ and tools such as sqlmap/ffuf if needed.
4. For JS-heavy sites, ensure tools/node_render.js is available and puppeteer installed.
5. Prefer non-intrusive scans first, analyze reports, then request permission for intrusive tests.

What I (JFlow) changed from prototype:
- Added non-interactive & config-based execution.
- Safer defaults: stealth enabled, lower thread defaults, rate limit.
- Container-friendly structure (tools/, reports/, wordlists/).
- Minimal headless renderer and multi-step login helper.
- Minimal reporting structure and logging.

Limitations:
- This is NOT a complete commercial-grade scanner.
- Many advanced checks still rely on external tools (sqlmap, ffuf, puppeteer).
- Intrusive modules not auto-run — requires explicit consent.
- Use as part of an overall testing process with manual verification.

If you want, I can:
- Create a CI workflow to run safe scans against an internal staging target.
- Add automated unit/integration tests against OWASP Juice Shop (example).
- Harden logging (encrypt reports) and add a results dashboard.

```
