#!/usr/bin/env python3
import os, json, sqlite3, subprocess, threading, time, bcrypt
from flask import Flask, render_template, request, jsonify, redirect, url_for, session, Response, stream_with_context
from functools import wraps

app = Flask(__name__)
# Persistent secret key (survives restarts)
SECRET_KEY_FILE = '/opt/prxy-panel/secret.key'
if os.path.exists(SECRET_KEY_FILE):
    with open(SECRET_KEY_FILE, 'rb') as f:
        app.secret_key = f.read()
else:
    app.secret_key = os.urandom(32)
    with open(SECRET_KEY_FILE, 'wb') as f:
        f.write(app.secret_key)
    os.chmod(SECRET_KEY_FILE, 0o600)

# Subpath support via DispatcherMiddleware
APPLICATION_ROOT = os.environ.get('PRXY_PANEL_PREFIX', '/prxy')
app.config['APPLICATION_ROOT'] = APPLICATION_ROOT
app.config['SESSION_COOKIE_PATH'] = APPLICATION_ROOT

from werkzeug.middleware.proxy_fix import ProxyFix
app.wsgi_app = ProxyFix(app.wsgi_app, x_proto=1, x_host=1, x_prefix=1)

USERS_FILE = '/opt/prxy-panel/users.json'
ACCESS_LOG = '/var/log/smart-proxy-access.log'
SMART_PROXY_DB = '/var/lib/smart-proxy/cache.db'
SMART_PROXY_CTL = '/usr/local/bin/smart-proxy-ctl'

SERVICES = [
    {'id': 'x-ui',        'name': 'x-ui (Xray)'},
    {'id': 'smart-proxy', 'name': 'Smart Proxy'},
    {'id': 'nginx',       'name': 'Nginx'},
    {'id': 'sslh',        'name': 'SSLH'},
    {'id': 'awg-quick@awg0', 'name': 'AmneziaWG'},
]

def init_users():
    if not os.path.exists(USERS_FILE):
        raw_pw = os.environ.get('PRXY_PANEL_INIT_PASSWORD', '')
        if not raw_pw:
            raise RuntimeError(
                "PRXY_PANEL_INIT_PASSWORD env var not set. "
                "Set it in /etc/default/prxy-panel before first start."
            )
        pw = bcrypt.hashpw(raw_pw.encode(), bcrypt.gensalt()).decode()
        data = {'admin': {'password': pw, 'role': 'admin'}}
        with open(USERS_FILE, 'w') as f:
            json.dump(data, f)
        os.chmod(USERS_FILE, 0o600)

def load_users():
    with open(USERS_FILE) as f:
        return json.load(f)

def save_users(data):
    with open(USERS_FILE, 'w') as f:
        json.dump(data, f)

def check_password(stored, provided):
    return bcrypt.checkpw(provided.encode(), stored.encode())

def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if 'user' not in session:
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated

def admin_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if 'user' not in session:
            return redirect(url_for('login'))
        users = load_users()
        if users.get(session['user'], {}).get('role') != 'admin':
            return jsonify({'error': 'Access denied'}), 403
        return f(*args, **kwargs)
    return decorated

def run_cmd(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15)
        return r.stdout + r.stderr
    except Exception as e:
        return str(e)

def get_service_status(service_id):
    r = subprocess.run(['systemctl', 'is-active', service_id],
                       capture_output=True, text=True)
    return r.stdout.strip()

@app.route('/login', methods=['GET','POST'])
def login():
    error = None
    if request.method == 'POST':
        username = request.form.get('username','')
        password = request.form.get('password','')
        users = load_users()
        if username in users and check_password(users[username]['password'], password):
            session['user'] = username
            session['role'] = users[username]['role']
            return redirect(url_for('index'))
        error = 'Nepravilnyy login ili parol'
    return render_template('login.html', error=error)

@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))

@app.route('/')
@login_required
def index():
    return render_template('index.html', user=session['user'], role=session.get('role'))

@app.route('/api/stats')
@login_required
def api_stats():
    try:
        conn = sqlite3.connect(SMART_PROXY_DB)
        cur = conn.cursor()
        rows = cur.execute("SELECT decision, COUNT(*) FROM domains GROUP BY decision").fetchall()
        manual = cur.execute("SELECT COUNT(*) FROM manual_overrides").fetchone()[0]
        total = cur.execute("SELECT COUNT(*) FROM domains").fetchone()[0]
        conn.close()
        s = {r[0]: r[1] for r in rows}
        s['manual'] = manual
        s['total'] = total
        svc = {s['id']: get_service_status(s['id']) for s in SERVICES}
        return jsonify({'cache': s, 'services': svc})
    except Exception as e:
        return jsonify({'error': str(e)})

@app.route('/api/last_domains')
@login_required
def api_last_domains():
    try:
        if not os.path.exists(ACCESS_LOG):
            return jsonify({'lines': []})
        result = subprocess.run(['tail', '-30', ACCESS_LOG], capture_output=True, text=True)
        lines = []
        for line in result.stdout.strip().split('\n'):
            parts = line.split()
            if len(parts) >= 3:
                lines.append({'time': parts[0], 'decision': parts[1], 'domain': parts[2]})
        return jsonify({'lines': lines})
    except Exception as e:
        return jsonify({'error': str(e)})

@app.route('/api/manual_list')
@login_required
def api_manual_list():
    try:
        conn = sqlite3.connect(SMART_PROXY_DB)
        cur = conn.cursor()
        rows = cur.execute("SELECT domain, decision, added_at, reason FROM manual_overrides ORDER BY added_at DESC").fetchall()
        conn.close()
        result = [{'domain': r[0], 'decision': r[1], 'added_at': r[2], 'reason': r[3]} for r in rows]
        return jsonify({'items': result})
    except Exception as e:
        return jsonify({'error': str(e)})

@app.route('/api/domain_action', methods=['POST'])
@login_required
def api_domain_action():
    data = request.json
    action = data.get('action')
    domain = data.get('domain','').strip().lower()
    reason = data.get('reason','')
    if not domain:
        return jsonify({'error': 'Domain required'})
    write_actions = ['add-tunnel', 'add-direct', 'remove']
    if action in write_actions and session.get('role') != 'admin':
        return jsonify({'error': 'Access denied: admin only'})
    if action == 'add-tunnel':
        out = run_cmd(f'{SMART_PROXY_CTL} add-tunnel "{domain}" "{reason}"')
    elif action == 'add-direct':
        out = run_cmd(f'{SMART_PROXY_CTL} add-direct "{domain}" "{reason}"')
    elif action == 'remove':
        out = run_cmd(f'{SMART_PROXY_CTL} remove "{domain}"')
    elif action == 'recheck':
        out = run_cmd(f'{SMART_PROXY_CTL} recheck "{domain}"')
    elif action == 'status':
        out = run_cmd(f'{SMART_PROXY_CTL} status "{domain}"')
    else:
        return jsonify({'error': 'Unknown action'})
    return jsonify({'output': out})

@app.route('/api/service_logs')
@login_required
def api_service_logs():
    service = request.args.get('service','')
    lines = request.args.get('lines', '15')
    try:
        lines = int(lines)
    except:
        lines = 15
    if not service:
        return jsonify({'error': 'Service required'})
    out = run_cmd(f'journalctl -u "{service}" --no-pager -n {lines}')
    return jsonify({'output': out})

@app.route('/api/service_action', methods=['POST'])
@admin_required
def api_service_action():
    data = request.json
    service = data.get('service','')
    action = data.get('action','')
    if not service or action not in ('restart','stop','start'):
        return jsonify({'error': 'Invalid request'})
    out = run_cmd(f'sudo systemctl {action} "{service}"')
    status = get_service_status(service)
    return jsonify({'output': out, 'status': status})

@app.route('/api/services_status')
@login_required
def api_services_status():
    result = {}
    for s in SERVICES:
        result[s['id']] = get_service_status(s['id'])
    return jsonify(result)

@app.route('/api/stream_logs')
@login_required
def api_stream_logs():
    service = request.args.get('service','')
    if not service:
        return jsonify({'error': 'Service required'})
    def generate():
        proc = subprocess.Popen(
            ['journalctl', '-u', service, '-f', '--no-pager', '-n', '0'],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        try:
            for line in proc.stdout:
                yield f"data: {json.dumps({'line': line.rstrip()})}\n\n"
        finally:
            proc.terminate()
    return Response(stream_with_context(generate()),
                    content_type='text/event-stream',
                    headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'})

@app.route('/api/stream_domains')
@login_required
def api_stream_domains():
    def generate():
        if not os.path.exists(ACCESS_LOG):
            open(ACCESS_LOG, 'w').close()
        proc = subprocess.Popen(
            ['tail', '-f', ACCESS_LOG],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        try:
            for line in proc.stdout:
                parts = line.strip().split()
                if len(parts) >= 3:
                    data = {'time': parts[0], 'decision': parts[1], 'domain': parts[2]}
                    yield f"data: {json.dumps(data)}\n\n"
        finally:
            proc.terminate()
    return Response(stream_with_context(generate()),
                    content_type='text/event-stream',
                    headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'})

@app.route('/api/users', methods=['GET'])
@admin_required
def api_users_list():
    users = load_users()
    result = [{'username': u, 'role': d['role']} for u, d in users.items()]
    return jsonify({'users': result})

@app.route('/api/users/add', methods=['POST'])
@admin_required
def api_users_add():
    data = request.json
    username = data.get('username','').strip()
    password = data.get('password','')
    role = data.get('role', 'user')
    if not username or not password:
        return jsonify({'error': 'Username and password required'})
    users = load_users()
    if username in users:
        return jsonify({'error': 'User already exists'})
    pw = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
    users[username] = {'password': pw, 'role': role}
    save_users(users)
    return jsonify({'ok': True})

@app.route('/api/users/delete', methods=['POST'])
@admin_required
def api_users_delete():
    data = request.json
    username = data.get('username','')
    if username == 'admin':
        return jsonify({'error': 'Cannot delete admin'})
    users = load_users()
    if username not in users:
        return jsonify({'error': 'User not found'})
    del users[username]
    save_users(users)
    return jsonify({'ok': True})

@app.route('/api/users/change_password', methods=['POST'])
@login_required
def api_change_password():
    data = request.json
    target = data.get('username', session['user'])
    if target != session['user'] and session.get('role') != 'admin':
        return jsonify({'error': 'Access denied'})
    old_pw = data.get('old_password','')
    new_pw = data.get('new_password','')
    if not new_pw:
        return jsonify({'error': 'New password required'})
    users = load_users()
    if session.get('role') != 'admin' or target == session['user']:
        if not check_password(users[target]['password'], old_pw):
            return jsonify({'error': 'Wrong current password'})
    users[target]['password'] = bcrypt.hashpw(new_pw.encode(), bcrypt.gensalt()).decode()
    save_users(users)
    return jsonify({'ok': True})


# --- Subpath dispatcher (must be at the very end) ---
from werkzeug.middleware.dispatcher import DispatcherMiddleware
from werkzeug.wrappers import Response as _WResp

def _not_found(environ, start_response):
    return _WResp('Not Found', status=404)(environ, start_response)

if APPLICATION_ROOT and APPLICATION_ROOT != '/':
    app.wsgi_app = DispatcherMiddleware(_not_found, {APPLICATION_ROOT: app.wsgi_app})

if __name__ == '__main__':
    init_users()
    app.run(host='127.0.0.1', port=5001, debug=False)
