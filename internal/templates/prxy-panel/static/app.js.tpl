if (typeof APP_PREFIX === 'undefined') var APP_PREFIX = '';
var currentModalAction = null;
var domainStream = null;
var logStreams = {};
var T = {"title": "Прокси Панель", "logout": "Выйти", "tab1": "Управление", "tab2": "Просмотр онлайн", "tab3": "Администратор", "actions": "Действия с доменами", "btn_tunnel": "Добавить в ТУННЕЛЬ", "btn_direct": "Добавить в ПРЯМОЙ", "btn_remove": "Удалить правило", "btn_recheck": "Перепроверить домен", "btn_status": "Статус домена", "stats_title": "Статистика кэша", "last30_title": "Последние 30 доменов", "manual_title": "Ручные правила", "refresh": "Обновить", "services_title": "Статус служб", "domains_title": "Домены в реальном времени", "start_mon": "Запустить мониторинг", "stop_mon": "Остановить", "clear": "Очистить", "time_col": "Время", "decision_col": "Решение", "domain_col": "Домен", "action_col": "Действие", "to_tunnel": "в ТУННЕЛЬ", "to_direct": "в ПРЯМОЙ", "delete": "Удалить", "pw_title": "Смена пароля", "old_pw": "Текущий пароль", "new_pw": "Новый пароль", "change_pw": "Изменить пароль", "users_title": "Пользователи", "add_user": "Добавить пользователя", "cancel": "Отмена", "confirm": "Подтвердить", "loading": "Загрузка...", "no_data": "Нет данных", "no_rules": "Нет ручных правил", "restart": "Перезапустить", "show_logs": "Показать логи", "live_logs": "Логи онлайн", "total": "Всего", "direct_count": "DIRECT", "tunnel_count": "TUNNEL", "manual_count": "Ручные", "reason_col": "Причина", "login_col": "Логин", "role_col": "Роль", "modal_tunnel": "Добавить домен в ТУННЕЛЬ", "modal_direct": "Добавить домен в ПРЯМОЙ доступ", "modal_remove": "Удалить ручное правило", "modal_recheck": "Перепроверить домен", "modal_status": "Статус домена", "modal_adduser": "Добавить пользователя", "domain_label": "Домен", "reason_label": "Причина (необязательно)", "domain_ph_tunnel": "например: spotify.com", "domain_ph_direct": "например: magnit.ru", "user_added": "Пользователь добавлен", "user_deleted": "Пользователь удалён", "pw_changed": "Пароль изменён", "mon_started": "Мониторинг запущен", "mon_stopped": "Мониторинг остановлен", "login_label": "Логин", "pw_label": "Пароль", "role_label": "Роль", "error": "Ошибка", "svc_restart": "Перезапустить"};

function applyRoleUI() {
    if (typeof USER_ROLE === 'undefined' || USER_ROLE === 'admin') return;
    // Hide action btn-group (add tunnel/direct/remove/recheck/status)
    var btnGroup = document.querySelector('#tab-management .btn-group');
    if (btnGroup) btnGroup.style.display = 'none';
}

function showTab(name) {
    document.querySelectorAll('.tab-pane').forEach(function(p) { p.classList.remove('active'); });
    document.querySelectorAll('.tab').forEach(function(t) { t.classList.remove('active'); });
    document.getElementById('tab-' + name).classList.add('active');
    var btn = document.getElementById('tab-btn-' + name);
    if (btn) btn.classList.add('active');
    if (name === 'monitor') loadServices();
    if (name === 'admin') loadUsers();
    if (name === 'management') { loadStats(); loadLastDomains(); loadManual(); applyRoleUI();

 }
}

function openModal(action) {
    currentModalAction = action;
    var titles = {tunnel:T.modal_tunnel, direct:T.modal_direct, remove:T.modal_remove, recheck:T.modal_recheck, status:T.modal_status, adduser:T.modal_adduser};
    var title = titles[action] || action;
    var body = '';
    if (action === 'tunnel' || action === 'direct') {
        var ph = action === 'tunnel' ? T.domain_ph_tunnel : T.domain_ph_direct;
        body = '<div class="form-group"><label>' + T.domain_label + '</label><input type="text" id="m-domain" placeholder="' + ph + '" style="width:100%"></div>' +
               '<div class="form-group"><label>' + T.reason_label + '</label><input type="text" id="m-reason" style="width:100%"></div>';
    } else if (action === 'remove' || action === 'recheck' || action === 'status') {
        body = '<div class="form-group"><label>' + T.domain_label + '</label><input type="text" id="m-domain" style="width:100%"></div>';
    } else if (action === 'adduser') {
        body = '<div class="form-group"><label>' + T.login_label + '</label><input type="text" id="m-username" style="width:100%"></div>' +
               '<div class="form-group"><label>' + T.pw_label + '</label><input type="password" id="m-userpassword" style="width:100%"></div>' +
               '<div class="form-group"><label>' + T.role_label + '</label><select id="m-role"><option value="user">user</option><option value="admin">admin</option></select></div>';
    }
    document.getElementById('modal-title').textContent = title;
    document.getElementById('modal-body').innerHTML = body;
    document.getElementById('modal').classList.add('open');
    setTimeout(function() { var d = document.getElementById('m-domain'); if (d) d.focus(); }, 100);
}

function closeModal() {
    document.getElementById('modal').classList.remove('open');
    currentModalAction = null;
}

document.addEventListener('DOMContentLoaded', function() {
    document.getElementById('modal').addEventListener('click', function(e) {
        if (e.target === this) closeModal();
    });
    document.addEventListener('click', function(e) {
        if (e.target.classList.contains('qa-btn')) {
            var action = e.target.getAttribute('data-action');
            var domain = e.target.getAttribute('data-domain');
            quickAction(action, domain);
        }
    });
});

function confirmModal() {
    var action = currentModalAction;
    if (action === 'adduser') {
        var username = (document.getElementById('m-username') || {value:''}).value.trim();
        var password = (document.getElementById('m-userpassword') || {value:''}).value;
        var role = (document.getElementById('m-role') || {value:'user'}).value;
        closeModal();
        fetch(APP_PREFIX + '/api/users/add', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({username:username, password:password, role:role})})
        .then(function(r) { return r.json(); }).then(function(d) { loadUsers(); showToast(d.ok ? T.user_added : (d.error||T.error), d.ok?'success':'error'); });
        return;
    }
    var domain = (document.getElementById('m-domain') || {value:''}).value.trim();
    var reason = (document.getElementById('m-reason') || {value:''}).value.trim();
    if (!domain) return;
    closeModal();
    var apiAction = action === 'tunnel' ? 'add-tunnel' : (action === 'direct' ? 'add-direct' : action);
    fetch(APP_PREFIX + '/api/domain_action', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({action:apiAction, domain:domain, reason:reason})})
    .then(function(r) { return r.json(); }).then(function(d) {
        var box = document.getElementById('action-output');
        box.style.display = 'block';
        box.textContent = d.output || d.error || 'OK';
        if (action==='tunnel'||action==='direct'||action==='remove') { loadLastDomains(); loadManual(); loadStats(); }
    });
}

function quickAction(action, domain) {
    fetch(APP_PREFIX + '/api/domain_action', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({action:action, domain:domain, reason:'manual'})})
    .then(function(r) { return r.json(); }).then(function(d) {
        loadLastDomains(); loadManual(); loadStats();
        showToast(domain + ' -> ' + (action==='add-tunnel'?'TUNNEL':'DIRECT'), 'success');
    });
}

function makeBtns(domain) {
    if (typeof USER_ROLE === 'undefined' || USER_ROLE !== 'admin') return '';
    return '<div class="td-actions">' +
        '<button class="btn btn-warning btn-sm qa-btn" data-action="add-tunnel" data-domain="' + domain + '">' + T.to_tunnel + '</button>' +
        '<button class="btn btn-success btn-sm qa-btn" data-action="add-direct" data-domain="' + domain + '">' + T.to_direct + '</button>' +
        '</div>';
}

function loadStats() {
    fetch(APP_PREFIX + '/api/stats').then(function(r) { return r.json(); }).then(function(d) {
        if (d.error) { document.getElementById('stats-block').textContent = d.error; return; }
        var c = d.cache || {};
        document.getElementById('stats-block').innerHTML =
            '<table><thead><tr><th>' + T.total + '</th><th>' + T.direct_count + '</th><th>' + T.tunnel_count + '</th><th>' + T.manual_count + '</th></tr></thead>' +
            '<tbody><tr><td>' + (c.total||0) + '</td><td>' + (c.direct||0) + '</td><td>' + (c.tunnel||0) + '</td><td>' + (c.manual||0) + '</td></tr></tbody></table>';
    });
}

function loadLastDomains() {
    fetch(APP_PREFIX + '/api/last_domains').then(function(r) { return r.json(); }).then(function(d) {
        var lines = d.lines || [];
        var el = document.getElementById('last-domains-block');
        if (!lines.length) { el.innerHTML = '<p style="color:#909399">' + T.no_data + '</p>'; return; }
        var html = '<div style="overflow-x:auto"><table><thead><tr>' +
            '<th style="width:90px">' + T.time_col + '</th>' +
            '<th style="width:100px">' + T.decision_col + '</th>' +
            '<th>' + T.domain_col + '</th>' +
            '<th style="width:240px">' + T.action_col + '</th>' +
            '</tr></thead><tbody>';
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i];
            var cls = l.decision === 'TUNNEL' ? 'decision-tunnel' : 'decision-direct';
            html += '<tr><td>' + l.time + '</td><td class="' + cls + '">' + l.decision + '</td><td>' + l.domain + '</td><td>' + makeBtns(l.domain) + '</td></tr>';
        }
        html += '</tbody></table></div>';
        el.innerHTML = html;
    });
}

function loadManual() {
    fetch(APP_PREFIX + '/api/manual_list').then(function(r) { return r.json(); }).then(function(d) {
        var items = d.items || [];
        var el = document.getElementById('manual-block');
        if (!items.length) { el.innerHTML = '<p style="color:#909399">' + T.no_rules + '</p>'; return; }
        var html = '<div style="overflow-x:auto"><table><thead><tr>' +
            '<th>' + T.domain_col + '</th>' +
            '<th style="width:100px">' + T.decision_col + '</th>' +
            '<th>' + T.reason_col + '</th>' +
            '<th style="width:280px">' + T.action_col + '</th>' +
            '</tr></thead><tbody>';
        for (var i = 0; i < items.length; i++) {
            var item = items[i];
            var cls = item.decision === 'tunnel' ? 'decision-tunnel' : 'decision-direct';
            var btns = '';
            if (typeof USER_ROLE !== 'undefined' && USER_ROLE === 'admin') {
                btns = '<div class="td-actions">';
                if (item.decision !== 'tunnel') btns += '<button class="btn btn-warning btn-sm qa-btn" data-action="add-tunnel" data-domain="' + item.domain + '">' + T.to_tunnel + '</button>';
                if (item.decision !== 'direct') btns += '<button class="btn btn-success btn-sm qa-btn" data-action="add-direct" data-domain="' + item.domain + '">' + T.to_direct + '</button>';
                btns += '<button class="btn btn-danger btn-sm qa-btn" data-action="remove" data-domain="' + item.domain + '">' + T.delete + '</button>';
                btns += '</div>';
            }
            html += '<tr><td>' + item.domain + '</td><td class="' + cls + '">' + item.decision.toUpperCase() + '</td><td>' + (item.reason||'') + '</td><td>' + btns + '</td></tr>';
        }
        html += '</tbody></table></div>';
        el.innerHTML = html;
    });
}

function loadServices() {
    fetch(APP_PREFIX + '/api/stats').then(function(r) { return r.json(); }).then(function(d) {
        var svcs = [
            {id:'x-ui', name:'x-ui (Xray)'},
            {id:'smart-proxy', name:'Smart Proxy'},
            {id:'nginx', name:'Nginx'},
            {id:'sslh', name:'SSLH'},
            {id:'awg-quick@awg0', name:'AmneziaWG'},
            {id:'openvpn@server', name:'OpenVPN'}
        ];
        var statuses = d.services || {};

        // Only update status spans if block already rendered, don't rebuild
        var existing = document.getElementById('services-block');
        if (existing && existing.querySelector('.service-row')) {
            for (var si = 0; si < svcs.length; si++) {
                var s = svcs[si];
                var st = statuses[s.id] || 'unknown';
                var cls = st === 'active' ? 'status-active' : (st === 'inactive' ? 'status-inactive' : 'status-unknown');
                var sid = s.id.replace('@','_');
                var span = existing.querySelector('#logs-' + sid + ' ~ div span, .service-name');
                // Find status span by service row
                var rows = existing.querySelectorAll('.service-row');
                for (var ri = 0; ri < rows.length; ri++) {
                    var nameEl = rows[ri].querySelector('.service-name');
                    if (nameEl && nameEl.textContent === s.name) {
                        var statusEl = rows[ri].querySelector('.service-status-wrap span');
                        if (statusEl) {
                            statusEl.textContent = st;
                            statusEl.className = cls;
                        }
                        break;
                    }
                }
            }
            return;
        }

        var html = '';
        for (var i = 0; i < svcs.length; i++) {
            var s = svcs[i];
            var st = statuses[s.id] || 'unknown';
            var cls = st === 'active' ? 'status-active' : (st === 'inactive' ? 'status-inactive' : 'status-unknown');
            var sid = s.id.replace('@','_');
            html += '<div class="service-row">';
            html += '<div class="service-name">' + s.name + '</div>';
            html += '<div class="service-status-wrap"><span class="' + cls + '">' + st + '</span></div>';
            html += '<div class="service-controls">';
            if (typeof USER_ROLE !== 'undefined' && USER_ROLE === 'admin') {
                html += "<button class=\"btn btn-warning btn-sm\" onclick=\"serviceAction('" + s.id + "','restart')\">" + T.restart + "</button>";
            }
            html += '<input type="number" id="lines-' + sid + '" placeholder="15" style="width:60px">';
            html += "<button class=\"btn btn-info btn-sm\" onclick=\"showLogs('" + s.id + "','" + sid + "')\">" + T.show_logs + "</button>";
            html += "<button class=\"btn btn-primary btn-sm\" onclick=\"streamLogs('" + s.id + "','" + sid + "')\">" + T.live_logs + "</button>";
            html += '</div></div>';
            html += '<div class="logs-panel" id="logs-' + sid + '"><div class="output-box" id="logbox-' + sid + '"></div></div>';
        }
        document.getElementById('services-block').innerHTML = html;
    });
}

function serviceAction(id, action) {
    fetch(APP_PREFIX + '/api/service_action', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({service:id, action:action})})
    .then(function(r) { return r.json(); }).then(function(d) { setTimeout(loadServices, 2000); showToast(id + ': ' + action, 'success'); });
}

function showLogs(id, sid) {
    var linesEl = document.getElementById('lines-' + sid);
    var n = (linesEl && linesEl.value) ? parseInt(linesEl.value) : 15;
    fetch(APP_PREFIX + '/api/service_logs?service=' + encodeURIComponent(id) + '&lines=' + n)
    .then(function(r) { return r.json(); }).then(function(d) {
        var panel = document.getElementById('logs-' + sid);
        var box = document.getElementById('logbox-' + sid);
        box.textContent = d.output || d.error || '';
        panel.classList.add('open');
        box.scrollTop = box.scrollHeight;
    });
}

function streamLogs(id, sid) {
    if (logStreams[sid]) { logStreams[sid].close(); delete logStreams[sid]; }
    var panel = document.getElementById('logs-' + sid);
    var box = document.getElementById('logbox-' + sid);
    if (!panel || !box) return;
    panel.classList.add('open');
    var reconnectTimer = null;
    var es = new EventSource(APP_PREFIX + '/api/stream_logs?service=' + encodeURIComponent(id));
    logStreams[sid] = es;
    es.onmessage = function(e) {
        try {
            var dd = JSON.parse(e.data);
            box.textContent += dd.line + '\n';
            if (box.textContent.length > 100000) {
                box.textContent = box.textContent.slice(-80000);
            }
            box.scrollTop = box.scrollHeight;
        } catch(err) {}
    };
    es.onerror = function() {
        es.close();
        delete logStreams[sid];
        // Reconnect after 3 seconds, keep panel open
        if (reconnectTimer) clearTimeout(reconnectTimer);
        reconnectTimer = setTimeout(function() {
            var p = document.getElementById('logs-' + sid);
            if (p && p.classList.contains('open')) {
                streamLogs(id, sid);
            }
        }, 3000);
    };
    // Auto-stop after 30 minutes
    setTimeout(function() {
        if (logStreams[sid]) {
            logStreams[sid].close();
            delete logStreams[sid];
            box.textContent += '\n[Stream stopped after 30 minutes]\n';
        }
    }, 1800000);
}

function startDomainStream() {
    if (domainStream) return;
    domainStream = new EventSource(APP_PREFIX + '/api/stream_domains');
    domainStream.onmessage = function(e) {
        var dd = JSON.parse(e.data);
        var tbody = document.getElementById('domain-stream-body');
        var cls = dd.decision === 'TUNNEL' ? 'decision-tunnel' : 'decision-direct';
        var tr = document.createElement('tr');
        tr.innerHTML = '<td>' + dd.time + '</td><td class="' + cls + '">' + dd.decision + '</td><td>' + dd.domain + '</td><td>' + makeBtns(dd.domain) + '</td>';
        tbody.insertBefore(tr, tbody.firstChild);
        if (tbody.children.length > 200) tbody.removeChild(tbody.lastChild);
    };
    domainStream.onerror = function() {
        domainStream = null;
    };
    showToast(T.mon_started, 'success');
}

function stopDomainStream() {
    if (domainStream) { domainStream.close(); domainStream = null; }
    showToast(T.mon_stopped, 'success');
}

function clearDomainStream() {
    document.getElementById('domain-stream-body').innerHTML = '';
}

function loadUsers() {
    fetch(APP_PREFIX + '/api/users').then(function(r) { return r.json(); }).then(function(d) {
        var users = d.users || [];
        var html = '<table><thead><tr><th>' + T.login_col + '</th><th>' + T.role_col + '</th><th style="width:120px">' + T.action_col + '</th></tr></thead><tbody>';
        for (var i = 0; i < users.length; i++) {
            var u = users[i];
            html += '<tr><td>' + u.username + '</td><td>' + u.role + '</td><td>';
            if (u.username !== 'admin') html += "<button class=\"btn btn-danger btn-sm\" onclick=\"deleteUser('" + u.username + "')\">" + T.delete + "</button>";
            html += '</td></tr>';
        }
        html += '</tbody></table>';
        document.getElementById('users-block').innerHTML = html;
    });
}

function deleteUser(username) {
    fetch(APP_PREFIX + '/api/users/delete', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({username:username})})
    .then(function(r) { return r.json(); }).then(function(d) { loadUsers(); showToast(d.ok ? T.user_deleted : (d.error||T.error), d.ok?'success':'error'); });
}

function changePassword() {
    var old_pw = document.getElementById('old-pw').value;
    var new_pw = document.getElementById('new-pw').value;
    fetch(APP_PREFIX + '/api/users/change_password', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({old_password:old_pw, new_password:new_pw})})
    .then(function(r) { return r.json(); }).then(function(d) {
        var el = document.getElementById('pw-result');
        el.innerHTML = d.ok ? '<div class="alert alert-success">' + T.pw_changed + '</div>' : '<div class="alert alert-error">' + (d.error||T.error) + '</div>';
    });
}

function showToast(msg, type) {
    var el = document.createElement('div');
    el.className = 'toast';
    el.style.background = type === 'success' ? '#f0f9eb' : '#fef0f0';
    el.style.color = type === 'success' ? '#67c23a' : '#f56c6c';
    el.style.border = '1px solid ' + (type === 'success' ? '#c2e7b0' : '#fbc4c4');
    el.textContent = msg;
    document.body.appendChild(el);
    setTimeout(function() { if (el.parentNode) el.parentNode.removeChild(el); }, 4000);
}

loadStats(); loadLastDomains(); loadManual(); applyRoleUI();


setInterval(function() {
    if (document.getElementById('tab-monitor').classList.contains('active')) loadServices();
}, 5000);
