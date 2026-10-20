const APP_VERSION = "26.10.21";

let currentFileHandle = null;
let extraConfigState = null;
let hasLocalBackend = false;

const DEFAULT_PROCESSES = [
  "Antigravity.exe",
  "Antigravity IDE.exe",
  "Gemini.exe",
  "language_server_windows_x64.exe",
  "language_server.exe",
  "node.exe",
  "agy.exe"
];

function showToast(msg) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(showToast._timer);
  showToast._timer = setTimeout(() => el.classList.remove('show'), 2600);
}

function setMode(mode) {
  const isAdv = mode === 'advanced';
  document.body.classList.toggle('mode-advanced', isAdv);
  document.getElementById('btnSimple').classList.toggle('active', !isAdv);
  document.getElementById('btnAdvanced').classList.toggle('active', isAdv);
}

function applyPreset(type, host, port, presetId) {
  document.getElementById('proxyType').value = type;
  document.getElementById('proxyHost').value = host;
  document.getElementById('proxyPort').value = port;
  document.querySelectorAll('.preset-item').forEach(btn => {
    btn.classList.toggle('active', btn.id === presetId);
  });
  onFormChange();
}

function syncPresetHighlight() {
  const type = document.getElementById('proxyType').value;
  const host = document.getElementById('proxyHost').value.trim();
  const port = Number(document.getElementById('proxyPort').value);
  const map = {
    'socks5:127.0.0.1:10808': 'preset-v2ray-socks',
    'socks5:127.0.0.1:7890': 'preset-clash-socks',
    'http:127.0.0.1:10809': 'preset-v2ray-http',
    'http:127.0.0.1:7890': 'preset-clash-http'
  };
  const activeId = map[`${type}:${host}:${port}`] || '';
  document.querySelectorAll('.preset-item').forEach(btn => {
    btn.classList.toggle('active', btn.id === activeId);
  });
}

function onTargetCheckChange() {
  const lines = document.getElementById('targetProcesses').value
    .split(/\r?\n/)
    .map(s => s.trim())
    .filter(Boolean);
  const set = new Set(lines);

  const toggleProc = (checked, name) => {
    for (const item of Array.from(set)) {
      if (item.toLowerCase() === name.toLowerCase()) set.delete(item);
    }
    if (checked) set.add(name);
  };

  toggleProc(document.getElementById('chkGemini').checked, 'Gemini.exe');
  toggleProc(document.getElementById('chkAntigravity').checked, 'Antigravity.exe');
  toggleProc(document.getElementById('chkAntigravityIde').checked, 'Antigravity IDE.exe');

  ['language_server_windows_x64.exe', 'language_server.exe', 'node.exe', 'agy.exe'].forEach(p => {
    const exists = Array.from(set).some(x => x.toLowerCase() === p.toLowerCase());
    if (!exists) set.add(p);
  });

  document.getElementById('targetProcesses').value = Array.from(set).join('\n');
  onFormChange();
}

function syncCheckboxesFromProcessList(list) {
  const lower = new Set((list || []).map(s => String(s).toLowerCase()));
  document.getElementById('chkGemini').checked = lower.has('gemini.exe');
  document.getElementById('chkAntigravity').checked = lower.has('antigravity.exe');
  document.getElementById('chkAntigravityIde').checked = lower.has('antigravity ide.exe');
}

function buildConfigObject() {
  const type = document.getElementById('proxyType').value;
  const host = document.getElementById('proxyHost').value.trim() || '127.0.0.1';
  const port = Math.max(0, Math.min(65535, parseInt(document.getElementById('proxyPort').value, 10) || 10808));

  const allowedPortsRaw = document.getElementById('allowedPorts').value;
  const allowedPorts = allowedPortsRaw
    .split(/[,\s]+/)
    .map(s => parseInt(s.trim(), 10))
    .filter(n => Number.isInteger(n) && n >= 1 && n <= 65535);

  const procLines = document.getElementById('targetProcesses').value
    .split(/\r?\n/)
    .map(s => s.trim())
    .filter(Boolean);

  const base = extraConfigState ? JSON.parse(JSON.stringify(extraConfigState)) : {};

  const cfg = Object.assign({}, base, {
    _version: APP_VERSION,
    log_level: document.getElementById('logLevel').value,
    proxy: {
      host,
      port,
      type
    },
    fake_ip: {
      enabled: document.getElementById('fakeIpEnabled').value === 'true',
      cidr: document.getElementById('fakeIpCidr').value.trim() || '198.18.0.0/15'
    },
    timeout: {
      connect: parseInt(document.getElementById('connectTimeout').value, 10) || 5000,
      send: parseInt(document.getElementById('sendTimeout').value, 10) || 5000,
      recv: parseInt(document.getElementById('recvTimeout').value, 10) || 5000
    },
    proxy_rules: Object.assign({}, base.proxy_rules || {}, {
      allowed_ports: allowedPorts,
      dns_mode: document.getElementById('dnsMode').value,
      ipv6_mode: document.getElementById('ipv6Mode').value,
      udp_mode: document.getElementById('udpMode').value,
      udp_fallback: "block",
      routing: (base.proxy_rules && base.proxy_rules.routing) ? base.proxy_rules.routing : {
        enabled: true,
        priority_mode: "order",
        default_action: "proxy",
        use_default_private: true,
        rules: []
      }
    }),
    child_injection: true,
    child_injection_mode: "filtered",
    child_injection_exclude: [
      "GeminiCrashpadHandler.exe",
      "chrome_crashpad_handler.exe"
    ],
    target_processes: procLines.length ? procLines : DEFAULT_PROCESSES.slice(),
    traffic_logging: Boolean(base.traffic_logging),
    diagnostics: base.diagnostics || { agent_ip_probe: false },
    ui: {
      load_notify: document.getElementById('uiNotify').value
    },
    updates: base.updates || {
      enabled: false,
      check_delay_ms: 15000,
      timeout_ms: 5000,
      notify_once: true,
      allow_insecure_mirrors: true,
      mirrors: [
        "https://gh-proxy.org/",
        "https://hk.gh-proxy.org/",
        "https://cdn.gh-proxy.org/",
        "https://edgeone.gh-proxy.org/"
      ]
    }
  });

  return cfg;
}

function onFormChange() {
  syncPresetHighlight();
  const cfg = buildConfigObject();
  syncCheckboxesFromProcessList(cfg.target_processes);
  document.getElementById('summaryText').textContent = `${cfg.proxy.type}://${cfg.proxy.host}:${cfg.proxy.port}`;
  document.getElementById('jsonPreview').value = JSON.stringify(cfg, null, 2);
}

function applyConfigToForm(cfg) {
  extraConfigState = cfg;
  if (cfg.proxy) {
    document.getElementById('proxyType').value = (cfg.proxy.type || 'socks5').toLowerCase() === 'http' ? 'http' : 'socks5';
    document.getElementById('proxyHost').value = cfg.proxy.host || '127.0.0.1';
    document.getElementById('proxyPort').value = cfg.proxy.port ?? 10808;
  } else if (Array.isArray(cfg.proxies) && cfg.proxies.length > 0) {
    const p = cfg.proxies[0];
    document.getElementById('proxyType').value = (p.type || 'socks5').toLowerCase() === 'http' ? 'http' : 'socks5';
    document.getElementById('proxyHost').value = p.host || '127.0.0.1';
    document.getElementById('proxyPort').value = p.port ?? 10808;
  }
  if (cfg.log_level) {
    document.getElementById('logLevel').value = cfg.log_level;
  }
  if (cfg.ui && cfg.ui.load_notify) {
    document.getElementById('uiNotify').value = cfg.ui.load_notify;
  }
  if (cfg.fake_ip) {
    document.getElementById('fakeIpEnabled').value = cfg.fake_ip.enabled !== false ? 'true' : 'false';
    document.getElementById('fakeIpCidr').value = cfg.fake_ip.cidr || '198.18.0.0/15';
  }
  if (cfg.timeout) {
    document.getElementById('connectTimeout').value = cfg.timeout.connect || cfg.timeout.connect_ms || 5000;
    document.getElementById('sendTimeout').value = cfg.timeout.send || cfg.timeout.send_ms || 5000;
    document.getElementById('recvTimeout').value = cfg.timeout.recv || cfg.timeout.recv_ms || 5000;
  }
  if (cfg.proxy_rules) {
    if (Array.isArray(cfg.proxy_rules.allowed_ports)) {
      document.getElementById('allowedPorts').value = cfg.proxy_rules.allowed_ports.join(', ');
    }
    if (cfg.proxy_rules.dns_mode) document.getElementById('dnsMode').value = cfg.proxy_rules.dns_mode;
    if (cfg.proxy_rules.ipv6_mode) document.getElementById('ipv6Mode').value = cfg.proxy_rules.ipv6_mode;
    if (cfg.proxy_rules.udp_mode) document.getElementById('udpMode').value = cfg.proxy_rules.udp_mode;
  }
  const procs = Array.isArray(cfg.target_processes) && cfg.target_processes.length
    ? cfg.target_processes.slice()
    : DEFAULT_PROCESSES.slice();
  if (!procs.some(p => String(p).toLowerCase() === 'gemini.exe')) {
    procs.push('Gemini.exe');
  }
  document.getElementById('targetProcesses').value = procs.join('\n');
  syncCheckboxesFromProcessList(procs);
  onFormChange();
}

function updateDetectedTargetsUI(targets) {
  if (!Array.isArray(targets)) return;
  const map = {
    gemini: { tag: 'tagGemini', sub: 'subGemini' },
    antigravity: { tag: 'tagAntigravity', sub: 'subAntigravity' },
    antigravity_ide: { tag: 'tagAntigravityIde', sub: 'subAntigravityIde' }
  };
  targets.forEach(t => {
    const ui = map[t.key];
    if (!ui) return;
    const tagEl = document.getElementById(ui.tag);
    const subEl = document.getElementById(ui.sub);
    if (t.found) {
      tagEl.textContent = t.installed ? '已安装代理' : '已检测到软件';
      tagEl.classList.toggle('installed', Boolean(t.installed));
      subEl.textContent = t.directory;
    } else {
      tagEl.textContent = '本机未检测到';
      tagEl.classList.remove('installed');
    }
  });
}

async function probeLocalBackend() {
  if (!location.protocol.startsWith('http')) return;
  try {
    const res = await fetch('/api/status', { cache: 'no-store' });
    if (!res.ok) return;
    const data = await res.json();
    hasLocalBackend = true;
    document.getElementById('localBridgeBadge').style.display = 'inline-block';
    document.getElementById('btnSaveAndInstall').style.display = 'inline-block';
    document.getElementById('btnSaveOnly').textContent = '直接保存 config.json';
    if (data.config) {
      applyConfigToForm(data.config);
    }
    if (data.targets) {
      updateDetectedTargetsUI(data.targets);
    }
  } catch (_) {}
}

async function openConfigFile() {
  if (hasLocalBackend) {
    try {
      const res = await fetch('/api/status', { cache: 'no-store' });
      if (res.ok) {
        const data = await res.json();
        if (data.config) {
          applyConfigToForm(data.config);
          showToast('已重新读取本地 config.json');
          return;
        }
      }
    } catch (_) {}
  }
  if (window.showOpenFilePicker) {
    try {
      const [handle] = await window.showOpenFilePicker({
        types: [{ description: 'JSON 配置文件', accept: { 'application/json': ['.json'] } }]
      });
      currentFileHandle = handle;
      const file = await handle.getFile();
      const text = await file.text();
      applyConfigToForm(JSON.parse(text));
      showToast('已读取: ' + file.name);
      return;
    } catch (e) {
      if (e && e.name === 'AbortError') return;
    }
  }
  document.getElementById('fileInput').click();
}

function onFileSelected(event) {
  const file = event.target.files && event.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    try {
      applyConfigToForm(JSON.parse(String(reader.result)));
      showToast('已读取: ' + file.name);
    } catch (err) {
      alert('解析 JSON 失败: ' + err.message);
    }
  };
  reader.readAsText(file, 'utf-8');
  event.target.value = '';
}

async function saveConfigFile() {
  const content = document.getElementById('jsonPreview').value + '\n';
  if (hasLocalBackend) {
    try {
      const res = await fetch('/api/save', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: content
      });
      const data = await res.json();
      if (data.ok) {
        showToast('已直接保存到本地 config.json（双击 install.bat 即可安装）');
        return;
      }
      alert('保存失败: ' + (data.error || '未知错误'));
      return;
    } catch (err) {
      alert('请求本地服务失败: ' + err.message);
      return;
    }
  }
  if (currentFileHandle && currentFileHandle.createWritable) {
    try {
      const writable = await currentFileHandle.createWritable();
      await writable.write(content);
      await writable.close();
      showToast('已直接保存至 config.json（双击 install.bat 即可安装）');
      return;
    } catch (_) {}
  }
  if (window.showSaveFilePicker) {
    try {
      const handle = await window.showSaveFilePicker({
        suggestedName: 'config.json',
        types: [{ description: 'JSON 配置文件', accept: { 'application/json': ['.json'] } }]
      });
      currentFileHandle = handle;
      const writable = await handle.createWritable();
      await writable.write(content);
      await writable.close();
      showToast('config.json 已保存（双击 install.bat 即可安装）');
      return;
    } catch (e) {
      if (e && e.name === 'AbortError') return;
    }
  }
  const blob = new Blob([content], { type: 'application/json;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = 'config.json';
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
  showToast('已保存 config.json');
}

async function saveAndInstall() {
  if (!hasLocalBackend) return;
  const cfg = buildConfigObject();
  const selectedKeys = [];
  if (document.getElementById('chkGemini').checked) selectedKeys.push('gemini');
  if (document.getElementById('chkAntigravity').checked) selectedKeys.push('antigravity');
  if (document.getElementById('chkAntigravityIde').checked) selectedKeys.push('antigravity_ide');

  try {
    const res = await fetch('/api/install', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        config: cfg,
        targets: selectedKeys
      })
    });
    const data = await res.json();
    if (data.targets) {
      updateDetectedTargetsUI(data.targets);
    }
    if (data.ok) {
      showToast(data.message || '已保存并安装到勾选软件');
    } else {
      alert(data.message || '部分软件安装失败，请先关闭正在运行的目标软件后重试');
    }
  } catch (err) {
    alert('安装请求失败: ' + err.message);
  }
}

// 初始化默认进程列表与 JSON
document.getElementById('targetProcesses').value = DEFAULT_PROCESSES.join('\n');
onFormChange();
probeLocalBackend();
