// The decisions panel (CEL-99/#125, CEL-101/#127), shared by the classic
// dashboard and v2 (CEL-106). It used to live inline in the classic page; v2
// needed the same two-click confirm, refresh-safe typing and "closed
// elsewhere", and a second copy is how one of them would quietly regress. So
// both pages load this file and supply the same small host contract:
//   $(id), esc(s), post(path, body), toast(text, ok), refreshTabs(),
//   LAST (with needsYou / needsYouGroups), #needsyou and #alerts-h elements.
// ---- needs you (CEL-99) -------------------------------------------------
// The choice, not the chrome: each option is a button with its tradeoff
// printed under it (a hover title is invisible on a phone), the recommended
// one is primary, and free text / drop hide behind one "other…" per card.
// No browser confirm dialog: a first click arms the button ("send: <label>?") for
// a few seconds and a second click sends - one step, still deliberate.
var NYF=localStorage.getItem('cel-ny-filter')||'';
var NYC=JSON.parse(localStorage.getItem('cel-ny-collapsed')||'{}');
var NYERR={};          // id -> reason the last send failed; stays on screen
var NYBULK=null;       // workspace whose "accept all" list is open
// WHAT THE OWNER IS DOING SURVIVES A REFRESH (CEL-101). The panel is rebuilt
// from innerHTML whenever its data changes, and the owner lost a half-typed
// answer within seconds: a new decision arriving anywhere repainted the list,
// closing "other…", dropping the text, the focus and an armed button. So the
// rebuild snapshots each card's state by decision id and puts it back, armed
// buttons live here rather than on an element the rebuild throws away, and a
// card the owner was working on that closed elsewhere stays on screen marked
// "closed elsewhere" instead of vanishing mid-sentence.
var NYARM={};          // id|key -> {label, timer}: an armed button, by identity
var NYGONE={};         // id -> decision closed elsewhere while being worked on
var NYDONE={};         // id -> 1: closed from this page, never "elsewhere"
var NYSEEN={};         // id -> the decision as last drawn
function nyAge(s){s=s||0;return s<3600?Math.round(s/60)+'m':s<86400?Math.round(s/3600)+'h':Math.round(s/86400)+'d'}
function nyRec(d){var n=d.recommended;return n&&d.options&&d.options[n-1]?{n:n,label:d.options[n-1].label}:null}
function nyCard(d){
  var gone=!!NYGONE[d.id];
  var ctx=d.context?(/^https?:/.test(d.context)?'<a href="'+esc(d.context)+'" target="_blank" rel="noopener">context ↗</a>':esc(d.context)):'';
  var rec=nyRec(d);
  return '<article class="nycard'+(d.urgent?' urgent':'')+(gone?' gone':'')+'" data-id="'+esc(d.id)+'">'+
    (gone?'<div class="nygone">closed elsewhere \u2014 nothing here will be sent <button class="dismiss">dismiss</button></div>':'')+
    '<div class="nyhead">'+(d.urgent?'<span class="tag urgent">urgent</span>':'')+
      '<b class="nytitle">'+esc(d.title)+'</b></div>'+
    '<div class="nymeta">'+esc(d.asker||'')+' \u00b7 '+nyAge(d.age_secs)+
      (d.blocks?' \u00b7 <span class="blocks">blocks: '+esc(d.blocks)+'</span>':'')+(ctx?' \u00b7 '+ctx:'')+'</div>'+
    '<div class="nyopts">'+(d.options||[]).map(function(o,i){
      var r=d.recommended===i+1;
      return '<button class="opt'+(r?' rec':'')+'" data-n="'+(i+1)+'" data-label="'+esc(o.label)+'">'+
        '<span class="lbl">'+esc(o.label)+(r?' <span class="tag">recommended</span>':'')+'</span>'+
        (o.tradeoff?'<span class="trade">'+esc(o.tradeoff)+'</span>':'')+'</button>'}).join('')+'</div>'+
    '<div class="nyact">'+(rec?'<button class="accept" data-n="'+rec.n+'" data-label="'+esc(rec.label)+'">accept recommended</button>':'')+
    '<details class="other"><summary>other\u2026</summary>'+
      '<div class="otherrow"><input class="free" placeholder="free-text answer"><button class="send">answer</button></div>'+
      '<div class="otherrow"><input class="why" placeholder="reason to drop"><button class="drop">drop</button></div>'+
      // CEL-101: most stale questions are stale for one of two reasons; saying
      // so should not need typing. Same arm-then-send, same guarded endpoint.
      '<div class="otherrow"><button class="close" data-why="already done">already done</button>'+
        '<button class="close" data-why="no longer needed">no longer needed</button></div></details></div>'+
    (NYERR[d.id]?'<div class="nyerr">not sent: '+esc(NYERR[d.id])+'</div>':'')+
    '</article>';
}
function nyLive(d){return !NYGONE[d.id]}
function nyBulkPanel(g){
  var list=g.items.filter(nyLive).filter(nyRec);
  return '<div class="nybulk"><p>Send these '+list.length+' answers?</p><ol>'+list.map(function(d){
    return '<li><b>'+esc(nyRec(d).label)+'</b> \u2190 '+esc(d.title)+'</li>'}).join('')+'</ol>'+
    '<button class="bulksend primary" data-ws="'+esc(g.workspace)+'">send '+list.length+'</button> '+
    '<button class="bulkcancel">cancel</button></div>';
}
// A button's identity across a rebuild: its card and what it is.
function nyKey(btn){
  var card=btn.closest('.nycard');
  // the label is part of the identity: an option renamed while armed must
  // disarm, never confirm one text and send another
  return (card?card.dataset.id:'')+'|'+btn.className.replace(' armed','')+'|'+(btn.dataset.n||'')+'|'+(btn.dataset.label||btn.dataset.why||'');
}
function nyFind(key){
  var host=$('needsyou'),all=host.querySelectorAll('.nycard button');
  for(var i=0;i<all.length;i++)if(nyKey(all[i])===key)return all[i];
  return null;
}
function nyShowArmed(btn,label){
  if(!btn.dataset.orig)btn.dataset.orig=btn.innerHTML;
  btn.classList.add('armed');btn.textContent='send: '+label+'?';
}
function arm(btn,label,fn){
  var key=nyKey(btn);
  if(NYARM[key]){clearTimeout(NYARM[key].timer);delete NYARM[key];btn.classList.remove('armed');fn();return}
  nyShowArmed(btn,label);
  NYARM[key]={label:label,timer:setTimeout(function(){
    delete NYARM[key];var b=nyFind(key);
    if(b){b.classList.remove('armed');if(b.dataset.orig){b.innerHTML=b.dataset.orig;delete b.dataset.orig}}},4000)};
}
// Everything the owner has open, typed or focused, per decision id.
function nySnap(host){
  var snap={},a=document.activeElement;
  Array.prototype.forEach.call(host.querySelectorAll('.nycard'),function(card){
    var o=card.querySelector('details.other'),fr=card.querySelector('.free'),wh=card.querySelector('.why');
    var x={open:!!(o&&o.open),free:fr?fr.value:'',why:wh?wh.value:'',focus:null,s:0,e:0};
    [['free',fr],['why',wh]].forEach(function(p){if(p[1]&&a===p[1]){x.focus=p[0];x.s=p[1].selectionStart;x.e=p[1].selectionEnd}});
    var grp=card.closest('details.nygroup');
    x.busy=x.open||!!x.free||!!x.why||!!x.focus||Object.keys(NYARM).some(function(k){return k.indexOf(card.dataset.id+'|')===0})
      // listed in an open bulk preview is being worked on too
      ||!!(NYBULK&&grp&&grp.dataset.ws===NYBULK&&card.querySelector('button.accept'));
    snap[card.dataset.id]=x;
  });
  return snap;
}
function nyRestore(host,snap){
  Array.prototype.forEach.call(host.querySelectorAll('.nycard'),function(card){
    var x=snap[card.dataset.id];if(!x)return;
    var o=card.querySelector('details.other');if(o&&x.open)o.open=true;
    var fr=card.querySelector('.free'),wh=card.querySelector('.why');
    if(fr)fr.value=x.free;if(wh)wh.value=x.why;
    var f=x.focus==='free'?fr:x.focus==='why'?wh:null;
    if(f){f.focus();try{f.setSelectionRange(x.s,x.e)}catch(e){}}
  });
  Object.keys(NYARM).forEach(function(k){var b=nyFind(k);
    if(b)nyShowArmed(b,NYARM[k].label);else{clearTimeout(NYARM[k].timer);delete NYARM[k]}});
}
function nyDrop(id){
  LAST.needsYou=(LAST.needsYou||[]).filter(function(d){return d.id!==id});
  (LAST.needsYouGroups||[]).forEach(function(g){g.items=g.items.filter(function(d){return d.id!==id});g.count=g.items.length});
  delete NYERR[id];delete NYGONE[id];NYDONE[id]=1;
}
async function nySend(card,body){
  var ctl=card.querySelectorAll('button,input');
  Array.prototype.forEach.call(ctl,function(c){c.disabled=true});
  var r;
  try{r=await post('/api/decide',body)}catch(e){r={ok:false,text:(e&&e.message)||String(e)}}
  toast(r.ok?(body.action==='drop'?'dropped':'answered'):r.text,r.ok);
  if(r.ok)nyDrop(body.id);else NYERR[body.id]=r.text;
  renderNeedsYou(true);refreshTabs();
}
function refreshTabs(){if(LAST)renderTabs(LAST)}
function renderNeedsYou(force){
  if(!LAST)return;
  var host=$('needsyou');
  // a card being worked on that is no longer open was closed elsewhere: keep
  // it, marked, in its group until the owner dismisses it
  var live={};(LAST.needsYou||[]).forEach(function(d){live[d.id]=1});
  var snap0=nySnap(host);
  Object.keys(snap0).forEach(function(id){
    if(snap0[id].busy&&!live[id]&&!NYDONE[id]&&NYSEEN[id]&&!NYGONE[id])NYGONE[id]=NYSEEN[id]});
  Object.keys(NYGONE).forEach(function(id){if(live[id])delete NYGONE[id]});
  var groups=(LAST.needsYouGroups||[]).map(function(g){return {workspace:g.workspace,urgent:g.urgent,items:g.items.slice()}});
  Object.keys(NYGONE).forEach(function(id){
    var d=NYGONE[id],g=groups.filter(function(x){return x.workspace===d.workspace})[0];
    if(!g){g={workspace:d.workspace,urgent:0,items:[]};groups.push(g)}
    g.items.push(d)});
  groups=groups.filter(function(g){return g.items.length});
  if(NYF&&!groups.some(function(g){return g.workspace===NYF}))NYF='';
  var sig=JSON.stringify([NYF,NYBULK,NYC,NYERR,Object.keys(NYGONE),groups.map(function(g){return g.items.map(function(d){return [d.id,d.updated||'',d.urgent]})})]);
  // a refresh every few seconds must not close an open "other…" or disarm a
  // button mid-confirm: repaint only when something actually changed, and
  // then put back what the owner had open (nyRestore below)
  if(!force&&host.dataset.sig===sig)return;
  host.dataset.sig=sig;
  groups.forEach(function(g){g.items.forEach(function(d){if(!NYGONE[d.id])NYSEEN[d.id]=d})});
  var total=groups.reduce(function(a,g){return a+g.items.filter(function(d){return !NYGONE[d.id]}).length},0);
  if(!total&&!Object.keys(NYGONE).length){host.innerHTML='';$('alerts-h').style.display='none';return}
  $('alerts-h').style.display='';
  var chips='<div class="nychips"><button class="chipbtn'+(NYF?'':' on')+'" data-ws="">all <b>'+total+'</b></button>'+
    groups.map(function(g){return '<button class="chipbtn'+(NYF===g.workspace?' on':'')+'" data-ws="'+esc(g.workspace)+'">'+
      esc(g.workspace)+' <b>'+g.items.filter(nyLive).length+'</b>'+(g.urgent?' <i class="u">!</i>':'')+'</button>'}).join('')+'</div>';
  host.innerHTML='<h2>decisions <span class="n">'+total+'</span></h2>'+chips+groups.filter(function(g){return !NYF||g.workspace===NYF}).map(function(g){
    var nrec=g.items.filter(nyLive).filter(nyRec).length;
    return '<details class="nygroup" data-ws="'+esc(g.workspace)+'"'+(NYC[g.workspace]?'':' open')+'>'+
      '<summary><span class="ws">'+esc(g.workspace)+'</span><span class="n">'+g.items.filter(nyLive).length+'</span>'+
      (nrec?'<button class="bulk" data-ws="'+esc(g.workspace)+'">accept all recommended ('+nrec+')</button>':'')+'</summary>'+
      (NYBULK===g.workspace?nyBulkPanel(g):'')+
      g.items.map(nyCard).join('')+'</details>';
  }).join('');
  Array.prototype.forEach.call(host.querySelectorAll('.chipbtn'),function(b){
    b.onclick=function(){NYF=b.dataset.ws;localStorage.setItem('cel-ny-filter',NYF);renderNeedsYou(true)}});
  Array.prototype.forEach.call(host.querySelectorAll('details.nygroup'),function(dt){
    // a group drawn open fires a toggle of its own; only the owner's toggles
    // count, or every repaint cleared the signature and the next refresh
    // repainted again - the loop that ate typed text every few seconds
    dt.ontoggle=function(){if(dt.open===!NYC[dt.dataset.ws])return;
      if(dt.open)delete NYC[dt.dataset.ws];else NYC[dt.dataset.ws]=1;
      localStorage.setItem('cel-ny-collapsed',JSON.stringify(NYC));host.dataset.sig=''}});
  Array.prototype.forEach.call(host.querySelectorAll('button.bulk'),function(b){
    b.onclick=function(e){e.preventDefault();e.stopPropagation();NYBULK=NYBULK===b.dataset.ws?null:b.dataset.ws;renderNeedsYou(true)}});
  var cancel=host.querySelector('button.bulkcancel');
  if(cancel)cancel.onclick=function(){NYBULK=null;renderNeedsYou(true)};
  var bsend=host.querySelector('button.bulksend');
  if(bsend)bsend.onclick=async function(){
    var g=groups.filter(function(x){return x.workspace===bsend.dataset.ws})[0];
    // the ids and options sent are exactly the ones the list above showed
    var items=g.items.filter(nyLive).filter(nyRec).map(function(d){return {id:d.id,option:nyRec(d).n}});
    bsend.disabled=true;bsend.textContent='sending\u2026';
    var r,res=[];
    try{r=await post('/api/decide-bulk',{items:items});res=r.ok?JSON.parse(r.text).results:[]}catch(e){r={ok:false,text:(e&&e.message)||String(e)}}
    if(!r.ok)items.forEach(function(it){NYERR[it.id]=r.text});
    var ok=0;res.forEach(function(x){if(x.ok){ok++;nyDrop(x.id)}else NYERR[x.id]=x.error||'refused'});
    toast(ok+' of '+items.length+' answered',ok===items.length);
    NYBULK=null;renderNeedsYou(true);refreshTabs();
  };
  Array.prototype.forEach.call(host.querySelectorAll('.nycard'),function(card){
    var id=card.dataset.id;
    if(NYGONE[id]){
      // closed elsewhere: the text stays readable, nothing here can send
      Array.prototype.forEach.call(card.querySelectorAll('.nyopts button,.nyact button'),function(b){b.disabled=true});
      card.querySelector('button.dismiss').onclick=function(){delete NYGONE[id];NYDONE[id]=1;renderNeedsYou(true)};
      return;
    }
    Array.prototype.forEach.call(card.querySelectorAll('button.close'),function(b){
      b.onclick=function(){arm(b,b.dataset.why,function(){nySend(card,{id:id,action:'drop',value:b.dataset.why})})}});
    Array.prototype.forEach.call(card.querySelectorAll('button.opt,button.accept'),function(b){
      b.onclick=function(){arm(b,b.dataset.label,function(){nySend(card,{id:id,action:'answer',option:+b.dataset.n})})}});
    card.querySelector('button.send').onclick=function(){
      var v=card.querySelector('.free').value.trim();if(!v){toast('type an answer',false);return}
      arm(this,v,function(){nySend(card,{id:id,action:'answer',value:v})})};
    card.querySelector('button.drop').onclick=function(){
      var v=card.querySelector('.why').value.trim();if(!v){toast('give a reason',false);return}
      arm(this,'drop',function(){nySend(card,{id:id,action:'drop',value:v})})};
  });
  nyRestore(host,snap0);
  // v2 folds each card to its title until opened; the fold is put back here
  if(typeof nyAfterRender==='function')nyAfterRender(host);
}
