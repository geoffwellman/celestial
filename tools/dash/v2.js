// Dashboard v2 (CEL-106). Built from the approved mockup; data from
// /api/state (what the classic page reads) and the /api/v2/* feeds (CEL-105).
//
// THE #127 RULE, PAGE-WIDE. A refresh every few seconds must never destroy
// what the owner is doing: open details, typed text, an armed button, an open
// drawer or palette. So nothing here rebuilds an element the owner can type
// in. Card bodies repaint only when their own HTML changed; the composer, the
// drawer's message box and the palette input are static elements that no
// render touches; and the decisions panel is the shared one (decisions.js),
// which snapshots and restores its own cards.
'use strict';
var csrf=document.querySelector('meta[name="cel-csrf-token"]').content;
window.V2ERRORS=[];
window.addEventListener('error',function(e){window.V2ERRORS.push(String(e.message||e))});
function $(id){return document.getElementById(id)}
function esc(s){return String(s==null?'':s).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]})}
async function post(path,body){
  var r=await fetch(location.origin+path,{method:'POST',
    headers:{'content-type':'application/json','x-cel-csrf':csrf},body:JSON.stringify(body)});
  return {ok:r.ok,text:await r.text()};
}
function toast(t,ok){var el=$('toast');el.textContent=t;el.style.borderColor=ok===false?'var(--bad)':'var(--gold)';
  el.style.display='block';clearTimeout(el._t);el._t=setTimeout(function(){el.style.display='none'},3200)}
function store(k,v){try{localStorage.setItem(k,JSON.stringify(v))}catch(e){}}
function recall(k,d){try{var v=JSON.parse(localStorage.getItem(k)||'null');return v==null?d:v}catch(e){return d}}

// ---- data ------------------------------------------------------------------
var S=null;            // /api/state as fetched
var F={};              // /api/v2/<feed> by name
var FAT={};            // when the server computed each F[name], ms (CEL-116)
var LAST=null;         // what decisions.js draws: S's decisions, filtered
var WSF=recall('cel-v2-ws','all');
var FEEDS=['fleet','services','since','activity','stuck','lanes','load','merges','cycle','heat','usage'];
function inWs(w){return WSF==='all'||!w||w===WSF}
function wsOf(x){return x&&(x.ws||x.workspace)||(S&&S.workspace)||''}
// the 8 s refresh; ?refreshMs in the dash config drives the classic page, the
// same knob a test uses here is window.v2refresh()
var REFRESH_MS=8000;
window.V2REFRESHES=0;
async function getJSON(u){var r=await fetch(u,{cache:'no-store'});if(!r.ok){var e=new Error(u+' '+r.status);e.status=r.status;throw e}return r.json()}
// A feed that failed is told apart from one not yet loaded: "loading" before
// the first answer, "unavailable (<status>) - retrying" after a failure, so a
// broken feed never reads as a slow one. ERR holds the latest failure by feed
// ('state' for /api/state) and clears on the next success.
var ERR={};
function failed(name){return function(e){ERR[name]=(e&&e.status)||'network'}}
// CEL-116: the server's x-cel-computed-at, so a card drawn from an old value says so
async function getFeed(u,name){var r=await fetch(u,{cache:'no-store'});if(!r.ok){var e=new Error(u+' '+r.status);e.status=r.status;throw e}
  var at=Date.parse(r.headers.get('x-cel-computed-at')||'');FAT[name]=isNaN(at)?Date.now():at;return r.json()}
// FIRST PAINT WITHOUT WAITING: one request for the last value of every card's
// feed, drawn at once; the live refresh then replaces it feed by feed. A feed
// the live refresh already answered is never overwritten by the snapshot.
async function snapshot(){
  try{var d=await getJSON('/api/v2/snapshot?ws='+encodeURIComponent(WSF));
    Object.keys(d.feeds||{}).forEach(function(f){if(F[f]===undefined){F[f]=d.feeds[f].v;FAT[f]=Date.parse(d.feeds[f].at)||Date.now()}});
    renderAll()}catch(e){/* the live refresh draws, or reports, every card */}
}
function ageNote(id){
  var src=NEEDS[id]||[],old=Infinity;
  src.forEach(function(n){if(FAT[n]!==undefined)old=Math.min(old,FAT[n])});
  if(old===Infinity)return '';var s=Math.round((Date.now()-old)/1000);
  if(s*1000<=REFRESH_MS*3)return '';
  return '<div class="sub age" title="this card is showing the last value the server computed">as of '+(s<120?s+'s':Math.round(s/60)+'m')+' ago</div>';
}
async function refresh(){
  var q='ws='+encodeURIComponent(WSF);
  var jobs=[getJSON('/api/state').then(function(s){S=s;delete ERR.state}).catch(failed('state'))];
  FEEDS.forEach(function(f){
    var extra=f==='activity'?'&limit=30':f==='merges'?'&days=14':f==='load'?'&hours=24':f==='lanes'?'&range=today':'';
    jobs.push(getFeed('/api/v2/'+f+'?'+q+extra,f).then(function(d){F[f]=d;delete ERR[f]}).catch(failed(f)));
  });
  await Promise.all(jobs);
  window.V2REFRESHES++;
  renderAll();
  $('updated').textContent='updated '+new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit',second:'2-digit'});
}
window.v2refresh=function(){return refresh()};

// ---- the decisions panel's host contract (decisions.js) --------------------
var NYSORT=recall('cel-v2-nysort','urgent');
var V2OPEN={};         // decision id -> opened in place
function buildLast(){
  var groups=((S&&S.needsYouGroups)||[]).filter(function(g){return inWs(g.workspace)}).map(function(g){
    var items=g.items.filter(function(d){return !NYDONE[d.id]});
    if(NYSORT==='newest')items.sort(function(a,b){return (a.age_secs||0)-(b.age_secs||0)});
    else if(NYSORT==='oldest')items.sort(function(a,b){return (b.age_secs||0)-(a.age_secs||0)});
    return {workspace:g.workspace,urgent:g.urgent,count:items.length,recommended:g.recommended,items:items}});
  var all=[];groups.forEach(function(g){all=all.concat(g.items)});
  LAST={needsYou:all,needsYouGroups:groups};
}
function refreshTabs(){var n=LAST?LAST.needsYou.length:0;$('nyc').textContent=n;var c=$('alerts-h');if(c)c.textContent=n}
function nyAfterRender(host){
  var ov=$('ov').classList.contains('open')&&host.closest('#ov');
  Array.prototype.forEach.call(host.querySelectorAll('.nycard'),function(c){
    if(V2OPEN[c.dataset.id]||ov)c.classList.add('open')});
}
var NYHOST=null;       // the one #needsyou, moved between its card and the overlay
function needsHost(){
  var h=NYHOST;
  if(!h){h=NYHOST=document.createElement('div');h.id='needsyou';
    // a card folds to its title; a click on the title opens it in place
    h.addEventListener('click',function(e){
      var hd=e.target.closest('.nyhead');if(!hd)return;
      var c=hd.closest('.nycard'),id=c.dataset.id;
      if(V2OPEN[id])delete V2OPEN[id];else V2OPEN[id]=1;
      c.classList.toggle('open',!!V2OPEN[id]);
    });
  }
  return h;
}

// ---- cards -----------------------------------------------------------------
var W=[
 {id:'since',t:'Since you last looked',size:'full'},{id:'needs',t:'Needs you',size:'full'},
 {id:'stuck',t:'Stuck - and why'},{id:'working',t:'Working now'},{id:'activity',t:'Activity'},{id:'prs',t:'Pull requests'},
 {id:'orchs',t:'Orchestrators'},{id:'merges',t:'Merged PRs · 14 days'},{id:'usage',t:'Usage',size:'full'},{id:'afk',t:'Away mode'},
 {id:'lanes',t:'Today by workspace',size:'full'},{id:'heat',t:'When work lands'},{id:'cycle',t:'Time to merge'},{id:'funnel',t:'PR flow'},
 {id:'load',t:'Box load · 24h'},{id:'box',t:'Box'},{id:'services',t:'Running services'}];
var LAYOUT_KEY='cel-v2-layout';
var L=recall(LAYOUT_KEY,null)||{};
L.order=(L.order||[]).filter(function(id){return W.some(function(w){return w.id===id})});
W.forEach(function(w){if(L.order.indexOf(w.id)<0)L.order.push(w.id)});
L.hidden=L.hidden||[];L.size=L.size||{};
function saveLayout(){store(LAYOUT_KEY,L)}
function sizeOf(w){return L.size[w.id]||w.size||'half'}
var CUSTOM=false;

function hhmm(iso){var d=new Date(iso);return isNaN(d)?'':d.toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'})}
function ago(iso){var s=(Date.now()-new Date(iso).getTime())/1000;if(!(s>=0))return '';return s<3600?Math.round(s/60)+'m':s<86400?Math.round(s/3600)+'h':Math.round(s/86400)+'d'}
function wsTag(w){return '<span class="ws">'+esc(w)+'</span>'}
function none(t){return '<div class="sub">'+esc(t)+'</div>'}
// Who is running and what is open come from the fleet feed, which spans
// every workspace in the filter; /api/state is one workspace's view and left
// "All workspaces" with no orchestrators, workers or PRs (#132 on real data).
function orchs(){return ((F.fleet||{}).orchestrators)||[]}
// working and blocked first: a pane that finished hours ago is still listed,
// below the ones that need watching
var WRANK={working:0,blocked:1,idle:2,done:3};
function workers(){return (((F.fleet||{}).workers)||[]).slice().sort(function(a,b){return (WRANK[a.status]==null?4:WRANK[a.status])-(WRANK[b.status]==null?4:WRANK[b.status])})}
function prRows(){var w={};workers().forEach(function(x){if(x.pr)w[x.repo+'#'+x.pr]=x.name});
  return (((F.fleet||{}).prs)||[]).map(function(p){return {ws:p.ws,repo:p.repo,number:p.number,title:p.title,url:p.url,review:p.review,
    checks:p.mergeable==='CONFLICTING'?'failing':'',draft:p.draft,agent:w[p.repo+'#'+p.number]||''}})}
function prOf(w){return w.pr?prRows().filter(function(p){return p.repo===w.repo&&p.number===w.pr})[0]||null:null}
function repoWs(){var m={};(((F.cycle||{}).repos)||[]).forEach(function(r){m[r.repo]=r.ws});return m}
function feedItems(f,key){return (((F[f]||{})[key||'items'])||[]).filter(function(x){return inWs(x.ws)})}

var BODY={
 since:function(){var d=F.since;if(!d)return none('waiting for the since feed');var c=d.counts||{};
  var cells=[['merged','PRs merged'],['decisions_closed','decisions closed'],['decisions_new','new decisions'],['incidents','incidents'],['stuck','stuck']];
  var items=feedItems('since');
  return '<div class="sub">Since '+esc(new Date(d.at).toLocaleString())+' · <button class="btn" data-act="seen">mark as seen</button></div>'+
   '<div class="since">'+cells.map(function(x){return '<div><div class="big">'+esc(c[x[0]]||0)+'</div><b>'+x[1]+'</b></div>'}).join('')+'</div>'+
   (items.length?'<div class="feed">'+items.slice(0,6).map(function(r){return '<div class="row" data-ws="'+esc(r.ws)+'"><time>'+hhmm(r.ts)+'</time>'+wsTag(r.ws)+'<span class="t">'+esc(r.text)+'</span></div>'}).join('')+'</div>':'')},
 stuck:function(){var it=feedItems('stuck');if(!F.stuck)return none('waiting for the stuck feed');
  return it.map(function(r){return '<div class="row" data-ws="'+esc(r.ws)+'" data-ref="'+esc(r.ref)+'"><span class="dot '+(/conflict/i.test(r.reason)?'bad':'warn')+'"></span><span class="t"><b>'+esc(r.ref)+'</b> '+wsTag(r.ws)+'<br><span class="sub">'+esc(r.reason)+(r.since?' · '+ago(r.since):'')+'</span></span>'+
   (r.fix?'<button class="btn" data-act="'+esc(r.fix.action)+'" data-target="'+esc(r.ref)+'" data-ws="'+esc(r.ws)+'" data-label="'+esc(r.fix.label)+'">'+esc(r.fix.label)+'</button>':'')+'</div>'}).join('')||none('nothing stuck')},
 working:function(){
  // only panes that need watching; idle and finished ones show in lanes
  var it=workers().filter(function(w){return inWs(w.ws)&&(w.status==='working'||w.status==='blocked')});
  return it.map(function(w){return '<div class="row" data-ws="'+esc(w.ws)+'"><span class="dot '+(w.status==='working'?'ok':w.status==='blocked'?'warn':'idle')+'"></span><span class="t"><b class="link" data-agent="'+esc(w.name)+'">'+esc(w.name)+'</b> '+wsTag(w.ws)+'<br><span class="sub">'+esc(w.repo+'/'+w.branch)+' · '+esc(w.status||'')+'</span></span><span class="sub">'+esc((w.model||'').split('/').pop())+'</span></div>'}).join('')||none('nothing running')},
 activity:function(){var it=feedItems('activity');if(!F.activity)return none('waiting for the activity feed');
  return '<div class="feed">'+it.slice(0,12).map(actRow).join('')+'</div>'||none('quiet')},
 prs:function(){var it=prRows().filter(function(p){return inWs(p.ws)});
  return it.map(function(p){var ok=p.review==='APPROVED';return '<div class="row" data-ws="'+esc(p.ws)+'" data-pr="'+esc(p.repo+'#'+p.number)+'"><span class="dot '+(p.checks==='failing'?'bad':ok?'ok':'warn')+'"></span><span class="t">'+esc(p.title)+'</span>'+wsTag(p.ws)+'<a class="sub mono" href="'+esc(p.url)+'" target="_blank" rel="noopener">'+esc(p.repo+'#'+p.number)+'</a><span class="sub">'+(ok?'approved':p.review==='CHANGES_REQUESTED'?'changes':'in review')+'</span></div>'}).join('')||none('no open PRs')},
 orchs:function(){var it=orchs().filter(function(o){return inWs(o.ws)});
  return it.map(function(o){return '<div class="row" data-ws="'+esc(o.ws)+'"><span class="dot '+(o.status==='working'?'ok':'idle')+'"></span><span class="t"><b class="link" data-agent="'+esc(o.name)+'">'+esc(o.name)+'</b> <span class="sub">'+esc(o.status)+'</span></span>'+wsTag(o.ws)+
   '<button class="btn" data-agent="'+esc(o.name)+'">message</button><button class="btn" data-act="orch.restart" data-target="'+esc(o.name)+'" data-ws="'+esc(o.ws)+'" data-label="restart '+esc(o.name)+'">restart</button></div>'}).join('')||none('no orchestrators here')},
 merges:function(){var days=((F.merges||{}).days)||[];if(!F.merges)return none('waiting for the merges feed');var rw=repoWs();
  var vals=days.map(function(d){var n=0;Object.keys(d.counts||{}).forEach(function(r){if(WSF==='all'||rw[r]===WSF)n+=d.counts[r]});return [d.day,n]});
  var mx=Math.max.apply(null,[1].concat(vals.map(function(v){return v[1]})));var tot=vals.reduce(function(a,v){return a+v[1]},0);
  return '<div><span class="big">'+tot+'</span> <span class="sub">PRs merged'+(WSF==='all'?' across all repos':' in '+esc(WSF))+'</span></div><div class="chart">'+vals.map(function(v){return '<div title="'+esc(v[0])+': '+v[1]+' merged" style="height:'+Math.max(3,v[1]/mx*100)+'%"></div>'}).join('')+'</div><div class="days">'+vals.map(function(v){return '<span>'+esc(String(v[0]).slice(8))+'</span>'}).join('')+'</div>'},
 usage:function(big){return usageHtml(F.usage,!!big)},
 afk:function(){return '<div class="row"><span class="t"><b>Away mode</b><br><span class="sub">While away the fleet lands approved green PRs and restarts stalled orchestrators; everything else waits and shows up in Since you last looked.</span></span></div><div class="row"><button class="btn rec" data-act="afk.on" data-label="go away">Go away</button><button class="btn" data-act="afk.off" data-label="I\'m back">I\'m back</button></div>'},
 lanes:function(){return lanesHtml(F.lanes,false)},
 heat:function(){var c=((F.heat||{}).cells)||[];if(!F.heat)return none('waiting for the heat feed');var dn=['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  var mx=Math.max.apply(null,[1].concat([].concat.apply([],c)));
  return '<div class="heat">'+c.map(function(r,d){return '<span class="hd">'+dn[d]+'</span>'+r.map(function(v,h){return '<i title="'+dn[d]+' '+h+':00 - '+v+' merged" style="opacity:'+(v?0.18+0.82*v/mx:0.06)+'"></i>'}).join('')}).join('')+'</div><div class="hx"><span>0</span><span>6</span><span>12</span><span>18</span><span>23</span></div>'},
 cycle:function(){var r=(((F.cycle||{}).repos)||[]).filter(function(x){return inWs(x.ws)});if(!F.cycle)return none('waiting for the cycle feed');
  var mx=Math.log(1+Math.max.apply(null,[1].concat(r.map(function(x){return x.median_hours}))));
  return r.map(function(x){var h=x.median_hours;return '<div class="row" data-ws="'+esc(x.ws)+'"><span class="t">'+esc(x.repo)+' <span class="sub">'+esc(x.prs)+' PRs</span></span><span class="cb"><i style="width:'+Math.max(3,Math.log(1+h)/mx*100)+'%;background:'+(h>48?'var(--bad)':h>6?'var(--warn)':'var(--ok)')+'"></i></span><span class="sub" style="width:56px;text-align:right">'+(h<48?(Math.round(h*10)/10)+' h':Math.round(h/24)+' d')+'</span></div>'}).join('')||none('no merges')},
 funnel:function(){var p=prRows().filter(function(x){return inWs(x.ws)});var rw=repoWs();
  var merged=(((F.merges||{}).days)||[]).reduce(function(a,d){Object.keys(d.counts||{}).forEach(function(r){if(WSF==='all'||rw[r]===WSF)a+=d.counts[r]});return a},0);
  var st=[['open',p.length],['in review',p.filter(function(x){return x.review!=='APPROVED'&&x.review!=='CHANGES_REQUESTED'}).length],['changes',p.filter(function(x){return x.review==='CHANGES_REQUESTED'}).length],['approved',p.filter(function(x){return x.review==='APPROVED'}).length],['merged 14d',merged]];
  var mx=Math.max.apply(null,[1].concat(st.map(function(s){return s[1]})));
  return st.map(function(s){return '<div class="row"><span class="sub" style="width:80px">'+s[0]+'</span><span class="cb"><i style="width:'+(s[1]/mx*100)+'%"></i></span><span style="width:40px;text-align:right">'+s[1]+'</span></div>'}).join('')},
 load:function(){var d=F.load;if(!d||!(d.points||[]).length)return none('collecting since '+(d&&d.collecting_since?new Date(d.collecting_since).toLocaleString():'now')+' - the steward samples the box every few minutes');var pts=d.points;
  var mx=Math.max.apply(null,[d.threads||1].concat(pts.map(function(p){return p.load})));var n=Math.max(1,pts.length-1);
  var line=pts.map(function(p,i){return (i/n*100)+','+(100-p.load/mx*92)}).join(' ');var cap=100-(d.threads||0)/mx*92;
  return '<svg viewBox="0 0 100 100" preserveAspectRatio="none" class="spark"><line x1="0" x2="100" y1="'+cap+'" y2="'+cap+'" class="cap"/><polyline points="0,100 '+line+' 100,100" class="area"/><polyline points="'+line+'" class="ln2"/></svg><div class="hx"><span>'+hhmm(pts[0].ts)+'</span><span>now</span></div><div class="sub">Load average; dashed line = '+esc(d.threads)+' threads, above it work is queuing.</div>'},
 box:function(){var d=F.load,p=d&&(d.current||(d.points||[])[(d.points||[]).length-1]);if(!p)return none('no reading yet');
  function m(label,pct,txt){return '<div class="row"><span class="sub" style="width:60px">'+label+'</span><span class="meter"><i style="width:'+Math.min(100,pct)+'%;background:'+(pct>85?'var(--bad)':pct>60?'var(--warn)':'var(--ok)')+'"></i></span><span class="sub">'+txt+'</span></div>'}
  return '<div class="row"><span class="dot ok"></span><span class="t"><b>box</b> <span class="sub">'+esc(d.threads)+' threads</span></span></div>'+
   m('CPU',p.load/(d.threads||1)*100,'load '+p.load)+m('Memory',p.mem_pct,Math.round(p.mem_pct)+'%')+m('Swap',p.swap_pct,Math.round(p.swap_pct)+'%')},
 services:function(){var s=(((F.services||{}).items)||[]).filter(function(x){return x.ws==='box'||inWs(x.ws)});
  return s.map(function(x){var up=x.state==='up';return '<div class="row" data-ws="'+esc(x.ws)+'"><span class="dot '+(up?'ok':'bad')+'"></span><span class="sub mono" style="width:56px">'+(x.port?':'+esc(x.port):'')+'</span><span class="t">'+(x.url?'<a href="'+esc(x.url)+'" target="_blank" rel="noopener">'+esc(x.name)+'</a>':esc(x.name))+'</span><span class="sub">'+esc(x.state)+'</span>'+wsTag(x.ws)+'</div>'}).join('')||none('no services')},
};
// what each card is drawn from; a card waits for, or reports, its sources
var NEEDS={since:['since'],stuck:['stuck'],activity:['activity'],merges:['merges'],usage:['usage'],lanes:['lanes'],
  heat:['heat'],cycle:['cycle'],load:['load'],box:['load'],working:['fleet'],prs:['fleet'],orchs:['fleet'],
  services:['services'],funnel:['fleet','merges'],afk:[]};
function cardStatus(id){
  var src=NEEDS[id]||[];
  for(var i=0;i<src.length;i++){var n=src[i];if(ERR[n]!==undefined)return n+' unavailable ('+ERR[n]+') - retrying'}
  for(var j=0;j<src.length;j++){var m=src[j];if(m==='state'?!S:F[m]===undefined)return 'loading '+m+'…'}
  return '';
}
// ---- usage (CEL-108) --------------------------------------------------------
// One card from the approved mockup: a summary strip, then each provider's
// accounts with one bar per window (used now, a tick at the projected % at
// reset), then the pay-as-you-go balances. A row opens to who used it this
// week only when the feed could tell; the expanded view adds each window's
// line over the week when the dashboard has recorded one.
var UX=recall('cel-v2-usage-open',{});
function money(v,u){if(v==null)return '?';var n=Number(v);return (n<0?'-':'')+(u==='usd'||!u?'$':'')+Math.abs(n).toFixed(2)+(u&&u!=='usd'?' '+esc(u):'')}
function whenShort(iso){if(!iso)return '';var d=new Date(iso);if(isNaN(d))return '';
  var h=(d-Date.now())/3600e3;return h<20?hhmm(iso):d.toLocaleDateString([], {weekday:'short'})+' '+hhmm(iso)}
function uTag(t){return '<span class="utag '+(t==='orch'?'o':t==='workers'?'k':t==='not orch'?'x':'')+'">'+esc(t)+'</span>'}
function uSpark(h){if(!h||h.length<2)return '';var t0=new Date(h[0][0]).getTime(),t1=new Date(h[h.length-1][0]).getTime(),sp=Math.max(1,t1-t0);
  var pts=h.map(function(p){return ((new Date(p[0]).getTime()-t0)/sp*100).toFixed(1)+','+(100-Math.min(100,p[1])).toFixed(1)}).join(' ');
  return '<svg class="uspark" viewBox="0 0 100 100" preserveAspectRatio="none"><polyline points="'+pts+'"/></svg>'}
function uWin(w,big){
  var pace=w.projected_pct!==w.used_pct&&w.projected_pct>w.used_pct;
  var head=w.at_risk?'<b class="'+(w.used_pct>=95?'neg':'amb')+'">'+esc(w.label)+' · '+w.used_pct+'%</b>':esc(w.label)+' · '+w.used_pct+'%';
  return '<div class="uwin"><div class="ulab">'+head+(w.resets?' · resets '+esc(whenShort(w.resets)):'')+'</div>'+
   '<div class="ubar"><i class="'+w.level+'" style="width:'+Math.min(100,w.used_pct)+'%"></i>'+(pace?'<s style="left:'+Math.min(99,w.projected_pct)+'%" title="~'+w.projected_pct+'% at reset at this pace"></s>':'')+'</div>'+
   (pace&&w.projected_pct>=50?'<div class="sub">'+(w.projected_pct>=100?'on pace for '+Math.min(999,w.projected_pct)+'% - hits the cap before it resets':'on pace for ~'+w.projected_pct+'%')+'</div>':'')+
   (big?(uSpark(w.history)||'<div class="sub">no history yet</div>'):'')+'</div>'}
function usageHtml(d,big){
  if(!d)return none('waiting for the usage feed');
  var sm=d.summary||{},risk=sm.at_risk||[],o=sm.orch||{};
  var h='<div class="usum">'+
   '<div><div class="big" style="color:var('+(risk.length?'--warn':'--ok')+')">'+risk.length+' at risk</div><div class="sub">'+
     (risk.length?risk.slice(0,3).map(function(r){return esc(r.who)+' '+esc(r.window)+' on pace for '+esc(Math.min(999,r.projected_pct))+'%'+(r.resets?' before '+esc(whenShort(r.resets)):'')}).join('; '):'nothing on pace to hit a cap before it resets')+'</div></div>'+
   '<div><div class="big">'+esc(o.serving||0)+' of '+esc(o.of||0)+'</div><div class="sub">Claude accounts serving orchestrators</div></div>'+
   '<div><div class="big'+(sm.below_floor?' neg':'')+'">'+esc(sm.below_floor||0)+' dry</div><div class="sub">pay-as-you-go balances below their floor - those workers are vetoed</div></div>'+
   '<div><div class="big pos">'+money(sm.funded,'usd')+'</div><div class="sub">funded balance'+((sm.funded_by||[]).length?': '+esc(sm.funded_by.join('; ')):'')+'</div></div></div>';
  (d.groups||[]).forEach(function(g){
    var who=[];if(g.who&&g.who.orch)who.push(uTag('orch')+'<span class="sub">orchestrators</span>');if(g.who&&g.who.workers)who.push(uTag('workers')+'<span class="sub">workers via gateway</span>');
    if(g.who&&(g.who.profiles||[]).length)who.push('<span class="sub">'+esc(g.who.profiles.join(' / '))+' profiles</span>');
    h+='<div class="ugrp" data-provider="'+esc(g.provider)+'"><h4>'+esc(g.title)+' · subscription'+(g.accounts.length>1?'s':'')+(who.length?' <span class="uwho">who uses it: '+who.join(' ')+'</span>':'')+'</h4>';
    g.accounts.forEach(function(a){
      var k=g.provider+'|'+a.account,can=!!(a.used_by&&a.used_by.length),open=can&&UX[k];
      h+='<div class="uacct'+(can?' can':'')+'" data-uk="'+esc(k)+'"><div class="un"><b>'+(can?(open?'▾ ':'▸ '):'')+esc(a.who)+'</b>'+(a.tags||[]).map(uTag).join('')+
        (a.state&&a.state!=='enabled'&&a.state!=='disabled'?'<div class="sub neg">'+esc(a.reason||a.state)+'</div>':'')+'</div>'+
        '<div class="uws">'+(a.windows||[]).map(function(w){return uWin(w,big)}).join('')+'</div></div>';
      if(open)h+='<div class="uused">this week: '+a.used_by.map(function(u){return esc(u.ws)+' · '+esc(u.profile)+' ×'+esc(u.n)}).join(', ')+'</div>';
    });
    h+='</div>';
  });
  // balances follow the workspace filter (the feed already narrows them; this
  // keeps a stale answer from showing the last filter's rows); subscriptions
  // are the box's and always shown
  var b=(d.balances||[]).filter(function(x){return WSF==='all'||!x.workspaces.length||x.workspaces.indexOf(WSF)>=0});
  if(b.length){
    h+='<div class="ugrp"><h4>Pay-as-you-go balances</h4>'+b.map(function(x){
      var st=x.remaining==null?'unknown':x.vetoed?'vetoed - below '+money(x.floor,x.unit)+' floor':'ok - floor '+money(x.floor,x.unit);
      return '<div class="umoney" data-ws="'+esc(x.workspaces.join(' '))+'"><div><b>'+esc(x.provider)+' · '+esc(x.workspaces.join(', ')||'-')+'</b>'+(x.workspaces.length>1?' <span class="sub">one account</span>':'')+'</div><div class="'+(x.vetoed?'neg':x.remaining>0?'pos':'')+'">'+money(x.remaining,x.unit)+'</div><div class="sub">'+st+'</div></div>'}).join('')+'</div>';
  }
  if(!(d.groups||[]).length&&!b.length)h+=none('no readings yet - cel quota');
  h+='<div class="ulegend sub"><span><i class="ubar ulg"><i class="ok" style="width:60%"></i></i> used now</span><span>│ projected at reset, at this week\'s pace</span><span>amber ≥ 75% · red ≥ 95% or below floor</span>'+(d.at?'<span>as of '+esc(hhmm(d.at))+'</span>':'')+'</div>';
  return h;
}
function usageToggle(e){var r=e.target.closest('.uacct.can');if(!r)return false;var k=r.dataset.uk;if(UX[k])delete UX[k];else UX[k]=1;store('cel-v2-usage-open',UX);renderAll();return true}

function actRow(r){return '<div class="row" data-ws="'+esc(r.ws)+'"><time>'+hhmm(r.ts)+'</time>'+wsTag(r.ws)+'<span class="sub" style="width:64px">'+esc(r.kind)+'</span><span class="t">'+(r.url?'<a href="'+esc(r.url)+'" target="_blank" rel="noopener">'+esc(r.text)+'</a>':esc(r.text))+'</span></div>'}

// Today by workspace: one row per workspace, a half-hour strip (count, amber =
// waiting on a person); click opens one lane per PR. A workspace with something
// waiting opens by itself unless the owner closed it.
var LX=recall('cel-v2-lanes',{});
function lanesHtml(d,all){
  if(!d)return none('waiting for the lanes feed');
  var t0=new Date(d.start).getTime(),t1=new Date(d.end).getTime(),now=new Date(d.now).getTime(),span=Math.max(1,t1-t0);
  var slot=1800e3,ns=Math.max(1,Math.ceil(span/slot));if(ns>96){slot=Math.ceil(span/96/1800e3)*1800e3;ns=Math.ceil(span/slot)}
  var pct=function(t){return Math.max(0,Math.min(100,(t-t0)/span*100))};
  var nowl='<b class="nowl" style="left:'+pct(now)+'%"></b>';
  var hours=Math.round(span/3600e3),step=hours>48?24:hours>12?3:1,ticks='';
  for(var h=0;h<=hours;h+=step){var tt=t0+h*3600e3;ticks+='<i style="left:'+pct(tt)+'%">'+(step>=24?new Date(tt).toLocaleDateString([], {weekday:'short'}):String(new Date(tt).getHours()).padStart(2,'0'))+'</i>'}
  var rows=(d.workspaces||[]).filter(function(w){return inWs(w.ws)}).map(function(w){
    var segs=[];w.lanes.forEach(function(l){l.segments.forEach(function(s){segs.push(s)})});
    var waiting=w.lanes.filter(function(l){return l.segments.some(function(s){return s.state==='waiting'&&new Date(s.to).getTime()>=now-60e3})}).length;
    var open=all||(LX[w.ws]!==undefined?LX[w.ws]:waiting>0);
    var cells='';
    for(var i=0;i<ns;i++){var a=t0+i*slot,b=a+slot;
      var on=segs.filter(function(s){return new Date(s.from).getTime()<b&&new Date(s.to).getTime()>a});
      var n=on.length,cls=on.some(function(s){return s.state==='waiting'})?'warn':on.some(function(s){return s.state==='running'})?'ok':n?'idle':'';
      cells+='<i class="'+cls+'" style="opacity:'+(n?0.35+Math.min(n,6)/6*0.65:1)+'" title="'+n+' at '+hhmm(new Date(a).toISOString())+'">'+(n>1?n:'')+'</i>'}
    return '<div class="wsrow" data-lane="'+esc(w.ws)+'" data-ws="'+esc(w.ws)+'"><span class="ln2">'+(w.lanes.length?(open?'▾ ':'▸ '):'  ')+'<b>'+esc(w.ws)+'</b><br><span class="sub">'+w.lanes.length+' lanes'+(waiting?' · <span class="w8">'+waiting+' waiting</span>':'')+'</span></span><div class="strip" style="grid-template-columns:repeat('+ns+',1fr)">'+(w.lanes.length?cells:'<em>no workers</em>')+nowl+'</div></div>'+
     (open?w.lanes.map(function(l){return '<div class="sublane" data-ws="'+esc(w.ws)+'"><span class="ln2 sub">'+esc(l.ref+(l.pr?' #'+l.pr:' (no PR yet)'))+'</span><div class="lt2">'+l.segments.map(function(s){var a=new Date(s.from).getTime(),b=new Date(s.to).getTime();
       return '<b class="'+esc(s.state)+'" style="left:'+pct(a)+'%;width:'+Math.max(0.5,pct(b)-pct(a))+'%" title="'+esc(l.label+' - '+s.state)+'">'+esc(l.label)+'</b>'}).join('')+nowl+'</div></div>'}).join(''):'')});
  return '<div class="lanes2"><div class="lh2"><span></span><div class="ticks">'+ticks+nowl+'</div></div>'+rows.join('')+'</div>'+
   (rows.length?'<div class="sub">The strip counts workers per half hour (amber = waiting on a person). Click a workspace for one lane per PR.</div>':none('no workspaces in range'));
}

function cardEl(w){
  var el=document.querySelector('#grid .w[data-id="'+w.id+'"]');
  if(el)return el;
  el=document.createElement('div');el.className='w';el.dataset.id=w.id;
  el.innerHTML='<h3><span class="ttl">'+esc(w.t)+'</span>'+(w.id==='needs'?' <span class="n" id="alerts-h"></span>':'')+'<span class="scope"></span>'+
    '<select class="size" title="card size"><option value="half">half</option><option value="full">full width</option><option value="tall">tall</option></select>'+
    '<span class="x"></span><span class="ex" title="expand">⤢</span><span class="grip" title="drag to move">⠿</span></h3><div class="body"></div>';
  if(w.id==='needs')el.querySelector('.body').appendChild(needsHost());
  return el;
}
function renderAll(){
  var g=$('grid'),prev=null;
  L.order.forEach(function(id){
    var w=W.filter(function(x){return x.id===id})[0];if(!w)return;
    var hid=L.hidden.indexOf(id)>=0,el=cardEl(w);
    if(hid&&!CUSTOM){if(el.parentNode)el.parentNode.removeChild(el);return}
    // a card is moved only when it is out of place: moving an element blurs
    // whatever has focus inside it, and that is the owner's caret
    if(el.parentNode!==g||el.previousElementSibling!==prev)g.insertBefore(el,prev?prev.nextSibling:g.firstChild);
    prev=el;
    var sz=sizeOf(w);el.className='w '+sz+(hid?' hidcard':'');
    el.querySelector('select.size').value=sz;
    el.querySelector('.x').textContent=hid?'＋':'✕';el.querySelector('.x').title=hid?'restore':'hide';
    el.querySelector('.scope').textContent=WSF==='all'?'':' · '+WSF;
    if(id==='needs')return;
    var html,why=cardStatus(id);
    if(why)html=none(why);else try{html=BODY[id]()+ageNote(id)}catch(e){html=none('could not draw: '+e.message);window.V2ERRORS.push(id+': '+e.message)}
    var b=el.querySelector('.body');
    if(b._html!==html){b._html=html;b.innerHTML=html;restoreArmed(b)}
  });
  if(S){buildLast();if(needsHost().isConnected)renderNeedsYou();refreshTabs()}
  renderComposer();renderThread();renderDrawer();renderOverlay();
  var o=orchs(),wsn={};o.forEach(function(x){wsn[x.ws]=1});((S&&S.needsYouGroups)||[]).forEach(function(x){wsn[x.workspace]=1});
  var p=F.load&&F.load.current;
  $('tagline').textContent=o.length+' orchestrators · '+Object.keys(wsn).length+' workspaces'+(p?' · box at '+Math.round(p.mem_pct)+'% memory':'');
  if(S){$('wsname').textContent=S.workspace||'';document.title='celestial · '+(S.workspace||'')}
  fillWsFilter(Object.keys(wsn));
  window.V2READY=true;
}
function fillWsFilter(list){
  var sel=$('wsf'),have=[].slice.call(sel.options).map(function(o){return o.value});
  ((F.lanes||{}).workspaces||[]).forEach(function(w){if(list.indexOf(w.ws)<0)list.push(w.ws)});
  if(WSF!=='all'&&list.indexOf(WSF)<0)list.push(WSF);
  list.sort().forEach(function(w){if(have.indexOf(w)<0){var o=document.createElement('option');o.value=w;o.textContent=w;sel.appendChild(o)}});
  if(sel.value!==WSF)sel.value=WSF;
}

// ---- two-click actions, by identity (the #127 rule) -------------------------
// The first click arms ("send: <label>?") for 4 s; the second runs it. Armed
// state is keyed by what the button does, not the element, so a repaint that
// rebuilds the button keeps it armed.
var ARM={};
function armKey(b){return (b.dataset.act||'')+'|'+(b.dataset.target||'')+'|'+(b.dataset.ws||'')}
function armBtn(b){if(!b.dataset.orig)b.dataset.orig=b.textContent;b.classList.add('armed');b.textContent='confirm: '+(b.dataset.label||b.dataset.orig)+'?'}
function restoreArmed(host){Array.prototype.forEach.call(host.querySelectorAll('[data-act]'),function(b){if(ARM[armKey(b)])armBtn(b)})}
function twoClick(key,onArm,run){
  if(ARM[key]){clearTimeout(ARM[key]);delete ARM[key];run();return true}
  ARM[key]=setTimeout(function(){delete ARM[key];
    Array.prototype.forEach.call(document.querySelectorAll('[data-act].armed'),function(b){if(armKey(b)===key){b.classList.remove('armed');b.textContent=b.dataset.orig}})},4000);
  onArm();return false;
}
async function act(action,target,args){
  var r;try{r=await post('/api/v2/act',{action:action,target:target||'',args:args||{}})}catch(e){r={ok:false,text:String(e&&e.message||e)}}
  toast(r.ok?action+(target?' → '+target:'')+': done':action+' refused: '+r.text,r.ok);
  return r;
}
document.addEventListener('click',function(e){
  var b=e.target.closest('[data-act]');if(!b||b.closest('#needsyou'))return;
  var key=armKey(b);
  twoClick(key,function(){armBtn(b)},function(){
    b.classList.remove('armed');b.textContent=b.dataset.orig||b.textContent;
    act(b.dataset.act,b.dataset.target,b.dataset.ws?{ws:b.dataset.ws}:{});
  });
});

// ---- layout: drag, hide, resize, saved per browser -------------------------
var drag=null;
$('grid').addEventListener('pointerdown',function(e){var g=e.target.closest('.grip');if(g)g.closest('.w').draggable=true});
$('grid').addEventListener('dragstart',function(e){drag=e.target.closest('.w');if(!drag)return;drag.classList.add('dragging');try{e.dataTransfer.setData('text/plain',drag.dataset.id)}catch(x){}});
$('grid').addEventListener('dragend',function(){if(drag){drag.classList.remove('dragging');drag.draggable=false}drag=null;
  document.querySelectorAll('.over').forEach(function(x){x.classList.remove('over')})});
$('grid').addEventListener('dragover',function(e){if(!drag)return;e.preventDefault();var o=e.target.closest('.w');
  document.querySelectorAll('.over').forEach(function(x){if(x!==o)x.classList.remove('over')});if(o&&o!==drag)o.classList.add('over')});
$('grid').addEventListener('drop',function(e){e.preventDefault();var o=e.target.closest('.w');if(!o||!drag||o===drag)return;
  var a=L.order.indexOf(drag.dataset.id);L.order.splice(a,1);L.order.splice(L.order.indexOf(o.dataset.id),0,drag.dataset.id);
  o.classList.remove('over');saveLayout();
  // move the dragged card's element itself, so nothing inside it is rebuilt
  o.parentNode.insertBefore(drag,o);renderAll()});
$('grid').addEventListener('click',function(e){
  var x=e.target.closest('.w h3 .x');if(x){var id=x.closest('.w').dataset.id;
    L.hidden=L.hidden.indexOf(id)>=0?L.hidden.filter(function(h){return h!==id}):L.hidden.concat([id]);saveLayout();renderAll();return}
  var ex=e.target.closest('.w h3 .ex');if(ex){expand(ex.closest('.w').dataset.id);return}
  if(usageToggle(e))return;
  var lane=e.target.closest('.wsrow');if(lane&&!lane.closest('#ov')){var ws=lane.dataset.lane,el=lane.closest('.body');
    var waiting=!!lane.querySelector('.w8');var cur=LX[ws]!==undefined?LX[ws]:waiting;LX[ws]=!cur;store('cel-v2-lanes',LX);renderAll();return}
  var ag=e.target.closest('[data-agent]');if(ag){openDrawer(ag.dataset.agent);return}
});
$('grid').addEventListener('change',function(e){var s=e.target.closest('select.size');if(!s)return;
  L.size[s.closest('.w').dataset.id]=s.value;saveLayout();renderAll()});
$('cust').onclick=function(){CUSTOM=!CUSTOM;document.body.classList.toggle('custom',CUSTOM);$('cust').textContent=CUSTOM?'✓ Done':'⊞ Customize';renderAll()};
$('wsf').onchange=function(e){WSF=e.target.value;store('cel-v2-ws',WSF);renderAll();refresh()};
$('nyjump').onclick=function(){var c=document.querySelector('#grid .w[data-id=needs]');if(c)c.scrollIntoView({behavior:'smooth',block:'start'})};

// ---- composer: talk to an orchestrator --------------------------------------
var KIND='task',TO=recall('cel-v2-to','celestial-orch');
var SENT=recall('cel-v2-sent',[]);
function renderComposer(){
  var list=orchs().filter(function(o){return inWs(o.ws)&&o.name!=='celestial-orch'});
  if(TO!=='celestial-orch'&&!list.some(function(o){return o.name===TO}))TO='celestial-orch';
  var cel=orchs().filter(function(o){return o.name==='celestial-orch'})[0];
  var html='<span class="sub">To</span> <button class="chip'+(TO==='celestial-orch'?' on':'')+'" data-o="celestial-orch" title="celestial-orch routes it to the right orchestrator"><span class="dot '+(cel&&cel.status==='working'?'ok':'idle')+'"></span>Any - celestial routes it</button>'+
    list.map(function(o){return '<button class="chip'+(o.name===TO?' on':'')+'" data-o="'+esc(o.name)+'" data-ws="'+esc(o.ws)+'"><span class="dot '+(o.status==='working'?'ok':'idle')+'"></span>'+esc(o.name.replace(/-orch$/,''))+'<span class="sub"> '+esc(o.ws)+'</span></button>'}).join('');
  var to=$('to');if(to._html!==html){to._html=html;to.innerHTML=html}
  var who=TO==='celestial-orch'?'celestial':TO.replace(/-orch$/,'');
  $('task').placeholder=KIND==='ask'?'Ask '+who+' anything - "where are we with the release?", "why is that PR stuck?"…':'Tell '+who+' what you want - it writes the spec, picks the worker and reports back…';
  $('chint').textContent=KIND==='ask'?'→ it answers in its inbox and here; no work starts':"→ goes to the orchestrator's inbox; it decides how to do it";
}
$('to').addEventListener('click',function(e){var b=e.target.closest('.chip');if(!b)return;TO=b.dataset.o;store('cel-v2-to',TO);renderComposer()});
Array.prototype.forEach.call(document.querySelectorAll('.ctabs span'),function(s){s.onclick=function(){
  Array.prototype.forEach.call(document.querySelectorAll('.ctabs span'),function(x){x.classList.remove('on')});s.classList.add('on');KIND=s.dataset.k;renderComposer()}});
$('go').onclick=async function(){
  var text=$('task').value.trim();if(!text){toast('type what you want first',false);return}
  var ws=(orchs().filter(function(o){return o.name===TO})[0]||{}).ws||'';
  var go=$('go');go.disabled=true;
  var r=await act('message',TO,{text:text,kind:KIND,urgent:$('curg').checked,ws:ws});
  go.disabled=false;
  if(!r.ok)return;
  SENT.unshift({to:TO,text:text,kind:KIND,at:new Date().toISOString()});SENT=SENT.slice(0,5);store('cel-v2-sent',SENT);
  $('task').value='';$('curg').checked=false;renderThread();
};
// Replies show as a thread under the message, read back from the inbox feed:
// anything the addressee sent after it.
function renderThread(){
  var inbox=(S&&S.inbox)||[];
  var html=SENT.map(function(m,i){
    var t=new Date(m.at).getTime(),next=i>0?new Date(SENT[i-1].at).getTime():Infinity;
    var rep=inbox.filter(function(x){var ts=new Date(x.ts).getTime();return (x.from===m.to||x.fromName===m.to)&&ts>=t&&ts<next});
    return '<div class="sentmsg"><span class="who">you → '+esc(m.to)+'</span> <span class="sub">'+(m.kind==='ask'?'question':'work')+' · '+hhmm(m.at)+'</span><div>'+esc(m.text)+'</div>'+
      (rep.length?rep.map(function(x){return '<div class="reply"><b>'+esc(x.fromName||x.from)+'</b> <span class="sub">'+hhmm(x.ts)+'</span><br>'+esc(x.message)+'</div>'}).join(''):'<div class="reply sub">waiting for a reply</div>')+'</div>'}).join('');
  var th=$('thread');if(th._html!==html){th._html=html;th.innerHTML=html}
}

// ---- agent drawer ----------------------------------------------------------
var DRAWER=null;
function findAgent(name){
  var w=workers().filter(function(x){return x.name===name})[0];
  if(w)return {name:name,ws:w.ws,status:w.status,pane:w.pane,pr:prOf(w),model:w.model,now:w.repo+'/'+w.branch};
  var o=orchs().filter(function(x){return x.name===name})[0];
  if(o)return {name:name,ws:o.ws,status:o.status,pane:o.pane,pr:null,model:'',now:o.status};
  return {name:name,ws:'',status:'unknown',pane:null,pr:null,model:'',now:''};
}
function openDrawer(name){DRAWER=name;$('drawer').classList.add('open');renderDrawer();remember('agent',name)}
function renderDrawer(){
  if(!DRAWER)return;var a=findAgent(DRAWER);
  var mail=((S&&S.inbox)||[]).filter(function(x){return x.to===a.name||x.toName===a.name});
  var lines=feedItems('activity').filter(function(x){return x.text.indexOf(a.name)>=0||(a.pr&&x.text.indexOf('#'+a.pr.number)>=0)}).slice(0,5);
  var html='<div class="sub">'+esc(a.ws)+(a.model?' · '+esc(a.model.split('/').pop()):'')+'</div><h4>Now</h4><div>'+esc(a.status||'')+(a.now&&a.now!==a.status?' · '+esc(a.now):'')+'</div>'+
    '<h4>Last lines</h4><pre class="mono tail">'+(lines.length?lines.map(function(x){return hhmm(x.ts)+' '+esc(x.text)}).join('\n'):'nothing recorded yet')+'</pre>'+
    '<h4>PR</h4><div>'+(a.pr?'<a href="'+esc(a.pr.url)+'" target="_blank" rel="noopener">'+esc(a.pr.repo+'#'+a.pr.number)+'</a> '+esc(a.pr.title)+' <span class="sub">'+esc(a.pr.review||'')+'</span>':'no PR yet')+'</div>'+
    '<h4>Inbox</h4><div>'+(mail.length?mail.slice(-3).map(function(x){return '<div class="sub">'+hhmm(x.ts)+' '+esc(x.fromName||x.from)+': '+esc(String(x.message).slice(0,140))+'</div>'}).join(''):'<span class="sub">nothing addressed to it</span>')+'</div>';
  $('dname').textContent=a.name;
  var di=$('dinfo');if(di._html!==html){di._html=html;di.innerHTML=html}
  $('dpane').disabled=!a.pane;
}
$('dclose').onclick=function(){DRAWER=null;$('drawer').classList.remove('open')};
$('dsend').onclick=async function(){var v=$('dmsg').value.trim();if(!v){toast('type a message',false);return}
  var a=findAgent(DRAWER);var r=await act('message',a.name,{text:v,kind:'task',urgent:false,ws:a.ws});if(r.ok)$('dmsg').value=''};
$('dpane').onclick=async function(){var a=findAgent(DRAWER);if(!a.pane)return;var r=await post('/api/focus',{pane:a.pane});toast(r.ok?'focused '+a.name:r.text,r.ok)};

// ---- expanded views ----------------------------------------------------------
var OV=null;          // id of the expanded card
var AQ={q:'',kind:'',ws:'',day:'',items:null,more:true};
var LRANGE='today';
function expand(id){
  var w=W.filter(function(x){return x.id===id})[0];OV=id;
  $('ovt').textContent=w.t;$('ovs').textContent=' · '+(WSF==='all'?'all workspaces':WSF);
  var b=$('ovb');b.innerHTML='';b._html=null;
  if(id==='needs'){
    b.innerHTML='<div class="ovctl"><label class="sub">sort <select class="nysort"><option value="urgent">urgent first, then oldest</option><option value="oldest">oldest first</option><option value="newest">newest first</option></select></label><span class="sub">filter by workspace with the chips; "accept all recommended" lists exactly what it will send</span></div>';
    b.querySelector('.nysort').value=NYSORT;
    b.querySelector('.nysort').onchange=function(e){NYSORT=e.target.value;store('cel-v2-nysort',NYSORT);buildLast();renderNeedsYou(true)};
    b.appendChild(needsHost());buildLast();renderNeedsYou(true);
  }else if(id==='activity'){
    AQ.items=null;AQ.more=true;
    b.innerHTML='<div class="ovctl"><input class="actq" placeholder="search"><select class="actkind"><option value="">every kind</option>'+
      ['merge','review','decision','incident','worker','orchestrator'].map(function(k){return '<option>'+k+'</option>'}).join('')+'</select>'+
      '<select class="actws"><option value="">every workspace</option></select><input type="date" class="actday"></div><div class="actlist"></div><button class="btn actmore">older →</button>';
    var sel=b.querySelector('.actws');[].slice.call($('wsf').options).slice(1).forEach(function(o){var x=document.createElement('option');x.textContent=o.value;sel.appendChild(x)});
    if(WSF!=='all')sel.value=WSF;
    b.querySelector('.actq').oninput=function(e){AQ.q=e.target.value.toLowerCase();drawActivity()};
    b.querySelector('.actkind').onchange=function(e){AQ.kind=e.target.value;drawActivity()};
    sel.onchange=function(e){AQ.ws=e.target.value;drawActivity()};
    b.querySelector('.actday').onchange=function(e){AQ.day=e.target.value;drawActivity()};
    b.querySelector('.actmore').onclick=moreActivity;
    AQ.ws=WSF==='all'?'':WSF;AQ.q='';AQ.kind='';AQ.day='';
    AQ.items=((F.activity||{}).items||[]).slice();drawActivity();
  }else if(id==='lanes'){
    b.innerHTML='<div class="ovctl"><label class="sub">range <select class="range"><option value="today">today</option><option value="3d">3 days</option><option value="week">week</option></select></label></div><div class="lanebody"></div>';
    b.querySelector('.range').value=LRANGE;
    b.querySelector('.range').onchange=function(e){LRANGE=e.target.value;loadLanes()};
    loadLanes();
  }else renderOverlay();
  $('ov').classList.add('open');
}
function drawActivity(){
  var b=$('ovb'),it=(AQ.items||[]).filter(function(r){
    return (!AQ.q||(r.text+' '+r.ws+' '+r.kind).toLowerCase().indexOf(AQ.q)>=0)&&(!AQ.kind||r.kind===AQ.kind)&&(!AQ.ws||r.ws===AQ.ws)&&
      (!AQ.day||String(r.ts).slice(0,10)===AQ.day)});
  var l=b.querySelector('.actlist');if(!l)return;
  l.innerHTML='<div class="feed">'+it.map(actRow).join('')+'</div>'+(it.length?'':none('nothing matches'));
  b.querySelector('.actmore').style.display=AQ.more?'':'none';
}
async function moreActivity(){
  var last=(AQ.items||[])[AQ.items.length-1];
  try{var d=await getJSON('/api/v2/activity?ws='+encodeURIComponent(WSF)+'&limit=50'+(last?'&before='+encodeURIComponent(last.ts):''));
    var add=(d.items||[]).filter(function(x){return !last||x.ts<last.ts});if(!add.length)AQ.more=false;AQ.items=AQ.items.concat(add)}catch(e){AQ.more=false}
  drawActivity();
}
async function loadLanes(){
  var d=F.lanes;
  if(LRANGE!=='today'){try{d=await getJSON('/api/v2/lanes?ws='+encodeURIComponent(WSF)+'&range='+LRANGE)}catch(e){d=null}}
  var lb=$('ovb').querySelector('.lanebody');if(lb)lb.innerHTML=lanesHtml(d,true);
}
function renderOverlay(){
  if(!OV||OV==='needs'||OV==='activity'||OV==='lanes')return;
  var html='<div class="w ovcard" data-id="'+OV+'">'+BODY[OV](true)+'</div>';
  var b=$('ovb');if(b._html!==html){b._html=html;b.innerHTML=html;restoreArmed(b)}
}
function closeOverlay(){
  if(!OV)return;
  if(OV==='needs'){var c=document.querySelector('#grid .w[data-id=needs] .body');if(c)c.appendChild(needsHost());renderNeedsYou(true)}
  OV=null;$('ov').classList.remove('open');$('ovb').innerHTML='';
}
$('ovx').onclick=closeOverlay;
$('ov').addEventListener('click',function(e){if(e.target.id==='ov')closeOverlay();
  if(usageToggle(e))return;
  var ag=e.target.closest('[data-agent]');if(ag)openDrawer(ag.dataset.agent)});

// ---- ⌘K palette ----------------------------------------------------------
var RECENT=recall('cel-v2-recent',[]);
function remember(kind,key){RECENT=[kind+'|'+key].concat(RECENT.filter(function(x){return x!==kind+'|'+key})).slice(0,8);store('cel-v2-recent',RECENT)}
function palItems(){
  var it=[];
  ((S&&S.needsYou)||[]).forEach(function(d){if(!NYDONE[d.id])it.push({k:'decision',ws:d.workspace,text:d.title,key:d.id})});
  prRows().forEach(function(p){it.push({k:'PR',ws:p.ws,text:p.repo+'#'+p.number+' '+p.title,key:p.repo+'#'+p.number,url:p.url})});
  workers().forEach(function(w){it.push({k:'agent',ws:w.ws,text:w.name,key:w.name})});
  orchs().forEach(function(o){it.push({k:'agent',ws:o.ws,text:o.name,key:o.name})});
  ((F.stuck||{}).items||[]).forEach(function(s){it.push({k:'stuck',ws:s.ws,text:s.ref+' - '+s.reason,key:s.ref})});
  it.push({k:'action',ws:'',text:'Give work…',key:'compose'});
  it.push({k:'action',ws:'',text:'Go away (away mode on)',key:'afk.on',act:'afk.on'});
  it.push({k:'action',ws:'',text:"I'm back (away mode off)",key:'afk.off',act:'afk.off'});
  it.push({k:'action',ws:'',text:'Mark everything as seen',key:'seen',act:'seen'});
  orchs().forEach(function(o){it.push({k:'action',ws:o.ws,text:'Restart '+o.name,key:'restart '+o.name,act:'orch.restart',target:o.name})});
  return it.filter(function(x){return !x.ws||inWs(x.ws)});
}
var palIdx=0,PR=[],PARM=null;
function pal(open){$('pal').classList.toggle('open',open);PARM=null;if(open){$('pq').value='';palIdx=0;pres();$('pq').focus()}}
function pres(){
  var q=$('pq').value.toLowerCase().trim(),all=palItems();
  var r;
  if(!q){var rec=RECENT.map(function(k){return all.filter(function(x){return x.k+'|'+x.key===k})[0]}).filter(Boolean);
    r=rec.concat(all.filter(function(x){return rec.indexOf(x)<0}))}
  else{var words=q.split(/\s+/);r=all.filter(function(x){var h=(x.k+' '+x.text+' '+x.ws).toLowerCase();return words.every(function(w){return h.indexOf(w)>=0})})}
  PR=r.slice(0,10);palIdx=Math.min(palIdx,Math.max(0,PR.length-1));
  $('pres').innerHTML=PR.map(function(p,i){return '<div class="pr'+(i===palIdx?' on':'')+'" data-i="'+i+'"'+(p.ws?' data-ws="'+esc(p.ws)+'"':'')+'><span class="k">'+esc(p.k)+'</span> '+esc(p.text)+'<span class="spacer"></span>'+(p.ws?'<span class="sub">'+esc(p.ws)+'</span>':'')+(PARM===p.k+'|'+p.key?' <b class="armed">Enter again to confirm</b>':'')+'</div>'}).join('')||'<div class="pr sub">no match</div>';
}
function palOpen(p){
  if(!p)return;
  if(p.act){ // actions confirm with two presses
    var id=p.k+'|'+p.key;
    if(PARM!==id){PARM=id;pres();return}
    PARM=null;pal(false);remember(p.k,p.key);act(p.act,p.target||'',{});return;
  }
  pal(false);remember(p.k,p.key);
  if(p.k==='decision'){
    if(OV)closeOverlay();
    V2OPEN[p.key]=1;renderNeedsYou(true);
    var c=document.querySelector('#needsyou .nycard[data-id="'+p.key+'"]');
    if(c){c.classList.add('open','flash');c.scrollIntoView({block:'center'});setTimeout(function(){c.classList.remove('flash')},1600);
      var o=c.querySelector('button.opt');if(o)o.focus({preventScroll:true})}
  }else if(p.k==='agent')openDrawer(p.key);
  else if(p.k==='PR'){var row=document.querySelector('#grid [data-pr="'+p.key+'"]');if(row){row.scrollIntoView({block:'center'});row.classList.add('flash')}
    else if(p.url)window.open(p.url,'_blank','noopener')}
  else if(p.k==='stuck'){var s=document.querySelector('#grid [data-ref="'+p.key+'"]');if(s)s.scrollIntoView({block:'center'})}
  else if(p.key==='compose'){$('task').focus();$('task').scrollIntoView({block:'center'})}
}
$('pq').oninput=function(){palIdx=0;PARM=null;pres()};
$('pres').addEventListener('click',function(e){var r=e.target.closest('.pr[data-i]');if(r){palIdx=+r.dataset.i;palOpen(PR[palIdx])}});
$('pal').addEventListener('click',function(e){if(e.target.id==='pal')pal(false)});
$('search').onclick=function(){pal(true)};
document.addEventListener('keydown',function(e){
  if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='k'){e.preventDefault();pal(!$('pal').classList.contains('open'));return}
  if($('pal').classList.contains('open')){
    if(e.key==='Escape'){pal(false);return}
    if(e.key==='ArrowDown'){e.preventDefault();palIdx=Math.min(palIdx+1,PR.length-1);PARM=null;pres()}
    if(e.key==='ArrowUp'){e.preventDefault();palIdx=Math.max(0,palIdx-1);PARM=null;pres()}
    if(e.key==='Enter'){e.preventDefault();palOpen(PR[palIdx])}
    return;
  }
  if(e.key==='Escape'){if(OV)closeOverlay();else if(DRAWER)$('dclose').onclick()}
});

// ---- boot --------------------------------------------------------------------
renderAll();
snapshot();
refresh();
setInterval(function(){if(!document.hidden)refresh()},REFRESH_MS);
