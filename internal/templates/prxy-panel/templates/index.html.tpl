<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Прокси Панель</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, BlinkMacSystemFont, Segoe UI, Roboto, sans-serif; background: #f0f2f5; color: #303133; font-size: 14px; }
.header { background: #fff; border-bottom: 1px solid #e4e7ed; padding: 0 24px; display: flex; align-items: center; justify-content: space-between; height: 56px; }
.header-title { font-size: 16px; font-weight: 500; color: #303133; }
.header-user { color: #606266; font-size: 13px; }
.header-user a { color: #409eff; text-decoration: none; margin-left: 16px; }
.tabs { display: flex; background: #fff; border-bottom: 1px solid #e4e7ed; padding: 0 24px; }
.tab { padding: 16px 20px; cursor: pointer; color: #606266; font-size: 14px; border-bottom: 2px solid transparent; transition: all 0.2s; user-select: none; }
.tab:hover { color: #409eff; }
.tab.active { color: #409eff; border-bottom-color: #409eff; }
.content { padding: 24px; }
.tab-pane { display: none; }
.tab-pane.active { display: block; }
.card { background: #fff; border-radius: 4px; padding: 20px; margin-bottom: 20px; box-shadow: 0 1px 4px rgba(0,0,0,0.08); }
.card-title { font-size: 15px; font-weight: 500; color: #303133; margin-bottom: 16px; padding-bottom: 12px; border-bottom: 1px solid #f0f0f0; }
.btn { display: inline-block; padding: 8px 16px; border-radius: 4px; border: none; cursor: pointer; font-size: 13px; transition: all 0.2s; white-space: nowrap; background: #909399; color: #fff; }
.btn:hover { opacity: 0.85; }
.btn-primary { background: #409eff; }
.btn-success { background: #67c23a; }
.btn-warning { background: #e6a23c; }
.btn-danger { background: #f56c6c; }
.btn-info { background: #909399; }
.btn-sm { padding: 5px 10px; font-size: 12px; }
.btn-group { display: flex; gap: 16px; flex-wrap: wrap; margin-bottom: 16px; }
input[type=text], input[type=password], input[type=number] { padding: 7px 10px; border: 1px solid #dcdfe6; border-radius: 4px; font-size: 13px; color: #303133; outline: none; }
input:focus { border-color: #409eff; }
select { padding: 7px 10px; border: 1px solid #dcdfe6; border-radius: 4px; font-size: 13px; color: #303133; outline: none; background: #fff; width: 100%; }
.output-box { background: #f8f9fa; border: 1px solid #e4e7ed; border-radius: 4px; padding: 12px; font-family: monospace; font-size: 12px; white-space: pre-wrap; max-height: 300px; overflow-y: auto; margin-top: 10px; color: #303133; }
.status-active { color: #67c23a; font-weight: 500; }
.status-inactive { color: #f56c6c; font-weight: 500; }
.status-unknown { color: #909399; font-weight: 500; }
table { width: 100%; border-collapse: collapse; }
th { text-align: left; padding: 10px 12px; background: #f5f7fa; color: #606266; font-weight: 500; font-size: 13px; border-bottom: 1px solid #ebeef5; }
td { padding: 10px 12px; border-bottom: 1px solid #f0f0f0; color: #303133; font-size: 13px; vertical-align: middle; line-height: 2; }
tr:last-child td { border-bottom: none; }
.decision-tunnel { color: #e6a23c; font-weight: 500; }
.decision-direct { color: #67c23a; font-weight: 500; }
.td-actions { display: flex; gap: 12px; }
.service-row { display: flex; align-items: flex-start; gap: 16px; padding: 16px 0; border-bottom: 1px solid #f0f0f0; flex-wrap: wrap; }
.service-row:last-child { border-bottom: none; }
.service-name { min-width: 160px; font-weight: 500; padding-top: 8px; }
.service-status-wrap { min-width: 100px; padding-top: 8px; }
.service-controls { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
.logs-panel { margin-top: 12px; width: 100%; display: none; }
.logs-panel.open { display: block; }
.modal { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.5); z-index: 1000; align-items: center; justify-content: center; }
.modal.open { display: flex; }
.modal-box { background: #fff; border-radius: 6px; padding: 28px; min-width: 380px; max-width: 480px; }
.modal-title { font-size: 15px; font-weight: 500; margin-bottom: 20px; }
.modal-actions { display: flex; gap: 12px; justify-content: flex-end; margin-top: 20px; }
.form-group { margin-bottom: 16px; }
.form-group label { display: block; margin-bottom: 6px; color: #606266; font-size: 13px; }
.form-group input { width: 100%; }
.alert { padding: 10px 14px; border-radius: 4px; margin-top: 10px; font-size: 13px; }
.alert-success { background: #f0f9eb; color: #67c23a; border: 1px solid #c2e7b0; }
.alert-error { background: #fef0f0; color: #f56c6c; border: 1px solid #fbc4c4; }
.toast { position: fixed; top: 70px; right: 24px; z-index: 9999; min-width: 200px; padding: 10px 16px; border-radius: 4px; font-size: 13px; box-shadow: 0 2px 8px rgba(0,0,0,0.15); }
</style>
</head>
<body>
<div class="header">
  <div class="header-title">Proxy Panel</div>
  <div class="header-user">{{ user }} <a href="{{ url_for('logout') }}">Выйти</a></div>
</div>
<div class="tabs">
  <div class="tab active" id="tab-btn-management" onclick="showTab('management')">Управление</div>
  <div class="tab" id="tab-btn-monitor" onclick="showTab('monitor')">Просмотр онлайн</div>
  {% if role == 'admin' %}
  <div class="tab" id="tab-btn-admin" onclick="showTab('admin')">Администратор</div>
  {% endif %}
</div>
<div class="content">
<div id="tab-management" class="tab-pane active">
  <div class="card">
    <div class="card-title">Действия с доменами</div>
    <div class="btn-group">
      <button class="btn btn-warning" onclick="openModal('tunnel')">Добавить в ТУННЕЛЬ</button>
      <button class="btn btn-success" onclick="openModal('direct')">Добавить в ПРЯМОЙ</button>
      <button class="btn btn-danger" onclick="openModal('remove')">Удалить правило</button>
      <button class="btn btn-primary" onclick="openModal('recheck')">Перепроверить домен</button>
      <button class="btn btn-info" onclick="openModal('status')">Статус домена</button>
    </div>
    <div id="action-output" class="output-box" style="display:none"></div>
  </div>
  <div class="card">
    <div class="card-title">Статистика кэша</div>
    <div id="stats-block"><p>Загрузка...</p></div>
  </div>
  <div class="card">
    <div class="card-title">Последние 30 доменов</div>
    <div style="margin-bottom:14px"><button class="btn btn-primary" onclick="loadLastDomains()">Обновить</button></div>
    <div id="last-domains-block"></div>
  </div>
  <div class="card">
    <div class="card-title">Ручные правила</div>
    <div style="margin-bottom:14px"><button class="btn btn-primary" onclick="loadManual()">Обновить</button></div>
    <div id="manual-block"></div>
  </div>
</div>
<div id="tab-monitor" class="tab-pane">
  <div class="card">
    <div class="card-title">Статус служб</div>
    <div id="services-block"><p>Загрузка...</p></div>
  </div>
  <div class="card">
    <div class="card-title">Домены в реальном времени</div>
    <div style="display:flex;gap:12px;margin-bottom:16px">
      <button class="btn btn-success" onclick="startDomainStream()">Запустить мониторинг</button>
      <button class="btn btn-danger" onclick="stopDomainStream()">Остановить</button>
      <button class="btn btn-info" onclick="clearDomainStream()">Очистить</button>
    </div>
    <div style="overflow-x:auto">
      <table><thead><tr>
        <th style="width:90px">Время</th>
        <th style="width:100px">Решение</th>
        <th>Домен</th>
        <th style="width:240px">Действие</th>
      </tr></thead><tbody id="domain-stream-body"></tbody></table>
    </div>
  </div>
</div>
<div id="tab-admin" class="tab-pane">
  <div class="card">
    <div class="card-title">Смена пароля</div>
    <div style="max-width:400px">
      <div class="form-group"><label>Текущий пароль</label><input type="password" id="old-pw" style="width:100%"></div>
      <div class="form-group"><label>Новый пароль</label><input type="password" id="new-pw" style="width:100%"></div>
      <button class="btn btn-primary" onclick="changePassword()">Изменить пароль</button>
      <div id="pw-result"></div>
    </div>
  </div>
  <div class="card">
    <div class="card-title">Пользователи</div>
    <div style="margin-bottom:14px"><button class="btn btn-primary" onclick="openModal('adduser')">Добавить пользователя</button></div>
    <div id="users-block"></div>
  </div>
</div>
</div>
<div id="modal" class="modal">
  <div class="modal-box">
    <div class="modal-title" id="modal-title"></div>
    <div id="modal-body"></div>
    <div class="modal-actions">
      <button class="btn btn-info" onclick="closeModal()">Отмена</button>
      <button class="btn btn-primary" onclick="confirmModal()">Подтвердить</button>
    </div>
  </div>
</div>
<script>
  var USER_ROLE = "{{ role }}";
  var APP_PREFIX = "{{ config.APPLICATION_ROOT|default('') }}";
  if (APP_PREFIX === '/') APP_PREFIX = '';
</script>
<script src="{{ url_for('static', filename='app.js') }}"></script>
</body>
</html>