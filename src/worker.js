import { importPKCS8, SignJWT } from "jose";

const VERSION_RE = /^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.]+)?$/;
const ARCHES = new Set(["x86_64", "aarch64"]);
const MAX_BODY_BYTES = 16 * 1024;
const JOB_TTL_MS = 15 * 24 * 60 * 60 * 1000;

export class BuildQueue {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/enqueue") {
      const body = await request.json();
      const result = await this.enqueue(body);
      if (result.accepted) this.state.waitUntil(this.startNext());
      return json(result, result.accepted ? 202 : result.status || 400);
    }
    if (request.method === "GET" && url.pathname.startsWith("/jobs/")) {
      const job = await this.refresh(await this.state.storage.get(`job:${url.pathname.slice(6)}`));
      return job ? json(publicJob(job)) : json({ error: "任务不存在或已过期" }, 404);
    }
    if (request.method === "GET" && url.pathname === "/history") {
      const entries = await this.state.storage.list({ prefix: "job:" });
      const recentJobs = [...entries.values()].filter((job) => Date.now() - job.createdAt < JOB_TTL_MS).sort((a, b) => b.createdAt - a.createdAt).slice(0, 100);
      const refreshedJobs = [];
      for (const job of recentJobs) refreshedJobs.push(["starting", "queued", "building"].includes(job.status) ? await this.refresh(job) : job);
      const jobs = refreshedJobs.map(publicJob);
      const jobReleaseTags = new Set(recentJobs.map((job) => `offline-${job.requestId}`));
      let releases = [];
      try {
        releases = (await githubFetch(this.env, `/repos/${this.env.GITHUB_OWNER}/${this.env.GITHUB_REPO}/releases?per_page=100`)).filter((release) => release.tag_name.startsWith("offline-") && !jobReleaseTags.has(release.tag_name)).map((release) => ({ name: release.name, createdAt: release.created_at, url: release.html_url, downloadUrl: release.assets?.[0]?.browser_download_url || null }));
      } catch (_error) {}
      const jobHistory = jobs.map((job) => ({ name: `${job.version} / ${job.arch}（${job.status}${job.progress && job.status === "building" ? ` · ${job.progress.percent}% · ${job.progress.step}` : ""}）`, createdAt: new Date(job.createdAt).toISOString(), url: job.runUrl, downloadUrl: job.downloadUrl, status: job.status, progress: job.progress || null }));
      return json({ jobs, releases: [...releases, ...jobHistory] });
    }
    if (request.method === "POST" && url.pathname === "/cleanup") {
      await this.cleanup();
      return json({ ok: true });
    }
    return json({ error: "Not found" }, 404);
  }

  async enqueue(input) {
    const now = Date.now();
    const state = (await this.state.storage.get("state")) || { active: null, queue: [] };
    const existing = await this.findExisting(input.version, input.arch, input.chinaMirror);
    if (existing) return { accepted: true, reused: true, job: publicJob(existing) };
    const rateKey = `rate:v2:${input.clientIp || "unknown"}`;
    const recent = (await this.state.storage.get(rateKey) || []).filter((time) => now - time < 60 * 60 * 1000);
    if (recent.length >= Number(this.env.MAX_REQUESTS_PER_HOUR || 10)) return { accepted: false, status: 429, error: "请求过于频繁，请稍后再试" };
    recent.push(now);
    await this.state.storage.put(rateKey, recent, { expirationTtl: 60 * 60 });
    if (state.queue.length >= Number(this.env.MAX_QUEUE_SIZE || 3) && state.active) {
      return { accepted: false, status: 429, error: "当前构建队列已满，请稍后重试" };
    }
    const job = {
      id: crypto.randomUUID(),
      requestId: crypto.randomUUID().replaceAll("-", "").slice(0, 16),
      version: input.version,
      arch: input.arch,
      chinaMirror: Boolean(input.chinaMirror),
      status: state.active ? "queued" : "starting",
      createdAt: now,
      updatedAt: now,
    };
    await this.state.storage.put(`job:${job.id}`, job);
    if (state.active) state.queue.push(job.id);
    else state.active = job.id;
    await this.state.storage.put("state", state);
    return { accepted: true, job: publicJob(job) };
  }

  async findExisting(version, arch, chinaMirror) {
    const entries = await this.state.storage.list({ prefix: "job:" });
    for (const job of entries.values()) {
      if (Date.now() - job.createdAt < JOB_TTL_MS && job.version === version && job.arch === arch && job.chinaMirror === Boolean(chinaMirror) && !["failed", "expired"].includes(job.status)) return job;
    }
    return null;
  }

  async startNext() {
    const state = (await this.state.storage.get("state")) || { active: null, queue: [] };
    if (!state.active) {
      state.active = state.queue.shift() || null;
      await this.state.storage.put("state", state);
    }
    if (!state.active) return;
    const job = await this.state.storage.get(`job:${state.active}`);
    if (!job || ["success", "failed", "expired"].includes(job.status)) return this.finishActive();
    if (job.status === "starting" || job.status === "queued") {
      job.status = "building";
      job.updatedAt = Date.now();
      await this.state.storage.put(`job:${job.id}`, job);
      try {
        job.runUrl = await triggerWorkflow(this.env, job);
        job.updatedAt = Date.now();
        await this.state.storage.put(`job:${job.id}`, job);
      } catch (error) {
        job.status = "failed";
        job.error = error instanceof Error ? error.message : String(error);
        job.updatedAt = Date.now();
        await this.state.storage.put(`job:${job.id}`, job);
        return this.finishActive();
      }
    }
  }

  async refresh(job) {
    if (!job || !["building", "starting"].includes(job.status)) return job;
    try {
      const run = await findRun(this.env, job.requestId);
      if (!run) return job;
      job.runUrl = run.html_url;
      if (run.status !== "completed") {
        job.status = "building";
        job.progress = await findRunProgress(this.env, run);
      } else if (run.conclusion === "success") {
        job.progress = { percent: 100, completedSteps: 0, totalSteps: 0, step: "正在发布构建产物" };
        const release = await findRelease(this.env, job.requestId);
        if (release) {
          job.status = "success";
          job.downloadUrl = release.assets?.[0]?.browser_download_url;
          job.releaseUrl = release.html_url;
        }
      } else {
        job.status = "failed";
        job.progress = job.progress || { percent: 0, completedSteps: 0, totalSteps: 0, step: "构建失败" };
        job.error = `GitHub Actions 构建结果：${run.conclusion || "未知"}`;
      }
      job.updatedAt = Date.now();
      await this.state.storage.put(`job:${job.id}`, job);
      if (["success", "failed"].includes(job.status)) await this.finishActive();
    } catch (error) {
      job.error = error instanceof Error ? error.message : String(error);
      job.updatedAt = Date.now();
      await this.state.storage.put(`job:${job.id}`, job);
    }
    return job;
  }

  async finishActive() {
    const state = (await this.state.storage.get("state")) || { active: null, queue: [] };
    if (state.active) {
      state.active = state.queue.shift() || null;
      await this.state.storage.put("state", state);
      if (state.active) this.state.waitUntil(this.startNext());
    }
  }

  async cleanup() {
    const cutoff = Date.now() - JOB_TTL_MS;
    const entries = await this.state.storage.list({ prefix: "job:" });
    for (const [key, job] of entries) if (job.createdAt < cutoff) await this.state.storage.delete(key);
  }
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders() });
    const url = new URL(request.url);
    if (url.pathname === "/favicon.svg") return new Response(faviconSvg(), { headers: { "content-type": "image/svg+xml", "cache-control": "public, max-age=86400" } });
    if (url.pathname === "/") return new Response(blueTheme(modernIndexHtml(env)), { headers: { "content-type": "text/html; charset=UTF-8" } });
    if (url.pathname === "/history") return new Response(blueTheme(modernHistoryHtml()), { headers: { "content-type": "text/html; charset=UTF-8" } });
    if (url.pathname === "/api/jobs" && request.method === "POST") return enqueue(request, env);
    if (url.pathname.startsWith("/api/jobs/") && request.method === "GET") return proxyQueue(request, env, `jobs/${url.pathname.slice(10)}`);
    if (url.pathname === "/api/history" && request.method === "GET") return proxyQueue(request, env, "history");
    return new Response("Not found", { status: 404 });
  },
  async scheduled(_event, env, ctx) {
    ctx.waitUntil(proxyQueue(new Request("https://queue/cleanup", { method: "POST" }), env, "cleanup"));
  },
};

async function enqueue(request, env) {
  if (Number(request.headers.get("content-length") || 0) > MAX_BODY_BYTES) return json({ error: "请求过大" }, 413);
  const body = await request.json().catch(() => null);
  if (!body || !VERSION_RE.test(body.version || "") || !ARCHES.has(body.arch) || typeof body.chinaMirror !== "boolean") return json({ error: "参数无效" }, 400);
  if (env.TURNSTILE_SECRET) {
    const result = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", { method: "POST", body: new URLSearchParams({ secret: env.TURNSTILE_SECRET, response: body.turnstileToken || "", remoteip: request.headers.get("CF-Connecting-IP") || "" }) });
    if (!(await result.json()).success) return json({ error: "验证失败，请刷新页面后重试" }, 403);
  }
  body.clientIp = request.headers.get("CF-Connecting-IP") || "unknown";
  return proxyQueue(new Request("https://queue/enqueue", { method: "POST", body: JSON.stringify(body) }), env, "enqueue");
}

async function proxyQueue(request, env, path) {
  const id = env.BUILD_QUEUE.idFromName("global");
  const init = { method: request.method, headers: request.headers };
  if (request.method !== "GET" && request.method !== "HEAD") init.body = request.body;
  return env.BUILD_QUEUE.get(id).fetch(new Request(`https://queue/${path}`, init));
}

function publicJob(job) {
  return { id: job.id, version: job.version, arch: job.arch, chinaMirror: job.chinaMirror, status: job.status, progress: job.progress || null, runUrl: job.runUrl || null, downloadUrl: job.downloadUrl || null, releaseUrl: job.releaseUrl || null, error: job.error || null, createdAt: job.createdAt, updatedAt: job.updatedAt };
}

function json(data, status = 200) { return new Response(JSON.stringify(data), { status, headers: { ...corsHeaders(), "content-type": "application/json; charset=UTF-8" } }); }
function corsHeaders() { return { "access-control-allow-origin": "*", "access-control-allow-methods": "GET,POST,OPTIONS", "access-control-allow-headers": "content-type" }; }

async function githubToken(env) {
  const key = await importPKCS8(env.GITHUB_APP_PRIVATE_KEY.replace(/\\n/g, "\n"), "RS256");
  const jwt = await new SignJWT({}).setProtectedHeader({ alg: "RS256", typ: "JWT" }).setIssuedAt().setExpirationTime("10m").setIssuer(env.GITHUB_APP_ID).sign(key);
  const response = await fetch(`https://api.github.com/app/installations/${env.GITHUB_INSTALLATION_ID}/access_tokens`, { method: "POST", headers: githubHeaders(jwt) });
  if (!response.ok) throw new Error(`GitHub App 授权失败（${response.status}）`);
  return (await response.json()).token;
}

function githubHeaders(token) { return { authorization: `Bearer ${token}`, accept: "application/vnd.github+json", "x-github-api-version": "2022-11-28", "user-agent": "docker-offline-builder" }; }
async function githubFetch(env, path, options = {}) { const token = await githubToken(env); const response = await fetch(`https://api.github.com${path}`, { ...options, headers: { ...githubHeaders(token), ...(options.headers || {}) } }); if (!response.ok) { const detail = await response.text(); let message = detail; try { message = JSON.parse(detail).message || detail; } catch (_error) {} throw new Error(`GitHub API 请求失败（${response.status}）：${message}`); } return response.status === 204 ? null : response.json(); }

async function triggerWorkflow(env, job) {
  const path = `/repos/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/actions/workflows/${env.GITHUB_WORKFLOW_FILE || "build.yml"}/dispatches`;
  await githubFetch(env, path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ ref: env.GITHUB_REF || "main", inputs: { custom_docker_version: job.version, docker_version: "29.6.1", arch: job.arch, china_mirror: String(job.chinaMirror), request_id: job.requestId } }) });
  return `https://github.com/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/actions/workflows/${env.GITHUB_WORKFLOW_FILE || "build.yml"}`;
}

async function findRun(env, requestId) { const data = await githubFetch(env, `/repos/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/actions/workflows/${env.GITHUB_WORKFLOW_FILE || "build.yml"}/runs?event=workflow_dispatch&per_page=20`); return data.workflow_runs.find((run) => run.display_title?.includes(requestId) || run.name?.includes(requestId)); }
async function findRelease(env, requestId) { return githubFetch(env, `/repos/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/releases/tags/offline-${requestId}`); }
async function findRunProgress(env, run) { try { const data = await githubFetch(env, `/repos/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/actions/runs/${run.id}/jobs?per_page=100`); const active = data.jobs.find((job) => job.status === "in_progress") || data.jobs.find((job) => job.status === "queued") || data.jobs[0]; const steps = active?.steps || []; const completedSteps = steps.filter((step) => step.status === "completed").length; const current = steps.find((step) => step.status === "in_progress") || steps.find((step) => step.status === "queued"); return { percent: steps.length ? Math.min(99, Math.round((completedSteps / steps.length) * 100)) : 0, completedSteps, totalSteps: steps.length, step: current?.name || (active?.status === "queued" ? "等待 Runner" : "准备构建") }; } catch (_error) { return { percent: 0, completedSteps: 0, totalSteps: 0, step: "正在获取构建进度" }; } }

function blueTheme(html) {
  const control = `<div class="mirror-control"><div><b>下载加速</b><span>选择合适的下载通道，提升国内网络下载速度</span></div><select id="downloadMirror"><option value="direct">直连 GitHub</option><option value="https://ghproxy.com">ghproxy.com</option><option value="https://gh-proxy.com">gh-proxy.com</option><option value="https://ghfast.top">ghfast.top</option><option value="https://mirror.ghproxy.com">mirror.ghproxy.com</option><option value="custom">自定义加速域名</option></select><input id="customMirror" placeholder="例如 https://your-mirror.example.com" autocomplete="url"></div>`;
  const script = `<script>(function(){const control=document.querySelector('#downloadMirror');if(!control)return;const custom=document.querySelector('#customMirror'),root=document.querySelector('#result')||document.querySelector('#list');const mirrorUrl=(original,selected)=>{if(!original||selected==='direct')return original;let base=selected==='custom'?custom.value.trim():selected;if(!/^https?:\\/\\//i.test(base))base='https://'+base;base=base.replace(/\\/+$/,'');try{const parsed=new URL(base);if(!['http:','https:'].includes(parsed.protocol)||!parsed.hostname)return original;return base+'/'+original}catch(_error){return original}};const sync=()=>{if(!root)return;root.querySelectorAll('a.download').forEach(link=>{if(!link.dataset.original)link.dataset.original=link.href;link.href=mirrorUrl(link.dataset.original,control.value)})};control.onchange=()=>{custom.style.display=control.value==='custom'?'block':'none';sync()};custom.oninput=sync;custom.style.display='none';if(root)new MutationObserver(sync).observe(root,{subtree:true,childList:true});sync()})()</script>`;
  const styled = html.replace("</head>", `<link rel="icon" href="/favicon.svg" type="image/svg+xml"><style>body{background:radial-gradient(circle at 12% -5%,#d9efff 0,transparent 34%),radial-gradient(circle at 95% 8%,#dff7ff 0,transparent 30%),#f7fbff}.mark{background:linear-gradient(135deg,#0b63f6,#00a8e8)!important;box-shadow:0 8px 24px #008ff044!important}.eyebrow{color:#0878f9!important}.primary{background:linear-gradient(135deg,#087cf8,#00a8e8)!important;box-shadow:0 10px 22px #008ff044!important}.primary:focus-visible,.action:focus-visible,.nav a:focus-visible{outline:3px solid #79d7ff;outline-offset:3px}.action{background:#e6f4ff!important;color:#075985!important}.action.download{background:#e4f8ee!important;color:#166534!important}.card{box-shadow:0 20px 55px #0077b814,0 2px 8px #1e293b0d!important}.mirror-control{display:grid;grid-template-columns:1fr 220px;gap:10px;align-items:center;margin:0 0 18px;padding:13px 14px;border:1px solid #d9edf9;border-radius:13px;background:#f4fbff}.mirror-control b{display:block;color:#075985;font-size:13px}.mirror-control span{display:block;color:#7891a7;font-size:12px;margin-top:2px}.mirror-control select,.mirror-control input{width:100%;height:38px;border:1px solid #cce3f1;border-radius:9px;background:#fff;padding:0 10px;color:#172033;font:13px inherit}.mirror-control input{grid-column:2}@media(max-width:640px){.mirror-control{grid-template-columns:1fr}.mirror-control input{grid-column:1}}</style></head>`);
  let withControl = styled.replace('<div id="result"></div>', `${control}<div id="result"></div>`);
  if (withControl.includes('id="list"')) withControl = withControl.replace('<div id="list"', `${control}<div id="list"`);
  return withControl.replace("</body>", `${script}${progressEnhancement()}${buttonStateEnhancement()}</body>`);
}

function progressEnhancement() {
  return `<style>.live-progress{margin:18px 0 2px}.progress-top{display:flex;justify-content:space-between;color:#526079;font-size:12px;font-weight:650;margin-bottom:7px}.progress-top b{color:#0878f9}.progress-track{height:7px;border-radius:99px;background:#dff0fa;overflow:hidden}.progress-track i{display:block;height:100%;border-radius:inherit;background:linear-gradient(90deg,#087cf8,#00b8e8);transition:width .4s ease}.live-progress small{display:block;color:#8290a8;font-size:11px;margin-top:7px}</style><script>(function(){const originalFetch=window.fetch.bind(window),escapeText=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));window.fetch=(...args)=>originalFetch(...args).then(response=>{const requestUrl=typeof args[0]==='string'?args[0]:args[0]?.url||'';if(requestUrl.includes('/api/jobs/')&&!requestUrl.endsWith('/api/jobs/'))response.clone().json().then(job=>{const box=document.querySelector('#result .result');if(!box||!job.progress)return;let panel=box.querySelector('.live-progress');if(!panel){panel=document.createElement('div');panel.className='live-progress';const actions=box.querySelector('.actions');box.insertBefore(panel,actions||null)}const percent=Math.max(0,Math.min(100,Number(job.progress.percent)||0));panel.innerHTML='<div class="progress-top"><span>'+escapeText(job.progress.step||'正在构建')+'</span><b>'+percent+'%</b></div><div class="progress-track"><i style="width:'+percent+'%"></i></div><small>已完成 '+(job.progress.totalSteps?escapeText(job.progress.completedSteps)+' / '+escapeText(job.progress.totalSteps)+' 个步骤':'正在同步 GitHub Actions 状态')+'</small>'}).catch(()=>{});return response})})()</script>`;
}

function buttonStateEnhancement() {
  return `<script>(function(){const button=document.querySelector('#submit'),result=document.querySelector('#result');if(!button||!result)return;new MutationObserver(()=>{const status=result.querySelector('.status');if(!status)return;const active=['building','starting','queued'].some(name=>status.classList.contains(name));button.disabled=active;button.textContent=active?(status.textContent==='排队中'?'排队中…':'构建进行中…'):'开始构建　→'}).observe(result,{subtree:true,childList:true,characterData:true})})()</script>`;
}

function faviconSvg() {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#0b63f6"/><stop offset="1" stop-color="#00a8e8"/></linearGradient></defs><rect width="64" height="64" rx="18" fill="url(#g)"/><path d="M18 16h18c9 0 14 5 14 12 0 5-3 9-8 11l10 10H40L30 40h-3v9H18V16Zm9 8v8h8c4 0 6-1 6-4s-2-4-6-4h-8Z" fill="white"/><circle cx="50" cy="14" r="4" fill="#b8f3ff"/></svg>`;
}

function modernIndexHtml(env) {
  const turnstile = env.TURNSTILE_SITE_KEY ? `<script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>` : "";
  const widget = env.TURNSTILE_SITE_KEY ? `<div class="cf-turnstile" data-sitekey="${escapeHtml(env.TURNSTILE_SITE_KEY)}" data-action="build"></div>` : "";
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Docker 离线包构建</title>${turnstile}<style>
  :root{font-family:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;color:#132238;background:#f4f8fc;line-height:1.5}*{box-sizing:border-box}body{margin:0;min-height:100vh;background:linear-gradient(135deg,#eef7ff 0,#f8fbff 44%,#f3f7ff 100%)}a{color:inherit}.shell{max-width:1180px;margin:auto;padding:24px 28px 56px}.nav{height:56px;display:flex;justify-content:space-between;align-items:center}.brand{display:flex;align-items:center;gap:11px;text-decoration:none;font-weight:800;letter-spacing:-.02em}.mark{display:grid;place-items:center;width:38px;height:38px;border-radius:12px;color:#fff;background:linear-gradient(135deg,#087cf8,#00b8e8);box-shadow:0 9px 22px #087cf833}.nav-right{display:flex;align-items:center;gap:12px}.nav-link{display:inline-flex;align-items:center;gap:6px;padding:9px 12px;color:#58708b;text-decoration:none;font-size:13px;font-weight:700;border-radius:10px}.nav-link:hover{background:#e7f3ff;color:#0878f9}.service-dot{width:7px;height:7px;border-radius:50%;background:#20b26b;box-shadow:0 0 0 4px #20b26b18}.service-text{color:#54718e;font-size:12px;font-weight:700}.hero{display:flex;justify-content:space-between;align-items:flex-end;gap:30px;padding:56px 0 30px}.eyebrow{color:#0878f9;font-size:12px;font-weight:800;letter-spacing:.13em;text-transform:uppercase}.hero h1{font-size:clamp(32px,5vw,50px);line-height:1.06;letter-spacing:-.055em;margin:10px 0 13px}.hero p{max-width:600px;color:#617992;font-size:16px;margin:0}.hero-note{min-width:190px;padding:14px 16px;border:1px solid #d9ebfa;border-radius:15px;background:#ffffffa8;color:#5f7891;font-size:12px}.hero-note b{display:block;color:#1a3550;font-size:20px;letter-spacing:-.03em}.dashboard{display:grid;grid-template-columns:minmax(0,1.45fr) minmax(280px,.75fr);gap:18px;align-items:start}.card{background:#fffffff0;border:1px solid #fff;border-radius:20px;padding:24px;box-shadow:0 16px 42px #1877b812,0 2px 8px #1e293b0b;backdrop-filter:blur(12px)}.card-title{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:20px}.card-title h2{font-size:16px;letter-spacing:-.02em;margin:0}.card-title p{color:#8094a9;font-size:12px;margin:4px 0 0}.section-icon{display:grid;place-items:center;width:34px;height:34px;border-radius:10px;background:#e7f4ff;color:#0878f9;font-size:16px}.grid{display:grid;grid-template-columns:1.1fr .9fr;gap:16px}.field label{display:block;color:#344b64;font-size:12px;font-weight:800;margin-bottom:8px}.input,.select{width:100%;height:46px;border:1px solid #d7e3ee;border-radius:11px;background:#fff;color:#132238;padding:0 13px;font:inherit;outline:none}.input:focus,.select:focus{border-color:#53a7ed;box-shadow:0 0 0 4px #53a7ed1c}.custom{margin-top:10px}.hint{color:#8297aa;font-size:11px;margin:7px 0 0}.turnstile{margin:18px 0}.primary{width:100%;height:48px;border:0;border-radius:11px;background:linear-gradient(135deg,#087cf8,#00a8e8);color:#fff;font:800 14px inherit;cursor:pointer;box-shadow:0 9px 20px #087cf82b;transition:transform .2s,box-shadow .2s,opacity .2s}.primary:hover{transform:translateY(-1px);box-shadow:0 12px 24px #087cf83b}.primary:disabled{opacity:.62;cursor:wait;transform:none}.side-stack{display:grid;gap:18px}.metric-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:10px}.metric{padding:13px;border-radius:13px;background:#f3f8fc;border:1px solid #e1edf5}.metric span{display:block;color:#8195a8;font-size:11px}.metric b{display:block;color:#173650;font-size:18px;margin-top:3px}.side-link{display:flex;justify-content:space-between;align-items:center;gap:10px;text-decoration:none;padding:12px 0;border-top:1px solid #e6eef5;color:#45627c;font-size:13px;font-weight:700}.side-link:first-of-type{border-top:0}.side-link em{font-style:normal;color:#0878f9}.result{margin-top:18px;padding:18px;border-radius:15px;background:#f5faff;border:1px solid #dceef9}.result-head{display:flex;justify-content:space-between;gap:12px;align-items:center;margin-bottom:14px}.result-head b{font-size:14px}.status{border-radius:999px;padding:5px 10px;font-size:11px;font-weight:800}.building{color:#0878f9;background:#dff1ff}.success{color:#15803d;background:#dcfce7}.failed{color:#b42318;background:#fee4e2}.meta{display:grid;grid-template-columns:repeat(2,1fr);gap:10px;color:#748aa0;font-size:11px}.meta b{display:block;color:#173650;font-size:13px;margin-top:2px}.actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:15px}.action{display:inline-flex;align-items:center;padding:9px 11px;border-radius:9px;background:#e7f4ff;color:#075985;text-decoration:none;font-size:12px;font-weight:800}.action:hover{filter:brightness(.97)}.download{background:#def8eb;color:#166534}.error{color:#b42318;font-size:12px;margin-top:11px}.foot{text-align:center;color:#8195a8;font-size:11px;margin-top:20px}@media(max-width:820px){.shell{padding:18px 18px 44px}.hero{padding-top:42px}.dashboard{grid-template-columns:1fr}}@media(max-width:580px){.shell{padding:14px 14px 36px}.nav{height:48px}.brand span:last-child{font-size:13px}.service-text{display:none}.hero{display:block;padding:36px 0 24px}.hero-note{margin-top:20px}.grid{grid-template-columns:1fr}.card{padding:18px;border-radius:17px}.metric-grid{grid-template-columns:repeat(2,1fr)}.meta{grid-template-columns:1fr}}
  </style></head><body><div class="shell"><nav class="nav"><a class="brand" href="/"><span class="mark">D</span><span>Docker Offline Builder</span></a><div class="nav-right"><span class="service-dot"></span><span class="service-text">服务正常</span><a class="nav-link" href="/history">构建历史　→</a></div></nav><section class="hero"><div><div class="eyebrow">Build console</div><h1>构建你的 Docker<br>离线包</h1><p>选择版本与目标架构，提交后自动编译并生成公开下载链接。</p></div><div class="hero-note"><b>15 天</b>构建记录与离线包保留周期</div></section><main class="dashboard"><section class="card"><div class="card-title"><div><h2>新建构建任务</h2><p>提交后将在 GitHub Actions 中完成编译</p></div><span class="section-icon">＋</span></div><form id="form"><div class="grid"><div class="field"><label for="versionPreset">Docker 版本</label><select id="versionPreset" class="select"><option value="29.6.1">29.6.1 · 推荐</option><option value="24.0.6">24.0.6</option><option value="23.0.6">23.0.6</option><option value="20.10.24">20.10.24</option><option value="19.03.15">19.03.15</option><option value="18.09.9">18.09.9</option><option value="custom">自定义版本</option></select><input class="input custom" name="version" value="29.6.1" pattern="\\d+\\.\\d+\\.\\d+(?:-[a-zA-Z0-9.]+)?" placeholder="例如 28.0.0" required><p class="hint">支持 X.Y.Z 或带后缀的版本号</p></div><div class="field"><label for="arch">目标架构</label><select id="arch" name="arch" class="select"><option value="x86_64">x86_64 · Intel / AMD</option><option value="aarch64">aarch64 · ARM64</option></select><p class="hint">请选择离线目标机器的 CPU 架构</p></div></div>${widget}<button class="primary" id="submit" type="submit">开始构建　→</button></form><div id="result"></div></section><aside class="side-stack"><section class="card"><div class="card-title"><div><h2>服务概览</h2><p>当前构建资源状态</p></div><span class="section-icon">◌</span></div><div class="metric-grid"><div class="metric"><span>并发构建</span><b>1</b></div><div class="metric"><span>历史保留</span><b>15 天</b></div></div></section><section class="card"><div class="card-title"><div><h2>快速入口</h2><p>查看任务和产物</p></div></div><a class="side-link" href="/history">全部构建历史 <em>→</em></a><a class="side-link" href="https://github.com/${escapeHtml(env.GITHUB_OWNER || "cyz-domo")}/${escapeHtml(env.GITHUB_REPO || "docker-offline")}/actions" target="_blank" rel="noopener">GitHub Actions <em>↗</em></a></section></aside></main><div class="foot">公开访问 · 无需登录 · 构建完成后提供下载链接</div></div><script>
  const form=document.querySelector('#form'),result=document.querySelector('#result'),submit=document.querySelector('#submit'),preset=document.querySelector('#versionPreset'),version=document.querySelector('input[name="version"]');preset.onchange=()=>{if(preset.value==='custom'){version.value='';version.focus()}else version.value=preset.value};version.oninput=()=>{preset.value=[...preset.options].some(o=>o.value===version.value)?version.value:'custom'};const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));const labels={starting:'准备中',queued:'排队中',building:'构建中',success:'构建成功',failed:'构建失败',expired:'已过期'};const terminal=['success','failed','expired'];form.onsubmit=async e=>{e.preventDefault();submit.disabled=true;submit.textContent='正在提交…';const data=Object.fromEntries(new FormData(form));data.chinaMirror=false;const token=document.querySelector('[name="cf-turnstile-response"]');if(token)data.turnstileToken=token.value;result.innerHTML='<div class="result"><b>正在创建构建任务…</b><p class="hint">正在连接构建队列，请稍候</p></div>';try{const response=await fetch('/api/jobs',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(data)});const body=await response.json();if(!response.ok){result.innerHTML='<div class="result error">'+esc(body.error||'提交失败')+'</div>';submit.disabled=false;submit.textContent='开始构建　→';return}poll(body.job.id)}catch(_error){result.innerHTML='<div class="result error">网络请求失败，请稍后重试</div>';submit.disabled=false;submit.textContent='开始构建　→'}};async function poll(id){try{const response=await fetch('/api/jobs/'+encodeURIComponent(id)),job=await response.json();if(!response.ok){result.innerHTML='<div class="result error">'+esc(job.error||'任务查询失败')+'</div>';submit.disabled=false;submit.textContent='开始构建　→';return}const state=job.status||'starting',progress=job.progress||{},statusClass=state==='success'?'success':state==='failed'?'failed':'building',percent=Math.max(0,Math.min(100,Number(progress.percent)||0));let html='<div class="result"><div class="result-head"><b>当前构建任务</b><span class="status '+statusClass+'">'+esc(labels[state]||state)+'</span></div><div class="meta"><div>Docker 版本<b>'+esc(job.version)+'</b></div><div>目标架构<b>'+esc(job.arch)+'</b></div></div>';if(!terminal.includes(state))html+='<div class="live-progress"><div class="progress-top"><span>'+esc(progress.step||'正在同步构建状态')+'</span><b>'+percent+'%</b></div><div class="progress-track"><i style="width:'+percent+'%"></i></div><small>已完成 '+(progress.totalSteps?esc(progress.completedSteps)+' / '+esc(progress.totalSteps)+' 个步骤':'正在同步 GitHub Actions 状态')+'</small></div>';if(state==='success')html+='<div class="success-note">构建完成，离线包已发布，可以下载。</div>';html+='<div class="actions">'+(job.runUrl?'<a class="action" target="_blank" rel="noopener" href="'+esc(job.runUrl)+'">查看 GitHub 构建 ↗</a>':'')+(job.downloadUrl?'<a class="action download" target="_blank" rel="noopener" href="'+esc(job.downloadUrl)+'">下载离线包 ↓</a>':'')+'</div>'+(job.error?'<div class="error">'+esc(job.error)+'</div>':'')+'</div>';result.innerHTML=html;if(terminal.includes(state)){submit.disabled=false;submit.textContent='开始构建　→'}else{submit.disabled=true;submit.textContent=state==='queued'?'排队中…':'构建进行中…';setTimeout(()=>poll(id),5000)}}catch(_error){result.innerHTML='<div class="result error">任务状态获取失败，请刷新页面重试</div>';submit.disabled=false;submit.textContent='开始构建　→'}}
  </script></body></html>`;
}

function modernHistoryHtml() {
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Docker 构建历史</title><style>:root{font-family:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;color:#132238;background:#f4f8fc;line-height:1.5}*{box-sizing:border-box}body{margin:0;min-height:100vh;background:linear-gradient(135deg,#eef7ff 0,#f8fbff 44%,#f3f7ff 100%)}.shell{max-width:1100px;margin:auto;padding:24px 28px 56px}.nav{height:56px;display:flex;justify-content:space-between;align-items:center}.brand{display:flex;align-items:center;gap:11px;text-decoration:none;font-weight:800;letter-spacing:-.02em}.mark{display:grid;place-items:center;width:38px;height:38px;border-radius:12px;color:#fff;background:linear-gradient(135deg,#087cf8,#00b8e8);box-shadow:0 9px 22px #087cf833}.nav-link{display:inline-flex;padding:9px 12px;color:#58708b;text-decoration:none;font-size:13px;font-weight:700;border-radius:10px}.nav-link:hover{background:#e7f3ff;color:#0878f9}.hero{display:flex;justify-content:space-between;align-items:flex-end;gap:24px;padding:54px 0 26px}.eyebrow{color:#0878f9;font-size:12px;font-weight:800;letter-spacing:.13em;text-transform:uppercase}.title{font-size:clamp(32px,5vw,48px);line-height:1.06;letter-spacing:-.055em;margin:10px 0 10px}.muted{color:#71879d}.hero p{margin:0;font-size:15px}.retention{padding:13px 16px;border:1px solid #d9ebfa;border-radius:14px;background:#ffffffa8;color:#5f7891;font-size:12px}.retention b{display:block;color:#173650;font-size:18px}.card{background:#fffffff0;border:1px solid #fff;border-radius:20px;padding:22px 24px;box-shadow:0 16px 42px #1877b812,0 2px 8px #1e293b0b;backdrop-filter:blur(12px)}.toolbar{display:flex;justify-content:space-between;align-items:center;gap:16px;margin-bottom:8px}.toolbar h2{font-size:16px;margin:0}.filters{display:flex;gap:7px;flex-wrap:wrap}.filter{border:1px solid #d9e7f1;border-radius:999px;background:#fff;color:#617992;padding:7px 11px;font:700 11px inherit;cursor:pointer}.filter.active,.filter:hover{border-color:#9bd2f5;background:#e7f4ff;color:#0878f9}.item{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:20px;border-top:1px solid #e6eef5;padding:17px 0}.item:first-child{border-top:0}.item-main{min-width:0}.item-name{display:flex;align-items:center;gap:9px;font-weight:800}.item-time{color:#8297aa;font-size:12px;margin-top:4px}.item-sub{color:#607b93;font-size:12px;margin-top:7px}.status{display:inline-flex;border-radius:999px;padding:4px 8px;font-size:10px;font-weight:800}.building{color:#0878f9;background:#dff1ff}.success{color:#15803d;background:#dcfce7}.failed{color:#b42318;background:#fee4e2}.expired{color:#667085;background:#edf1f5}.actions{display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end}.action{display:inline-flex;align-items:center;padding:9px 11px;border-radius:9px;background:#e7f4ff;color:#075985;text-decoration:none;font-size:12px;font-weight:800}.download{background:#def8eb;color:#166534}.progress-line{margin-top:9px;max-width:480px}.progress-top{display:flex;justify-content:space-between;color:#6b8398;font-size:11px;margin-bottom:5px}.progress-top b{color:#0878f9}.progress-track{height:6px;border-radius:99px;background:#dfeef7;overflow:hidden}.progress-track i{display:block;height:100%;border-radius:inherit;background:linear-gradient(90deg,#087cf8,#00b8e8);transition:width .4s ease}.empty{padding:42px 12px;text-align:center;color:#8297aa;font-size:13px}.load-error{padding:20px;color:#b42318;font-size:13px}@media(max-width:680px){.shell{padding:16px 14px 40px}.hero{display:block;padding:38px 0 22px}.retention{display:inline-block;margin-top:18px}.card{padding:18px 16px;border-radius:17px}.toolbar{display:block}.filters{margin-top:14px}.item{display:block}.actions{justify-content:flex-start;margin-top:12px}.progress-line{max-width:none}}
  </style></head><body><div class="shell"><nav class="nav"><a class="brand" href="/"><span class="mark">D</span><span>Docker Offline Builder</span></a><a class="nav-link" href="/">← 返回构建</a></nav><section class="hero"><div><div class="eyebrow">Build archive</div><h1 class="title">构建历史</h1><p class="muted">近 15 天的构建任务和公开下载包</p></div><div class="retention"><b>15 天</b>自动保留周期</div></section><main class="card"><div class="toolbar"><h2>全部任务</h2><div class="filters"><button class="filter active" data-filter="all">全部</button><button class="filter" data-filter="building">构建中</button><button class="filter" data-filter="success">已完成</button><button class="filter" data-filter="failed">失败</button></div></div><div id="list" class="muted">加载中…</div></main></div><script>const list=document.querySelector('#list'),filters=[...document.querySelectorAll('.filter')],esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])),stateLabel={starting:'准备中',queued:'排队中',building:'构建中',success:'已完成',failed:'失败',expired:'已过期'};let items=[];let activeFilter='all';const render=()=>{const visible=items.filter(item=>activeFilter==='all'||item.status===activeFilter);if(!visible.length){list.innerHTML='<div class="empty">'+(items.length?'没有符合条件的构建任务':'暂无近 15 天构建记录')+'</div>';return}list.innerHTML=visible.map(item=>{const status=item.status||'building',progress=item.progress||{},percent=Math.max(0,Math.min(100,Number(progress.percent)||0));let progressHtml=['starting','queued','building'].includes(status)?'<div class="progress-line"><div class="progress-top"><span>'+esc(progress.step||stateLabel[status])+'</span><b>'+percent+'%</b></div><div class="progress-track"><i style="width:'+percent+'%"></i></div></div>':'';return '<article class="item"><div class="item-main"><div class="item-name">'+esc(item.name||'Docker 离线包')+' <span class="status '+esc(status)+'">'+esc(stateLabel[status]||status)+'</span></div><div class="item-time">'+esc(new Date(item.createdAt).toLocaleString())+'</div>'+progressHtml+'</div><div class="actions">'+(item.url?'<a class="action" target="_blank" rel="noopener" href="'+esc(item.url)+'">查看构建 ↗</a>':'')+(item.downloadUrl?'<a class="action download" target="_blank" rel="noopener" href="'+esc(item.downloadUrl)+'">下载 ↓</a>':'')+'</div></article>'}).join('')};filters.forEach(button=>button.onclick=()=>{activeFilter=button.dataset.filter;filters.forEach(item=>item.classList.toggle('active',item===button));render()});const load=()=>fetch('/api/history').then(r=>r.json()).then(data=>{items=[...(data.releases||[])].sort((a,b)=>new Date(b.createdAt)-new Date(a.createdAt));render()}).catch(()=>{list.innerHTML='<div class="load-error">历史记录加载失败，请稍后重试</div>'});load();setInterval(load,15000)</script></body></html>`;
}

function indexHtml(env) {
  const turnstile = env.TURNSTILE_SITE_KEY ? `<script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>` : "";
  const widget = env.TURNSTILE_SITE_KEY ? `<div class="cf-turnstile" data-sitekey="${escapeHtml(env.TURNSTILE_SITE_KEY)}"></div>` : "";
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Docker 离线包构建</title>${turnstile}<style>body{font:16px system-ui;max-width:600px;margin:8vh auto;padding:0 20px;color:#17202a}main{border:1px solid #ddd;border-radius:12px;padding:28px;box-shadow:0 4px 18px #0001}label{display:block;margin:16px 0 6px}input,select,button{width:100%;padding:10px;font:inherit;box-sizing:border-box}button{margin-top:22px;background:#0969da;color:#fff;border:0;border-radius:6px;cursor:pointer}.muted{color:#667085}.result{margin-top:22px;padding:14px;background:#f6f8fa;border-radius:8px}a{color:#0969da}</style></head><body><main><h1>Docker 离线包构建</h1><p class="muted"><a href="/history">查看近 15 天构建历史</a></p><p class="muted">填写参数后，GitHub Actions 将编译并生成公开下载链接。</p><form id="form"><label>Docker 版本</label><select id="versionPreset"><option value="29.6.1">29.6.1</option><option value="24.0.6">24.0.6</option><option value="23.0.6">23.0.6</option><option value="20.10.24">20.10.24</option><option value="19.03.15">19.03.15</option><option value="18.09.9">18.09.9</option><option value="custom">自定义版本</option></select><input name="version" value="29.6.1" pattern="\\d+\\.\\d+\\.\\d+(?:-[a-zA-Z0-9.]+)?" placeholder="输入自定义版本，例如 28.0.0" required><label>架构</label><select name="arch"><option>x86_64</option><option>aarch64</option></select><label><input type="checkbox" name="chinaMirror" style="width:auto"> 使用国内镜像加速</label>${widget}<button>开始构建</button></form><div id="result"></div></main><script>const f=document.querySelector('#form'),r=document.querySelector('#result'),versionPreset=document.querySelector('#versionPreset'),versionInput=document.querySelector('input[name="version"]');versionPreset.onchange=()=>{if(versionPreset.value==='custom'){versionInput.value='';versionInput.focus()}else{versionInput.value=versionPreset.value}};versionInput.oninput=()=>{versionPreset.value=[...versionPreset.options].some(o=>o.value===versionInput.value)?versionInput.value:'custom'};f.onsubmit=async e=>{e.preventDefault();const d=Object.fromEntries(new FormData(f));d.chinaMirror=!!d.chinaMirror;const token=document.querySelector('[name="cf-turnstile-response"]');if(token)d.turnstileToken=token.value;r.innerHTML='<div class="result">正在提交…</div>';const x=await fetch('/api/jobs',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(d)});const j=await x.json();if(!x.ok){r.innerHTML='<div class="result">'+(j.error||'提交失败')+'</div>';return}poll(j.job.id)};async function poll(id){const x=await fetch('/api/jobs/'+id),j=await x.json();if(!x.ok){r.innerHTML='<div class="result">'+(j.error||'任务查询失败')+'</div>';return}let s='<div class="result"><b>状态：</b>'+j.status+'<br><b>版本：</b>'+j.version+'<br><b>架构：</b>'+j.arch;if(j.runUrl)s+='<br><a target="_blank" href="'+j.runUrl+'">查看 GitHub Actions 构建</a>';if(j.downloadUrl)s+='<br><br><a target="_blank" href="'+j.downloadUrl+'">下载离线包</a>';if(j.error)s+='<br><span>'+j.error+'</span>';r.innerHTML=s+'</div>';if(!['success','failed','expired'].includes(j.status))setTimeout(()=>poll(id),5000)} </script></body></html>`;
}

function historyHtml() {
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Docker 构建历史</title><style>body{font:16px system-ui;max-width:900px;margin:6vh auto;padding:0 20px;color:#17202a}main{border:1px solid #ddd;border-radius:12px;padding:28px;box-shadow:0 4px 18px #0001}a{color:#0969da}.item{border-top:1px solid #eee;padding:14px 0}.muted{color:#667085}</style></head><body><main><h1>Docker 构建历史</h1><p><a href="/">返回构建页面</a></p><div id="list" class="muted">加载中…</div></main><script>const list=document.querySelector('#list');fetch('/api/history').then(x=>x.json()).then(data=>{const items=[...(data.releases||[])].sort((a,b)=>new Date(b.createdAt)-new Date(a.createdAt));if(!items.length){list.textContent='暂无近 15 天构建记录';return}list.innerHTML=items.map(item=>'<div class="item"><b>'+item.name+'</b><br><span class="muted">'+new Date(item.createdAt).toLocaleString()+'</span><br><a target="_blank" href="'+item.url+'">查看构建信息</a>'+(item.downloadUrl?'　<a target="_blank" href="'+item.downloadUrl+'">下载离线包</a>':'')+'</div>').join('')}).catch(()=>{list.textContent='历史记录加载失败，请稍后重试'})</script></body></html>`;
}

function escapeHtml(value) { return String(value).replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]); }
