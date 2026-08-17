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
      const jobs = [...entries.values()].filter((job) => Date.now() - job.createdAt < JOB_TTL_MS).sort((a, b) => b.createdAt - a.createdAt).slice(0, 100).map(publicJob);
      let releases = [];
      try {
        releases = (await githubFetch(this.env, `/repos/${this.env.GITHUB_OWNER}/${this.env.GITHUB_REPO}/releases?per_page=100`)).filter((release) => release.tag_name.startsWith("offline-")).map((release) => ({ name: release.name, createdAt: release.created_at, url: release.html_url, downloadUrl: release.assets?.[0]?.browser_download_url || null }));
      } catch (_error) {}
      const jobHistory = jobs.map((job) => ({ name: `${job.version} / ${job.arch}（${job.status}）`, createdAt: new Date(job.createdAt).toISOString(), url: job.runUrl, downloadUrl: job.downloadUrl }));
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
      } else if (run.conclusion === "success") {
        const release = await findRelease(this.env, job.requestId);
        if (release) {
          job.status = "success";
          job.downloadUrl = release.assets?.[0]?.browser_download_url;
          job.releaseUrl = release.html_url;
        }
      } else {
        job.status = "failed";
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
    if (url.pathname === "/") return new Response(indexHtml(env), { headers: { "content-type": "text/html; charset=UTF-8" } });
    if (url.pathname === "/history") return new Response(historyHtml(), { headers: { "content-type": "text/html; charset=UTF-8" } });
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
  return { id: job.id, version: job.version, arch: job.arch, chinaMirror: job.chinaMirror, status: job.status, runUrl: job.runUrl || null, downloadUrl: job.downloadUrl || null, releaseUrl: job.releaseUrl || null, error: job.error || null, createdAt: job.createdAt, updatedAt: job.updatedAt };
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

function indexHtml(env) {
  const turnstile = env.TURNSTILE_SITE_KEY ? `<script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>` : "";
  const widget = env.TURNSTILE_SITE_KEY ? `<div class="cf-turnstile" data-sitekey="${escapeHtml(env.TURNSTILE_SITE_KEY)}"></div>` : "";
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Docker 离线包构建</title>${turnstile}<style>body{font:16px system-ui;max-width:600px;margin:8vh auto;padding:0 20px;color:#17202a}main{border:1px solid #ddd;border-radius:12px;padding:28px;box-shadow:0 4px 18px #0001}label{display:block;margin:16px 0 6px}input,select,button{width:100%;padding:10px;font:inherit;box-sizing:border-box}button{margin-top:22px;background:#0969da;color:#fff;border:0;border-radius:6px;cursor:pointer}.muted{color:#667085}.result{margin-top:22px;padding:14px;background:#f6f8fa;border-radius:8px}a{color:#0969da}</style></head><body><main><h1>Docker 离线包构建</h1><p class="muted"><a href="/history">查看近 15 天构建历史</a></p><p class="muted">填写参数后，GitHub Actions 将编译并生成公开下载链接。</p><form id="form"><label>Docker 版本</label><select id="versionPreset"><option value="29.6.1">29.6.1</option><option value="24.0.6">24.0.6</option><option value="23.0.6">23.0.6</option><option value="20.10.24">20.10.24</option><option value="19.03.15">19.03.15</option><option value="18.09.9">18.09.9</option><option value="custom">自定义版本</option></select><input name="version" value="29.6.1" pattern="\\d+\\.\\d+\\.\\d+(?:-[a-zA-Z0-9.]+)?" placeholder="输入自定义版本，例如 28.0.0" required><label>架构</label><select name="arch"><option>x86_64</option><option>aarch64</option></select><label><input type="checkbox" name="chinaMirror" style="width:auto"> 使用国内镜像加速</label>${widget}<button>开始构建</button></form><div id="result"></div></main><script>const f=document.querySelector('#form'),r=document.querySelector('#result'),versionPreset=document.querySelector('#versionPreset'),versionInput=document.querySelector('input[name="version"]');versionPreset.onchange=()=>{if(versionPreset.value==='custom'){versionInput.value='';versionInput.focus()}else{versionInput.value=versionPreset.value}};versionInput.oninput=()=>{versionPreset.value=[...versionPreset.options].some(o=>o.value===versionInput.value)?versionInput.value:'custom'};f.onsubmit=async e=>{e.preventDefault();const d=Object.fromEntries(new FormData(f));d.chinaMirror=!!d.chinaMirror;const token=document.querySelector('[name="cf-turnstile-response"]');if(token)d.turnstileToken=token.value;r.innerHTML='<div class="result">正在提交…</div>';const x=await fetch('/api/jobs',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(d)});const j=await x.json();if(!x.ok){r.innerHTML='<div class="result">'+(j.error||'提交失败')+'</div>';return}poll(j.job.id)};async function poll(id){const x=await fetch('/api/jobs/'+id),j=await x.json();if(!x.ok){r.innerHTML='<div class="result">'+(j.error||'任务查询失败')+'</div>';return}let s='<div class="result"><b>状态：</b>'+j.status+'<br><b>版本：</b>'+j.version+'<br><b>架构：</b>'+j.arch;if(j.runUrl)s+='<br><a target="_blank" href="'+j.runUrl+'">查看 GitHub Actions 构建</a>';if(j.downloadUrl)s+='<br><br><a target="_blank" href="'+j.downloadUrl+'">下载离线包</a>';if(j.error)s+='<br><span>'+j.error+'</span>';r.innerHTML=s+'</div>';if(!['success','failed','expired'].includes(j.status))setTimeout(()=>poll(id),5000)} </script></body></html>`;
}

function historyHtml() {
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Docker 构建历史</title><style>body{font:16px system-ui;max-width:900px;margin:6vh auto;padding:0 20px;color:#17202a}main{border:1px solid #ddd;border-radius:12px;padding:28px;box-shadow:0 4px 18px #0001}a{color:#0969da}.item{border-top:1px solid #eee;padding:14px 0}.muted{color:#667085}</style></head><body><main><h1>Docker 构建历史</h1><p><a href="/">返回构建页面</a></p><div id="list" class="muted">加载中…</div></main><script>const list=document.querySelector('#list');fetch('/api/history').then(x=>x.json()).then(data=>{const items=[...(data.releases||[])].sort((a,b)=>new Date(b.createdAt)-new Date(a.createdAt));if(!items.length){list.textContent='暂无近 15 天构建记录';return}list.innerHTML=items.map(item=>'<div class="item"><b>'+item.name+'</b><br><span class="muted">'+new Date(item.createdAt).toLocaleString()+'</span><br><a target="_blank" href="'+item.url+'">查看构建信息</a>'+(item.downloadUrl?'　<a target="_blank" href="'+item.downloadUrl+'">下载离线包</a>':'')+'</div>').join('')}).catch(()=>{list.textContent='历史记录加载失败，请稍后重试'})</script></body></html>`;
}

function escapeHtml(value) { return String(value).replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]); }
