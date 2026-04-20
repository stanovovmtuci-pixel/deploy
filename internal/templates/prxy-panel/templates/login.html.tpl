<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Proxy Panel - Login</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f0f2f5; display: flex; align-items: center; justify-content: center; min-height: 100vh; }
.login-box { background: #fff; border-radius: 8px; padding: 40px; width: 360px; box-shadow: 0 2px 12px rgba(0,0,0,0.1); }
h2 { text-align: center; margin-bottom: 28px; color: #303133; font-size: 20px; font-weight: 500; }
label { display: block; margin-bottom: 6px; color: #606266; font-size: 14px; }
input { width: 100%; padding: 10px 12px; border: 1px solid #dcdfe6; border-radius: 4px; font-size: 14px; color: #303133; outline: none; transition: border-color 0.2s; }
input:focus { border-color: #409eff; }
.form-group { margin-bottom: 20px; }
button { width: 100%; padding: 10px; background: #409eff; color: #fff; border: none; border-radius: 4px; font-size: 14px; cursor: pointer; transition: background 0.2s; }
button:hover { background: #66b1ff; }
.error { color: #f56c6c; font-size: 13px; margin-bottom: 16px; text-align: center; }
.title-line { text-align: center; color: #909399; font-size: 13px; margin-bottom: 24px; }
</style>
</head>
<body>
<div class="login-box">
  <h2>Proxy Panel</h2>
  <p class="title-line">Smart Proxy Management</p>
  {% if error %}<div class="error">{{ error }}</div>{% endif %}
  <form method="POST" action="{{ url_for('login') }}">
    <div class="form-group">
      <label>Login</label>
      <input type="text" name="username" placeholder="Username" autofocus>
    </div>
    <div class="form-group">
      <label>Password</label>
      <input type="password" name="password" placeholder="Password">
    </div>
    <button type="submit">Войти</button>
  </form>
</div>
</body>
</html>