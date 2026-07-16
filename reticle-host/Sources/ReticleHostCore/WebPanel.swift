import Foundation
import Hummingbird
import NIOCore

/// Returns the built-in display-only Reticle session panel.
func webPanelResponse() -> Response {
    var buffer = ByteBufferAllocator().buffer(capacity: webPanelHtml.utf8.count)
    buffer.writeString(webPanelHtml)
    return Response(
        status: .ok,
        headers: [.contentType: "text/html; charset=utf-8"],
        body: .init(byteBuffer: buffer)
    )
}

/// Self-contained HTML/JS for the zero-build read-only web panel.
private let webPanelHtml = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Reticle Evidence Timeline</title>
<style>
:root{color-scheme:dark;--bg:#0b1020;--panel:#111827;--soft:#162033;--line:#263244;--muted:#9ca3af;--text:#e5e7eb;--accent:#60a5fa;--ok:#34d399;--warn:#fbbf24}
*{box-sizing:border-box}
body{margin:0;background:linear-gradient(180deg,#0f172a 0,var(--bg) 180px);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
body.modal-open{overflow:hidden}
header{position:sticky;top:0;z-index:3;padding:16px 20px;border-bottom:1px solid var(--line);background:rgba(15,23,42,.96);backdrop-filter:blur(12px)}
.topbar{display:flex;align-items:flex-start;justify-content:space-between;gap:16px}
h1{margin:0;font-size:18px}
.status{margin-top:4px;color:var(--muted);font-size:12px}
.session-control{color:var(--muted);font-size:12px;text-align:right}
.session-control select{display:block;min-width:240px;margin-top:5px;padding:7px 10px;border:1px solid var(--line);border-radius:10px;background:#0b1220;color:var(--text)}
.filterbar{display:flex;flex-wrap:wrap;gap:8px;margin-top:12px}
.filterbar button,.copy-chip{border:1px solid var(--line);border-radius:999px;background:#0b1220;color:var(--muted);padding:5px 9px;font:inherit;font-size:12px;cursor:pointer}
.filterbar button.active{border-color:rgba(96,165,250,.7);color:#bfdbfe;background:rgba(30,64,175,.28)}
.search{margin-top:12px;width:100%;max-width:420px;padding:7px 11px;border:1px solid var(--line);border-radius:999px;background:#0b1220;color:var(--text);font:inherit;font-size:12px}
.search::placeholder{color:var(--muted)}
.group{margin:0 0 26px}
.group-head{display:flex;align-items:baseline;justify-content:space-between;gap:12px;margin:0 0 12px;padding-bottom:8px;border-bottom:1px solid var(--line)}
.group-head h2{margin:0;font-size:15px;font-weight:720;word-break:break-all}
.group-head .count{color:var(--muted);font-size:12px;white-space:nowrap}
.group-list{display:grid;gap:14px}
.copy-chip{margin-left:6px;color:#bbf7d0;border-color:rgba(52,211,153,.45);background:rgba(6,78,59,.2)}
.selector-chips{display:flex;flex-wrap:wrap;gap:8px;margin-top:12px}
.selector-chips .copy-chip{margin-left:0}
main{max-width:1320px;margin:0 auto;padding:22px 18px 42px}
.empty{padding:24px;border:1px solid var(--line);border-radius:18px;background:rgba(17,24,39,.9);color:var(--muted)}
.timeline{position:relative}
.timeline:before{content:"";position:absolute;left:50%;top:0;bottom:0;width:1px;background:linear-gradient(180deg,transparent,var(--line) 22px,var(--line) calc(100% - 22px),transparent)}
.lane-labels{display:grid;grid-template-columns:minmax(0,1fr) 64px minmax(0,1fr);margin:0 0 14px;color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
.lane-labels div:first-child{padding-right:18px;text-align:right}
.lane-labels div:last-child{padding-left:18px}
.trace-group{margin:0 0 24px}
.node{position:relative;display:grid;grid-template-columns:minmax(0,1fr) 64px minmax(0,1fr);align-items:start;margin:0 0 14px}
.event-side{display:flex;min-width:0;padding-right:18px;flex-direction:column;align-items:flex-end}
.network-side{min-height:1px;padding-left:18px}
.time{padding:0 0 6px;color:var(--muted);font-size:12px;text-align:right}
.marker{position:relative;min-height:42px}
.marker:before{content:"";position:absolute;left:50%;top:13px;width:13px;height:13px;border:2px solid var(--accent);border-radius:999px;background:#0b1020;box-shadow:0 0 0 6px rgba(96,165,250,.08);transform:translateX(-50%)}
.node.before .marker:before,.node.after .marker:before{border-color:var(--ok);box-shadow:0 0 0 6px rgba(52,211,153,.08)}
.node.diff .marker:before{border-color:var(--warn);box-shadow:0 0 0 6px rgba(251,191,36,.08)}
.node.runtime .marker:before{border-color:#fb7185;box-shadow:0 0 0 6px rgba(251,113,133,.08)}
.node.network .marker:before{border-color:#c084fc;box-shadow:0 0 0 6px rgba(192,132,252,.08)}
.card{width:100%;min-width:0;border:1px solid var(--line);border-radius:18px;background:rgba(17,24,39,.92);box-shadow:0 18px 50px rgba(0,0,0,.22);overflow:hidden}
.node.before .card,.node.after .card{width:auto;max-width:100%}
.card-head{display:flex;align-items:flex-start;justify-content:space-between;padding:14px 16px;border-bottom:1px solid var(--line);background:linear-gradient(135deg,rgba(96,165,250,.12),rgba(17,24,39,0))}
.phase{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
.title{margin-top:3px;font-size:17px;font-weight:760}
.meta{margin-top:4px;color:var(--muted);font-size:12px;word-break:break-all}
.badge{margin-left:12px;padding:4px 8px;border:1px solid var(--line);border-radius:999px;background:#0b1220;color:var(--muted);font-size:12px;white-space:nowrap}.badge.mock{border-color:rgba(52,211,153,.55);color:#bbf7d0;background:rgba(6,78,59,.28)}
.body{padding:14px 16px}
.shot-body{display:grid;grid-template-columns:minmax(180px,260px) max-content;gap:14px;align-items:start;max-width:100%}
.shot-copy{min-width:0}
.media{margin-top:10px}
.shot-body .media{display:flex;justify-content:flex-start;margin-top:0;max-width:100%}
.artifact{margin-top:10px;padding:10px 12px;border:1px solid var(--line);border-radius:12px;background:#0b1220;color:var(--muted);font-size:12px}
.shot-copy .artifact:first-child{margin-top:0}
.facts{display:grid;grid-template-columns:repeat(3,1fr);border:1px solid var(--line);border-radius:12px;overflow:hidden}
.fact{min-width:0;padding:10px 12px;border-right:1px solid var(--line);background:#0b1220}
.fact:last-child{border-right:0}
.fact span{display:block;color:var(--muted);font-size:12px}
.fact b{display:block;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
details{margin-top:12px;padding-top:12px;border-top:1px solid var(--line)}
summary{cursor:pointer;color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
.shot-link{display:inline-flex;align-items:center;justify-content:center;max-width:100%;border:1px solid var(--line);border-radius:10px;background:#020617;overflow:hidden;cursor:zoom-in}
.shot{display:block;width:auto;max-width:100%;height:min(54vh,560px);object-fit:contain}
.shot-error{padding:18px;border:1px solid var(--line);border-radius:10px;background:#170f13;color:#fca5a5;font-size:12px}
.net-card{border:1px solid var(--line);border-radius:16px;background:rgba(17,24,39,.92);box-shadow:0 18px 50px rgba(0,0,0,.18);overflow:hidden}
.net-head{display:flex;justify-content:space-between;gap:12px;padding:12px 14px;border-bottom:1px solid var(--line);background:linear-gradient(135deg,rgba(192,132,252,.13),rgba(17,24,39,0))}
.net-url{margin-top:3px;font-weight:720;word-break:break-all}.net-meta{color:var(--muted);font-size:12px}.net-body{padding:12px 14px}
.net-section{margin-top:12px;padding:10px 12px;border:1px solid var(--line);border-radius:12px;background:#0b1220}
.net-section:first-child{margin-top:0}.net-section h3{margin:0 0 8px;font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.05em}
.net-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}.body-preview{margin-top:8px;max-height:180px;overflow:auto;white-space:pre-wrap;word-break:break-word;color:#d1d5db}
.link{color:var(--accent);word-break:break-all}
pre{margin:0;max-height:260px;overflow:auto;white-space:pre-wrap;word-break:break-word;color:#d1d5db}
table{width:100%;border-collapse:collapse}
th,td{padding:7px 8px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{color:var(--muted);font-weight:600}
.lightbox{position:fixed;inset:0;z-index:10;display:flex;align-items:center;justify-content:center;padding:24px;background:rgba(2,6,23,.86)}
.lightbox[hidden]{display:none}
.lightbox-panel{position:relative;max-width:96vw;max-height:94vh;padding:42px 16px 16px;border:1px solid var(--line);border-radius:14px;background:#020617;box-shadow:0 24px 80px rgba(0,0,0,.45)}
.lightbox img{display:block;max-width:92vw;max-height:82vh;object-fit:contain}
.lightbox-close{position:absolute;right:12px;top:10px;border:1px solid var(--line);border-radius:999px;background:var(--soft);color:var(--text);padding:5px 10px;cursor:pointer}
.lightbox-caption{margin-top:8px;color:var(--muted);font-size:12px;text-align:center}
@media(max-width:900px){main{padding:16px 12px 36px}.timeline:before{left:24px}.lane-labels{display:none}.node{grid-template-columns:42px 1fr}.event-side{grid-column:2;padding-right:0;align-items:stretch}.network-side{display:none}.time{padding:0 0 4px;text-align:left}.marker{grid-column:1;grid-row:1 / span 2}.card{width:100%}.shot-body,.facts{display:block}.shot-body .media{margin-top:10px}.fact{border-right:0;border-bottom:1px solid var(--line)}.fact:last-child{border-bottom:0}.card-head{display:block}.badge{display:inline-block;margin:10px 0 0}}
</style>
</head>
<body>
<header>
<div class="topbar"><div><h1>Reticle Evidence Timeline</h1><div id="status" class="status">Loading session events...</div><div id="view-toggle" class="filterbar"><button type="button" data-view="timeline" class="active">Timeline</button><button type="button" data-view="mocks">Mock groups</button></div><div id="network-filters" class="filterbar"><button type="button" data-filter="all" class="active">All</button><button type="button" data-filter="mock">MOCK</button><button type="button" data-filter="error">ERROR</button><button type="button" data-filter="mitm">MITM</button><button type="button" data-filter="tunnel">TUNNEL</button></div><div id="network-status-filters" class="filterbar"><button type="button" data-status="all" class="active">Any status</button><button type="button" data-status="2xx">2xx</button><button type="button" data-status="3xx">3xx</button><button type="button" data-status="4xx">4xx</button><button type="button" data-status="5xx">5xx</button></div><input id="network-search" class="search" type="search" placeholder="Filter network: method, url, host, status, mock id..."></div><label class="session-control">Session<select id="session-picker"></select></label></div>
</header>
<main>
<div id="timeline"></div>
</main>
<div id="lightbox" class="lightbox" hidden>
  <div class="lightbox-panel">
    <button id="lightbox-close" class="lightbox-close" type="button">Close</button>
    <img id="lightbox-image" alt="">
    <div id="lightbox-caption" class="lightbox-caption"></div>
  </div>
</div>
<script>
const state={events:[],sessions:[],selectedSession:null,currentSession:null,manifests:new Map(),stream:null,networkFilter:'all',networkStatusClass:'all',networkSearch:'',view:'timeline'};
const timeline=document.getElementById('timeline');
const statusEl=document.getElementById('status');
const sessionPicker=document.getElementById('session-picker');
const networkFilters=document.getElementById('network-filters');
const networkStatusFilters=document.getElementById('network-status-filters');
const networkSearch=document.getElementById('network-search');
const viewToggle=document.getElementById('view-toggle');
const lightbox=document.getElementById('lightbox'),lightboxImage=document.getElementById('lightbox-image'),lightboxCaption=document.getElementById('lightbox-caption');
function selectedIsCurrent(){return state.selectedSession===state.currentSession;}
function sessionRoute(){return selectedIsCurrent()?'current':encodeURIComponent(state.selectedSession||'current');}
function artifactUrl(event,ref){return `/sessions/${sessionRoute()}/artifacts?event=${encodeURIComponent(event.id)}&ref=${encodeURIComponent(ref)}`;}
function escapeHtml(value){return String(value===undefined||value===null?'':value).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');}
function pretty(value){return escapeHtml(JSON.stringify(value,null,2));}
function actionEvents(){return state.events.filter((event)=>event.type==='action.trace');}
function networkEvents(){return state.events.filter((event)=>/^network\./.test(event.type));}
function runtimeEvents(){return state.events.filter((event)=>event.type==='runtime.advisory');}
function networkTransactions(){
  const groups=new Map();
  for(const event of networkEvents()){
    const p=event.payload||{}, id=p.requestId||event.id;
    const tx=groups.get(id)||{id,events:[],refs:{},request:null,response:null,error:null};
    tx.events.push(event);Object.assign(tx.refs,event.refs||{});
    if(event.type==='network.request'){tx.request=event;}
    if(event.type==='network.response'){tx.response=event;}
    if(event.type==='network.error'){tx.error=event;}
    groups.set(id,tx);
  }
  return [...groups.values()].map((tx)=>{tx.event=tx.error||tx.response||tx.request||tx.events[tx.events.length-1];tx.payload=Object.assign({},...(tx.events.map((e)=>e.payload||{})));return tx;});
}
function statusClassOf(payload){
  const status=Number(payload.status);
  if(!Number.isFinite(status)){return null;}
  if(status>=200&&status<300){return '2xx';}
  if(status>=300&&status<400){return '3xx';}
  if(status>=400&&status<500){return '4xx';}
  if(status>=500&&status<600){return '5xx';}
  return null;
}
function networkFilterMatches(tx){
  const p=tx.payload||{};
  switch(state.networkFilter){
    case 'mock': if(!p.mocked){return false;} break;
    case 'error': if(!p.error){return false;} break;
    case 'mitm': if(!p.mitm){return false;} break;
    case 'tunnel': if(!p.tunnel){return false;} break;
  }
  if(state.networkStatusClass!=='all'&&statusClassOf(p)!==state.networkStatusClass){return false;}
  if(state.networkSearch){
    const needle=state.networkSearch.toLowerCase();
    const hay=[p.method,p.url,p.host,p.path,p.status,p.mockRuleId,p.mockValueId].map((v)=>String(v===undefined||v===null?'':v).toLowerCase()).join(' ');
    if(!hay.includes(needle)){return false;}
  }
  return true;
}
function slugForMock(value){
  const slug=String(value||'').toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-+|-+$/g,'').slice(0,48);
  return /^[a-z0-9]/.test(slug)?slug:`mock-${slug}`;
}
function shellQuote(value){return `'${String(value===undefined||value===null?'':value).replace(/'/g,"'\\''")}'`;}
function mockCommandFor(tx){
  const p=tx.payload||{}, refs=tx.refs||{};
  const bodyRef=Object.keys(refs).find((ref)=>ref.startsWith('responseBody.'));
  const bodyPath=bodyRef?refs[bodyRef]:null;
  const id=slugForMock(`${p.host||'host'}${p.path||'/'}`);
  const status=isPresent(p.status)?p.status:200;
  const headers=p.responseHeaders||{};
  const contentType=headers['Content-Type']||headers['content-type']||'application/json';
  const parts=['reticle mock set',`--id ${id}`,`--value-id ${id}`,`--method ${p.method||'GET'}`,`--url ${shellQuote(p.path||'/')}`,'--match exact',`--status ${status}`,`--content-type ${shellQuote(contentType)}`];
  if(p.host){parts.push(`--host ${shellQuote(p.host)}`);}
  if(bodyPath){parts.push(`--body-file ${shellQuote(bodyPath)}`);}else{parts.push(`--body ${shellQuote('')}`);}
  return parts.join(' ');
}
function canCopyAsMock(tx){const p=tx.payload||{};return !(p.tunnel&&!p.mitm);}
function isPresent(value){return value!==undefined&&value!==null&&value!==''&&value!=='<null>';}
function eventMillis(event){
  const payload=event.payload||{};
  const value=Number(payload.recordedAtMillis||payload.startMillis||payload.endMillis||event.ts||0);
  return Number.isFinite(value)?value:0;
}
function labelFor(event){const payload=event.payload||{};return `${payload.gesture||'action'} ${selectorLabel(payload.selector)}`;}
function selectorLabel(selector){
  if(!selector){return 'direct target';}
  const fields=[['testId','test-id'],['cssSelector','css'],['ref','ref'],['resourceId','res'],['region','region'],['point','point']];
  for(const [key,label] of fields){const value=selector[key];if(isPresent(value)){return `${label}=${typeof value==='object'?JSON.stringify(value):value}`;}}
  return 'direct target';
}
function formatTime(ms){const date=new Date(ms);return Number.isNaN(date.getTime())?String(ms):date.toLocaleTimeString();}
function mergeEvent(event){
  const index=state.events.findIndex((item)=>item.id===event.id);
  if(index>=0){state.events[index]=event;}else{state.events.push(event);}
  state.events.sort((a,b)=>eventMillis(a)-eventMillis(b)||a.id.localeCompare(b.id));
}
function updateStatusLine(){
  const actions=actionEvents(), runtimes=runtimeEvents(), allNetworks=networkTransactions(), networks=allNetworks.filter(networkFilterMatches);
  const live=selectedIsCurrent()?'live':'history';
  const mockCount=allNetworks.filter((tx)=>tx.payload&&tx.payload.mocked).length;
  statusEl.textContent=`${state.selectedSession||'session'} · ${live} · ${state.events.length} event(s), ${actions.length} action trace(s), ${runtimes.length} runtime advisory(s), ${networks.length}/${allNetworks.length} network request(s), ${mockCount} mock(s)`;
}
function renderTimeline(){
  updateStatusLine();
  if(state.view==='mocks'){renderNetworkGroups();return;}
  const actions=actionEvents(), runtimes=runtimeEvents(), allNetworks=networkTransactions(), networks=allNetworks.filter(networkFilterMatches);
  if(actions.length===0&&allNetworks.length===0&&runtimes.length===0){
    timeline.className='';
    timeline.innerHTML='<div class="empty">No evidence yet. Run reticle act or enable the proxy while serve is running.</div>';
    return;
  }
  timeline.className='timeline';
  const items=[...actions.map((event,index)=>({at:eventMillis(event),html:traceGroup(event,index+1)})),...runtimes.map((event)=>({at:eventMillis(event),html:runtimeNode(event)})),...networks.map((tx)=>({at:eventMillis(tx.request||tx.event),html:networkNode(tx)}))].sort((a,b)=>a.at-b.at);
  timeline.innerHTML=`<div class="lane-labels"><div>UI evidence</div><div></div><div>Network requests</div></div>${items.map((item)=>item.html).join('')}`;
  attachScreenshotPreviews();
  attachCopyChips();
  hydrateDiffs();
  hydrateBodyPreviews();
}
function groupSection(title,count,txs){
  const cards=[...txs].sort((a,b)=>eventMillis(a.request||a.event)-eventMillis(b.request||b.event)).map(networkCard).join('');
  return `<section class="group"><div class="group-head"><h2>${escapeHtml(title)}</h2><div class="count">${escapeHtml(count)}</div></div><div class="group-list">${cards}</div></section>`;
}
function renderNetworkGroups(){
  const networks=networkTransactions().filter(networkFilterMatches);
  if(networks.length===0){
    timeline.className='';
    timeline.innerHTML='<div class="empty">No network requests match the current filters. Enable the proxy while serve is running, or relax the filters above.</div>';
    return;
  }
  timeline.className='';
  const groups=[];
  const byRule=new Map();
  for(const tx of networks.filter((tx)=>tx.payload&&tx.payload.mocked)){
    const key=(tx.payload&&tx.payload.mockRuleId)||'(unknown rule)';
    if(!byRule.has(key)){byRule.set(key,[]);}
    byRule.get(key).push(tx);
  }
  for(const [ruleId,txs] of byRule){groups.push(groupSection(`Mock rule: ${ruleId}`,`${txs.length} hit(s)`,txs));}
  const byHost=new Map();
  for(const tx of networks.filter((tx)=>!(tx.payload&&tx.payload.mocked))){
    const key=(tx.payload&&tx.payload.host)||'(unknown host)';
    if(!byHost.has(key)){byHost.set(key,[]);}
    byHost.get(key).push(tx);
  }
  for(const [host,txs] of byHost){groups.push(groupSection(`Host: ${host}`,`${txs.length} request(s)`,txs));}
  timeline.innerHTML=groups.join('');
  attachCopyChips();
  hydrateBodyPreviews();
}
function refLink(event,ref,label){
  if(!event.refs||!event.refs[ref]){return '<span class="status">missing</span>';}
  return `<a class="link" href="${artifactUrl(event,ref)}" target="_blank" rel="noopener noreferrer">${escapeHtml(label||event.refs[ref])}</a>`;
}
function screenshot(event,ref){
  if(!event.refs||!event.refs[ref]){return '<div class="status">No screenshot captured.</div>';}
  const url=artifactUrl(event,ref);
  return `<button class="shot-link" type="button" data-shot-src="${url}" data-shot-label="Screenshot"><img class="shot" src="${url}" alt="Screenshot" data-ref="${escapeHtml(ref)}"></button>`;
}
function node(event,kind,time,title,phase,badge,body){
  return `<div class="node ${kind}"><div class="event-side"><div class="time">${escapeHtml(time)}</div><div class="card"><div class="card-head"><div><div class="phase">${escapeHtml(phase)}</div><div class="title">${escapeHtml(title)}</div><div class="meta">${escapeHtml(event.id)} &middot; ${escapeHtml(event.payload&&event.payload.packageName||event.target||'unknown target')}</div></div><div class="badge">${escapeHtml(badge)}</div></div><div class="body">${body}</div></div></div><div class="marker"></div><div class="network-side"></div></div>`;
}
function networkCard(tx){
  const p=tx.payload||{}, event=tx.event, status=p.error?'error':(p.status||'pending'), duration=isPresent(p.durationMs)?`${p.durationMs} ms`:'pending';
  const mode=p.mocked?(p.mitm?'MOCK HTTPS MITM':'MOCK HTTP'):(p.tunnel?'CONNECT tunnel':(p.mitm?'HTTPS MITM':'HTTP'));
  const badge=p.mocked?'MOCK':status;
  const mockMeta=p.mocked?` <button class="copy-chip" type="button" data-copy="${escapeHtml(p.mockRuleId||'')}">rule ${escapeHtml(p.mockRuleId||'unknown')}</button><button class="copy-chip" type="button" data-copy="${escapeHtml(p.mockValueId||'')}">value ${escapeHtml(p.mockValueId||'unknown')}</button>`:'';
  const mockAction=canCopyAsMock(tx)?` <button class="copy-chip" type="button" data-copy="${escapeHtml(mockCommandFor(tx))}">copy as mock</button>`:'';
  const facts=`<div class="facts"><div class="fact"><span>Host</span><b title="${escapeHtml(p.host||'unknown')}">${escapeHtml(p.host||'unknown')}</b></div><div class="fact"><span>Status</span><b>${escapeHtml(status)}</b></div><div class="fact"><span>Duration</span><b>${escapeHtml(duration)}</b></div></div>`;
  const refs=Object.keys(tx.refs||{}), requestRef=refs.find((ref)=>ref.startsWith('requestBody.')), responseRef=refs.find((ref)=>ref.startsWith('responseBody.'));
  const body=(label,ref,bytes,truncated)=>!ref?'':`<div class="net-section"><h3>${label} body</h3><div class="artifact">${refLink(event,ref,`${bytes||0} bytes${truncated?' · truncated':''}`)}</div><pre class="body-preview" data-event-id="${escapeHtml(event.id)}" data-ref="${escapeHtml(ref)}">Loading preview...</pre></div>`;
  const headers=(title,items)=>items?`<details class="net-section" open><summary>${escapeHtml(title)} headers</summary><pre>${pretty(items)}</pre></details>`:'';
  const refsBlock=refs.length?`<details class="net-section"><summary>Artifact refs</summary><pre>${pretty(tx.refs)}</pre></details>`:'';
  const request=`<div class="net-section"><h3>Request</h3><div class="meta">${escapeHtml(p.method||'HTTP')} ${escapeHtml(p.path||'/')}</div>${headers('request',p.requestHeaders)}${body('Request',requestRef,p.requestBodyBytes,p.requestBodyTruncated)}</div>`;
  const response=`<div class="net-section"><h3>Response</h3><div class="meta">${escapeHtml(isPresent(p.status)?`HTTP ${p.status}`:'pending')}</div>${headers('response',p.responseHeaders)}${body('Response',responseRef,p.responseBodyBytes,p.responseBodyTruncated)}</div>`;
  return `<div class="net-card"><div class="net-head"><div><div class="phase">${escapeHtml(mode)}</div><div class="net-url">${escapeHtml((p.method||'HTTP')+' '+(p.url||p.host||''))}</div><div class="net-meta">${escapeHtml(tx.id)} · ${tx.events.length} event(s)${mockMeta}${mockAction}</div></div><div class="badge ${p.mocked?'mock':''}">${escapeHtml(badge)}</div></div><div class="net-body">${facts}${p.error?`<div class="shot-error">${escapeHtml(p.error)}</div>`:''}<div class="net-grid">${request}${response}</div>${refsBlock}</div></div>`;
}
function networkNode(tx){
  const event=tx.event;
  return `<div class="node network"><div class="event-side"><div class="time">${escapeHtml(formatTime(eventMillis(tx.request||event)))}</div></div><div class="marker"></div><div class="network-side">${networkCard(tx)}</div></div>`;
}
function runtimeNode(event){
  const p=event.payload||{}, kind=p.kind||'runtime advisory';
  const facts=`<div class="facts"><div class="fact"><span>Kind</span><b>${escapeHtml(kind)}</b></div><div class="fact"><span>Previous</span><b>${escapeHtml(pidRuntimeLabel(p.previousPid,p.previousRuntime))}</b></div><div class="fact"><span>Current</span><b>${escapeHtml(pidRuntimeLabel(p.currentPid,p.currentRuntime))}</b></div></div>`;
  const body=`${facts}<div class="artifact">${escapeHtml(p.message||'Runtime state changed.')}</div><details><summary>Runtime advisory payload</summary><pre>${pretty(p)}</pre></details>`;
  return node(event,'runtime',formatTime(eventMillis(event)),'Runtime advisory','runtime',kind,body);
}
function pidRuntimeLabel(pid,runtime){
  const parts=[];if(isPresent(pid)){parts.push(`pid=${pid}`);}if(isPresent(runtime)){parts.push(runtime);}return parts.join(' · ')||'unknown';
}
function traceGroup(event,index){
  const payload=event.payload||{}, target=payload.target||{}, result=payload.result||{};
  const time=formatTime(eventMillis(event)), targetSource=target.source||result.source||'unknown', targetRef=target.ref||result.ref||'none';
  const targetPoint=target.point?`${target.point.x}, ${target.point.y}`:(result.x&&result.y?`${result.x}, ${result.y}`:'none');
  const beforeBody=`<div class="shot-body"><div class="shot-copy"><div class="artifact">Snapshot: ${refLink(event,'beforeSnapshot','snapshot.json')}</div><details><summary>Evidence ref</summary><pre>${pretty({snapshot:event.refs&&event.refs.beforeSnapshot,screenshot:event.refs&&event.refs.beforeScreenshot})}</pre></details></div><div class="media">${screenshot(event,'beforeScreenshot')}</div></div>`;
  const actionBody=`<div class="facts"><div class="fact"><span>Selector</span><b>${escapeHtml(selectorLabel(payload.selector))}</b></div><div class="fact"><span>Target source</span><b>${escapeHtml(targetSource)}</b></div><div class="fact"><span>Point</span><b>${escapeHtml(targetPoint)}</b></div></div>${selectorChips(payload.selector,target,result)}<details><summary>Selector JSON</summary><pre>${pretty(payload.selector||{})}</pre></details><details><summary>Target / result JSON</summary><pre>${pretty(payload.target||payload.result||{})}</pre></details>`;
  const afterBody=`<div class="shot-body"><div class="shot-copy"><div class="artifact">Snapshot: ${refLink(event,'afterSnapshot','snapshot.json')}</div><details><summary>Evidence ref</summary><pre>${pretty({snapshot:event.refs&&event.refs.afterSnapshot,screenshot:event.refs&&event.refs.afterScreenshot})}</pre></details></div><div class="media">${screenshot(event,'afterScreenshot')}</div></div>`;
  const diffBody=`<div class="artifact">Manifest: ${refLink(event,'manifest','trace.json')} &middot; target ref: ${escapeHtml(targetRef)}</div><div class="diff-target" data-event-id="${escapeHtml(event.id)}">Loading diff...</div><details><summary>Artifact refs</summary><pre>${pretty(event.refs||{})}</pre></details><details><summary>Full payload</summary><pre>${pretty(payload)}</pre></details>`;
  return `<article class="trace-group">${node(event,'before',time,`Screenshot`,`${index}.1 evidence`,event.refs&&event.refs.beforeScreenshot?'screenshot':'snapshot only',beforeBody)}${node(event,'action',time,labelFor(event),`${index}.2 action`,targetSource,actionBody)}${node(event,'after',time,`Screenshot`,`${index}.3 evidence`,event.refs&&event.refs.afterScreenshot?'screenshot':'snapshot only',afterBody)}${node(event,'diff',time,`Diff`,`${index}.4 changes`,`${payload.changeCount||0} change(s)`,diffBody)}</article>`;
}
function selectorChips(selector,target,result){
  const chips=[];
  const add=(label,value)=>{if(isPresent(value)){chips.push(`<button class="copy-chip selector-chip" type="button" data-copy="${escapeHtml(value)}">${escapeHtml(label)} ${escapeHtml(value)}</button>`);}};
  selector=selector||{};target=target||{};result=result||{};
  add('test-id',selector.testId);add('css',selector.cssSelector);add('ref',selector.ref||target.ref||result.ref);add('resource',selector.resourceId);add('point',target.point?`${target.point.x},${target.point.y}`:(result.x&&result.y?`${result.x},${result.y}`:null));
  return chips.length?`<div class="selector-chips">${chips.join('')}</div>`:'';
}
function openLightbox(src,label){lightboxImage.src=src;lightboxImage.alt=label;lightboxCaption.textContent=label;lightbox.hidden=false;document.body.classList.add('modal-open');}
function closeLightbox(){lightbox.hidden=true;lightboxImage.removeAttribute('src');document.body.classList.remove('modal-open');}
function attachScreenshotPreviews(){timeline.querySelectorAll('.shot-link').forEach((button)=>{button.addEventListener('click',()=>openLightbox(button.dataset.shotSrc,button.dataset.shotLabel));button.querySelector('img')?.addEventListener('error',()=>{button.outerHTML=`<div class="shot-error">Screenshot artifact could not be loaded: ${escapeHtml(button.querySelector('img')?.dataset.ref||'unknown')}</div>`;});});}
function attachCopyChips(){timeline.querySelectorAll('.copy-chip').forEach((button)=>button.addEventListener('click',async()=>{try{await navigator.clipboard.writeText(button.dataset.copy||'');button.textContent='copied';}catch(error){button.textContent='copy failed';}}));}
async function loadManifest(event){
  if(!event.refs||!event.refs.manifest){return null;}
  if(state.manifests.has(event.id)){return state.manifests.get(event.id);}
  try{const response=await fetch(artifactUrl(event,'manifest'));if(!response.ok){throw new Error(`HTTP ${response.status}`);}const manifest=await response.json();state.manifests.set(event.id,manifest);return manifest;
  }catch(error){state.manifests.set(event.id,{error:String(error)});return state.manifests.get(event.id);}
}
function renderDiff(manifest){
  const diff=manifest&&Array.isArray(manifest.diff)?manifest.diff:[];
  if(diff.length===0){return '<div class="status">No snapshot diff entries.</div>';}
  const sorted=[...diff].sort((a,b)=>diffRank(a)-diffRank(b));
  const rows=(items)=>`<table><thead><tr><th>Ref</th><th>Field</th><th>Before</th><th>After</th></tr></thead><tbody>${items.map((change)=>`<tr><td>${escapeHtml(change.ref||'snapshot')}</td><td>${escapeHtml(change.field)}</td><td>${escapeHtml(change.before)}</td><td>${escapeHtml(change.after)}</td></tr>`).join('')}</tbody></table>`;
  if(sorted.length<=8){return rows(sorted);}
  return `<div class="status">${sorted.length} diff entries; showing 8 highest-signal changes first.</div>${rows(sorted.slice(0,8))}<details><summary>Show all diff entries</summary>${rows(sorted)}</details>`;
}
function diffRank(change){const field=String(change.field||'');if(/text|label|contentDescription|testId|resourceId/.test(field)){return 0;}if(/visible|enabled|interactive|role|kind/.test(field)){return 1;}if(/frame|alpha|background|style/.test(field)){return 2;}if(/nodeCount|children|present/.test(field)){return 9;}return 4;}
function hydrateDiffs(){
  timeline.querySelectorAll('.diff-target').forEach(async (el)=>{
    const event=state.events.find((item)=>item.id===el.dataset.eventId);
    if(!event){return;}
    const manifest=await loadManifest(event);
    el.innerHTML=manifest&&manifest.error?`<div class="status">${escapeHtml(manifest.error)}</div>`:renderDiff(manifest);
  });
}
function hydrateBodyPreviews(){
  timeline.querySelectorAll('.body-preview').forEach(async (el)=>{
    const event=state.events.find((item)=>item.id===el.dataset.eventId);
    if(!event){return;}
    try{
      const response=await fetch(artifactUrl(event,el.dataset.ref));
      if(!response.ok){throw new Error(`HTTP ${response.status}`);}
      const text=new TextDecoder().decode(await response.arrayBuffer());
      el.textContent=text.length>4096?`${text.slice(0,4096)}\n... preview truncated ...`:text;
    }catch(error){
      el.textContent=`Preview unavailable: ${error}`;
    }
  });
}
async function loadSessions(){
  const response=await fetch('/sessions');const data=await response.json();
  state.sessions=data.sessions||[];state.currentSession=(state.sessions.find((s)=>s.isCurrent)||state.sessions[0]||{}).id||null;
  if(!state.selectedSession){state.selectedSession=state.currentSession;}
  sessionPicker.innerHTML=state.sessions.map((s)=>`<option value="${escapeHtml(s.id)}">${escapeHtml(sessionLabel(s))}</option>`).join('');
  sessionPicker.value=state.selectedSession||'';
}
function sessionLabel(session){const stamp=session.updatedAtMillis?formatTime(session.updatedAtMillis):'no events';return `${session.isCurrent?'current · ':''}${session.id} · ${session.actionTraceCount} trace(s) · ${stamp}`;}
async function loadHistory(){
  if(!state.selectedSession){return;}
  const response=await fetch(`/sessions/${sessionRoute()}/events`),data=await response.json();state.events=[];state.manifests.clear();
  (data.events||[]).forEach(mergeEvent);
  renderTimeline();
}
function connectStream(){
  if(state.stream){state.stream.close();state.stream=null;}
  if(!selectedIsCurrent()){return;}
  const stream=new EventSource('/events/stream');
  state.stream=stream;
  const handleMessage=(message)=>{
    try{
      mergeEvent(JSON.parse(message.data));
      renderTimeline();
    }catch(error){
      statusEl.textContent=`Could not parse event: ${error}`;
    }
  };
  stream.onmessage=handleMessage;
  stream.addEventListener('action.trace',handleMessage);
  stream.addEventListener('network.request',handleMessage);
  stream.addEventListener('network.response',handleMessage);
  stream.addEventListener('network.error',handleMessage);
  stream.addEventListener('runtime.advisory',handleMessage);
  stream.onerror=()=>{statusEl.textContent='Live event stream disconnected; retrying...';};
}
sessionPicker.addEventListener('change',async()=>{state.selectedSession=sessionPicker.value;if(state.stream){state.stream.close();state.stream=null;}await loadHistory();connectStream();});
networkFilters.addEventListener('click',(event)=>{const button=event.target.closest('button[data-filter]');if(!button){return;}state.networkFilter=button.dataset.filter||'all';networkFilters.querySelectorAll('button').forEach((item)=>item.classList.toggle('active',item===button));renderTimeline();});
networkStatusFilters.addEventListener('click',(event)=>{const button=event.target.closest('button[data-status]');if(!button){return;}state.networkStatusClass=button.dataset.status||'all';networkStatusFilters.querySelectorAll('button').forEach((item)=>item.classList.toggle('active',item===button));renderTimeline();});
networkSearch.addEventListener('input',()=>{state.networkSearch=networkSearch.value.trim();renderTimeline();});
viewToggle.addEventListener('click',(event)=>{const button=event.target.closest('button[data-view]');if(!button){return;}state.view=button.dataset.view||'timeline';viewToggle.querySelectorAll('button').forEach((item)=>item.classList.toggle('active',item===button));renderTimeline();});
document.getElementById('lightbox-close').addEventListener('click',closeLightbox);
lightbox.addEventListener('click',(event)=>{if(event.target===lightbox){closeLightbox();}});
document.addEventListener('keydown',(event)=>{if(event.key==='Escape'&&!lightbox.hidden){closeLightbox();}});
loadSessions().then(loadHistory).then(connectStream).catch((error)=>{statusEl.textContent=`Load failed: ${error}`;});
</script>
</body>
</html>
"""#
