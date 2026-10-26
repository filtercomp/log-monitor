(function () {
  'use strict';

  var state = {
    cluster: 'cn-prod',
    date: '',
    updatedAt: '',
    alerts: [],
    filters: { ns: '', wl: '', kw: '' },
    selectedId: '',
    selectedSource: '',
    viewLines: 200,
    onlyMatch: false,
    linesCache: {},
    currentLines: []
  };

  var el = {
    clusterName: document.getElementById('clusterName'),
    statusDot: document.getElementById('statusDot'),
    statusText: document.getElementById('statusText'),
    refreshBtn: document.getElementById('refreshBtn'),
    fNs: document.getElementById('fNs'),
    fWl: document.getElementById('fWl'),
    fKw: document.getElementById('fKw'),
    alertCount: document.getElementById('alertCount'),
    alertList: document.getElementById('alertList'),
    detail: document.getElementById('detail')
  };

  function esc(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function escapeRe(s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  function hhmmss(s) {
    return typeof s === 'string' && s.length >= 19 ? s.slice(11, 19) : (s || '—');
  }

  function localDate() {
    var d = new Date();
    var p = function (n) { return String(n).padStart(2, '0'); };
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
  }

  function setStatus(kind, text) {
    el.statusDot.className = 'dot' + (kind ? ' ' + kind : '');
    el.statusText.textContent = text;
  }

  function updateStatus() {
    if (!state.updatedAt) {
      setStatus('idle', '今日暂无扫描记录');
      return;
    }
    var fresh = state.date === localDate();
    setStatus(fresh ? 'ok' : 'idle', '最后扫描 ' + state.updatedAt);
  }

  /* ---------------- 数据加载 ---------------- */

  function loadMeta() {
    return fetch('/data/alerts.json?t=' + Date.now(), { cache: 'no-store' })
      .then(function (res) {
        if (res.status === 404) {
          state.alerts = [];
          state.updatedAt = '';
          state.date = '';
          renderList();
          setStatus('idle', '等待首次扫描');
          return;
        }
        if (!res.ok) throw new Error('HTTP ' + res.status);
        return res.json().then(function (data) {
          state.cluster = data.cluster || state.cluster;
          state.date = data.date || '';
          state.updatedAt = data.updated_at || '';
          state.alerts = Array.isArray(data.alerts) ? data.alerts : [];
          el.clusterName.textContent = state.cluster;
          renderNsOptions();
          renderList();
          updateStatus();
          if (state.selectedId && !state.alerts.some(function (a) { return a.id === state.selectedId; })) {
            state.selectedId = '';
            renderDetailEmpty('告警记录不存在或已过期');
          }
        });
      })
      .catch(function () {
        setStatus('err', '连接失败，稍后自动重试');
      });
  }

  function renderNsOptions() {
    var names = [];
    state.alerts.forEach(function (a) {
      if (a.namespace && names.indexOf(a.namespace) === -1) names.push(a.namespace);
    });
    names.sort();
    el.fNs.innerHTML = '<option value="">全部</option>' + names.map(function (n) {
      return '<option value="' + esc(n) + '">' + esc(n) + '</option>';
    }).join('');
    if (names.indexOf(state.filters.ns) !== -1) el.fNs.value = state.filters.ns;
  }

  /* ---------------- 列表 ---------------- */

  function visibleAlerts() {
    var wl = state.filters.wl.trim().toLowerCase();
    return state.alerts.filter(function (a) {
      if (state.filters.ns && a.namespace !== state.filters.ns) return false;
      if (wl && String(a.workload || '').toLowerCase().indexOf(wl) === -1) return false;
      return true;
    });
  }

  function renderList() {
    var items = visibleAlerts();
    el.alertCount.textContent = items.length === state.alerts.length
      ? String(items.length)
      : items.length + ' / ' + state.alerts.length;

    if (!items.length) {
      el.alertList.innerHTML = '<div class="empty">' +
        (state.alerts.length ? '没有符合筛选条件的告警' : '今天暂无告警') + '</div>';
      return;
    }

    el.alertList.innerHTML = items.map(function (a) {
      var chips = '<span class="chip">' + esc(a.namespace) + '</span>' +
        '<span class="chip">' + esc(a.hits) + ' 个 Pod/容器</span>';
      if (Number(a.error_count) > 0) {
        chips += '<span class="chip err">ERROR ' + esc(a.error_count) + '</span>';
      }
      if (Number(a.exception_count) > 0) {
        chips += '<span class="chip err">Exception ' + esc(a.exception_count) + '</span>';
      }
      return '<button type="button" class="alert-item' + (a.id === state.selectedId ? ' active' : '') +
        '" data-id="' + esc(a.id) + '">' +
        '<div class="arow1"><span class="wl">' + esc(a.workload) + '</span>' +
        '<span class="atime">' + esc(hhmmss(a.scan_time)) + '</span></div>' +
        '<div class="arow2">' + chips + '</div>' +
        '<div class="arow3">' + esc(a.file) + ' · ' + esc(a.size_human) + '</div>' +
        '</button>';
    }).join('');
  }

  /* ---------------- 详情 ---------------- */

  function renderDetailEmpty(text) {
    state.selectedSource = '';
    el.detail.innerHTML = '<div class="empty">' + esc(text) + '</div>';
  }

  function sourcesOf(a) {
    if (Array.isArray(a.sources) && a.sources.length) return a.sources;
    return [{
      snapshot: a.id,
      pod: a.rep_pod,
      container: a.rep_container,
      file: a.file,
      size_human: a.size_human,
      mtime_str: a.mtime_str,
      error_count: a.error_count,
      exception_count: a.exception_count
    }];
  }

  function sourceBySnapshot(a, snapshot) {
    var list = sourcesOf(a);
    for (var i = 0; i < list.length; i++) {
      if (list[i].snapshot === snapshot) return list[i];
    }
    return null;
  }

  function updateSourceMeta(a) {
    var meta = document.getElementById('sourceMeta');
    if (!meta) return;
    var s = sourceBySnapshot(a, state.selectedSource) || sourcesOf(a)[0];
    if (!s) {
      meta.textContent = '';
      return;
    }
    meta.textContent = [
      s.file,
      s.size_human,
      '最后写入 ' + (s.mtime_str || '—'),
      'ERROR ' + (s.error_count || 0),
      'Exception ' + (s.exception_count || 0)
    ].join(' · ');
  }

  function openAlert(id) {
    var alert = null;
    for (var i = 0; i < state.alerts.length; i++) {
      if (state.alerts[i].id === id) { alert = state.alerts[i]; break; }
    }
    if (!alert) {
      state.selectedId = '';
      renderDetailEmpty('告警记录不存在或已过期');
      return;
    }
    state.selectedId = id;
    state.selectedSource = '';
    renderList();
    renderDetail(alert);
  }

  function renderDetail(a) {
    var badges = '';
    if (Number(a.error_count) > 0) badges += '<span class="badge">ERROR ' + esc(a.error_count) + '</span>';
    if (Number(a.exception_count) > 0) badges += '<span class="badge">Exception ' + esc(a.exception_count) + '</span>';
    if (!badges) badges = '<span class="badge neutral">无 ERROR 关键字</span>';

    var podChips = (a.pods || []).map(function (p) {
      return '<span class="chip">' + esc(p) + '</span>';
    }).join('') || '—';

    var linkRow = a.link
      ? '<div class="meta-item wide"><span>告警链接</span><a class="link" href="' + esc(a.link) + '">' + esc(a.link) + '</a></div>'
      : '';

    var sources = sourcesOf(a);
    var current = sourceBySnapshot(a, state.selectedSource);
    if (!current) {
      for (var si = 0; si < sources.length; si++) {
        if (sources[si].pod === a.rep_pod && sources[si].container === a.rep_container) {
          current = sources[si];
          break;
        }
      }
    }
    if (!current) current = sources[0];
    state.selectedSource = current ? current.snapshot : '';

    var sourceOptions = sources.map(function (s) {
      var label = (s.pod || '') + (s.container ? ' · ' + s.container : '');
      return '<option value="' + esc(s.snapshot) + '"' + (s.snapshot === state.selectedSource ? ' selected' : '') + '>' +
        esc(label) + '</option>';
    }).join('');

    var sourceBar = '<div class="log-toolbar source-bar">' +
      (sources.length > 1
        ? '<span>查看副本 <select id="sourceSelect">' + sourceOptions + '</select></span>'
        : '<span>副本：' + esc((current.pod || '') + (current.container ? ' · ' + current.container : '')) + '</span>') +
      '<span class="source-meta" id="sourceMeta"></span>' +
      '</div>';

    el.detail.innerHTML =
      '<div class="detail-head">' +
        '<div><h2>' + esc(a.workload) + '</h2>' +
        '<p class="sub">' + esc(a.namespace) + ' · 扫描于 ' + esc(a.scan_time) + '</p></div>' +
        '<div class="badges">' + badges + '</div>' +
      '</div>' +
      '<div class="meta-grid">' +
        '<div class="meta-item"><span>代表 Pod</span><strong class="value mono">' + esc(a.rep_pod || (a.pods || [])[0] || '—') + '</strong></div>' +
        '<div class="meta-item"><span>容器</span><strong class="value mono">' + esc(a.rep_container || (a.containers || []).join(', ') || '—') + '</strong></div>' +
        '<div class="meta-item"><span>代表日志</span><strong class="value mono">' + esc(a.file) + '</strong></div>' +
        '<div class="meta-item"><span>文件大小</span><strong>' + esc(a.size_human) + '</strong></div>' +
        '<div class="meta-item"><span>最后写入</span><strong class="value mono">' + esc(a.mtime_str) + '</strong></div>' +
        '<div class="meta-item"><span>窗口内变更文件</span><strong>' + esc(a.file_count) + ' 个</strong></div>' +
        '<div class="meta-item"><span>日志副本</span><strong>' + esc(sources.length) + ' 份</strong></div>' +
        '<div class="meta-item wide"><span>受影响 Pod（共 ' + esc(a.hits) + ' 个 Pod/容器）</span>' +
          '<div class="pods">' + podChips + '</div></div>' +
        linkRow +
      '</div>' +
      sourceBar +
      '<div class="log-toolbar">' +
        '<span>显示最新 <select id="lineCount">' +
          [100, 200, 1000, 2000].map(function (n) {
            return '<option value="' + n + '"' + (n === state.viewLines ? ' selected' : '') + '>' + n + '</option>';
          }).join('') +
        '</select> 行</span>' +
        '<label class="check"><input type="checkbox" id="onlyMatch"' + (state.onlyMatch ? ' checked' : '') + '> 只看匹配行</label>' +
        '<span class="matchinfo" id="matchInfo"></span>' +
        '<span class="grow"></span>' +
        '<span>快照仅保留当天</span>' +
      '</div>' +
      '<div class="log" id="logView"><div class="loading">加载日志…</div></div>';

    document.getElementById('lineCount').addEventListener('change', function (e) {
      state.viewLines = Number(e.target.value) || 200;
      renderLog();
    });
    document.getElementById('onlyMatch').addEventListener('change', function (e) {
      state.onlyMatch = e.target.checked;
      renderLog();
    });
    var sourceSelect = document.getElementById('sourceSelect');
    if (sourceSelect) {
      sourceSelect.addEventListener('change', function (e) {
        state.selectedSource = e.target.value;
        updateSourceMeta(a);
        loadLines(a);
      });
    }

    updateSourceMeta(a);
    loadLines(a);
  }

  function loadLines(a) {
    var view = document.getElementById('logView');
    if (!view) return;
    var snapshot = state.selectedSource || a.id;
    var cached = state.linesCache[snapshot];
    if (cached) {
      state.currentLines = cached;
      renderLog();
      return;
    }
    view.innerHTML = '<div class="loading">加载日志…</div>';
    fetch('/data/logs/' + encodeURIComponent(snapshot) + '.json?t=' + Date.now(), { cache: 'no-store' })
      .then(function (res) {
        if (!res.ok) throw new Error('HTTP ' + res.status);
        return res.json();
      })
      .then(function (data) {
        if (state.selectedId !== a.id || state.selectedSource !== snapshot) return;
        state.linesCache[snapshot] = Array.isArray(data.lines) ? data.lines : [];
        state.currentLines = state.linesCache[snapshot];
        renderLog();
      })
      .catch(function () {
        if (state.selectedId !== a.id || state.selectedSource !== snapshot) return;
        state.currentLines = [];
        var box = document.getElementById('logView');
        if (box) box.innerHTML = '<div class="empty">日志快照不存在（仅保留当天数据）</div>';
      });
  }

  function renderLine(line, kw) {
    var src = String(line);
    if (!kw) return esc(src);
    var re = new RegExp(escapeRe(kw), 'gi');
    var out = '';
    var last = 0;
    var m;
    while ((m = re.exec(src)) !== null) {
      out += esc(src.slice(last, m.index)) + '<mark>' + esc(m[0]) + '</mark>';
      last = m.index + m[0].length;
      if (m[0].length === 0) re.lastIndex++;
    }
    return out + esc(src.slice(last));
  }

  function renderLog() {
    var view = document.getElementById('logView');
    if (!view) return;
    var lines = state.currentLines || [];
    var total = lines.length;
    var n = Math.min(state.viewLines, total);
    var start = total - n;
    var slice = lines.slice(start);
    var kw = state.filters.kw.trim();
    var hits = 0;
    var html = [];

    for (var i = 0; i < slice.length; i++) {
      var hit = false;
      if (kw) {
        var re = new RegExp(escapeRe(kw), 'gi');
        hit = re.test(slice[i]);
      }
      if (hit) hits++;
      if (kw && state.onlyMatch && !hit) continue;
      html.push('<div class="log-line' + (hit ? ' hit' : '') + '">' +
        '<span class="ln">' + (start + i + 1) + '</span>' +
        '<span class="lc">' + renderLine(slice[i], kw) + '</span></div>');
    }

    document.getElementById('matchInfo').textContent = kw ? ('匹配 ' + hits + ' 行') : '';
    view.innerHTML = html.length
      ? html.join('')
      : '<div class="empty">' + (kw && state.onlyMatch ? '没有匹配的行' : '日志为空') + '</div>';
    view.scrollTop = view.scrollHeight;
  }

  /* ---------------- 交互 ---------------- */

  el.alertList.addEventListener('click', function (e) {
    var btn = e.target.closest('.alert-item');
    if (!btn || !btn.dataset.id) return;
    var hash = '#/alert/' + btn.dataset.id;
    if (location.hash === hash) openAlert(btn.dataset.id);
    else location.hash = hash;
  });

  el.fNs.addEventListener('change', function () {
    state.filters.ns = el.fNs.value;
    renderList();
  });

  el.fWl.addEventListener('input', function () {
    state.filters.wl = el.fWl.value;
    renderList();
  });

  var kwTimer = null;
  el.fKw.addEventListener('input', function () {
    state.filters.kw = el.fKw.value;
    clearTimeout(kwTimer);
    kwTimer = setTimeout(function () {
      if (state.selectedId) renderLog();
    }, 120);
  });

  el.refreshBtn.addEventListener('click', function () {
    loadMeta();
  });

  function route() {
    var m = location.hash.match(/^#\/alert\/(.+)$/);
    if (!m) {
      if (state.selectedId) {
        state.selectedId = '';
        renderList();
        renderDetailEmpty('从左侧选择一条告警查看详情');
      }
      return;
    }
    try {
      openAlert(decodeURIComponent(m[1]));
    } catch (err) {
      renderDetailEmpty('告警记录不存在或已过期');
    }
  }

  window.addEventListener('hashchange', route);
  setInterval(loadMeta, 60000);
  loadMeta().then(route);
})();
