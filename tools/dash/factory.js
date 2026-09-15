/* The factory is a view of reported work, not a progress simulator. */
(() => {
  const bays = [
    { id: 'intake', name: 'Intake', subtitle: 'Awaiting the next turn', code: '01' },
    { id: 'build', name: 'Build bay', subtitle: 'Agents at work', code: '02' },
    { id: 'checks', name: 'Test lab', subtitle: 'Reported CI checks', code: '03' },
    { id: 'review', name: 'Review', subtitle: 'Human & agent inspection', code: '04' },
    { id: 'ready', name: 'Dispatch', subtitle: 'Ready for a merge decision', code: '05' },
    { id: 'hold', name: 'Holding area', subtitle: 'Blocked or awaiting signal', code: '06' },
  ];
  const views = new WeakMap();
  const esc = (value) => String(value ?? '').replace(/[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const short = (value, length) => {
    const text = String(value ?? '');
    return text.length > length ? text.slice(0, length - 1) + '…' : text;
  };
  const webLink = (value) => {
    try { const url = new URL(value); return ['https:', 'http:'].includes(url.protocol) ? url.href : null; }
    catch { return null; }
  };

  function workOrder(work) {
    const pr = work.pr;
    let bay = 'hold', reason = 'No current agent or PR signal', tone = 'unknown';
    if (work.status === 'blocked') {
      reason = 'Agent needs input'; tone = 'blocked';
    } else if (pr?.checks === 'failing') {
      reason = 'CI checks failing' + (work.status === 'working' ? ' · agent working' : ''); tone = 'blocked';
    } else if (pr?.review === 'CHANGES_REQUESTED') {
      reason = 'Review requested changes' + (work.status === 'working' ? ' · agent working' : ''); tone = 'blocked';
    } else if (work.status === 'working') {
      bay = 'build'; reason = work.shape === 'scout' ? 'Research agent working' : 'Agent working'; tone = 'working';
    } else if (pr?.checks === 'pending') {
      bay = 'checks'; reason = 'CI checks pending'; tone = 'waiting';
    } else if (pr && !pr.draft && pr.review === 'APPROVED' && pr.checks === 'green') {
      bay = 'ready'; reason = 'Approved · checks green · not merged'; tone = 'ready';
    } else if (pr && !pr.draft && pr.review === 'APPROVED') {
      bay = 'checks'; reason = 'Approved · checks not reported'; tone = 'unknown';
    } else if (pr && !pr.draft) {
      bay = 'review'; reason = 'Awaiting review' + (pr.checks === 'green' ? ' · checks green' : ''); tone = 'waiting';
    } else if (pr?.draft) {
      bay = 'build'; reason = 'Draft PR · no active turn reported'; tone = 'waiting';
    } else if (work.status === 'idle' || work.status === 'done') {
      bay = 'intake'; reason = work.status === 'done' ? 'Turn ended · no PR reported' : 'Agent idle · no PR reported'; tone = 'waiting';
    }
    return { work, bay, reason, tone, key: JSON.stringify([work.repo, work.branch]) };
  }

  function machine(bay, count, busy, x) {
    const robot = bay.id === 'build' ? '<g class="factory-robot"><path d="M -14 -111 L 9 -148 L 43 -126 L 25 -101"/><circle cx="9" cy="-148" r="6"/><circle cx="43" cy="-126" r="5"/><path d="M 17 -99 L 25 -91 L 33 -104"/></g>' : '';
    const scanner = bay.id === 'checks' ? '<path class="factory-scanner" d="M -42 -87 L -42 -133 L 42 -91 L 42 -46"/>' : '';
    const roof = bay.id === 'review' ? '<path class="factory-roof-mark" d="M -23 -99 L -4 -89 L 18 -100 M -23 -89 L -4 -79 L 18 -90"/>' :
      bay.id === 'ready' ? '<path class="factory-roof-mark" d="M -24 -92 L -4 -81 L 27 -98 M -4 -81 L -4 -98"/>' : '';
    return `<g class="factory-station factory-bay-${bay.id}${busy ? ' is-running' : ''}" transform="translate(${x} 204)" aria-hidden="true">
      <text class="factory-station-code" x="-91" y="-175">${bay.code} / ${bay.id === 'hold' ? 'EXCEPTIONS' : 'PRODUCTION'}</text>
      <text class="factory-station-name" x="-91" y="-151">${bay.name}</text>
      <text class="factory-station-count" x="87" y="-151" text-anchor="end">${count}</text>
      <path class="factory-plinth-side" d="M -100 0 L 0 50 L 100 0 L 100 15 L 0 65 L -100 15 Z"/>
      <path class="factory-plinth" d="M -100 0 L 0 -50 L 100 0 L 0 50 Z"/>
      <path class="factory-machine-left" d="M -57 -88 L 0 -59 L 0 0 L -57 -29 Z"/>
      <path class="factory-machine-right" d="M 0 -59 L 57 -88 L 57 -29 L 0 0 Z"/>
      <path class="factory-machine-top" d="M -57 -88 L 0 -117 L 57 -88 L 0 -59 Z"/>
      <path class="factory-window" d="M -43 -70 L -12 -54 L -12 -37 L -43 -53 Z"/>
      <path class="factory-window-lines" d="M -38 -62 L -18 -52 M -38 -56 L -26 -50"/>
      <path class="factory-door" d="M 17 -42 L 40 -54 L 40 -22 L 17 -10 Z"/>
      <path class="factory-panel-lines" d="M -45 -37 L -13 -21 M -45 -30 L -13 -14"/>
      <circle class="factory-beacon" cx="43" cy="-73" r="4"/>
      ${robot}${scanner}${roof}
      <text class="factory-station-subtitle" x="0" y="89" text-anchor="middle">${esc(bay.subtitle)}</text>
    </g>`;
  }

  function piece(order, index, x, y, selected) {
    const w = order.work;
    const label = w.ticket?.id || w.branch || 'Unnamed work';
    return `<g class="factory-piece tone-${order.tone}${selected ? ' is-selected' : ''}" transform="translate(${x} ${y})"
      role="button" tabindex="0" data-order="${index}" aria-pressed="${selected}" aria-label="${esc(`${w.repo}/${w.branch}: ${order.reason}. Inspect work order`)}">
      <title>${esc(`${w.repo}/${w.branch}\n${w.pr?.title || ''}\n${order.reason}`)}</title>
      <ellipse class="factory-piece-shadow" cx="0" cy="26" rx="88" ry="28"/>
      <path class="factory-crate-left" d="M -77 -23 L 0 16 L 0 38 L -77 -1 Z"/>
      <path class="factory-crate-right" d="M 0 16 L 77 -23 L 77 -1 L 0 38 Z"/>
      <path class="factory-crate-top" d="M -77 -23 L 0 -62 L 77 -23 L 0 16 Z"/>
      <path class="factory-crate-seam" d="M -38 -42 L 39 -3 M -12 -55 L 65 -16"/>
      <rect class="factory-piece-label" x="-83" y="-10" width="166" height="43" rx="7"/>
      <circle class="factory-piece-light" cx="-69" cy="4" r="3"/>
      <text class="factory-piece-id" x="-59" y="9">${esc(short(label, 19))}</text>
      <text class="factory-piece-repo" x="-69" y="24">${esc(short(w.repo, 25))}</text>
      <text class="factory-piece-status" x="0" y="58" text-anchor="middle">${esc(short(order.reason, 30))}</text>
    </g>`;
  }

  function detail(host, view) {
    const panel = host.querySelector('.factory-detail');
    const order = view.orders.find((item) => item.key === view.selected);
    if (!order) {
      panel.innerHTML = '<div class="factory-detail-hint"><span class="factory-crosshair" aria-hidden="true"></span><div><strong>Inspect a work order</strong><p>Select a crate to see its agent, branch and delivery signals.</p></div></div>';
      return;
    }
    const w = order.work;
    const prUrl = webLink(w.pr?.url), ticketUrl = webLink(w.ticket?.url);
    panel.innerHTML = `<div class="factory-detail-copy"><div class="factory-eyebrow">WORK ORDER / ${esc(w.ticket?.id || w.repo)}</div>
      <h3>${esc(w.pr?.title || w.branch)}</h3><p class="factory-detail-branch">${esc(w.repo)}/${esc(w.branch)}</p>
      <div class="factory-detail-signals"><span class="factory-signal tone-${order.tone}">${esc(order.reason)}</span>
      <span>${esc(w.agent || 'No agent reported')}${w.model ? ' · ' + esc(w.model) : ''}</span></div></div>
      <div class="factory-detail-actions">${prUrl ? `<a href="${esc(prUrl)}" target="_blank" rel="noopener noreferrer">Open PR #${esc(w.pr.number)} ↗</a>` : ''}
      ${ticketUrl ? `<a href="${esc(ticketUrl)}" target="_blank" rel="noopener noreferrer">Open ticket ↗</a>` : ''}
      ${w.pane ? '<button type="button" data-focus-worker>Focus worker</button>' : ''}
      <button type="button" data-task-list>Task list</button><span class="factory-action-status" role="status"></span></div>`;
    panel.querySelector('[data-task-list]').onclick = view.actions.list;
    const focus = panel.querySelector('[data-focus-worker]');
    if (focus) focus.onclick = async () => {
      focus.disabled = true;
      const message = panel.querySelector('.factory-action-status');
      try {
        const result = await view.actions.focus(w.pane);
        message.textContent = result.ok ? 'Worker pane focused' : 'Could not focus worker: ' + result.text;
      } catch { message.textContent = 'Could not reach the worker'; }
      finally { focus.disabled = false; }
    };
  }

  function render(host, state, actions) {
    let view = views.get(host);
    if (!view) { view = { selected: null, signature: '', orders: [], actions }; views.set(host, view); }
    view.actions = actions;
    const orders = (state.inflight || []).map(workOrder);
    const signature = JSON.stringify(orders);
    if (signature === view.signature && host.querySelector('.factory-map')) return;
    view.signature = signature;
    view.orders = orders;
    if (!orders.some((order) => order.key === view.selected)) view.selected = null;
    const groups = bays.map((bay) => orders.map((order, index) => ({ order, index })).filter((item) => item.order.bay === bay.id));
    const rows = Math.max(1, ...groups.map((group) => group.length));
    const height = orders.length ? 355 + rows * 128 : 390;
    const active = orders.filter((order) => order.work.status === 'working').length;
    const held = orders.filter((order) => order.bay === 'hold').length;
    const ready = orders.filter((order) => order.bay === 'ready').length;
    host.innerHTML = `<div class="factory-heading"><div><div class="factory-eyebrow">CELESTIAL / AI SOFTWARE FACTORY</div>
      <h2>The factory floor</h2><p>From a work order to a reviewed change. One crate, one task.</p></div>
      <div class="factory-shift"><span class="${active ? 'is-active' : ''}"></span>${active ? active + ' agent' + (active === 1 ? '' : 's') + ' working' : 'No active turns reported'}</div></div>
      <div class="factory-rail"><span><b>${orders.length}</b> work orders</span><span><b>${held}</b> on hold</span><span><b>${ready}</b> ready for merge</span>
      <button type="button" data-factory-list>View task list <span aria-hidden="true">→</span></button></div>
      <div class="factory-map" tabindex="0" role="region" aria-label="Isometric factory floor. Scroll to explore all work orders.">
      <svg viewBox="0 0 1440 ${height}" role="group" aria-label="${orders.length} real work orders across six factory stations">
        <defs><pattern id="factory-grid" width="80" height="40" patternUnits="userSpaceOnUse"><path d="M0 20 L40 0 L80 20 L40 40 Z" fill="none"/></pattern></defs>
        <rect class="factory-grid" width="1440" height="${height}" fill="url(#factory-grid)"/>
        <path class="factory-belt-base" d="M118 193 H1322 V215 H118 Z"/>
        <path class="factory-belt${active ? ' is-running' : ''}" d="M118 204 H1322"/>
        ${bays.map((bay, i) => machine(bay, groups[i].length, groups[i].some(({ order }) => order.tone === 'working'), 120 + i * 240)).join('')}
        ${groups.map((group, column) => group.map(({ order, index }, row) => piece(order, index, 120 + column * 240, 361 + row * 128, order.key === view.selected)).join('')).join('')}
      </svg>${orders.length ? '' : '<div class="factory-empty"><strong>The floor is clear.</strong><p>Work orders appear when a worker or open PR is reported.</p></div>'}</div>
      <div class="factory-legend"><span><i class="tone-working"></i>Agent working</span><span><i class="tone-waiting"></i>Waiting</span><span><i class="tone-blocked"></i>Needs attention</span><span><i class="tone-unknown"></i>Signal missing</span><span><i class="tone-ready"></i>Ready, not merged</span><small>Stations follow reported agent, PR and CI signals — not percentage estimates. Scroll the floor to explore.</small></div>
      <div class="factory-detail" aria-live="polite"></div>`;
    host.querySelector('[data-factory-list]').onclick = actions.list;
    host.querySelectorAll('[data-order]').forEach((node) => {
      const select = () => {
        view.selected = orders[Number(node.dataset.order)].key;
        host.querySelectorAll('[data-order]').forEach((item) => {
          const selected = item === node;
          item.classList.toggle('is-selected', selected);
          item.setAttribute('aria-pressed', String(selected));
        });
        detail(host, view);
      };
      node.onclick = select;
      node.onkeydown = (event) => {
        if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); select(); }
      };
    });
    detail(host, view);
  }

  window.CelFactory = { render };
})();
